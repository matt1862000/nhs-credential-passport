"""
Parse completion CSV for bulk issue. Supports canonical headers and common aliases
(ESR-style exports can be mapped via column names in the first row).
"""
import csv
import io
from dataclasses import dataclass
from datetime import date, datetime
from typing import Optional

from .models import CompletionRecord, CSTF_MODULES

MAX_CSV_BYTES = 2 * 1024 * 1024
MAX_DATA_ROWS = 2000

CODE_TO_NAME = {code: name for code, name in CSTF_MODULES if code != "non_cstf"}


def _norm(h: str) -> str:
    return h.strip().lower().replace(" ", "_").replace("-", "_")


# canonical_field -> accepted header forms (after _norm)
HEADER_ALIASES: dict[str, tuple[str, ...]] = {
    "staff_full_name": (
        "staff_full_name",
        "full_name",
        "employee_name",
        "staff_name",
        "name",
        "learner_name",
        "display_name",
    ),
    "staff_identifier": (
        "staff_identifier",
        "esr_id",
        "person_number",
        "employee_number",
        "nhs_number",
        "identifier",
        "assignment_number",
    ),
    "module_code": ("module_code", "cstf_code", "course_code", "training_code"),
    "module_name": (
        "module_name",
        "course_name",
        "training_name",
        "module",
        "course_title",
        "subject",
        "title",  # ESR Compliance & Competency export
    ),
    "completion_date": (
        "completion_date",
        "date_completed",
        "completed_on",
        "completion",
        "achieved_date",
    ),
    "expiry_date": (
        "expiry_date",
        "date_expires",
        "expires",
        "valid_until",
        "renew_by",
        "expiry",
    ),
    "issuing_trust_ods_code": (
        "issuing_trust_ods_code",
        "trust_ods",
        "ods_code",
        "ods",
        "organisation_code",
        "org_code",
        "employer_ods",
    ),
    "issuing_trust_name": (
        "issuing_trust_name",
        "trust_name",
        "trust",
        "organisation_name",
        "employer_name",
        "organization_name",
        "employer",
    ),
    # --- ESR "Compliance and Competency" (and similar) exports ---
    "esr_competency_name": ("competency_name",),
    "esr_person_line": ("last_updated_by",),
    "esr_awarded_by": ("awarded_by",),
    "date_last_awarded": ("date_last_awarded",),
    "date_start": ("date_start",),
    "certification_date": ("certification_date",),
    "esr_description": ("description",),
    "esr_vpd": ("vpd",),
}

_ALIAS_TO_CANONICAL: dict[str, str] = {}
for canonical, aliases in HEADER_ALIASES.items():
    for a in aliases:
        _ALIAS_TO_CANONICAL[_norm(a)] = canonical


def csv_template_header() -> str:
    return (
        "staff_full_name,staff_identifier,module_code,module_name,"
        "completion_date,expiry_date,issuing_trust_ods_code,issuing_trust_name\n"
    )


def _parse_date(raw: str) -> Optional[date]:
    s = (raw or "").strip()
    if not s:
        return None
    if "no expiry" in s.lower():
        return date(2099, 12, 31)
    fmts = (
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%d-%b-%Y",
        "%d-%b-%y",
        "%Y/%m/%d",
        "%Y-%m-%d",
        "%d/%m/%Y",
        "%d-%m-%Y",
        "%d/%m/%y",
        "%d-%m-%y",
    )
    candidates = [s, s[:19].strip(), s[:11].strip(), s[:10].strip()]
    seen: set[str] = set()
    for cand in candidates:
        if not cand or cand in seen:
            continue
        seen.add(cand)
        for fmt in fmts:
            try:
                return datetime.strptime(cand, fmt).date()
            except ValueError:
                continue
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def _esr_infer_module_display(row: dict[str, str]) -> str:
    """Same module text used for issuing — if empty, row is junk (e.g. blank line in export)."""

    def gx(k: str) -> str:
        v = row.get(k)
        if v is None:
            return ""
        return str(v).strip()

    bits = [
        gx("module_name"),
        _first_line(gx("esr_description")),
        _parse_esr_competency_cell(gx("esr_competency_name")),
    ]
    return next((b for b in bits if b), "")


def _parse_esr_competency_cell(raw: str) -> str:
    """Pipe-delimited ESR cell, e.g. NHS|CSTF|Fire Safety - 2 Years|."""
    t = (raw or "").strip().strip('"').strip()
    if not t:
        return ""
    parts = [p.strip() for p in t.split("|") if p.strip()]
    if len(parts) >= 3 and parts[0] in ("NHS", "457", "DEMO") and parts[1] in ("CSTF", "LOCAL"):
        return parts[2]
    if parts:
        return parts[-1]
    return t


def _first_line(text: str, limit: int = 240) -> str:
    line = (text or "").replace("\r\n", "\n").split("\n", 1)[0].strip()
    if len(line) > limit:
        return line[: limit - 3] + "..."
    return line


def _split_esr_assignment_line(raw: str) -> tuple[Optional[str], Optional[str]]:
    """ESR often uses 'ASSIGNMENT|Display Name'."""
    line = (raw or "").strip()
    if not line:
        return None, None
    if "|" in line:
        left, right = line.split("|", 1)
        left, right = left.strip(), right.strip()
        if right:
            return (left or None, right)
    return None, line


def _resolve_module(
    code_raw: Optional[str],
    name_raw: Optional[str],
    *,
    allow_non_cstf: bool = False,
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """Returns (module_code, module_name, error_fragment)."""
    code = (code_raw or "").strip()
    name = (name_raw or "").strip()
    if code and code in CODE_TO_NAME:
        canonical_name = CODE_TO_NAME[code]
        if name and name.lower() != canonical_name.lower():
            return code, canonical_name, None
        return code, canonical_name, None
    if name:
        nlow = name.lower()
        for c, title in CSTF_MODULES:
            if c == "non_cstf":
                continue
            if title.lower() == nlow:
                return c, title, None
        for c, title in CSTF_MODULES:
            if c == "non_cstf":
                continue
            if nlow in title.lower() or title.lower() in nlow:
                return c, title, None
        if allow_non_cstf:
            snippet = name.strip()
            if len(snippet) > 240:
                snippet = snippet[:237] + "..."
            return "non_cstf", snippet, None
        return None, None, f"unknown module '{name}'"
    if code:
        return None, None, f"unknown module_code '{code}'"
    return None, None, "module_code or module_name required"


@dataclass
class ParsedCsvRow:
    row_number: int  # 1-based file row (header = 1)
    record: Optional[CompletionRecord]
    error: Optional[str]


def _row_to_record(
    row: dict[str, str], *, is_esr_layout: bool = False
) -> tuple[Optional[CompletionRecord], Optional[str]]:
    def g(*keys: str) -> str:
        for k in keys:
            v = row.get(k)
            if v is not None and str(v).strip() != "":
                return str(v).strip()
        return ""

    if is_esr_layout:
        staff_identifier, staff_full_name = _split_esr_assignment_line(g("esr_person_line"))
        if not staff_full_name:
            staff_identifier, staff_full_name = _split_esr_assignment_line(g("esr_awarded_by"))
        if not staff_full_name:
            return None, "missing staff (Last Updated By or Awarded By)"

        module_display = _esr_infer_module_display(row)
        if not module_display:
            return None, "missing module (Title, Description, or Competency Name)"

        module_code = g("module_code")
        mc, mn, mod_err = _resolve_module(
            module_code or None, module_display, allow_non_cstf=True
        )
        if mod_err:
            return None, mod_err

        completion_s = (
            g("completion_date")
            or g("date_last_awarded")
            or g("date_start")
            or g("certification_date")
        )
        expiry_s = g("expiry_date")
        ods = g("issuing_trust_ods_code") or g("esr_vpd") or "ESR"
        trust_name = g("issuing_trust_name") or (
            f"Employer ref {ods} (from ESR export)" if ods else "ESR import"
        )

        miss = []
        if not completion_s:
            miss.append("completion date (e.g. Date Last Awarded / Date Start)")
        if not expiry_s:
            miss.append("Expiry Date")
        if miss:
            return None, "missing: " + ", ".join(miss)

        completion_date = _parse_date(completion_s)
        expiry_date = _parse_date(expiry_s)
        if not completion_date:
            return None, f"bad completion date: {completion_s!r}"
        if not expiry_date:
            return None, f"bad expiry date: {expiry_s!r}"

        sid = (staff_identifier or "").strip() or (staff_full_name[:48] if staff_full_name else "unknown")
        try:
            rec = CompletionRecord(
                staff_full_name=staff_full_name,
                staff_identifier=sid,
                module_code=mc or "",
                module_name=mn or "",
                completion_date=completion_date,
                expiry_date=expiry_date,
                issuing_trust_ods_code=ods[:48],
                issuing_trust_name=trust_name[:240] if len(trust_name) > 240 else trust_name,
            )
            return rec, None
        except Exception as e:
            return None, str(e)

    staff_full_name = g("staff_full_name")
    staff_identifier = g("staff_identifier")
    module_code = g("module_code")
    module_name = g("module_name")
    completion_s = g("completion_date")
    expiry_s = g("expiry_date")
    ods = g("issuing_trust_ods_code")
    trust_name = g("issuing_trust_name")

    missing = [
        label
        for label, val in (
            ("staff_full_name", staff_full_name),
            ("staff_identifier", staff_identifier),
            ("completion_date", completion_s),
            ("expiry_date", expiry_s),
            ("issuing_trust_ods_code", ods),
            ("issuing_trust_name", trust_name),
        )
        if not val
    ]
    if missing:
        return None, "missing: " + ", ".join(missing)

    mc, mn, mod_err = _resolve_module(module_code or None, module_name or None)
    if mod_err:
        return None, mod_err

    completion_date = _parse_date(completion_s)
    expiry_date = _parse_date(expiry_s)
    if not completion_date:
        return None, f"bad completion_date: {completion_s!r}"
    if not expiry_date:
        return None, f"bad expiry_date: {expiry_s!r}"

    try:
        rec = CompletionRecord(
            staff_full_name=staff_full_name,
            staff_identifier=staff_identifier,
            module_code=mc or "",
            module_name=mn or "",
            completion_date=completion_date,
            expiry_date=expiry_date,
            issuing_trust_ods_code=ods,
            issuing_trust_name=trust_name,
        )
        return rec, None
    except Exception as e:
        return None, str(e)


def parse_completion_csv(text: str) -> tuple[list[ParsedCsvRow], Optional[str]]:
    """
    Returns (parsed_rows, fatal_error). Each data row is a ParsedCsvRow.
    fatal_error is set if headers are unusable.
    """
    if len(text.encode("utf-8")) > MAX_CSV_BYTES:
        return [], "file too large"

    stream = io.StringIO(text)
    reader = csv.reader(stream)
    try:
        header_cells = next(reader)
    except StopIteration:
        return [], "empty file"

    col_map: dict[int, str] = {}
    seen_canonical: set[str] = set()
    for i, cell in enumerate(header_cells):
        key = _norm(cell)
        if not key:
            continue
        canonical = _ALIAS_TO_CANONICAL.get(key)
        if canonical:
            if canonical in seen_canonical:
                return [], f"duplicate column for {canonical}"
            seen_canonical.add(canonical)
            col_map[i] = canonical

    present = set(col_map.values())
    is_esr_layout = "esr_competency_name" in present

    if is_esr_layout:
        if "expiry_date" not in present:
            return [], "ESR export: missing Expiry Date column"
        if "esr_vpd" not in present:
            return [], "ESR export: missing VPD column"
        if not (
            present & {"module_name", "esr_description", "esr_competency_name"}
        ):
            return [], "ESR export: need at least one of Title, Description, or Competency Name"
        if not (
            present & {"date_last_awarded", "date_start", "certification_date", "completion_date"}
        ):
            return [], "ESR export: need a completion column (e.g. Date Last Awarded or Date Start)"
        if "esr_person_line" not in present and not (
            {"staff_full_name", "staff_identifier"} <= present
        ):
            return [], "ESR export: missing Last Updated By (or staff name / ID columns)"
    else:
        required = set(HEADER_ALIASES.keys()) - {
            "module_code",
            "module_name",
            "esr_competency_name",
            "esr_person_line",
            "esr_awarded_by",
            "date_last_awarded",
            "date_start",
            "certification_date",
            "esr_description",
            "esr_vpd",
        }
        if not ({"module_code"} & present or {"module_name"} & present):
            return [], "CSV must include module_code and/or module_name column"
        if not required.issubset(present):
            return [], "missing required columns: " + ", ".join(sorted(required - present))

    out: list[ParsedCsvRow] = []
    data_row_index = 0
    for file_row_num, cells in enumerate(reader, start=2):
        if all(not (c or "").strip() for c in cells):
            continue
        row_dict: dict[str, str] = {}
        for col_idx, canonical in col_map.items():
            if col_idx < len(cells):
                row_dict[canonical] = cells[col_idx]
            else:
                row_dict[canonical] = ""
        if is_esr_layout and not _esr_infer_module_display(row_dict):
            continue
        data_row_index += 1
        if data_row_index > MAX_DATA_ROWS:
            out.append(
                ParsedCsvRow(
                    row_number=file_row_num,
                    record=None,
                    error=f"row limit ({MAX_DATA_ROWS}) exceeded; truncate file",
                )
            )
            break
        rec, err = _row_to_record(row_dict, is_esr_layout=is_esr_layout)
        out.append(ParsedCsvRow(row_number=file_row_num, record=rec, error=err))

    return out, None
