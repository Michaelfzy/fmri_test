[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutputDir,
    [string]$Heuristic,
    [string]$CondaEnv,
    [string[]]$Subject,
    [switch]$Run,
    [switch]$SkipValidator,
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if (-not $OutputDir) {
    $OutputDir = Join-Path $Root "bids"
}
if (-not $Heuristic) {
    $Heuristic = Join-Path $Root "code\heuristic_adni.py"
}

function Resolve-CondaEnvPath {
    param([Parameter(Mandatory)][string]$NameOrPath)

    if (Test-Path -LiteralPath $NameOrPath -PathType Container) {
        return (Resolve-Path -LiteralPath $NameOrPath).Path
    }

    $envInfo = conda env list --json | ConvertFrom-Json
    $match = $envInfo.envs | Where-Object { (Split-Path $_ -Leaf) -eq $NameOrPath } | Select-Object -First 1
    if (-not $match) {
        throw "Conda environment not found: $NameOrPath"
    }
    return $match
}

function Enable-CondaEnvTools {
    param([Parameter(Mandatory)][string]$NameOrPath)

    $envPath = Resolve-CondaEnvPath $NameOrPath
    $toolDirs = @(
        (Join-Path $envPath "Scripts"),
        (Join-Path $envPath "Library\bin"),
        (Join-Path $envPath "Lib\site-packages\bin")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    $env:PATH = (($toolDirs + @($env:PATH)) -join [IO.Path]::PathSeparator)
    return $envPath
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Content -join [Environment]::NewLine) + [Environment]::NewLine), $utf8NoBom)
}

if ($CondaEnv) {
    $resolvedCondaEnv = Resolve-CondaEnvPath $CondaEnv
    Write-Host "Using Conda environment: $resolvedCondaEnv"
    $condaRunEnvArgs = @("-p", $resolvedCondaEnv)
}

function ConvertTo-BidsSubject {
    param([Parameter(Mandatory)][string]$AdniSubject)
    return ($AdniSubject -replace "[^A-Za-z0-9]", "")
}

function ConvertTo-BidsSession {
    param([Parameter(Mandatory)][string]$AdniDateFolder)
    if ($AdniDateFolder -notmatch "^(\d{4})-(\d{2})-(\d{2})") {
        throw "Cannot parse ADNI date folder '$AdniDateFolder'. Expected YYYY-MM-DD_*."
    }
    return "$($Matches[1])$($Matches[2])$($Matches[3])"
}

function Get-AdniSeries {
    param(
        [Parameter(Mandatory)][string]$ModalityRoot,
        [Parameter(Mandatory)][string]$AdniSubject
    )

    $subjectDir = Join-Path $ModalityRoot $AdniSubject
    if (-not (Test-Path -LiteralPath $subjectDir -PathType Container)) {
        return @()
    }

    $dicomFiles = Get-ChildItem -LiteralPath $subjectDir -Recurse -File -Filter "*.dcm"
    $leafDirs = $dicomFiles | Group-Object DirectoryName

    foreach ($leaf in $leafDirs) {
        $dir = $leaf.Name
        $relative = $dir.Substring($subjectDir.Length).TrimStart("\", "/")
        $parts = $relative -split "[\\/]"
        if ($parts.Count -lt 3) {
            Write-Warning "Skipping unexpected ADNI path: $dir"
            continue
        }

        [PSCustomObject]@{
            Path = $dir
            Series = $parts[0]
            DateFolder = $parts[1]
            Session = ConvertTo-BidsSession $parts[1]
            ImageId = $parts[2]
            Count = $leaf.Count
        }
    }
}

function Write-BidsMetadata {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string]$BidsRoot
    )

    New-Item -ItemType Directory -Path $BidsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $BidsRoot "code") -Force | Out-Null

    $datasetDescription = [ordered]@{
        Name = "ADNI T1w and resting-state fMRI BIDS conversion"
        BIDSVersion = "1.9.0"
        DatasetType = "raw"
        Authors = @("ADNI", "Local conversion with HeuDiConv")
        HowToAcknowledge = "Original DICOM data were downloaded from the ADNI database."
    }
    $datasetDescriptionLines = $datasetDescription | ConvertTo-Json -Depth 4
    Write-Utf8NoBom -Path (Join-Path $BidsRoot "dataset_description.json") -Content $datasetDescriptionLines

    $participants = $Rows |
        Sort-Object BidsSubject -Unique |
        ForEach-Object { [PSCustomObject]@{ participant_id = "sub-$($_.BidsSubject)"; adni_subject_id = $_.AdniSubject } }
    $participantLines = $participants |
        ConvertTo-Csv -Delimiter "`t" -NoTypeInformation |
        ForEach-Object { $_ -replace '"', "" }
    Write-Utf8NoBom -Path (Join-Path $BidsRoot "participants.tsv") -Content $participantLines

    $participantsJson = [ordered]@{
        adni_subject_id = [ordered]@{
            Description = "Original ADNI subject identifier before BIDS label sanitization."
        }
    } | ConvertTo-Json -Depth 4
    Write-Utf8NoBom -Path (Join-Path $BidsRoot "participants.json") -Content $participantsJson

    $mapLines = $Rows |
        Sort-Object AdniSubject, Session |
        ConvertTo-Csv -Delimiter "`t" -NoTypeInformation |
        ForEach-Object { $_ -replace '"', "" }
    Write-Utf8NoBom -Path (Join-Path $BidsRoot "code\adni_id_map.tsv") -Content $mapLines

    $readme = @(
        "ADNI T1w and resting-state fMRI BIDS conversion",
        "",
        "This raw BIDS dataset was converted from ADNI DICOM exports stored in sibling anat/ and func/ folders.",
        "BIDS subject labels remove underscores from the original ADNI identifiers, and session labels use the scan date as ses-YYYYMMDD.",
        "The functional scans are ADNI eyes-open resting-state fMRI and are labeled task-rest.",
        "The file bids/code/adni_id_map.tsv records the original ADNI subject IDs, image IDs, session dates, and DICOM counts used for conversion."
    )
    Write-Utf8NoBom -Path (Join-Path $BidsRoot "README") -Content $readme
}

function Repair-BidsOutputs {
    param([Parameter(Mandatory)][string]$BidsRoot)

    Get-ChildItem -LiteralPath $BidsRoot -Recurse -File -Filter "*_task-rest_events.tsv" |
        ForEach-Object {
            $_.IsReadOnly = $false
            Remove-Item -LiteralPath $_.FullName -Force
        }

    Get-ChildItem -LiteralPath $BidsRoot -Recurse -File -Filter "*task-rest_bold.json" |
        ForEach-Object {
            $json = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            $json.TaskName = "rest"
            if ($json.PSObject.Properties.Name -contains "CogAtlasID" -and $json.CogAtlasID -like "*TODO*") {
                $json.PSObject.Properties.Remove("CogAtlasID")
            }
            $_.IsReadOnly = $false
            $lines = $json | ConvertTo-Json -Depth 20
            Write-Utf8NoBom -Path $_.FullName -Content $lines
        }
}

$anatRoot = Join-Path $Root "anat"
$funcRoot = Join-Path $Root "func"

foreach ($required in @($anatRoot, $funcRoot, $Heuristic)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required path not found: $required"
    }
}

$anatSubjects = Get-ChildItem -LiteralPath $anatRoot -Directory | Select-Object -ExpandProperty Name
$funcSubjects = Get-ChildItem -LiteralPath $funcRoot -Directory | Select-Object -ExpandProperty Name
$candidateSubjects = $anatSubjects | Where-Object { $funcSubjects -contains $_ } | Sort-Object

if ($Subject) {
    $candidateSubjects = $candidateSubjects | Where-Object { $Subject -contains $_ -or $Subject -contains (ConvertTo-BidsSubject $_) }
}

if (-not $candidateSubjects) {
    throw "No matched ADNI subjects found under anat/ and func/."
}

$planRows = @()
$hasFatalProblem = $false

foreach ($adniSubject in $candidateSubjects) {
    $anatSeries = @(Get-AdniSeries -ModalityRoot $anatRoot -AdniSubject $adniSubject)
    $funcSeries = @(Get-AdniSeries -ModalityRoot $funcRoot -AdniSubject $adniSubject)

    if ($anatSeries.Count -ne 1 -or $funcSeries.Count -ne 1) {
        Write-Warning "$adniSubject expected exactly one anat and one func series; found anat=$($anatSeries.Count), func=$($funcSeries.Count)."
        $hasFatalProblem = $true
        continue
    }

    if ($anatSeries[0].Session -ne $funcSeries[0].Session) {
        Write-Warning "$adniSubject has mismatched sessions: anat=$($anatSeries[0].Session), func=$($funcSeries[0].Session)."
        $hasFatalProblem = $true
        continue
    }

    if ($anatSeries[0].Count -lt 150 -or $anatSeries[0].Count -gt 220) {
        Write-Warning "$adniSubject T1 DICOM count is unusual: $($anatSeries[0].Count)"
    }
    if ($funcSeries[0].Count -lt 120 -or $funcSeries[0].Count -gt 260) {
        Write-Warning "$adniSubject rs-fMRI DICOM count is unusual: $($funcSeries[0].Count)"
    }

    $bidsSubject = ConvertTo-BidsSubject $adniSubject
    $planRows += [PSCustomObject]@{
        AdniSubject = $adniSubject
        BidsSubject = $bidsSubject
        Session = $anatSeries[0].Session
        AnatSeries = $anatSeries[0].Series
        AnatImageId = $anatSeries[0].ImageId
        AnatDicomCount = $anatSeries[0].Count
        FuncSeries = $funcSeries[0].Series
        FuncImageId = $funcSeries[0].ImageId
        FuncDicomCount = $funcSeries[0].Count
    }
}

if ($hasFatalProblem) {
    throw "Fatal input problems detected. Fix the source layout or pass a narrower -Subject list."
}

Write-Host ""
Write-Host "ADNI to BIDS conversion plan:"
$planRows | Format-Table -AutoSize

if (-not $Run) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Run to invoke HeuDiConv."
    exit 0
}

Write-BidsMetadata -Rows $planRows -BidsRoot $OutputDir

foreach ($row in $planRows) {
    $anatSeries = @(Get-AdniSeries -ModalityRoot $anatRoot -AdniSubject $row.AdniSubject)[0]
    $funcSeries = @(Get-AdniSeries -ModalityRoot $funcRoot -AdniSubject $row.AdniSubject)[0]

    $heudiconvArgs = @(
        "--files", $anatSeries.Path, $funcSeries.Path,
        "-s", $row.BidsSubject,
        "-ss", $row.Session,
        "-f", $Heuristic,
        "-c", "dcm2niix",
        "-b",
        "-o", $OutputDir
    )

    if ($Overwrite) {
        $heudiconvArgs += "--overwrite"
    }

    Write-Host ""
    Write-Host "Running HeuDiConv for sub-$($row.BidsSubject), ses-$($row.Session)"
    if ($CondaEnv) {
        & conda run --no-capture-output @condaRunEnvArgs heudiconv @heudiconvArgs
    }
    else {
        & heudiconv @heudiconvArgs
    }
    if ($LASTEXITCODE -ne 0) {
        throw "HeuDiConv failed for $($row.AdniSubject) with exit code $LASTEXITCODE."
    }
}

Repair-BidsOutputs -BidsRoot $OutputDir

if (-not $SkipValidator) {
    Write-Host ""
    Write-Host "Running BIDS validator..."
    if ($CondaEnv) {
        & conda run --no-capture-output @condaRunEnvArgs bids-validator $OutputDir
    }
    else {
        & bids-validator $OutputDir
    }
    if ($LASTEXITCODE -ne 0) {
        throw "BIDS validator reported problems. Review the messages above."
    }
}
