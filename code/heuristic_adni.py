"""HeuDiConv heuristic for the local ADNI T1w + resting-state fMRI export.

Expected BIDS labels are supplied by run_heudiconv_adni.ps1:
  subject: 013S6725
  session: 20190822
"""

try:
    from nipype.interfaces.base import CommandLine

    CommandLine.set_default_terminal_output("allatonce")
except Exception:
    pass


def create_key(template, outtype=("nii.gz",), annotation_classes=None):
    if template is None or not template:
        raise ValueError("Template must be a valid format string")
    return template, outtype, annotation_classes


t1w = create_key(
    "sub-{subject}/{session}/anat/sub-{subject}_{session}_T1w"
)

rest_bold = create_key(
    "sub-{subject}/{session}/func/sub-{subject}_{session}_task-rest_bold"
)


def _as_text(*values):
    return " ".join(str(value or "") for value in values).lower()


def _get(seqinfo, name, default=None):
    return getattr(seqinfo, name, default)


def infotodict(seqinfo):
    """Map ADNI DICOM series to BIDS outputs."""
    info = {t1w: [], rest_bold: []}

    for series in seqinfo:
        description = _as_text(
            _get(series, "series_description"),
            _get(series, "protocol_name"),
            _get(series, "image_type"),
        )
        dim4 = _get(series, "dim4", 1) or 1
        nfiles = _get(series, "total_files_till_now", 0) or 0
        series_id = _get(series, "series_id")

        is_t1 = (
            ("mprage" in description or "t1" in description)
            and "rsfmri" not in description
            and "bold" not in description
            and int(dim4) <= 1
        )

        is_rest = (
            ("rsfmri" in description or "rest" in description)
            and ("eyes" in description or "bold" in description or int(dim4) > 1 or nfiles > 100)
        )

        if is_t1:
            info[t1w].append(series_id)
        elif is_rest:
            info[rest_bold].append(series_id)

    return info
