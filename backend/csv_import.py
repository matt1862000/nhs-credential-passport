"""
Parse completion CSV for bulk issue. Supports canonical headers and common aliases
(ESR-style exports can be mapped via column names in the first row).
"""
import csv
import io
import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Optional

# Rows filtered as another person's training (team / trust-wide ESR export).
SKIP_OTHER_PERSON = "SKIP:other_person"
SKIP_TEAM_ROW_NO_STAFF = "SKIP:team_export_row_without_staff"

from .models import CompletionRecord, CSTF_MODULES

MAX_CSV_BYTES = 2 * 1024 * 1024
MAX_CSV_EVIDENCE_BYTES = 10 * 1024 * 1024  # screenshot / PDF of ESR (or similar)
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
    "esr_competency_name": (
        "competency_name",
        "competency",
        "competency_title",
        "competencyname",
        "mandatory_training_competency",
        "core_competency",
        "competancy_name",
    ),
    "esr_person_line": (
        "last_updated_by",
        "last_updated",
        "updated_by",
        "person",
        "employee",
        "learner",
        "user_name",
        "username",
    ),
    "esr_awarded_by": ("awarded_by", "awarded", "award_by"),
    "esr_acquired_by": ("acquired_by", "acquired"),
    "esr_measured_by": ("measured_by", "measured"),
    "date_last_awarded": ("date_last_awarded", "last_awarded", "date_awarded"),
    "date_start": ("date_start", "start_date", "started"),
    "certification_date": ("certification_date", "certified", "cert_date"),
    "next_review_date": ("next_review_date", "review_date", "renewal_date"),
    "esr_description": ("description", "desc", "details"),
    "esr_vpd": ("vpd", "organisation_vpd", "org_vpd", "employer_vpd"),
    "compliance_status": ("compliance_status", "status", "rag_status"),
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
    """Pipe-delimited ESR cell, e.g. NHS|CSTF|Fire Safety - 2 Years| or 457|LOCAL|Title|."""
    t = (raw or "").strip().strip('"').strip()
    if not t:
        return ""
    parts = [p.strip() for p in t.split("|") if p.strip()]
    if len(parts) >= 3 and parts[1].upper() in ("CSTF", "LOCAL", "CORE", "MANDATORY"):
        return parts[2]
    if len(parts) >= 3 and parts[0].upper() in ("NHS", "457", "DEMO") and re.match(r"^[A-Z0-9]{2,6}$", parts[0], re.I):
        return parts[2] if len(parts) > 2 else parts[-1]
    if parts:
        return parts[-1]
    return t


def _cstf_match_order() -> list[tuple[str, str]]:
    """Safeguarding levels 3→1 first so generic 'safeguarding' substring does not latch Level 1."""
    sg = [(c, t) for c, t in CSTF_MODULES if c.startswith("safeguarding_level_")]
    sg.sort(key=lambda x: int(x[0].rsplit("_", 1)[-1]), reverse=True)
    rest = [(c, t) for c, t in CSTF_MODULES if not c.startswith("safeguarding_level_") and c != "non_cstf"]
    return sg + rest


def _infer_cstf_synonym(name_raw: str) -> tuple[Optional[str], Optional[str]]:
    """Map messy ESR / trust competency text onto CSTF codes (Fire, BLS/CPR/resus, Safeguarding L1–3)."""
    name = (name_raw or "").strip()
    if not name:
        return None, None
    n = name.lower()

    if re.search(
        r"fire\s*(safety|awareness|warden|marshal|marshall|extinguisher|drill|prevention|risk|training|e\-?learning|aware)",
        n,
    ) or re.search(r"\b(fire\s+safety|fire\s+awareness)\b", n):
        return "fire_safety", CODE_TO_NAME["fire_safety"]

    if re.search(r"\bbls\b", n) or "basic life support" in n:
        return "resuscitation", CODE_TO_NAME["resuscitation"]
    if re.search(r"\b(cpr|cardiopulmonary\s+resuscitation)\b", n) and (
        "adult" in n
        or "basic" in n
        or "training" in n
        or "resus" in n
        or "immediate" in n
        or "life support" in n
        or "aed" in n
    ):
        return "resuscitation", CODE_TO_NAME["resuscitation"]
    if re.search(r"\b(als|ils)\b", n) or "advanced life support" in n or "immediate life support" in n:
        return "resuscitation", CODE_TO_NAME["resuscitation"]
    if "resuscitation" in n or ("life support" in n and "safeguarding" not in n and "mental health" not in n):
        return "resuscitation", CODE_TO_NAME["resuscitation"]

    sg_kw = ("safeguarding", "child protection", "adult protection")
    if any(k in n for k in sg_kw):
        lev: Optional[int] = None
        m = re.search(r"(?:level|l\.?)\s*([123])\b", n, re.I)
        if m:
            lev = int(m.group(1))
        if lev is None:
            m2 = re.search(r"\b([123])\s*(?:st|nd|rd)?\s*level\b", n, re.I)
            if m2:
                lev = int(m2.group(1))
        if lev == 1:
            return "safeguarding_level_1", CODE_TO_NAME["safeguarding_level_1"]
        if lev == 2:
            return "safeguarding_level_2", CODE_TO_NAME["safeguarding_level_2"]
        if lev == 3:
            return "safeguarding_level_3", CODE_TO_NAME["safeguarding_level_3"]

    return None, None


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
        if left:
            return (left, None)
    return None, line


@dataclass
class ImportProfileContext:
    """Signed-in user profile — scopes ESR import to their training only."""

    display_name: str = ""
    staff_identifier: str = ""  # GMC or ESR person number
    current_trust: str = ""
    personal_scope: bool = True  # when True, skip other people's rows in team exports


def _normalize_gmc_digits(raw: str) -> str:
    return re.sub(r"\D", "", raw or "")


def _profile_matches_staff(
    profile: ImportProfileContext,
    staff_name: Optional[str],
    staff_identifier: Optional[str],
) -> bool:
    """True if this CSV row appears to belong to the signed-in user."""
    if not profile.personal_scope:
        return True
    pname = (profile.display_name or "").strip().lower()
    pgmc = _normalize_gmc_digits(profile.staff_identifier)
    sname = (staff_name or "").strip().lower()
    sid = (staff_identifier or "").strip()
    sid_digits = _normalize_gmc_digits(sid)
    hay = (sname + " " + sid).lower()

    if pgmc and len(pgmc) >= 7:
        gmc7 = pgmc[-7:]
        if sid_digits.endswith(gmc7) or gmc7 in _normalize_gmc_digits(hay):
            return True
        if gmc7 in hay:
            return True

    if pname and sname:
        if pname in sname or sname in pname:
            return True
        # "Surname, Title Forename" vs "Forename Surname"
        if "," in pname:
            surname = pname.split(",", 1)[0].strip()
            if len(surname) > 2 and surname in sname:
                return True
        parts = [p for p in re.split(r"[\s,]+", pname) if len(p) > 2]
        if parts and all(p in sname for p in parts[:2]):
            return True

    if not pname and not pgmc:
        return True
    return False


def _extract_esr_staff_from_row(row: dict[str, str]) -> tuple[Optional[str], Optional[str]]:
    """Try common ESR person columns in priority order."""
    plain_name = (row.get("staff_full_name") or "").strip()
    plain_id = (row.get("staff_identifier") or "").strip()
    if plain_name and "|" not in plain_name:
        return plain_id or None, plain_name

    for key in ("esr_person_line", "esr_awarded_by", "esr_acquired_by", "esr_measured_by"):
        sid, sname = _split_esr_assignment_line(row.get(key, ""))
        if sname:
            return sid, sname
        if sid:
            return sid, None
    return plain_id or None, plain_name or None


def _scan_esr_distinct_staff(row_dicts: list[dict[str, str]]) -> int:
    names: set[str] = set()
    for row in row_dicts:
        _, sname = _extract_esr_staff_from_row(row)
        if sname:
            names.add(sname.lower())
    return len(names)


def _resolve_esr_staff(
    row: dict[str, str],
    profile: Optional[ImportProfileContext],
    *,
    multi_person_export: bool,
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """
    Returns (staff_identifier, staff_full_name, error_or_skip_token).
  error_or_skip_token may be SKIP_OTHER_PERSON or SKIP_TEAM_ROW_NO_STAFF.
    """
    staff_identifier, staff_full_name = _extract_esr_staff_from_row(row)

    if profile and profile.personal_scope:
        if staff_full_name or staff_identifier:
            if not _profile_matches_staff(profile, staff_full_name, staff_identifier):
                return None, None, SKIP_OTHER_PERSON
            staff_identifier = profile.staff_identifier.strip() or staff_identifier
            staff_full_name = profile.display_name.strip() or staff_full_name
        elif multi_person_export:
            return None, None, SKIP_TEAM_ROW_NO_STAFF
        elif profile.display_name or profile.staff_identifier:
            staff_identifier = profile.staff_identifier.strip() or staff_identifier
            staff_full_name = profile.display_name.strip() or staff_full_name
        else:
            return None, None, "missing staff (no person column and profile incomplete)"

    if not staff_full_name:
        if staff_identifier:
            staff_full_name = staff_identifier
        else:
            return None, None, "missing staff (person name or assignment column)"

    sid = (staff_identifier or "").strip() or (
        staff_full_name[:48] if staff_full_name else "unknown"
    )
    return sid, staff_full_name, None


def _detect_esr_layout(present: set[str]) -> bool:
    """Recognise ESR Compliance & Competency exports and close variants."""
    has_expiry = "expiry_date" in present
    has_completion = bool(
        present
        & {"date_last_awarded", "date_start", "certification_date", "completion_date"}
    )
    has_module = bool(present & {"module_name", "esr_description", "esr_competency_name"})
    has_staff = bool(
        present
        & {
            "esr_person_line",
            "esr_awarded_by",
            "esr_acquired_by",
            "esr_measured_by",
            "staff_full_name",
            "staff_identifier",
        }
    )
    if "esr_competency_name" in present and has_expiry:
        return True
    if has_expiry and has_completion and has_module:
        return True
    return False


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
        syn_c, syn_n = _infer_cstf_synonym(name)
        if syn_c and syn_n:
            return syn_c, syn_n, None
        nlow = name.lower()
        for c, title in _cstf_match_order():
            if title.lower() == nlow:
                return c, title, None
        for c, title in _cstf_match_order():
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
    skipped: bool = False


def _row_to_record(
    row: dict[str, str],
    *,
    is_esr_layout: bool = False,
    profile: Optional[ImportProfileContext] = None,
    multi_person_export: bool = False,
) -> tuple[Optional[CompletionRecord], Optional[str], bool]:
    def g(*keys: str) -> str:
        for k in keys:
            v = row.get(k)
            if v is not None and str(v).strip() != "":
                return str(v).strip()
        return ""

    if is_esr_layout:
        staff_identifier, staff_full_name, staff_err = _resolve_esr_staff(
            row, profile, multi_person_export=multi_person_export
        )
        if staff_err:
            skipped = staff_err.startswith("SKIP:")
            return None, staff_err, skipped

        module_display = _esr_infer_module_display(row)
        if not module_display:
            return None, "missing module (Title, Description, or Competency Name)", False

        module_code = g("module_code")
        mc, mn, mod_err = _resolve_module(
            module_code or None, module_display, allow_non_cstf=True
        )
        if mod_err:
            return None, mod_err, False

        completion_s = (
            g("completion_date")
            or g("date_last_awarded")
            or g("date_start")
            or g("certification_date")
        )
        expiry_s = g("expiry_date") or g("next_review_date")
        ods = g("issuing_trust_ods_code") or g("esr_vpd") or ""
        trust_name = g("issuing_trust_name") or ""
        if profile and not trust_name.strip():
            trust_name = (profile.current_trust or "").strip()

        miss = []
        if not completion_s:
            miss.append("completion date (e.g. Date Last Awarded / Date Start)")
        if not expiry_s:
            miss.append("Expiry Date (or Next Review Date)")
        if miss:
            return None, "missing: " + ", ".join(miss), False

        completion_date = _parse_date(completion_s)
        expiry_date = _parse_date(expiry_s)
        if not completion_date:
            return None, f"bad completion date: {completion_s!r}", False
        if not expiry_date:
            return None, f"bad expiry date: {expiry_s!r}", False

        sid = (staff_identifier or "").strip() or (
            staff_full_name[:48] if staff_full_name else "unknown"
        )
        try:
            rec = CompletionRecord(
                staff_full_name=staff_full_name or "",
                staff_identifier=sid,
                module_code=mc or "",
                module_name=mn or "",
                completion_date=completion_date,
                expiry_date=expiry_date,
                issuing_trust_ods_code=ods[:48],
                issuing_trust_name=trust_name[:240] if len(trust_name) > 240 else trust_name,
            )
            return rec, None, False
        except Exception as e:
            return None, str(e), False

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
        return None, "missing: " + ", ".join(missing), False

    mc, mn, mod_err = _resolve_module(module_code or None, module_name or None)
    if mod_err:
        return None, mod_err, False

    completion_date = _parse_date(completion_s)
    expiry_date = _parse_date(expiry_s)
    if not completion_date:
        return None, f"bad completion_date: {completion_s!r}", False
    if not expiry_date:
        return None, f"bad expiry_date: {expiry_s!r}", False

    if profile and profile.personal_scope:
        if not _profile_matches_staff(profile, staff_full_name, staff_identifier):
            return None, SKIP_OTHER_PERSON, True
        staff_full_name = profile.display_name.strip() or staff_full_name
        staff_identifier = profile.staff_identifier.strip() or staff_identifier

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
        return rec, None, False
    except Exception as e:
        return None, str(e), False


def _profile_from_dict(data: Optional[dict]) -> Optional[ImportProfileContext]:
    if not data:
        return None
    return ImportProfileContext(
        display_name=str(data.get("display_name") or "").strip(),
        staff_identifier=str(data.get("staff_identifier") or data.get("gmc_number") or "").strip(),
        current_trust=str(data.get("current_trust") or "").strip(),
        personal_scope=bool(data.get("personal_scope", True)),
    )


def parse_completion_csv(
    text: str, profile: Optional[ImportProfileContext] = None
) -> tuple[list[ParsedCsvRow], Optional[str]]:
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
    is_esr_layout = _detect_esr_layout(present)

    if is_esr_layout:
        if "expiry_date" not in present and "next_review_date" not in present:
            return [], "ESR export: missing Expiry Date (or Next Review Date) column"
        if not (
            present & {"module_name", "esr_description", "esr_competency_name"}
        ):
            return [], "ESR export: need at least one of Title, Description, or Competency Name"
        if not (
            present & {"date_last_awarded", "date_start", "certification_date", "completion_date"}
        ):
            return [], "ESR export: need a completion column (e.g. Date Last Awarded or Date Start)"
        if not profile and "esr_person_line" not in present and not (
            {"staff_full_name", "staff_identifier"} <= present
        ):
            return [], (
                "ESR export: missing a person column (e.g. Last Updated By) — "
                "sign in so we can match rows to your profile, or include staff name columns"
            )
    else:
        required = set(HEADER_ALIASES.keys()) - {
            "module_code",
            "module_name",
            "esr_competency_name",
            "esr_person_line",
            "esr_awarded_by",
            "esr_acquired_by",
            "esr_measured_by",
            "date_last_awarded",
            "date_start",
            "certification_date",
            "next_review_date",
            "esr_description",
            "esr_vpd",
            "compliance_status",
        }
        if not ({"module_code"} & present or {"module_name"} & present):
            return [], "CSV must include module_code and/or module_name column"
        if not required.issubset(present):
            return [], "missing required columns: " + ", ".join(sorted(required - present))

    # Pre-scan ESR rows to detect team-wide exports (multiple staff in one file).
    multi_person_export = False
    if is_esr_layout:
        preview_rows: list[dict[str, str]] = []
        stream2 = io.StringIO(text)
        reader2 = csv.reader(stream2)
        next(reader2)
        for cells in reader2:
            if all(not (c or "").strip() for c in cells):
                continue
            row_dict = {}
            for col_idx, canonical in col_map.items():
                if col_idx < len(cells):
                    row_dict[canonical] = cells[col_idx]
                else:
                    row_dict[canonical] = ""
            if is_esr_layout and not _esr_infer_module_display(row_dict):
                continue
            preview_rows.append(row_dict)
            if len(preview_rows) >= 500:
                break
        multi_person_export = _scan_esr_distinct_staff(preview_rows) > 1

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
        rec, err, skipped = _row_to_record(
            row_dict,
            is_esr_layout=is_esr_layout,
            profile=profile,
            multi_person_export=multi_person_export,
        )
        if err and err.startswith("SKIP:"):
            msg = {
                SKIP_OTHER_PERSON: "not your training (another person in this export)",
                SKIP_TEAM_ROW_NO_STAFF: "no person on this row (team export — use View My Compliance)",
            }.get(err, err.replace("SKIP:", "").replace("_", " "))
            out.append(
                ParsedCsvRow(row_number=file_row_num, record=None, error=msg, skipped=True)
            )
        else:
            out.append(
                ParsedCsvRow(row_number=file_row_num, record=rec, error=err, skipped=skipped)
            )

    return out, None
