# ADNI DICOM to BIDS with HeuDiConv

This workspace contains ADNI DICOM exports split into `anat/` and `func/`.
The conversion writes BIDS output to `bids/` without moving or renaming the raw DICOM files.

## Environment

```powershell
conda create -n adni-heudiconv -c conda-forge heudiconv dcm2niix bids-validator
conda activate adni-heudiconv
```

This machine also has an existing `heudiconv` Conda environment. Use `-CondaEnv heudiconv`
if the tools are not visible in the active PowerShell `PATH`.

## Dry run

```powershell
.\code\run_heudiconv_adni.ps1
```

## Convert all matched subjects

```powershell
.\code\run_heudiconv_adni.ps1 -Run
```

## Convert one subject first

```powershell
.\code\run_heudiconv_adni.ps1 -Subject 013_S_6725 -Run
```

Using a named Conda environment:

```powershell
.\code\run_heudiconv_adni.ps1 -Subject 013_S_6725 -Run -CondaEnv heudiconv
```

## Validate later

```powershell
bids-validator F:\fmri_project\test_data\bids
```
