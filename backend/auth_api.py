"""
Optional staff accounts: email + password, HttpOnly session cookie, server-stored wallet JSON.
PII in wallet entries is the same as localStorage today (JWT payloads); registry table still has no PII.
"""
import json
import os
import re
import base64
from datetime import datetime, date
from pathlib import Path
import sqlite3
from typing import Callable, Iterator, Optional

import bcrypt
from fastapi import APIRouter, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import compliance_snapshot, crypto, db, session_auth
from .credential_service import (
    completion_dedupe_key,
    get_verification_url_base,
    issue_credentials,
    revoke_credential,
    wallet_dedupe_keys,
)
from .models import CompletionRecord, CSTF_MODULES, HrBulkTrainingResponse, HrBulkTrainingRow

router = APIRouter(prefix="/api")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _public_app_base(request: Request) -> str:
    """Public https URL for QR/share links. Prefer env so reverse proxies do not yield internal hosts."""
    for key in ("BASE_URL", "RENDER_EXTERNAL_URL", "PUBLIC_URL"):
        raw = (os.environ.get(key) or "").strip().rstrip("/")
        if raw:
            return raw
    return str(request.base_url).rstrip("/")
GMC_RE = re.compile(r"^\d{7}$")
MAX_WALLET_BYTES = 4 * 1024 * 1024
DEV_SEED_EMAIL = "sheffieldhr@nhs.net"
MAX_HR_BULK_ROSTER_BYTES = 256 * 1024
MAX_HR_BULK_LINES = 50
MAX_HR_COHORT_LINES = 200
MAX_HR_BULK_EVIDENCE_BYTES = 10 * 1024 * 1024
MAX_MESSAGE_ATTACHMENT_BYTES = 5 * 1024 * 1024
MAX_MESSAGE_ATTACHMENTS = 5

def _first_name_from_nhs_email(email: str) -> str:
    """Derive a greeting name from email local part (e.g. william.smith@gmail.com → William)."""
    local = (email or "").split("@")[0].strip().lower()
    if not local:
        return "Colleague"
    part = local.split(".")[0]
    part = re.sub(r"\d+$", "", part)
    if not part:
        return "Colleague"
    return part[0].upper() + part[1:] if len(part) > 1 else part.upper()


def _cohort_welcome_name(doc: dict) -> str:
    """Prefer profile display name; fall back to first name from email."""
    display = (doc.get("display_name") or "").strip()
    if display:
        return display
    return _first_name_from_nhs_email(doc.get("email") or "")


def trust_display_name(trust_name: str) -> str:
    """Human-readable trust label for messages and UI (not raw all-caps HR profile text)."""
    from .trust_packs import trust_display_name as _display

    return _display(trust_name)


def _auth_me_payload(u: dict) -> dict:
    ct = (u.get("current_trust") or "").strip() or None
    return {
        "id": u["id"],
        "email": u["email"],
        "premium": db.user_is_premium(u),
        "gmc_number": u.get("gmc_number"),
        "display_name": db.user_effective_display_name(u),
        "current_trust": ct,
        "current_trust_display": trust_display_name(ct) if ct else None,
        "personal_email": u.get("email"),
        "must_change_password": bool(u.get("must_change_password")),
        "onboarding_completed": bool(u.get("onboarding_completed")),
        "hr_welcome_message_template": (u.get("hr_welcome_message_template") or "").strip()
        or None
        if db.user_is_premium(u)
        else None,
    }


DEFAULT_COHORT_WELCOME_TEMPLATE = (
    "Welcome {name} to {trust}. Please reply if you have any queries or concerns."
)

MAX_WELCOME_TEMPLATE_LEN = 4000


def _normalize_welcome_template(raw: Optional[str]) -> Optional[str]:
    t = (raw or "").strip()
    if not t:
        return None
    if len(t) > MAX_WELCOME_TEMPLATE_LEN:
        raise HTTPException(
            status_code=400,
            detail=f"Welcome message must be {MAX_WELCOME_TEMPLATE_LEN} characters or fewer",
        )
    return t


def _render_welcome_template(template: str, doc: dict, hr_trust: str) -> str:
    name = _cohort_welcome_name(doc)
    trust = trust_display_name(hr_trust) or "your trust"
    text = template.replace("{name}", name).replace("{trust}", trust)
    return text.strip()


def _resolve_welcome_template(cohort_id: int) -> str:
    """Cohort override, then cohort creator HR default, then system default."""
    cohort = db.cohort_get_by_id(int(cohort_id))
    if not cohort:
        return DEFAULT_COHORT_WELCOME_TEMPLATE
    cohort_tmpl = (cohort.get("welcome_message_template") or "").strip()
    if cohort_tmpl:
        return cohort_tmpl
    creator = db.user_get_by_id(int(cohort["created_by_user_id"]))
    if creator:
        hr_tmpl = (creator.get("hr_welcome_message_template") or "").strip()
        if hr_tmpl:
            return hr_tmpl
    return DEFAULT_COHORT_WELCOME_TEMPLATE


def _cohort_welcome_message(doc: dict, hr_trust: str, cohort_id: int) -> str:
    return _render_welcome_template(_resolve_welcome_template(cohort_id), doc, hr_trust)


def _welcome_template_meta(cohort: dict, hr_user: dict) -> dict:
    cohort_tmpl = (cohort.get("welcome_message_template") or "").strip() or None
    hr_default = (hr_user.get("hr_welcome_message_template") or "").strip() or None
    effective = cohort_tmpl or hr_default or DEFAULT_COHORT_WELCOME_TEMPLATE
    return {
        "welcome_message_template": cohort_tmpl,
        "welcome_message_hr_default": hr_default,
        "welcome_message_system_default": DEFAULT_COHORT_WELCOME_TEMPLATE,
        "welcome_message_effective": effective,
    }


def _normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def _normalize_gmc(raw: str) -> str:
    """UK GMC registration number: seven digits (ignore spaces and non-digits)."""
    return re.sub(r"\D", "", raw or "")


def _current_user_id(request: Request) -> Optional[int]:
    raw = request.cookies.get(session_auth.SESSION_COOKIE)
    if not raw:
        return None
    dec = session_auth.decode_session_token(raw)
    return dec[0] if dec else None


def require_user_id(request: Request) -> int:
    """Use on issuance and wallet-mutating routes so only signed-in users can build a list."""
    uid = _current_user_id(request)
    if uid is None:
        raise HTTPException(status_code=401, detail="Sign in to manage your training list")
    return uid


def require_premium_user(request: Request) -> dict:
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    if not db.user_is_premium(u):
        raise HTTPException(status_code=403, detail="Premium account required")
    return u


def _profile_is_complete(u: dict) -> bool:
    return not _profile_missing_fields(u)


def _profile_missing_fields(u: dict) -> list[str]:
    missing: list[str] = []
    if not (u.get("display_name") or "").strip():
        missing.append("full name")
    if not (u.get("gmc_number") or "").strip():
        missing.append("GMC number")
    if not (u.get("current_trust") or "").strip():
        missing.append("current trust")
    return missing


def require_profile_complete(u: dict) -> None:
    if db.user_is_premium(u):
        return
    missing = _profile_missing_fields(u)
    if missing:
        raise HTTPException(
            status_code=400,
            detail="Complete your profile before requesting HR verification (missing: "
            + ", ".join(missing)
            + ").",
        )


def _issuing_trust_from_wallet_entry(w: dict) -> Optional[str]:
    """Prefer plain wallet field; otherwise decode signed JWT for issuing_trust_name."""
    if not isinstance(w, dict):
        return None
    raw = (w.get("issuing_trust_name") or "").strip()
    if raw:
        return raw
    jwt_str = w.get("jwt")
    if not jwt_str or not isinstance(jwt_str, str):
        return None
    payload, _err = crypto.verify_jwt(jwt_str)
    if not isinstance(payload, dict):
        return None
    name = (payload.get("issuing_trust_name") or "").strip()
    return name or None


def _hr_evidence_content_type(content_type: Optional[str], filename: Optional[str]) -> Optional[str]:
    ct = (content_type or "").split(";")[0].strip().lower()
    if ct in ("image/jpeg", "image/png", "image/webp", "application/pdf"):
        return ct
    fn = (filename or "").lower()
    if fn.endswith(".pdf"):
        return "application/pdf"
    if fn.endswith(".png"):
        return "image/png"
    if fn.endswith(".jpg") or fn.endswith(".jpeg"):
        return "image/jpeg"
    if fn.endswith(".webp"):
        return "image/webp"
    return None


def _decode_roster_text(raw: bytes) -> Optional[str]:
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return None


def _parse_roster_lines(text: str) -> list[str]:
    out: list[str] = []
    for raw_line in (text or "").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "," in line:
            line = line.split(",")[0].strip().strip('"')
        if line:
            out.append(line)
    return out


def _match_trust_config_json(hr_trust_name: str) -> Optional[dict]:
    """Best-effort match HR profile trust string to static/trust/config/*.json."""
    t = (hr_trust_name or "").strip().lower()
    if not t:
        return None
    root = Path(__file__).resolve().parent.parent / "static" / "trust" / "config"
    if not root.is_dir():
        return None
    best: Optional[dict] = None
    for path in sorted(root.glob("*.json")):
        try:
            raw = path.read_text(encoding="utf-8")
            data = json.loads(raw)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        dn = str(data.get("display_name") or "").strip().lower()
        if not dn:
            continue
        if dn in t or t in dn:
            if best is None or len(dn) > len(str(best.get("display_name") or "")):
                best = data
    return best


def _hr_resolve_issuing_trust(
    hr: dict,
    ods_override: Optional[str],
    name_override: Optional[str],
) -> tuple[str, str]:
    ods = (ods_override or "").strip().upper()
    name = (name_override or "").strip()
    hr_trust = (hr.get("current_trust") or "").strip()
    matched = _match_trust_config_json(hr_trust) if (not ods or not name) else None
    if matched:
        if not ods:
            ods = str(matched.get("ods") or "").strip().upper()
        if not name:
            name = str(matched.get("display_name") or "").strip()
    if not ods:
        raise HTTPException(
            status_code=400,
            detail="Issuing trust ODS code is required (enter it on the form, or align your profile trust name with a file under static/trust/config).",
        )
    if not name:
        name = hr_trust or "Issuing trust"
    return ods, name


def _resolve_issuing_trust_from_name(trust_name: str) -> dict:
    """ODS + canonical display name from profile trust string and static trust packs."""
    from . import trust_packs

    profile_trust = (trust_name or "").strip()
    if not profile_trust:
        return {
            "profile_trust": "",
            "issuing_trust_ods_code": "",
            "issuing_trust_name": "",
            "matched_trust_config": False,
        }
    matched = _match_trust_config_json(profile_trust)
    if matched:
        ods = str(matched.get("ods") or "").strip().upper()
        name = str(matched.get("display_name") or "").strip() or profile_trust
        return {
            "profile_trust": profile_trust,
            "issuing_trust_ods_code": ods,
            "issuing_trust_name": name,
            "matched_trust_config": bool(ods),
        }
    ods = trust_packs.ods_for_trust_name(profile_trust)
    if ods:
        display = trust_packs.trust_display_name(profile_trust) or profile_trust
        return {
            "profile_trust": profile_trust,
            "issuing_trust_ods_code": ods,
            "issuing_trust_name": display,
            "matched_trust_config": True,
        }
    return {
        "profile_trust": profile_trust,
        "issuing_trust_ods_code": "",
        "issuing_trust_name": profile_trust,
        "matched_trust_config": False,
    }


def _hr_issuing_defaults_payload(hr: dict) -> dict:
    """Suggested ODS + display name for HR forms (same source as server-side resolution when overrides are blank)."""
    return _resolve_issuing_trust_from_name((hr.get("current_trust") or "").strip())


def _staff_identifier_for_issue(doc: dict) -> str:
    gmc_digits = _normalize_gmc(str(doc.get("gmc_number") or ""))
    if len(gmc_digits) >= 7:
        return gmc_digits[-7:]
    em = (doc.get("email") or "").strip().lower()
    if em:
        return em
    return str(int(doc["id"]))


def _merge_hr_attested_wallet_items_into_training(q: dict, hr_trust: str) -> None:
    """Append HR-bulk-issued credentials to the merged training payload (same item shape as share_items)."""
    doctor_id = int(q["doctor_user_id"])
    attested = db.hr_attested_rows_for_doctor_trust(doctor_id, hr_trust)
    if not attested:
        return
    wallet_raw = db.user_wallet_get(doctor_id)
    try:
        wallet = json.loads(wallet_raw)
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    wallet_by_id: dict = {}
    for c in wallet:
        if isinstance(c, dict) and c.get("credential_id"):
            wallet_by_id[str(c["credential_id"])] = c
    existing = {str(it.get("credential_id")) for it in (q.get("items") or []) if it.get("credential_id")}
    items = q.setdefault("items", [])
    for row in attested:
        cid = str(row["credential_id"])
        if cid in existing:
            continue
        w = wallet_by_id.get(cid, {})
        issuer = _issuing_trust_from_wallet_entry(w)
        items.append(
            {
                "session_id": -1,
                "session_created_at": row.get("attested_at"),
                "session_share_kind": "hr_bulk",
                "credential_id": cid,
                "module_name": row.get("module_name") or w.get("module_name"),
                "expiry_date": row.get("expiry_date") or w.get("expiry_date"),
                "status": "VERIFIED",
                "decision_at": row.get("attested_at"),
                "decline_reason": None,
                "certificate_base64": w.get("certificate_base64"),
                "certificate_filename": w.get("certificate_filename"),
                "issuing_trust_name": issuer,
                "verified_by_trust_name": row.get("verified_by_trust_name"),
            }
        )
        existing.add(cid)


# Conservative synthetic JWT length so pre-check does not under-estimate wallet growth
# (verification_url embeds the same token).
_HR_WALLET_NEW_ROW_GUARD_JWT_LEN = 12_000


def _hr_wallet_size_would_exceed_after_append(
    wallet_raw: str,
    *,
    module_name: str,
    expiry_date: date,
    base: str,
    evidence_b64: str,
    evidence_filename: str,
) -> bool:
    try:
        wallet = json.loads(wallet_raw)
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    jwt_stub = "x" * _HR_WALLET_NEW_ROW_GUARD_JWT_LEN
    cid = "nhs-el-guard000000000000000000"
    verify_base = get_verification_url_base(base)
    syn = {
        "credential_id": cid,
        "verification_url": f"{verify_base}/{cid}?jwt={jwt_stub}",
        "jwt": jwt_stub,
        "pdf_base64": None,
        "module_name": module_name,
        "expiry_date": expiry_date.isoformat(),
        "revoked": False,
        "certificate_base64": evidence_b64,
        "certificate_filename": evidence_filename,
    }
    merged = json.dumps(wallet + [syn])
    return len(merged.encode("utf-8")) > MAX_WALLET_BYTES


def _hr_training_line_classify(
    *,
    trust: str,
    doc: dict,
    roster_line: str,
    mc: str,
    module_name: str,
    cd: date,
    ed: date,
    ods: str,
    issuing_name: str,
) -> tuple[str, Optional[HrBulkTrainingRow], Optional[CompletionRecord], str, set]:
    """First-pass classification for one resolved clinician (no DB writes beyond reads).

    Returns (kind, error_row_or_none, rec_or_none, wallet_raw, existing_dedupe_keys).
    kind is 'error' | 'skipped' | 'issue'.
    """
    if doc.get("premium"):
        return (
            "error",
            HrBulkTrainingRow(
                roster_line=roster_line,
                status="error",
                message="This account is not a clinician record.",
            ),
            None,
            "[]",
            set(),
        )
    doc_id = int(doc["id"])
    with sqlite3.connect(db.DB_PATH) as conn:
        if not db._doctor_visible_to_trust(doc_id, trust, conn):
            return (
                "error",
                HrBulkTrainingRow(
                    roster_line=roster_line,
                    status="error",
                    message="This clinician has not permitted your trust to view or update their records.",
                    doctor_user_id=doc_id,
                ),
                None,
                "[]",
                set(),
            )

    staff_name = (doc.get("display_name") or doc.get("email") or "").strip() or "Clinician"
    staff_identifier = _staff_identifier_for_issue(doc)
    rec = CompletionRecord(
        staff_full_name=staff_name,
        staff_identifier=staff_identifier,
        module_code=mc,
        module_name=module_name,
        completion_date=cd,
        expiry_date=ed,
        issuing_trust_ods_code=ods,
        issuing_trust_name=issuing_name,
    )

    wallet_raw = db.user_wallet_get(doc_id)
    existing_keys = wallet_dedupe_keys(wallet_raw)
    if completion_dedupe_key(rec) in existing_keys:
        return ("skipped", None, None, wallet_raw, existing_keys)
    return ("issue", None, rec, wallet_raw, existing_keys)


def _hr_commit_training_for_clinician(
    *,
    hr: dict,
    trust: str,
    doc: dict,
    roster_line: str,
    rec: CompletionRecord,
    module_name: str,
    ed: date,
    base: str,
    ev_b64: str,
    ev_name: str,
) -> tuple[HrBulkTrainingRow, str]:
    """Persist one HR-attested training row after classify + wallet guard passed."""
    doc_id = int(doc["id"])
    wallet_raw = db.user_wallet_get(doc_id)
    existing_keys = wallet_dedupe_keys(wallet_raw)
    results, _iss_skipped = issue_credentials(
        [rec],
        base,
        include_pdf=False,
        skip_duplicate_keys=existing_keys,
    )
    r0 = results[0] if results else None
    if r0 is None:
        return (
            HrBulkTrainingRow(
                roster_line=roster_line,
                status="skipped_duplicate",
                message="Clinician already has this completion in their wallet.",
                doctor_user_id=doc_id,
            ),
            "skipped",
        )

    try:
        wallet = json.loads(wallet_raw)
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    cred_id = r0["credential_id"]
    wallet.append(
        {
            "credential_id": cred_id,
            "verification_url": r0["verification_url"],
            "jwt": r0["jwt"],
            "pdf_base64": r0.get("pdf_base64"),
            "module_name": module_name,
            "expiry_date": ed.isoformat(),
            "revoked": False,
            "certificate_base64": ev_b64,
            "certificate_filename": ev_name,
        }
    )
    merged = json.dumps(wallet)
    if len(merged.encode("utf-8")) > MAX_WALLET_BYTES:
        try:
            revoke_credential(cred_id)
        except Exception:
            pass
        return (
            HrBulkTrainingRow(
                roster_line=roster_line,
                status="error",
                message="Clinician wallet would exceed server size limit after adding this record.",
                doctor_user_id=doc_id,
            ),
            "error",
        )
    db.user_wallet_put(doc_id, merged)
    db.hr_attestation_upsert(
        doctor_user_id=doc_id,
        credential_id=cred_id,
        hr_user_id=int(hr["id"]),
        verified_by_trust_name=trust,
        module_name=module_name,
        expiry_date=ed.isoformat(),
    )
    _notify_clinician_hr_training(
        doc_id,
        kind="hr_issued",
        module_name=module_name,
        trust_name=trust,
    )
    _audit_hr_action(
        hr,
        "hr_issue_training",
        doctor_user_id=doc_id,
        credential_id=cred_id,
        detail=module_name,
        meta={"roster_line": roster_line, "expiry_date": ed.isoformat()},
    )
    return (
        HrBulkTrainingRow(
            roster_line=roster_line,
            status="ok",
            message="Issued and recorded as HR-verified for your trust.",
            doctor_user_id=doc_id,
            credential_id=cred_id,
        ),
        "issued",
    )


def _session_response(data: dict, user_id: int, email: str, request: Request) -> JSONResponse:
    token = session_auth.create_session_token(user_id, email)
    resp = JSONResponse(data)
    secure = request.url.scheme == "https"
    resp.set_cookie(
        session_auth.SESSION_COOKIE,
        token,
        httponly=True,
        secure=secure,
        samesite="lax",
        max_age=session_auth.SESSION_DAYS * 86400,
        path="/",
    )
    return resp


@router.post("/auth/register")
def auth_register(request: Request, body: dict):
    """Self-service registration disabled; HR provisions accounts via cohorts."""
    raise HTTPException(
        status_code=403,
        detail="Accounts are created by your HR team. Sign in with your personal email address.",
    )


@router.post("/auth/login")
def auth_login(request: Request, body: dict):
    email = _normalize_email(body.get("email") or "")
    password = body.get("password") or ""
    u = db.user_get_by_email(email)
    if not u:
        raise HTTPException(status_code=401, detail="Invalid email or password")
    try:
        ok = bcrypt.checkpw(
            str(password).encode("utf-8"),
            u["password_hash"].encode("utf-8"),
        )
    except ValueError:
        ok = False
    if not ok:
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return _session_response({"ok": True, "email": email}, u["id"], email, request)


@router.post("/auth/logout")
def auth_logout(request: Request):
    resp = JSONResponse({"ok": True})
    secure = request.url.scheme == "https"
    resp.delete_cookie(
        session_auth.SESSION_COOKIE,
        path="/",
        samesite="lax",
        httponly=True,
        secure=secure,
    )
    return resp


@router.get("/auth/me")
def auth_me(request: Request):
    uid = _current_user_id(request)
    if uid is None:
        raise HTTPException(status_code=401, detail="Not signed in")
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    return _auth_me_payload(u)


@router.post("/auth/change-password")
async def auth_change_password(request: Request):
    uid = require_user_id(request)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    current = str(body.get("current_password") or "")
    new_pw = str(body.get("new_password") or "")
    if len(new_pw) < 8:
        raise HTTPException(status_code=400, detail="New password must be at least 8 characters")
    brief = db.user_get_by_id(uid)
    if not brief:
        raise HTTPException(status_code=401, detail="Not signed in")
    u = db.user_get_by_email(brief.get("email") or "")
    if not u or "password_hash" not in u:
        raise HTTPException(status_code=401, detail="Not signed in")
    try:
        ok = bcrypt.checkpw(current.encode("utf-8"), u["password_hash"].encode("utf-8"))
    except ValueError:
        ok = False
    if not ok:
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    h = bcrypt.hashpw(new_pw.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    db.user_set_password(uid, h, clear_must_change=True)
    return {"ok": True}


@router.put("/me/profile")
async def me_profile_put(request: Request):
    uid = require_user_id(request)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object")

    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")

    if "display_name" in body:
        display_name = (body.get("display_name") or "").strip() or None
    else:
        display_name = u.get("display_name")

    if "gmc_number" in body:
        gmc = _normalize_gmc(str(body.get("gmc_number") or ""))
        if gmc and not GMC_RE.match(gmc):
            raise HTTPException(status_code=400, detail="GMC number must be exactly 7 digits")
        gmc = gmc or None
    else:
        gmc = u.get("gmc_number")

    if "current_trust" in body:
        from .trust_packs import normalize_stored_trust_name

        current_trust = normalize_stored_trust_name((body.get("current_trust") or "").strip())
    else:
        current_trust = u.get("current_trust")

    hr_welcome_template = u.get("hr_welcome_message_template")
    if db.user_is_premium(u) and "hr_welcome_message_template" in body:
        hr_welcome_template = _normalize_welcome_template(
            body.get("hr_welcome_message_template")
        )

    merged = {
        "display_name": display_name,
        "gmc_number": gmc,
        "current_trust": current_trust,
    }
    if not db.user_is_premium(u):
        missing = _profile_missing_fields(merged)
        if missing:
            raise HTTPException(
                status_code=400,
                detail="All profile fields are required (missing: "
                + ", ".join(missing)
                + ").",
            )
        gn = _normalize_gmc(str(gmc or ""))
        if not gn or not GMC_RE.match(gn):
            raise HTTPException(status_code=400, detail="GMC number must be exactly 7 digits")

    was_complete = _profile_is_complete(
        {
            "display_name": u.get("display_name"),
            "gmc_number": u.get("gmc_number"),
            "current_trust": u.get("current_trust"),
        }
    )
    if db.user_is_premium(u) and "hr_welcome_message_template" in body:
        db.user_set_profile(
            uid,
            display_name,
            gmc,
            current_trust,
            hr_welcome_template,
            update_hr_welcome_template=True,
        )
    else:
        db.user_set_profile(uid, display_name, gmc, current_trust)
    if not db.user_is_premium(u) and _profile_is_complete(merged):
        db.user_mark_onboarding_complete(uid)
    if not db.user_is_premium(u) and _profile_is_complete(merged) and not was_complete:
        _hr_process_pending_welcomes(uid)
    return {"ok": True}


def _try_seed_mandatory_from_pack(trust_name: str) -> Optional[str]:
    """If trust has no topics and a static pack exists, seed once. Returns message or None."""
    from . import trust_packs

    trust_name = (trust_name or "").strip()
    if not trust_name or db.mandatory_topics_count(trust_name) > 0:
        return None
    pack_id = trust_packs.pack_id_for_trust_name(trust_name)
    if not pack_id:
        return None
    pack = trust_packs.load_trust_pack(pack_id)
    if not pack:
        return None
    _n, msg = db.seed_mandatory_from_trust_pack(trust_name, pack)
    return msg if _n else None


@router.get("/me/trust-requirements")
def me_trust_requirements(request: Request):
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    trust = (u.get("current_trust") or "").strip()
    if not trust:
        return {"topics": [], "trust": None}
    _try_seed_mandatory_from_pack(trust)
    return {"topics": db.mandatory_topics_list(trust), "trust": trust}


@router.get("/me/wallet")
def me_wallet_get(request: Request):
    uid = _current_user_id(request)
    if uid is None:
        raise HTTPException(status_code=401, detail="Not signed in")
    raw = db.user_wallet_get(uid)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = []
    if not isinstance(parsed, list):
        parsed = []
    return parsed


@router.put("/me/wallet")
async def me_wallet_put(request: Request):
    uid = _current_user_id(request)
    if uid is None:
        raise HTTPException(status_code=401, detail="Not signed in")
    body = await request.body()
    if len(body) > MAX_WALLET_BYTES:
        raise HTTPException(status_code=413, detail="Wallet too large")
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if isinstance(data, dict) and isinstance(data.get("credentials"), list):
        data = data["credentials"]
    if not isinstance(data, list):
        raise HTTPException(status_code=400, detail="Expected a JSON array of credentials")
    if len(data) > 5000:
        raise HTTPException(status_code=400, detail="Too many credentials")
    db.user_wallet_put(uid, json.dumps(data))
    return {"ok": True, "count": len(data)}


@router.post("/me/shares")
async def me_shares_post(request: Request):
    uid = require_user_id(request)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object")
    ids = body.get("credential_ids")
    if not isinstance(ids, list) or not ids:
        raise HTTPException(status_code=400, detail="Expected credential_ids: [..]")
    ids = [str(x).strip() for x in ids if str(x).strip()]
    if not ids:
        raise HTTPException(status_code=400, detail="No credential ids provided")
    if len(ids) > 200:
        raise HTTPException(status_code=400, detail="Too many items selected")

    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    require_profile_complete(u)

    # Enrich share items from the current wallet (best-effort)
    wallet_raw = db.user_wallet_get(uid)
    try:
        wallet = json.loads(wallet_raw)
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    wallet_by_id = {}
    for c in wallet:
        if isinstance(c, dict) and c.get("credential_id"):
            wallet_by_id[str(c.get("credential_id"))] = c

    # One wallet row may hold batch evidence (e.g. CSV import); copy to every share item for HR.
    fallback_b64 = None
    fallback_fn = None
    for cid in ids:
        w = wallet_by_id.get(cid) or {}
        if w.get("certificate_base64"):
            fallback_b64 = w.get("certificate_base64")
            fallback_fn = w.get("certificate_filename")
            break

    portfolio = bool(body.get("portfolio"))
    if portfolio:
        vmap = db.doctor_verified_map(uid)
        for cid in ids:
            vm = vmap.get(cid) or {}
            st = str(vm.get("status") or "").upper().strip()
            if not vm.get("shared") or st != "VERIFIED":
                raise HTTPException(
                    status_code=400,
                    detail="Reference pack only: every credential must already be VERIFIED by HR. "
                    "Remove any that are still awaiting verification, or use normal Verify with HR first.",
                )

    items = []
    batch_cert_attached = False
    for cid in ids:
        w = wallet_by_id.get(cid) or {}
        b64 = w.get("certificate_base64")
        fn = w.get("certificate_filename")
        if not b64 and fallback_b64 and not batch_cert_attached:
            b64 = fallback_b64
            fn = fallback_fn
            batch_cert_attached = True
        issuing = _issuing_trust_from_wallet_entry(w)
        entry = {
            "credential_id": cid,
            "module_name": w.get("module_name"),
            "expiry_date": w.get("expiry_date"),
            "certificate_base64": b64,
            "certificate_filename": fn,
            "issuing_trust_name": issuing,
        }
        if portfolio:
            prior = db.share_portfolio_prior_decision_at(uid, cid)
            entry["portfolio_verified_at"] = prior or datetime.utcnow().isoformat()
            entry["verified_by_trust_name"] = db.share_portfolio_prior_verifier_trust(uid, cid)
        items.append(entry)

    created = db.share_session_create(
        doctor_user_id=uid,
        doctor_email=u.get("email") or "",
        items=items,
        share_kind="portfolio" if portfolio else "review",
        target_trust=u.get("current_trust") or None,
    )
    base = _public_app_base(request)
    share_url = f"{base}/static/hr/?session={created['session_id']}"
    return {
        "ok": True,
        "session_id": created["session_id"],
        "share_url": share_url,
        "share_kind": "portfolio" if portfolio else "review",
    }


@router.get("/me/verified-map")
def me_verified_map(request: Request):
    uid = require_user_id(request)
    return db.doctor_verified_map(uid)


@router.get("/me/getting-started-progress")
def me_getting_started_progress(request: Request):
    """Checklist steps 4–5: only count actions the clinician took (not HR bulk issue)."""
    uid = require_user_id(request)
    return db.doctor_getting_started_progress(uid)


@router.get("/me/visibility")
def me_visibility_get(request: Request):
    uid = require_user_id(request)
    return db.visibility_get(uid)


@router.put("/me/visibility")
async def me_visibility_put(request: Request):
    uid = require_user_id(request)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object")
    mode = str(body.get("mode") or "all").strip()
    raw_al = body.get("allowlist")
    allowlist = raw_al if isinstance(raw_al, list) else []
    allowlist = [e for e in allowlist if isinstance(e, dict) and (e.get("trust_name") or "").strip()]
    db.visibility_set(uid, mode, allowlist)
    return {"ok": True}


def _hr_trust(hr_user: dict) -> Optional[str]:
    """Normalised current_trust of an HR user, used for trust-scoping inbox queries."""
    t = (hr_user.get("current_trust") or "").strip().lower()
    return t or None


def _notify_clinician_hr_training(
    doctor_user_id: int,
    *,
    kind: str,
    module_name: str,
    trust_name: str,
    decline_reason: Optional[str] = None,
) -> None:
    mod = (module_name or "Training").strip() or "Training"
    trust = (trust_name or "HR").strip() or "HR"
    titles = {
        "hr_verified": "Training verified",
        "hr_declined": "Training declined",
        "hr_unverified": "Verification reverted",
        "hr_issued": "Training recorded by HR",
    }
    title = titles.get(kind, "Training update")
    if kind == "hr_verified":
        body = f"{mod} was verified by HR at {trust}."
        link = "/static/staff/"
    elif kind == "hr_declined":
        reason = (decline_reason or "").strip()
        body = f"{mod} was declined by HR at {trust}."
        if reason:
            body += f" Reason: {reason}"
        link = "/static/staff/"
    elif kind == "hr_unverified":
        body = f"HR at {trust} reverted verification for {mod}. It is awaiting review again."
        link = "/static/staff/"
    else:
        body = f"{mod} was recorded by HR at {trust}."
        link = "/static/staff/"
    db.notification_create(
        int(doctor_user_id),
        kind=kind,
        title=title,
        body=body,
        link_path=link,
        meta={"module_name": mod, "trust_name": trust},
    )


def _audit_hr_action(
    hr: dict,
    action: str,
    *,
    doctor_user_id: Optional[int] = None,
    credential_id: Optional[str] = None,
    session_id: Optional[int] = None,
    detail: Optional[str] = None,
    meta: Optional[dict] = None,
) -> None:
    trust = (hr.get("current_trust") or "").strip()
    db.hr_audit_log_append(
        int(hr["id"]),
        action,
        trust_name=trust,
        doctor_user_id=doctor_user_id,
        credential_id=credential_id,
        session_id=session_id,
        detail=detail,
        meta=meta,
    )


def _assert_same_trust(hr_user: dict, session: dict) -> None:
    """Raise 403 if the session's doctor is not from the HR user's trust."""
    trust = _hr_trust(hr_user)
    if not trust:
        return  # HR account has no trust set — don't block (edge case / admin)
    doc_trust = (session.get("target_trust") or session.get("doctor_trust") or "").strip().lower()
    if doc_trust != trust:
        raise HTTPException(status_code=403, detail="This submission is not from your trust.")


@router.get("/hr/shares")
def hr_shares_list(request: Request, limit: int = 50):
    hr = require_premium_user(request)
    return {"sessions": db.share_inbox_list(limit=limit, hr_trust=_hr_trust(hr))}


@router.get("/hr/doctors/search")
def hr_doctors_search(request: Request, q: str = "", limit: int = 30):
    """Search clinicians by name / email / GMC. Respects doctor visibility settings."""
    hr = require_premium_user(request)
    trust = (hr.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set to search for doctors.")
    results = db.hr_doctor_search(q=q, hr_trust=trust, limit=limit)
    return {"results": results}


@router.get("/me/issuing-trust-defaults")
def me_issuing_trust_defaults(request: Request):
    """Suggested issuing-trust ODS and display name from the signed-in user's current trust."""
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    return _resolve_issuing_trust_from_name((u.get("current_trust") or "").strip())


@router.get("/trust/resolve-ods")
def trust_resolve_ods(request: Request, name: str = Query("")):
    """Resolve ODS from a trust name string (pack config first, for client auto-fill)."""
    require_user_id(request)
    resolved = _resolve_issuing_trust_from_name(name)
    return {
        "ods": resolved.get("issuing_trust_ods_code") or "",
        "name": resolved.get("issuing_trust_name") or (name or "").strip(),
    }


@router.get("/hr/issuing-defaults")
def hr_issuing_defaults(request: Request):
    """Suggested issuing-trust ODS and display name from the signed-in HR profile and static trust directory."""
    hr = require_premium_user(request)
    return _hr_issuing_defaults_payload(hr)


@router.get("/hr/doctors/{doctor_user_id}/training")
def hr_doctor_training(request: Request, doctor_user_id: int):
    """Read-only verified training for a doctor found via search.
    Checks visibility settings but skips trust-inbox scoping (doctor may be at a different trust)."""
    hr = require_premium_user(request)
    trust = (hr.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set.")
    # Check doctor visibility allows this HR trust
    with __import__('sqlite3').connect(db.DB_PATH) as conn:
        if not db._doctor_visible_to_trust(int(doctor_user_id), trust, conn):
            raise HTTPException(status_code=403, detail="This clinician has not permitted your trust to view their records.")
    q = db.share_doctor_queue(int(doctor_user_id), hr_trust=None)
    if not q:
        raise HTTPException(status_code=404, detail="Clinician not found")
    _merge_hr_attested_wallet_items_into_training(q, trust)
    return q


@router.post("/hr/doctors/{doctor_user_id}/add-training", response_model=HrBulkTrainingResponse)
async def hr_doctor_add_training(
    request: Request,
    doctor_user_id: int,
    evidence: Optional[UploadFile] = File(None),
    module_code: str = Form(...),
    completion_date: str = Form(...),
    expiry_date: str = Form(...),
    issuing_trust_ods_code: Optional[str] = Form(None),
    issuing_trust_name: Optional[str] = Form(None),
):
    """
    Premium HR: add one training completion to a specific clinician (same rules as bulk roster —
    visibility, duplicate detection, shared evidence file).
    """
    hr = require_premium_user(request)
    trust = (hr.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set.")

    doc = db.user_get_by_id(int(doctor_user_id))
    if not doc:
        raise HTTPException(status_code=404, detail="Clinician not found")
    roster_line = (doc.get("email") or "").strip() or f"user:{doctor_user_id}"

    mc = str(module_code or "").strip().lower()
    module_lookup = dict(CSTF_MODULES)
    if mc not in module_lookup:
        raise HTTPException(status_code=400, detail="Unknown module_code.")
    module_name = module_lookup[mc]

    try:
        cd = date.fromisoformat(str(completion_date).strip()[:10])
        ed = date.fromisoformat(str(expiry_date).strip()[:10])
    except ValueError:
        raise HTTPException(status_code=400, detail="completion_date and expiry_date must be YYYY-MM-DD.")

    ods, issuing_name = _hr_resolve_issuing_trust(hr, issuing_trust_ods_code, issuing_trust_name)
    base = _public_app_base(request)

    kind, err_row, rec, wallet_raw, _keys = _hr_training_line_classify(
        trust=trust,
        doc=doc,
        roster_line=roster_line,
        mc=mc,
        module_name=module_name,
        cd=cd,
        ed=ed,
        ods=ods,
        issuing_name=issuing_name,
    )

    if kind == "error":
        assert err_row is not None
        return HrBulkTrainingResponse(
            dry_run=False,
            aborted=False,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=1,
            issued=0,
            skipped_duplicate=0,
            errors=1,
            rows=[err_row],
        )

    doc_id = int(doc["id"])
    if kind == "skipped":
        row = HrBulkTrainingRow(
            roster_line=roster_line,
            status="skipped_duplicate",
            message="Clinician already has this completion in their wallet.",
            doctor_user_id=doc_id,
        )
        return HrBulkTrainingResponse(
            dry_run=False,
            aborted=False,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=1,
            issued=0,
            skipped_duplicate=1,
            errors=0,
            rows=[row],
        )

    assert rec is not None
    if evidence is None or not (evidence.filename or "").strip():
        raise HTTPException(
            status_code=400,
            detail="Evidence file is required to issue a credential.",
        )
    ev_raw = await evidence.read()
    if len(ev_raw) > MAX_HR_BULK_EVIDENCE_BYTES:
        raise HTTPException(status_code=413, detail="Evidence file too large (max 10 MB).")
    ev_ct = _hr_evidence_content_type(evidence.content_type, evidence.filename)
    if not ev_ct:
        raise HTTPException(
            status_code=400,
            detail="Evidence must be a PDF or image (JPEG, PNG, or WebP).",
        )
    ev_name = (evidence.filename or "evidence").strip()
    ev_b64 = base64.b64encode(ev_raw).decode("ascii")

    if _hr_wallet_size_would_exceed_after_append(
        wallet_raw,
        module_name=module_name,
        expiry_date=ed,
        base=base,
        evidence_b64=ev_b64,
        evidence_filename=ev_name,
    ):
        return HrBulkTrainingResponse(
            dry_run=False,
            aborted=False,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=1,
            issued=0,
            skipped_duplicate=0,
            errors=1,
            rows=[
                HrBulkTrainingRow(
                    roster_line=roster_line,
                    status="error",
                    message="Clinician wallet would exceed server size limit after adding this record.",
                    doctor_user_id=doc_id,
                )
            ],
        )

    row, outcome = _hr_commit_training_for_clinician(
        hr=hr,
        trust=trust,
        doc=doc,
        roster_line=roster_line,
        rec=rec,
        module_name=module_name,
        ed=ed,
        base=base,
        ev_b64=ev_b64,
        ev_name=ev_name,
    )
    issued = 1 if outcome == "issued" else 0
    skipped = 1 if outcome == "skipped" else 0
    errors = 1 if outcome == "error" else 0

    return HrBulkTrainingResponse(
        dry_run=False,
        aborted=False,
        issuing_trust_ods_code=ods,
        issuing_trust_name=issuing_name,
        module_code=mc,
        attempted=1,
        issued=issued,
        skipped_duplicate=skipped,
        errors=errors,
        rows=[row],
    )


NDJSON_STREAM_HEADERS = {"Cache-Control": "no-store", "X-Accel-Buffering": "no"}


def _ndjson_progress_line(
    phase: str, message: str, current: int = 0, total: int = 0
) -> str:
    return (
        json.dumps(
            {
                "event": "progress",
                "phase": phase,
                "message": message,
                "current": current,
                "total": total,
            }
        )
        + "\n"
    )


def _ndjson_complete_line(data: dict) -> str:
    return json.dumps({"event": "complete", "data": data}) + "\n"


def _ndjson_stream_wrap(gen: Iterator[str]) -> Iterator[str]:
    try:
        yield from gen
    except HTTPException as exc:
        detail = exc.detail
        msg = detail if isinstance(detail, str) else str(detail)
        yield json.dumps({"event": "error", "message": msg}) + "\n"


def _bulk_training_progress_line(
    phase: str, message: str, current: int = 0, total: int = 0
) -> str:
    return _ndjson_progress_line(phase, message, current, total)


def _bulk_training_complete_line(resp: HrBulkTrainingResponse) -> str:
    return _ndjson_complete_line(resp.model_dump())


def _hr_bulk_training_run(ctx: dict, *, emit_progress: bool = True) -> Iterator[str]:
    """
    Execute bulk training; yields NDJSON progress lines and a final complete line.
    When emit_progress is False, only the complete line is yielded (for JSON clients).
    """
    hr = ctx["hr"]
    trust = ctx["trust"]
    lines: list[str] = ctx["lines"]
    cohort_label: str = ctx.get("cohort_label") or ""
    mc: str = ctx["mc"]
    module_name: str = ctx["module_name"]
    cd: date = ctx["cd"]
    ed: date = ctx["ed"]
    ods: str = ctx["ods"]
    issuing_name: str = ctx["issuing_name"]
    base: str = ctx["base"]
    evidence_upload = ctx.get("evidence_upload")

    total = len(lines)

    def progress(phase: str, message: str, current: int = 0, total_n: int = 0) -> None:
        if emit_progress:
            yield_lines.append(
                _bulk_training_progress_line(phase, message, current, total_n or total)
            )

    yield_lines: list[str] = []

    if cohort_label:
        progress(
            "prepare",
            f'Loaded {total} clinician{"s" if total != 1 else ""} from cohort “{cohort_label}”.',
            0,
            total,
        )
    else:
        progress(
            "prepare",
            f'Loaded roster ({total} line{"s" if total != 1 else ""}).',
            0,
            total,
        )
    for line in yield_lines:
        yield line
    yield_lines.clear()

    plans: list[dict] = []
    for idx, line in enumerate(lines):
        progress("validate", f"Checking clinician {idx + 1} of {total}…", idx + 1, total)
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        doc = db.hr_lookup_doctor_by_roster_line(line)
        if not doc:
            plans.append(
                {
                    "line": line,
                    "kind": "missing",
                    "doc": None,
                    "err_row": None,
                    "rec": None,
                    "wallet_raw": "[]",
                }
            )
            continue
        kind, err_row, rec, wallet_raw, _keys = _hr_training_line_classify(
            trust=trust,
            doc=doc,
            roster_line=line,
            mc=mc,
            module_name=module_name,
            cd=cd,
            ed=ed,
            ods=ods,
            issuing_name=issuing_name,
        )
        plans.append(
            {
                "line": line,
                "kind": kind,
                "doc": doc,
                "err_row": err_row,
                "rec": rec,
                "wallet_raw": wallet_raw,
            }
        )

    def _row_missing(line: str) -> HrBulkTrainingRow:
        return HrBulkTrainingRow(roster_line=line, status="error", message="No matching clinician account.")

    has_classify_error = any(p["kind"] in ("missing", "error") for p in plans)
    if has_classify_error:
        progress("validate", "Roster validation finished — errors found.", total, total)
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        rows_out: list[HrBulkTrainingRow] = []
        errors = skipped = 0
        for p in plans:
            if p["kind"] == "missing":
                rows_out.append(_row_missing(p["line"]))
                errors += 1
            elif p["kind"] == "error":
                assert p["err_row"] is not None
                rows_out.append(p["err_row"])
                errors += 1
            elif p["kind"] == "skipped":
                doc_id = int(p["doc"]["id"])
                rows_out.append(
                    HrBulkTrainingRow(
                        roster_line=p["line"],
                        status="would_skip_duplicate",
                        message="Clinician already has this completion in their wallet.",
                        doctor_user_id=doc_id,
                    )
                )
                skipped += 1
            else:
                doc_id = int(p["doc"]["id"])
                rows_out.append(
                    HrBulkTrainingRow(
                        roster_line=p["line"],
                        status="not_committed",
                        message="Not issued: another line on the roster failed validation. Fix errors and submit again.",
                        doctor_user_id=doc_id,
                    )
                )
        resp = HrBulkTrainingResponse(
            dry_run=False,
            aborted=True,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=len(lines),
            issued=0,
            skipped_duplicate=skipped,
            errors=errors,
            rows=rows_out,
        )
        yield _bulk_training_complete_line(resp)
        return

    issue_plans = [p for p in plans if p["kind"] == "issue"]
    if not issue_plans:
        progress("validate", "Everyone on the roster already has this training.", total, total)
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        rows_out = []
        skipped = 0
        for p in plans:
            assert p["kind"] == "skipped"
            doc_id = int(p["doc"]["id"])
            rows_out.append(
                HrBulkTrainingRow(
                    roster_line=p["line"],
                    status="skipped_duplicate",
                    message="Clinician already has this completion in their wallet.",
                    doctor_user_id=doc_id,
                )
            )
            skipped += 1
        resp = HrBulkTrainingResponse(
            dry_run=False,
            aborted=False,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=len(lines),
            issued=0,
            skipped_duplicate=skipped,
            errors=0,
            rows=rows_out,
        )
        yield _bulk_training_complete_line(resp)
        return

    progress("validate", f"Roster OK — issuing to {len(issue_plans)} clinician(s).", total, total)
    for chunk in yield_lines:
        yield chunk
    yield_lines.clear()

    if evidence_upload is None or not (evidence_upload.get("filename") or "").strip():
        raise HTTPException(
            status_code=400,
            detail="Evidence file is required when at least one clinician would receive a new credential.",
        )
    progress("evidence", "Reading and validating evidence file…", 0, len(issue_plans))
    for chunk in yield_lines:
        yield chunk
    yield_lines.clear()

    ev_raw = evidence_upload["raw"]
    if len(ev_raw) > MAX_HR_BULK_EVIDENCE_BYTES:
        raise HTTPException(status_code=413, detail="Evidence file too large (max 10 MB).")
    ev_ct = _hr_evidence_content_type(
        evidence_upload.get("content_type"), evidence_upload.get("filename")
    )
    if not ev_ct:
        raise HTTPException(
            status_code=400,
            detail="Evidence must be a PDF or image (JPEG, PNG, or WebP).",
        )
    ev_name = (evidence_upload.get("filename") or "evidence").strip()
    ev_b64 = base64.b64encode(ev_raw).decode("ascii")

    wallet_bad: set[str] = set()
    wallet_total = len(issue_plans)
    for widx, p in enumerate(issue_plans):
        progress(
            "wallet",
            f"Checking wallet size {widx + 1} of {wallet_total}…",
            widx + 1,
            wallet_total,
        )
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        if _hr_wallet_size_would_exceed_after_append(
            p["wallet_raw"],
            module_name=module_name,
            expiry_date=ed,
            base=base,
            evidence_b64=ev_b64,
            evidence_filename=ev_name,
        ):
            wallet_bad.add(p["line"])

    if wallet_bad:
        progress("wallet", "Wallet size check failed for at least one clinician.", wallet_total, wallet_total)
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        rows_out = []
        errors = skipped = 0
        for p in plans:
            if p["kind"] == "skipped":
                doc_id = int(p["doc"]["id"])
                rows_out.append(
                    HrBulkTrainingRow(
                        roster_line=p["line"],
                        status="would_skip_duplicate",
                        message="Clinician already has this completion in their wallet.",
                        doctor_user_id=doc_id,
                    )
                )
                skipped += 1
            elif p["kind"] == "issue":
                doc_id = int(p["doc"]["id"])
                if p["line"] in wallet_bad:
                    rows_out.append(
                        HrBulkTrainingRow(
                            roster_line=p["line"],
                            status="error",
                            message="Clinician wallet would exceed server size limit after adding this record.",
                            doctor_user_id=doc_id,
                        )
                    )
                    errors += 1
                else:
                    rows_out.append(
                        HrBulkTrainingRow(
                            roster_line=p["line"],
                            status="not_committed",
                            message="Not issued: roster failed a wallet size check for at least one other clinician.",
                            doctor_user_id=doc_id,
                        )
                    )
        resp = HrBulkTrainingResponse(
            dry_run=False,
            aborted=True,
            issuing_trust_ods_code=ods,
            issuing_trust_name=issuing_name,
            module_code=mc,
            attempted=len(lines),
            issued=0,
            skipped_duplicate=skipped,
            errors=errors,
            rows=rows_out,
        )
        yield _bulk_training_complete_line(resp)
        return

    issue_total = len(issue_plans)
    rows_out = []
    issued = skipped = errors = 0
    issue_idx = 0
    for p in plans:
        if p["kind"] == "skipped":
            doc_id = int(p["doc"]["id"])
            rows_out.append(
                HrBulkTrainingRow(
                    roster_line=p["line"],
                    status="skipped_duplicate",
                    message="Clinician already has this completion in their wallet.",
                    doctor_user_id=doc_id,
                )
            )
            skipped += 1
            continue
        if p["kind"] != "issue":
            continue
        issue_idx += 1
        progress(
            "issue",
            f"Issuing training record {issue_idx} of {issue_total}…",
            issue_idx,
            issue_total,
        )
        for chunk in yield_lines:
            yield chunk
        yield_lines.clear()

        assert p["rec"] is not None and p["doc"] is not None
        row, outcome = _hr_commit_training_for_clinician(
            hr=hr,
            trust=trust,
            doc=p["doc"],
            roster_line=p["line"],
            rec=p["rec"],
            module_name=module_name,
            ed=ed,
            base=base,
            ev_b64=ev_b64,
            ev_name=ev_name,
        )
        rows_out.append(row)
        if outcome == "issued":
            issued += 1
        elif outcome == "skipped":
            skipped += 1
        elif outcome == "error":
            errors += 1

    progress("finalize", "Finishing up…", issue_total, issue_total)
    for chunk in yield_lines:
        yield chunk
    yield_lines.clear()

    resp = HrBulkTrainingResponse(
        dry_run=False,
        aborted=False,
        issuing_trust_ods_code=ods,
        issuing_trust_name=issuing_name,
        module_code=mc,
        attempted=len(lines),
        issued=issued,
        skipped_duplicate=skipped,
        errors=errors,
        rows=rows_out,
    )
    yield _bulk_training_complete_line(resp)


def _hr_bulk_training_collect(ctx: dict) -> HrBulkTrainingResponse:
    resp: Optional[HrBulkTrainingResponse] = None
    for line in _hr_bulk_training_run(ctx, emit_progress=False):
        payload = json.loads(line)
        if payload.get("event") == "complete":
            resp = HrBulkTrainingResponse(**payload["data"])
    if resp is None:
        raise HTTPException(status_code=500, detail="Bulk training did not return a result.")
    return resp


async def _hr_bulk_training_build_context(
    request: Request,
    hr: dict,
    trust: str,
    *,
    roster: Optional[UploadFile],
    cohort_id: Optional[str],
    evidence: Optional[UploadFile],
    module_code: str,
    completion_date: str,
    expiry_date: str,
    issuing_trust_ods_code: Optional[str],
    issuing_trust_name: Optional[str],
) -> dict:
    lines: list[str] = []
    cohort_label = ""
    raw_cohort = (cohort_id or "").strip()
    if raw_cohort:
        try:
            cid = int(raw_cohort)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="Invalid cohort_id")
        cohort = db.cohort_get(cid, trust)
        if not cohort:
            raise HTTPException(status_code=404, detail="Cohort not found")
        cohort_label = cohort.get("name") or f"Cohort {cid}"
        lines = db.cohort_roster_lines(cid, trust)
        if not lines:
            raise HTTPException(status_code=400, detail="Selected cohort has no members with email or GMC.")
    elif roster and (roster.filename or "").strip():
        raw_roster = await roster.read()
        if len(raw_roster) > MAX_HR_BULK_ROSTER_BYTES:
            raise HTTPException(status_code=413, detail="Roster file too large")
        text = _decode_roster_text(raw_roster)
        if text is None:
            raise HTTPException(status_code=400, detail="Roster encoding not recognised (try UTF-8).")
        lines = _parse_roster_lines(text)
        if not lines:
            raise HTTPException(status_code=400, detail="Roster is empty.")
    else:
        raise HTTPException(
            status_code=400,
            detail="Select a cohort or upload a roster file.",
        )
    if len(lines) > MAX_HR_BULK_LINES:
        raise HTTPException(
            status_code=400,
            detail=f"Too many roster lines ({len(lines)}). Maximum is {MAX_HR_BULK_LINES} per upload.",
        )

    mc = str(module_code or "").strip().lower()
    module_lookup = dict(CSTF_MODULES)
    if mc not in module_lookup:
        raise HTTPException(status_code=400, detail="Unknown module_code.")
    module_name = module_lookup[mc]

    try:
        cd = date.fromisoformat(str(completion_date).strip()[:10])
        ed = date.fromisoformat(str(expiry_date).strip()[:10])
    except ValueError:
        raise HTTPException(status_code=400, detail="completion_date and expiry_date must be YYYY-MM-DD.")

    ods, issuing_name = _hr_resolve_issuing_trust(hr, issuing_trust_ods_code, issuing_trust_name)
    base = _public_app_base(request)

    evidence_upload = None
    if evidence is not None and (evidence.filename or "").strip():
        ev_raw = await evidence.read()
        evidence_upload = {
            "raw": ev_raw,
            "filename": (evidence.filename or "evidence").strip(),
            "content_type": evidence.content_type,
        }

    return {
        "hr": hr,
        "trust": trust,
        "lines": lines,
        "cohort_label": cohort_label,
        "mc": mc,
        "module_name": module_name,
        "cd": cd,
        "ed": ed,
        "ods": ods,
        "issuing_name": issuing_name,
        "base": base,
        "evidence_upload": evidence_upload,
    }


@router.post("/hr/bulk-training")
async def hr_bulk_training(
    request: Request,
    roster: Optional[UploadFile] = File(None),
    cohort_id: Optional[str] = Form(None),
    evidence: Optional[UploadFile] = File(None),
    module_code: str = Form(...),
    completion_date: str = Form(...),
    expiry_date: str = Form(...),
    issuing_trust_ods_code: Optional[str] = Form(None),
    issuing_trust_name: Optional[str] = Form(None),
    stream: bool = Form(False),
):
    """
    Premium HR: issue one CSTF-style module completion to many clinicians from a roster file
    or a cohort (one GMC or email per line, or CSV with identifier in the first column) plus shared evidence.

    All-or-nothing on roster validation: every line is checked first; if any line fails
    (unknown clinician, visibility, premium account, or wallet size guard), nothing is issued.
    When the roster is clean, lines that would duplicate an existing wallet entry are skipped
    and all remaining lines are issued in one pass.

    Pass stream=true (form field) to receive application/x-ndjson progress events, then a
    final {"event":"complete","data":...} line.
    """
    hr = require_premium_user(request)
    trust = (hr.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set.")

    ctx = await _hr_bulk_training_build_context(
        request,
        hr,
        trust,
        roster=roster,
        cohort_id=cohort_id,
        evidence=evidence,
        module_code=module_code,
        completion_date=completion_date,
        expiry_date=expiry_date,
        issuing_trust_ods_code=issuing_trust_ods_code,
        issuing_trust_name=issuing_trust_name,
    )

    if stream:

        def _stream_with_errors() -> Iterator[str]:
            try:
                yield from _hr_bulk_training_run(ctx, emit_progress=True)
            except HTTPException as exc:
                detail = exc.detail
                msg = detail if isinstance(detail, str) else str(detail)
                yield json.dumps({"event": "error", "message": msg}) + "\n"

        return StreamingResponse(
            _stream_with_errors(),
            media_type="application/x-ndjson",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    return _hr_bulk_training_collect(ctx)


@router.get("/hr/doctors/{doctor_user_id}/queue")
def hr_doctor_queue(request: Request, doctor_user_id: int):
    """Merged inbox for one clinician (all share sessions combined)."""
    hr = require_premium_user(request)
    q = db.share_doctor_queue(int(doctor_user_id), hr_trust=_hr_trust(hr))
    if not q:
        raise HTTPException(status_code=404, detail="Clinician not found")
    return q


@router.get("/hr/shares/{session_id}")
def hr_shares_get(request: Request, session_id: int):
    hr = require_premium_user(request)
    s = db.share_session_get(int(session_id))
    if not s:
        raise HTTPException(status_code=404, detail="Share not found")
    _assert_same_trust(hr, s)
    return s


@router.post("/hr/shares/{session_id}/items/{credential_id}/verify")
def hr_share_item_verify(request: Request, session_id: int, credential_id: str):
    hr = require_premium_user(request)
    s = db.share_session_get(int(session_id))
    if not s:
        raise HTTPException(status_code=404, detail="Share not found")
    _assert_same_trust(hr, s)
    if str(s.get("share_kind") or "review").lower() == "portfolio":
        raise HTTPException(
            status_code=400,
            detail="This is a reference-only pack (already verified elsewhere). No further verification is required.",
        )
    # Ensure item exists in session
    item = next(
        (it for it in (s.get("items") or []) if it.get("credential_id") == credential_id),
        None,
    )
    if not item:
        raise HTTPException(status_code=404, detail="Item not found in share")
    db.share_item_set_decision(int(session_id), str(credential_id), int(hr["id"]), status="VERIFIED")
    trust_label = (hr.get("current_trust") or s.get("target_trust") or "").strip()
    mod = (item.get("module_name") or credential_id or "Training").strip()
    _notify_clinician_hr_training(
        int(s["doctor_user_id"]),
        kind="hr_verified",
        module_name=mod,
        trust_name=trust_label,
    )
    _audit_hr_action(
        hr,
        "verify",
        doctor_user_id=int(s["doctor_user_id"]),
        credential_id=credential_id,
        session_id=int(session_id),
        detail=mod,
    )
    return {"ok": True}


@router.post("/hr/shares/{session_id}/items/{credential_id}/decline")
async def hr_share_item_decline(request: Request, session_id: int, credential_id: str):
    hr = require_premium_user(request)
    s = db.share_session_get(int(session_id))
    if not s:
        raise HTTPException(status_code=404, detail="Share not found")
    _assert_same_trust(hr, s)
    if str(s.get("share_kind") or "review").lower() == "portfolio":
        raise HTTPException(
            status_code=400,
            detail="This is a reference-only pack (already verified elsewhere). It cannot be declined here.",
        )
    if not any(it.get("credential_id") == credential_id for it in (s.get("items") or [])):
        raise HTTPException(status_code=404, detail="Item not found in share")
    try:
        body = await request.json()
    except Exception:
        body = {}
    reason = ""
    if isinstance(body, dict):
        reason = str(body.get("reason") or "").strip()
    if not reason:
        raise HTTPException(status_code=400, detail="Decline reason required")
    item = next(
        (it for it in (s.get("items") or []) if it.get("credential_id") == credential_id),
        None,
    )
    db.share_item_set_decision(int(session_id), str(credential_id), int(hr["id"]), status="DECLINED", decline_reason=reason)
    trust_label = (hr.get("current_trust") or s.get("target_trust") or "").strip()
    mod = ((item or {}).get("module_name") or credential_id or "Training").strip()
    _notify_clinician_hr_training(
        int(s["doctor_user_id"]),
        kind="hr_declined",
        module_name=mod,
        trust_name=trust_label,
        decline_reason=reason,
    )
    _audit_hr_action(
        hr,
        "decline",
        doctor_user_id=int(s["doctor_user_id"]),
        credential_id=credential_id,
        session_id=int(session_id),
        detail=reason,
        meta={"module_name": mod},
    )
    return {"ok": True}


@router.post("/hr/shares/{session_id}/items/{credential_id}/unverify")
def hr_share_item_unverify(request: Request, session_id: int, credential_id: str):
    """Revert a verified share item to pending so HR can review again."""
    hr = require_premium_user(request)
    s = db.share_session_get(int(session_id))
    if not s:
        raise HTTPException(status_code=404, detail="Share not found")
    _assert_same_trust(hr, s)
    if str(s.get("share_kind") or "review").lower() == "portfolio":
        raise HTTPException(
            status_code=400,
            detail="This is a reference-only pack (already verified elsewhere). It cannot be changed here.",
        )
    item = next(
        (it for it in (s.get("items") or []) if it.get("credential_id") == credential_id),
        None,
    )
    if not item:
        raise HTTPException(status_code=404, detail="Item not found in share")
    if str(item.get("status") or "").upper() != "VERIFIED":
        raise HTTPException(status_code=400, detail="Only verified records can be unverified.")
    db.share_item_set_decision(int(session_id), str(credential_id), int(hr["id"]), status="PENDING")
    trust_label = (hr.get("current_trust") or s.get("target_trust") or "").strip()
    mod = (item.get("module_name") or credential_id or "Training").strip()
    _notify_clinician_hr_training(
        int(s["doctor_user_id"]),
        kind="hr_unverified",
        module_name=mod,
        trust_name=trust_label,
    )
    _audit_hr_action(
        hr,
        "unverify",
        doctor_user_id=int(s["doctor_user_id"]),
        credential_id=credential_id,
        session_id=int(session_id),
        detail=mod,
    )
    return {"ok": True}


@router.post("/hr/doctors/{doctor_user_id}/credentials/{credential_id}/unverify")
def hr_doctor_credential_unverify(request: Request, doctor_user_id: int, credential_id: str):
    """
    Premium HR: remove verification for a credential (HR-issued attestation or shared item
    verified at this trust).
    """
    hr = require_premium_user(request)
    trust = (hr.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set.")
    with __import__("sqlite3").connect(db.DB_PATH) as conn:
        if not db._doctor_visible_to_trust(int(doctor_user_id), trust, conn):
            raise HTTPException(
                status_code=403,
                detail="This clinician has not permitted your trust to view or update their records.",
            )
    cid = str(credential_id).strip()
    mod = cid
    wallet = []
    try:
        wallet = json.loads(db.user_wallet_get(int(doctor_user_id)))
    except Exception:
        wallet = []
    if isinstance(wallet, list):
        for c in wallet:
            if isinstance(c, dict) and str(c.get("credential_id")) == cid:
                mod = (c.get("module_name") or cid).strip()
                break
    if db.hr_attestation_delete(int(doctor_user_id), cid, trust):
        _notify_clinician_hr_training(
            int(doctor_user_id),
            kind="hr_unverified",
            module_name=mod,
            trust_name=trust,
        )
        _audit_hr_action(
            hr,
            "unverify",
            doctor_user_id=int(doctor_user_id),
            credential_id=cid,
            detail=mod,
            meta={"source": "hr_attestation"},
        )
        return {"ok": True, "source": "hr_attestation"}
    found = db.share_item_find_verified_for_trust(int(doctor_user_id), cid, trust)
    if found:
        if str(found.get("share_kind") or "review").lower() == "portfolio":
            raise HTTPException(
                status_code=400,
                detail="This is a reference-only pack (already verified elsewhere). It cannot be changed here.",
            )
        db.share_item_set_decision(int(found["session_id"]), cid, int(hr["id"]), status="PENDING")
        _notify_clinician_hr_training(
            int(doctor_user_id),
            kind="hr_unverified",
            module_name=mod,
            trust_name=trust,
        )
        _audit_hr_action(
            hr,
            "unverify",
            doctor_user_id=int(doctor_user_id),
            credential_id=cid,
            session_id=int(found["session_id"]),
            detail=mod,
            meta={"source": "share"},
        )
        return {"ok": True, "source": "share", "session_id": found["session_id"]}
    raise HTTPException(status_code=404, detail="No verified record found for this clinician at your trust.")


# ── Phase 0: notifications, audit, compliance snapshots ─────────────────────

@router.get("/me/notifications")
def me_notifications_list(request: Request, limit: int = 50, unread_only: bool = False):
    uid = require_user_id(request)
    return {
        "items": db.notifications_list(uid, limit=limit, unread_only=unread_only),
        "unread_count": db.notifications_unread_count(uid),
    }


@router.get("/me/notifications/unread-count")
def me_notifications_unread_count(request: Request):
    uid = require_user_id(request)
    return {"count": db.notifications_unread_count(uid)}


@router.post("/me/notifications/{notification_id}/read")
def me_notification_mark_read(request: Request, notification_id: int):
    uid = require_user_id(request)
    if not db.notification_mark_read(int(notification_id), uid):
        raise HTTPException(status_code=404, detail="Notification not found")
    return {"ok": True, "unread_count": db.notifications_unread_count(uid)}


@router.post("/me/notifications/read-all")
def me_notifications_read_all(request: Request):
    uid = require_user_id(request)
    n = db.notifications_mark_all_read(uid)
    return {"ok": True, "marked": n, "unread_count": 0}


@router.get("/me/compliance-snapshot")
def me_compliance_snapshot(request: Request):
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    trust = (u.get("current_trust") or "").strip()
    if not trust:
        return {"snapshot": None, "message": "Set your current trust in Profile to see mandatory requirements."}
    _try_seed_mandatory_from_pack(trust)
    return {"snapshot": compliance_snapshot.doctor_compliance_snapshot(uid, trust)}


@router.get("/hr/audit-log")
def hr_audit_log(request: Request, limit: int = 100, offset: int = 0, action: Optional[str] = None):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {
        "items": db.hr_audit_log_list(trust, limit=limit, offset=offset, action=action or None),
        "trust": trust,
    }


@router.get("/hr/compliance/expiring")
def hr_compliance_expiring(
    request: Request,
    window_days: int = 90,
    cohort_id: Optional[int] = None,
):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return compliance_snapshot.trust_expiring_report(
        trust, window_days=window_days, cohort_id=cohort_id
    )


@router.get("/hr/cohorts/{cohort_id}/compliance-snapshot")
def hr_cohort_compliance_snapshot(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    snap = compliance_snapshot.cohort_compliance_snapshot(int(cohort_id), trust)
    if not snap:
        raise HTTPException(status_code=404, detail="Cohort not found")
    return {"snapshot": snap}


@router.get("/hr/cohorts/{cohort_id}/compliance-export")
def hr_cohort_compliance_export(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    result = compliance_snapshot.cohort_compliance_csv(int(cohort_id), trust)
    if not result:
        raise HTTPException(status_code=404, detail="Cohort not found")
    filename, csv_text = result
    return Response(
        content=csv_text,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ── Phase 3: trust move, bulk templates, verifier links, welcome templates ───


@router.get("/me/trust-move/candidates")
def me_trust_move_candidates(request: Request):
    """HR-verified wallet items eligible for a portfolio reference pack."""
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    items = db.doctor_verified_bundle_items(uid)
    return {
        "current_trust": (u.get("current_trust") or "").strip() or None,
        "items": items,
    }


@router.post("/me/trust-move/complete")
async def me_trust_move_complete(request: Request):
    """
    Update current trust, create portfolio share for selected verified credentials.
    """
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    require_profile_complete(u)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected JSON object")
    from .trust_packs import normalize_stored_trust_name

    new_trust = normalize_stored_trust_name((body.get("new_trust") or "").strip())
    if not new_trust:
        raise HTTPException(status_code=400, detail="new_trust is required")
    ids = body.get("portfolio_credential_ids") or []
    if not isinstance(ids, list):
        raise HTTPException(status_code=400, detail="portfolio_credential_ids must be a list")
    ids = [str(x).strip() for x in ids if str(x).strip()]
    if body.get("update_profile", True):
        db.user_set_profile(
            uid,
            (u.get("display_name") or "").strip() or None,
            (u.get("gmc_number") or "").strip() or None,
            new_trust,
        )
    portfolio_session = None
    share_url = None
    if ids:
        wallet_raw = db.user_wallet_get(uid)
        try:
            wallet = json.loads(wallet_raw)
        except Exception:
            wallet = []
        if not isinstance(wallet, list):
            wallet = []
        wallet_by_id = {
            str(c.get("credential_id")): c
            for c in wallet
            if isinstance(c, dict) and c.get("credential_id")
        }
        vmap = db.doctor_verified_map(uid)
        items = []
        for cid in ids:
            if str(vmap.get(cid, {}).get("status") or "").upper() != "VERIFIED":
                raise HTTPException(
                    status_code=400,
                    detail=f"Credential {cid} is not HR-verified and cannot go in a reference pack.",
                )
            w = wallet_by_id.get(cid) or {}
            issuing = _issuing_trust_from_wallet_entry(w)
            entry = {
                "credential_id": cid,
                "module_name": w.get("module_name"),
                "expiry_date": w.get("expiry_date"),
                "certificate_base64": w.get("certificate_base64"),
                "certificate_filename": w.get("certificate_filename"),
                "issuing_trust_name": issuing,
            }
            prior = db.share_portfolio_prior_decision_at(uid, cid)
            entry["portfolio_verified_at"] = prior or datetime.utcnow().isoformat()
            entry["verified_by_trust_name"] = db.share_portfolio_prior_verifier_trust(uid, cid)
            items.append(entry)
        created = db.share_session_create(
            doctor_user_id=uid,
            doctor_email=u.get("email") or "",
            items=items,
            share_kind="portfolio",
            target_trust=new_trust,
        )
        portfolio_session = created.get("session_id")
        base = _public_app_base(request)
        share_url = f"{base}/static/hr/?session={portfolio_session}"
    snap = None
    try:
        from . import compliance_snapshot

        snap = compliance_snapshot.doctor_compliance_snapshot(uid, new_trust)
    except Exception:
        snap = None
    return {
        "ok": True,
        "new_trust": new_trust,
        "portfolio_session_id": portfolio_session,
        "share_url": share_url,
        "compliance_at_new_trust": snap,
    }


@router.get("/public/verifier-link/{token}")
def public_verifier_link_bundle(request: Request, token: str):
    """Read-only verified training bundle for staffing (no login)."""
    row = db.verifier_link_get_by_token(token)
    if not row:
        raise HTTPException(status_code=404, detail="Link not found")
    payload = db.verifier_link_bundle_payload(row)
    if not payload:
        raise HTTPException(status_code=410, detail="This link has expired or been revoked")
    return payload


@router.get("/hr/verifier-links")
def hr_verifier_links_list_api(request: Request, limit: int = 50):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"items": db.verifier_links_list(trust, limit=limit), "trust": trust}


@router.post("/hr/verifier-links")
async def hr_verifier_links_create(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected JSON object")
    doctor_user_id = body.get("doctor_user_id")
    cohort_id = body.get("cohort_id")
    try:
        link = db.verifier_link_create(
            hr_trust=trust,
            created_by_user_id=int(hr["id"]),
            doctor_user_id=int(doctor_user_id) if doctor_user_id else None,
            cohort_id=int(cohort_id) if cohort_id else None,
            label=(body.get("label") or "").strip() or None,
            expires_days=int(body.get("expires_days") or 14),
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    base = _public_app_base(request)
    url = f"{base}/static/verifier/bundle.html?token={link['token']}"
    _audit_hr_action(
        hr,
        "verifier_link_created",
        doctor_user_id=int(doctor_user_id) if doctor_user_id else None,
        detail=link.get("label") or url,
        meta={"link_id": link.get("id"), "cohort_id": cohort_id},
    )
    return {"ok": True, "link": link, "url": url}


@router.post("/hr/verifier-links/{link_id}/revoke")
def hr_verifier_link_revoke(request: Request, link_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.verifier_link_revoke(int(link_id), trust):
        raise HTTPException(status_code=404, detail="Link not found")
    return {"ok": True}


@router.get("/hr/bulk-templates")
def hr_bulk_templates_list_api(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"templates": db.hr_bulk_templates_list(trust), "trust": trust}


@router.post("/hr/bulk-templates")
async def hr_bulk_templates_save_api(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected JSON object")
    name = (body.get("name") or "").strip()
    payload = body.get("payload")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload object required")
    tid = body.get("id")
    tmpl = db.hr_bulk_template_save(
        trust,
        int(hr["id"]),
        name,
        payload,
        template_id=int(tid) if tid else None,
    )
    return {"ok": True, "template": tmpl}


@router.delete("/hr/bulk-templates/{template_id}")
def hr_bulk_templates_delete_api(request: Request, template_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.hr_bulk_template_delete(int(template_id), trust):
        raise HTTPException(status_code=404, detail="Template not found")
    return {"ok": True}


@router.get("/hr/welcome-templates")
def hr_welcome_templates_list_api(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"templates": db.hr_welcome_templates_list(trust), "trust": trust}


@router.post("/hr/welcome-templates")
async def hr_welcome_templates_save_api(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Expected JSON object")
    tmpl = db.hr_welcome_template_save(
        trust,
        (body.get("name") or "").strip() or "Template",
        (body.get("body") or "").strip(),
        topic_id=body.get("topic_id"),
        template_id=int(body["id"]) if body.get("id") else None,
    )
    return {"ok": True, "template": tmpl}


@router.delete("/hr/welcome-templates/{template_id}")
def hr_welcome_templates_delete_api(request: Request, template_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.hr_welcome_template_delete(int(template_id), trust):
        raise HTTPException(status_code=404, detail="Template not found")
    return {"ok": True}


@router.get("/hr/cohorts/{cohort_id}/welcome-template-suggestions")
def hr_cohort_welcome_template_suggestions(request: Request, cohort_id: int):
    """Suggest welcome templates based on mandatory gaps in the cohort."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    snap = compliance_snapshot.cohort_compliance_snapshot(int(cohort_id), trust)
    if not snap:
        raise HTTPException(status_code=404, detail="Cohort not found")
    gap_topics = [
        t for t in (snap.get("topics") or [])
        if int(t.get("gap") or 0) > 0 or int(t.get("expiring") or 0) > 0
    ]
    all_tmpl = db.hr_welcome_templates_list(trust)
    suggested = []
    for gt in gap_topics:
        tname = (gt.get("topic_name") or "").strip().lower()
        tid = gt.get("topic_id")
        for tmpl in all_tmpl:
            if tmpl.get("topic_id") and tid and int(tmpl["topic_id"]) == int(tid):
                suggested.append({**tmpl, "reason": "Matches gap topic: " + (gt.get("topic_name") or "")})
                break
            elif tmpl.get("topic_name") and tname and tname in (tmpl.get("name") or "").lower():
                suggested.append({**tmpl, "reason": "Related to: " + (gt.get("topic_name") or "")})
                break
    return {
        "gap_topics": gap_topics,
        "suggested_templates": suggested,
        "all_templates": all_tmpl,
    }


# ── Mandatory topics ──────────────────────────────────────────────────────────

def _hr_trust_required(hr_user: dict) -> str:
    trust = (hr_user.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set in your profile.")
    return trust


def _parse_match_hints(body: dict) -> Optional[dict]:
    hints = body.get("match_hints")
    if isinstance(hints, dict):
        return hints
    subs = body.get("match_name_substrings")
    codes = body.get("match_module_codes")
    if subs or codes:
        out: dict = {}
        if codes:
            out["match_module_codes"] = codes
        if subs:
            out["match_name_substrings"] = subs
        return out
    return None


@router.get("/hr/mandatory-topics")
def hr_mandatory_topics_list(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    _try_seed_mandatory_from_pack(trust)
    return {
        "topics": db.mandatory_topics_list(trust, seed_defaults=False),
        "trust": trust,
        "pack_available": bool(_pack_id_for_hr_trust(trust)),
    }


def _pack_id_for_hr_trust(trust: str):
    from . import trust_packs

    return trust_packs.pack_id_for_trust_name(trust)


@router.post("/hr/mandatory-topics/seed-from-pack")
async def hr_mandatory_topics_seed_from_pack(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    from . import trust_packs

    try:
        body = await request.json()
    except Exception:
        body = {}
    pack_id = str(body.get("pack_id") or "").strip() or trust_packs.pack_id_for_trust_name(trust)
    if not pack_id:
        raise HTTPException(
            status_code=400,
            detail="No trust pack found for your profile trust name. Set current trust to match the pack display name or pass pack_id.",
        )
    pack = trust_packs.load_trust_pack(pack_id)
    if not pack:
        raise HTTPException(status_code=404, detail="Trust pack not found")
    n, msg = db.seed_mandatory_from_trust_pack(trust, pack)
    if n == 0 and "skipped" in msg.lower():
        raise HTTPException(status_code=409, detail=msg)
    return {"ok": True, "seeded": n, "message": msg, "topics": db.mandatory_topics_list(trust, seed_defaults=False)}


@router.post("/hr/mandatory-topics")
async def hr_mandatory_topic_add(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    topic_name = str(body.get("topic_name") or "").strip()
    category = str(body.get("category") or "").strip()
    if not topic_name:
        raise HTTPException(status_code=400, detail="topic_name is required")
    try:
        topic = db.mandatory_topic_add(
            trust,
            topic_name,
            category,
            delivery_channel=str(body.get("delivery_channel") or "").strip() or None,
            resource_url=str(body.get("resource_url") or "").strip() or None,
            match_hints=_parse_match_hints(body),
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return topic


@router.put("/hr/mandatory-topics/{topic_id}")
async def hr_mandatory_topic_update(request: Request, topic_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    topic_name = str(body.get("topic_name") or "").strip()
    category = str(body.get("category") or "").strip()
    if not topic_name:
        raise HTTPException(status_code=400, detail="topic_name is required")
    updated = db.mandatory_topic_update(
        int(topic_id),
        trust,
        topic_name,
        category,
        delivery_channel=str(body.get("delivery_channel") or "").strip() or None,
        resource_url=str(body.get("resource_url") or "").strip() or None,
        match_hints=_parse_match_hints(body),
        update_delivery_channel="delivery_channel" in body,
        update_resource_url="resource_url" in body,
        update_match_hints="match_hints" in body or "match_name_substrings" in body,
    )
    if not updated:
        raise HTTPException(status_code=404, detail="Topic not found")
    return {"ok": True}


@router.delete("/hr/mandatory-topics/{topic_id}")
def hr_mandatory_topic_delete(request: Request, topic_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    deleted = db.mandatory_topic_delete(int(topic_id), trust)
    if not deleted:
        raise HTTPException(status_code=404, detail="Topic not found")
    return {"ok": True}


@router.post("/hr/mandatory-topics/reorder")
async def hr_mandatory_topics_reorder(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    ids = body.get("ids")
    if not isinstance(ids, list):
        raise HTTPException(status_code=400, detail="ids must be a list")
    db.mandatory_topic_reorder(trust, [int(i) for i in ids])
    return {"ok": True}


# ── Messaging ─────────────────────────────────────────────────────────────────

def _get_conversation_assert_doctor(conv_id: int, doctor_user_id: int):
    """Fetch conversation and verify it belongs to this doctor."""
    convs = db.conversations_for_doctor(int(doctor_user_id))
    conv = next((c for c in convs if c["id"] == int(conv_id)), None)
    if not conv:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conv


def _get_conversation_assert_hr(conv_id: int, hr_trust: str):
    """Fetch conversation and verify it belongs to this HR trust."""
    convs = db.conversations_for_hr_trust(hr_trust)
    conv = next((c for c in convs if c["id"] == int(conv_id)), None)
    if not conv:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conv


async def _message_send_payload(request: Request) -> tuple[str, list[tuple[str, str, bytes]]]:
    """Parse JSON or multipart message send (body + optional files)."""
    ct = (request.headers.get("content-type") or "").lower()
    if "multipart/form-data" in ct:
        form = await request.form()
        text = str(form.get("body") or "").strip()
        attachments: list[tuple[str, str, bytes]] = []
        for uf in form.getlist("files"):
            if not hasattr(uf, "read"):
                continue
            raw = await uf.read()
            name = (getattr(uf, "filename", None) or "attachment").strip()
            mime = _hr_evidence_content_type(getattr(uf, "content_type", None), name)
            if not mime:
                raise HTTPException(
                    status_code=400,
                    detail=f"Unsupported file type for {name}. Use PDF or image (JPEG, PNG, WebP).",
                )
            if len(raw) > MAX_MESSAGE_ATTACHMENT_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail=f"File too large (max 5 MB): {name}",
                )
            attachments.append((name, mime, raw))
        if len(attachments) > MAX_MESSAGE_ATTACHMENTS:
            raise HTTPException(
                status_code=400,
                detail=f"Maximum {MAX_MESSAGE_ATTACHMENTS} attachments per message.",
            )
        return text, attachments
    try:
        raw = await request.json()
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    return str(raw.get("body") or "").strip(), []


def _require_message_content(text: str, attachments: list) -> None:
    if not (text or "").strip() and not attachments:
        raise HTTPException(
            status_code=400,
            detail="Message must include text or at least one attachment",
        )


@router.get("/messages/attachments/{attachment_id}")
def message_attachment_download(request: Request, attachment_id: int):
    uid = require_user_id(request)
    result = db.message_attachment_get_for_viewer(int(attachment_id), uid)
    if not result:
        raise HTTPException(status_code=404, detail="Attachment not found")
    meta, data = result
    fn = (meta.get("filename") or "attachment").replace('"', "")
    return Response(
        content=data,
        media_type=meta.get("content_type") or "application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{fn}"'},
    )


# Doctor endpoints
@router.get("/me/messages")
def me_messages_list(request: Request):
    uid = require_user_id(request)
    convs = db.conversations_for_doctor(uid)
    return {"conversations": convs}


@router.get("/me/messages/unread-count")
def me_messages_unread(request: Request):
    uid = require_user_id(request)
    return {"unread": db.messages_unread_count_for_doctor(uid)}


@router.get("/me/messages/{conv_id}")
def me_messages_thread(request: Request, conv_id: int):
    uid = require_user_id(request)
    _get_conversation_assert_doctor(conv_id, uid)
    msgs = db.messages_list(int(conv_id), viewer_user_id=uid, viewer_is_hr=False)
    return {"messages": msgs}


@router.get("/me/messaging-trusts")
def me_messaging_trusts_search(request: Request, q: str = ""):
    """Search trusts that have at least one premium (HR) inbox on this service."""
    require_user_id(request)
    return {"trusts": db.hr_messageable_trusts_search(q, limit=40)}


@router.post("/me/messages/start")
async def me_messages_start(request: Request):
    """Start (or retrieve) a conversation with HR for your profile trust, or another trust if hr_trust is set."""
    uid = require_user_id(request)
    user = db.user_get_by_id(uid)
    if not user:
        raise HTTPException(status_code=401, detail="Not signed in")
    body: dict = {}
    try:
        raw = await request.json()
        if isinstance(raw, dict):
            body = raw
    except Exception:
        body = {}
    explicit = str(body.get("hr_trust") or "").strip()
    if explicit:
        canonical = db.hr_messageable_trust_canonical(explicit)
        if not canonical:
            raise HTTPException(
                status_code=400,
                detail="No HR messaging inbox found for that trust. Use search to pick a trust on this demo.",
            )
        trust = canonical
    else:
        trust = (user.get("current_trust") or "").strip()
        if not trust:
            raise HTTPException(status_code=400, detail="Set your current trust in your profile before messaging HR.")
        trust = db.conversation_trust_canonical(trust)
    conv = db.conversation_get_or_create(uid, trust)
    return conv


@router.post("/me/messages/{conv_id}/send")
async def me_messages_send(request: Request, conv_id: int):
    uid = require_user_id(request)
    _get_conversation_assert_doctor(conv_id, uid)
    text, attachments = await _message_send_payload(request)
    _require_message_content(text, attachments)
    try:
        msg = db.message_send_body(int(conv_id), uid, text, attachments=attachments or None)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return msg


# HR endpoints
@router.get("/hr/messages/doctors/search")
def hr_messages_doctors_search(request: Request, q: str = "", limit: int = 30):
    """Search clinicians or cohorts by name to start a message."""
    hr = require_premium_user(request)
    results = db.hr_doctors_search_messaging(q=q, limit=limit)
    cohorts: list[dict] = []
    trust = (hr.get("current_trust") or "").strip()
    if trust:
        cohorts = db.hr_cohort_search_by_name(trust, q=q, limit=10)
    return {"results": results, "cohorts": cohorts}


@router.post("/hr/messages/start")
async def hr_messages_start(request: Request):
    """Start or open a conversation with any registered clinician."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    raw_id = body.get("doctor_user_id")
    if raw_id is None or raw_id == "":
        raise HTTPException(status_code=400, detail="doctor_user_id is required")
    try:
        doctor_id = int(raw_id)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="doctor_user_id must be an integer")
    doc = db.user_get_by_id(doctor_id)
    if not doc or db.user_is_premium(doc):
        raise HTTPException(status_code=404, detail="Clinician not found")
    if int(doc["id"]) == int(hr["id"]):
        raise HTTPException(status_code=400, detail="Cannot message yourself")
    conv = db.conversation_get_or_create(doctor_id, trust)
    return conv


def _parse_doctor_user_ids(raw) -> list[int]:
    if raw is None:
        return []
    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, str):
        raw = raw.strip()
        if not raw:
            return []
        try:
            parsed = json.loads(raw)
            items = parsed if isinstance(parsed, list) else [parsed]
        except json.JSONDecodeError:
            items = [p for p in raw.replace(",", " ").split() if p.strip()]
    else:
        items = [raw]
    out: list[int] = []
    seen: set[int] = set()
    for item in items:
        try:
            uid = int(item)
        except (TypeError, ValueError):
            continue
        if uid in seen:
            continue
        seen.add(uid)
        out.append(uid)
    return out


@router.post("/hr/messages/broadcast")
async def hr_messages_broadcast(
    request: Request,
    stream: bool = Query(False),
):
    """Send the same message to multiple clinicians (separate private threads each)."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    ct = (request.headers.get("content-type") or "").lower()
    if "multipart/form-data" in ct:
        form = await request.form()
        if not stream:
            stream = str(form.get("stream") or "").strip().lower() in ("1", "true", "yes")
        doctor_ids = _parse_doctor_user_ids(form.get("doctor_user_ids"))
        text = str(form.get("body") or "").strip()
        attachments: list[tuple[str, str, bytes]] = []
        for uf in form.getlist("files"):
            if not hasattr(uf, "read"):
                continue
            raw = await uf.read()
            name = (getattr(uf, "filename", None) or "attachment").strip()
            mime = _hr_evidence_content_type(getattr(uf, "content_type", None), name)
            if not mime:
                raise HTTPException(
                    status_code=400,
                    detail=f"Unsupported file type for {name}. Use PDF or image (JPEG, PNG, WebP).",
                )
            if len(raw) > MAX_MESSAGE_ATTACHMENT_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail=f"File too large (max 5 MB): {name}",
                )
            attachments.append((name, mime, raw))
        if len(attachments) > MAX_MESSAGE_ATTACHMENTS:
            raise HTTPException(
                status_code=400,
                detail=f"Maximum {MAX_MESSAGE_ATTACHMENTS} attachments per message.",
            )
    else:
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON")
        if not isinstance(body, dict):
            raise HTTPException(status_code=400, detail="Invalid JSON")
        doctor_ids = _parse_doctor_user_ids(body.get("doctor_user_ids"))
        text = str(body.get("body") or "").strip()
        attachments = []
        if not stream:
            stream = bool(body.get("stream"))
    if not doctor_ids:
        raise HTTPException(status_code=400, detail="Select at least one clinician")
    if len(doctor_ids) > MAX_HR_COHORT_LINES:
        raise HTTPException(
            status_code=400,
            detail=f"Too many recipients (maximum {MAX_HR_COHORT_LINES})",
        )
    _require_message_content(text, attachments)
    if int(hr["id"]) in doctor_ids:
        raise HTTPException(status_code=400, detail="Cannot message yourself")
    if stream:
        return StreamingResponse(
            _ndjson_stream_wrap(
                _hr_broadcast_stream(
                    int(hr["id"]),
                    trust,
                    doctor_ids,
                    text,
                    attachments=attachments or None,
                )
            ),
            media_type="application/x-ndjson",
            headers=NDJSON_STREAM_HEADERS,
        )
    return _hr_broadcast_to_doctors(
        int(hr["id"]), trust, doctor_ids, text, attachments=attachments or None
    )


@router.get("/hr/messages")
def hr_messages_list(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    convs = db.conversations_for_hr_trust(trust)
    return {"conversations": convs}


@router.get("/hr/messages/unread-count")
def hr_messages_unread(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"unread": db.messages_unread_count_for_hr(trust)}


@router.get("/hr/messages/{conv_id}")
def hr_messages_thread(request: Request, conv_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    _get_conversation_assert_hr(conv_id, trust)
    msgs = db.messages_list(int(conv_id), viewer_user_id=int(hr["id"]), viewer_is_hr=True)
    return {"messages": msgs}


@router.post("/hr/messages/{conv_id}/send")
async def hr_messages_send(request: Request, conv_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    _get_conversation_assert_hr(conv_id, trust)
    text, attachments = await _message_send_payload(request)
    _require_message_content(text, attachments)
    try:
        msg = db.message_send_body(
            int(conv_id), int(hr["id"]), text, attachments=attachments or None
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return msg


# ── HR cohorts (provision clinicians + group messaging) ─────────────────────


def _cohort_reserved_emails() -> set[str]:
    return {
        db.DEV_SEED_EMAIL.strip().lower(),
        db.DEV_SEED_EMAIL_ROTHERHAM.strip().lower(),
    }


def _parse_cohort_emails(raw_emails) -> list[str]:
    if isinstance(raw_emails, list):
        lines = [str(x).strip() for x in raw_emails if str(x).strip()]
    elif isinstance(raw_emails, str):
        lines = _parse_roster_lines(raw_emails)
    else:
        lines = []
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        email = _normalize_email(line.split(",")[0].strip())
        if not email or email in seen:
            continue
        seen.add(email)
        out.append(email)
    return out


def _cohort_member_from_item(item) -> Optional[dict]:
    """Normalize one roster row: personal_email (login) required."""
    if isinstance(item, str):
        personal = _normalize_email(item)
        return {"personal_email": personal} if personal else None
    if not isinstance(item, dict):
        return None
    personal = _normalize_email(
        str(
            item.get("personal_email")
            or item.get("personal")
            or item.get("login_email")
            or item.get("email")
            or ""
        )
    )
    if personal and not EMAIL_RE.match(personal):
        personal = ""
    if not personal:
        return None
    dn = str(item.get("display_name") or item.get("full_name") or item.get("name") or "").strip()
    gmc_raw = str(item.get("gmc_number") or item.get("gmc") or "").strip()
    out: dict = {"personal_email": personal}
    if dn:
        out["display_name"] = dn
    if gmc_raw:
        out["gmc_number"] = gmc_raw
    return out


def _parse_cohort_members(body: dict) -> list[dict]:
    """
    Accept members: [{personal_email, display_name?, gmc_number?}, ...]
    or legacy emails: [string, ...].
    """
    raw_members = body.get("members")
    if raw_members is not None:
        if not isinstance(raw_members, list):
            raise HTTPException(status_code=400, detail="members must be a list")
        seen: set[str] = set()
        out: list[dict] = []
        for item in raw_members:
            row = _cohort_member_from_item(item)
            key = row.get("personal_email") if row else ""
            if not row or key in seen:
                continue
            seen.add(key)
            out.append(row)
        return out
    emails = _parse_cohort_emails(body.get("emails"))
    return [{"personal_email": e} for e in emails]


def _validate_cohort_members(members: list[dict]) -> None:
    if not members:
        raise HTTPException(status_code=400, detail="At least one personal email address is required")
    if len(members) > MAX_HR_COHORT_LINES:
        raise HTTPException(
            status_code=400,
            detail=f"Too many rows ({len(members)}). Maximum is {MAX_HR_COHORT_LINES}.",
        )
    for row in members:
        personal = row.get("personal_email") or ""
        if not EMAIL_RE.match(personal):
            raise HTTPException(status_code=400, detail=f"Invalid personal email: {personal}")
        gmc = _normalize_gmc(str(row.get("gmc_number") or ""))
        if row.get("gmc_number") and gmc and not GMC_RE.match(gmc):
            raise HTTPException(
                status_code=400,
                detail=f"GMC number for {personal} must be exactly 7 digits",
            )


def _hr_broadcast_to_doctors(
    hr_user_id: int,
    hr_trust: str,
    doctor_ids: list[int],
    body: str,
    attachments: Optional[list[tuple[str, str, bytes]]] = None,
    *,
    on_progress: Optional[Callable[[str, str, int, int], None]] = None,
) -> dict:
    sent = 0
    failed: list[dict] = []
    att = attachments or None
    total = len(doctor_ids)
    for idx, did in enumerate(doctor_ids):
        if on_progress:
            on_progress(
                "send",
                f"Sending message {idx + 1} of {total}…",
                idx + 1,
                total,
            )
        try:
            doc = db.user_get_by_id(int(did))
            if not doc or db.user_is_premium(doc):
                failed.append({"doctor_user_id": did, "error": "clinician not found"})
                continue
            conv = db.conversation_get_or_create(int(did), hr_trust)
            db.message_send_body(int(conv["id"]), int(hr_user_id), body, attachments=att)
            sent += 1
        except Exception as e:
            failed.append({"doctor_user_id": did, "error": str(e)})
    return {"sent": sent, "failed": failed}


def _hr_broadcast_stream(
    hr_user_id: int,
    hr_trust: str,
    doctor_ids: list[int],
    body: str,
    attachments: Optional[list[tuple[str, str, bytes]]] = None,
) -> Iterator[str]:
    total = len(doctor_ids)
    yield _ndjson_progress_line(
        "prepare",
        f"Preparing to message {total} clinician{'s' if total != 1 else ''}…",
        0,
        total,
    )
    sent = 0
    failed: list[dict] = []
    att = attachments or None
    for idx, did in enumerate(doctor_ids):
        yield _ndjson_progress_line(
            "send",
            f"Sending message {idx + 1} of {total}…",
            idx + 1,
            total,
        )
        try:
            doc = db.user_get_by_id(int(did))
            if not doc or db.user_is_premium(doc):
                failed.append({"doctor_user_id": did, "error": "clinician not found"})
                continue
            conv = db.conversation_get_or_create(int(did), hr_trust)
            db.message_send_body(int(conv["id"]), int(hr_user_id), body, attachments=att)
            sent += 1
        except Exception as e:
            failed.append({"doctor_user_id": did, "error": str(e)})
    yield _ndjson_complete_line({"sent": sent, "failed": failed})


def _hr_process_pending_welcomes(user_id: int) -> int:
    """
    Send queued cohort welcome message(s) once the clinician profile is complete.
    One message per HR trust; uses profile display name when set.
    Returns number of trust-level welcomes sent.
    """
    doc = db.user_get_by_id(int(user_id))
    if not doc or db.user_is_premium(doc) or not _profile_is_complete(doc):
        return 0
    pending = db.cohort_pending_welcomes_for_user(int(user_id))
    if not pending:
        return 0
    by_trust: dict[str, dict] = {}
    for row in pending:
        key = (row.get("hr_trust") or "").strip().lower()
        if key and key not in by_trust:
            by_trust[key] = row
    sent = 0
    cohort_ids: list[int] = []
    for row in pending:
        cohort_ids.append(int(row["cohort_id"]))
    for row in by_trust.values():
        trust = row["hr_trust"]
        try:
            text = _cohort_welcome_message(doc, trust, int(row["cohort_id"]))
            conv = db.conversation_get_or_create(int(user_id), trust)
            db.message_send_body(
                int(conv["id"]), int(row["created_by_user_id"]), text
            )
            sent += 1
        except Exception:
            pass
    if cohort_ids:
        db.cohort_mark_welcome_sent_for_user(int(user_id), cohort_ids)
    return sent


def _hr_after_cohort_welcome_queue(user_ids: list[int]) -> dict:
    """Try to send queued welcomes immediately; count those still waiting on profile."""
    welcome_sent = 0
    welcome_queued = 0
    seen: set[int] = set()
    for raw_id in user_ids:
        if raw_id is None:
            continue
        uid = int(raw_id)
        if uid in seen:
            continue
        seen.add(uid)
        welcome_sent += _hr_process_pending_welcomes(uid)
        if db.cohort_pending_welcomes_for_user(uid):
            welcome_queued += 1
    return {"welcome_sent": welcome_sent, "welcome_queued": welcome_queued}


def _hr_welcome_send_stream(
    cohort_id: int,
    trust: str,
    hr: dict,
    user_ids: list[int],
) -> Iterator[str]:
    unique: list[int] = []
    seen: set[int] = set()
    for raw_id in user_ids:
        if raw_id is None:
            continue
        uid = int(raw_id)
        if uid in seen:
            continue
        seen.add(uid)
        unique.append(uid)
    total = len(unique)
    yield _ndjson_progress_line(
        "prepare",
        f"Preparing welcome message{'s' if total != 1 else ''} for {total} clinician{'s' if total != 1 else ''}…",
        0,
        total,
    )
    welcome_sent = 0
    welcome_queued = 0
    for idx, uid in enumerate(unique):
        yield _ndjson_progress_line(
            "welcome",
            f"Sending welcome {idx + 1} of {total}…",
            idx + 1,
            total,
        )
        welcome_sent += _hr_process_pending_welcomes(uid)
        if db.cohort_pending_welcomes_for_user(uid):
            welcome_queued += 1
    cohort = db.cohort_get(cohort_id, trust)
    meta = _welcome_template_meta(cohort or {}, hr) if cohort else {}
    yield _ndjson_complete_line(
        {
            "cohort": {**cohort, **meta} if cohort else None,
            "welcome_sent": welcome_sent,
            "welcome_queued": welcome_queued,
        }
    )


def _cohort_provision_stream(
    cohort_id: int,
    trust: str,
    members: list[dict],
    hr: dict,
    reserved: set[str],
    *,
    queue_welcome: bool,
    prepare_message: str,
) -> Iterator[str]:
    from . import trust_packs

    if not db.cohort_get(cohort_id, trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    processable = db.cohort_processable_members(members)
    total = len(processable)
    default_trust = trust_packs.trust_display_name(trust) or None
    yield _ndjson_progress_line("prepare", prepare_message, 0, total)
    results: list[dict] = []
    hr_user_id = int(hr["id"])
    for idx, row in enumerate(processable):
        yield _ndjson_progress_line(
            "provision",
            f"Adding clinician {idx + 1} of {total}…",
            idx + 1,
            total,
        )
        results.append(
            db.cohort_add_single_member(
                cohort_id,
                row,
                hr_user_id=hr_user_id,
                reserved_emails=reserved,
                queue_welcome=queue_welcome,
                default_trust=default_trust,
            )
        )
    user_ids = _cohort_member_user_ids_from_results(results)
    welcome_summary = _welcome_review_summary(user_ids)
    cohort = db.cohort_get(cohort_id, trust)
    meta = _welcome_template_meta(cohort or {}, hr) if cohort else {}
    payload = {
        "results": results,
        "cohort": {**cohort, **meta} if cohort else None,
        "summary": {
            "created": sum(1 for r in results if r.get("status") == "created"),
            "existing": sum(1 for r in results if r.get("status") == "existing"),
            "failed": sum(1 for r in results if r.get("status") == "failed"),
            **welcome_summary,
        },
    }
    yield _ndjson_complete_line(payload)


def _cohort_create_stream(
    trust: str,
    name: str,
    members: list[dict],
    hr: dict,
    reserved: set[str],
) -> Iterator[str]:
    yield _ndjson_progress_line("prepare", f'Creating cohort “{name}”…', 0, 1)
    cohort_id = db.cohort_create(trust, name, int(hr["id"]))
    yield from _cohort_provision_stream(
        cohort_id,
        trust,
        members,
        hr,
        reserved,
        queue_welcome=True,
        prepare_message=f"Provisioning accounts for “{name}”…",
    )


def _cohort_member_user_ids_from_results(results: list[dict]) -> list[int]:
    ids: list[int] = []
    seen: set[int] = set()
    for row in results:
        if row.get("status") not in ("created", "existing"):
            continue
        raw = row.get("user_id")
        if raw is None:
            continue
        uid = int(raw)
        if uid in seen:
            continue
        seen.add(uid)
        ids.append(uid)
    return ids


def _welcome_review_summary(user_ids: list[int]) -> dict:
    n = len(user_ids)
    if not n:
        return {"welcome_awaiting_review": 0}
    return {"welcome_awaiting_review": n}


@router.get("/hr/cohorts")
def hr_cohorts_list(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"cohorts": db.cohort_list_for_trust(trust)}


@router.post("/hr/cohorts")
async def hr_cohorts_create(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    name = str(body.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="Cohort name is required")
    members = _parse_cohort_members(body)
    _validate_cohort_members(members)
    stream = bool(body.get("stream"))
    reserved = _cohort_reserved_emails()

    if stream:
        return StreamingResponse(
            _ndjson_stream_wrap(
                _cohort_create_stream(trust, name, members, hr, reserved)
            ),
            media_type="application/x-ndjson",
            headers=NDJSON_STREAM_HEADERS,
        )

    cohort_id = db.cohort_create(trust, name, int(hr["id"]))
    results = db.cohort_add_members(
        cohort_id,
        trust,
        members,
        int(hr["id"]),
        reserved,
        queue_welcome=True,
    )
    user_ids = _cohort_member_user_ids_from_results(results)
    welcome_summary = _welcome_review_summary(user_ids)

    created = sum(1 for r in results if r.get("status") == "created")
    existing = sum(1 for r in results if r.get("status") == "existing")
    failed = sum(1 for r in results if r.get("status") == "failed")

    cohort = db.cohort_get(cohort_id, trust)
    meta = _welcome_template_meta(cohort or {}, hr) if cohort else {}
    return {
        "cohort": {**cohort, **meta} if cohort else None,
        "results": results,
        "summary": {
            "created": created,
            "existing": existing,
            "failed": failed,
            **welcome_summary,
        },
    }


@router.delete("/hr/cohorts/{cohort_id}")
def hr_cohorts_delete(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_delete(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    return {"ok": True, "deleted_cohort_id": int(cohort_id)}


@router.get("/hr/cohorts/{cohort_id}")
def hr_cohorts_detail(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    cohort = db.cohort_get(int(cohort_id), trust)
    if not cohort:
        raise HTTPException(status_code=404, detail="Cohort not found")
    members = db.cohort_members_list(int(cohort_id), trust)
    meta = _welcome_template_meta(cohort, hr)
    return {
        "cohort": {**cohort, **meta},
        "members": members,
    }


@router.patch("/hr/cohorts/{cohort_id}")
async def hr_cohorts_patch(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if "welcome_message_template" not in body:
        raise HTTPException(status_code=400, detail="No fields to update")
    tmpl = _normalize_welcome_template(body.get("welcome_message_template"))
    cohort = db.cohort_set_welcome_template(int(cohort_id), trust, tmpl)
    if not cohort:
        raise HTTPException(status_code=404, detail="Cohort not found")
    meta = _welcome_template_meta(cohort, hr)
    return {"cohort": {**cohort, **meta}}


@router.patch("/hr/cohorts/{cohort_id}/members/{doctor_user_id}")
async def hr_cohort_member_update(
    request: Request, cohort_id: int, doctor_user_id: int
):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    display_name = body.get("display_name") if "display_name" in body else None
    gmc_raw = body.get("gmc_number") if "gmc_number" in body else None
    if gmc_raw is not None:
        gmc = _normalize_gmc(str(gmc_raw or ""))
        if str(gmc_raw).strip() and gmc and not GMC_RE.match(gmc):
            raise HTTPException(
                status_code=400,
                detail="GMC number must be exactly 7 digits",
            )
    member = db.cohort_member_update_profile(
        int(cohort_id),
        int(doctor_user_id),
        trust,
        display_name=display_name if "display_name" in body else None,
        gmc_number=gmc_raw if "gmc_number" in body else None,
    )
    if not member:
        raise HTTPException(status_code=404, detail="Member not found")
    return {"member": member}


@router.delete("/hr/cohorts/{cohort_id}/members/{doctor_user_id}")
def hr_cohort_member_remove(request: Request, cohort_id: int, doctor_user_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_member_remove(int(cohort_id), int(doctor_user_id), trust):
        raise HTTPException(status_code=404, detail="Member not found")
    return {"ok": True, "removed_user_id": int(doctor_user_id)}


@router.post("/hr/cohorts/{cohort_id}/members")
async def hr_cohorts_add_members(request: Request, cohort_id: int):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    members = _parse_cohort_members(body)
    _validate_cohort_members(members)
    stream = bool(body.get("stream"))
    reserved = _cohort_reserved_emails()
    cid = int(cohort_id)

    if stream:
        cohort = db.cohort_get(cid, trust) or {}
        cname = cohort.get("name") or f"Cohort {cid}"
        return StreamingResponse(
            _ndjson_stream_wrap(
                _cohort_provision_stream(
                    cid,
                    trust,
                    members,
                    hr,
                    reserved,
                    queue_welcome=True,
                    prepare_message=f'Adding clinicians to “{cname}”…',
                )
            ),
            media_type="application/x-ndjson",
            headers=NDJSON_STREAM_HEADERS,
        )

    results = db.cohort_add_members(
        cid,
        trust,
        members,
        int(hr["id"]),
        reserved,
        queue_welcome=True,
    )
    user_ids = _cohort_member_user_ids_from_results(results)
    welcome_summary = _welcome_review_summary(user_ids)

    cohort = db.cohort_get(cid, trust)
    meta = _welcome_template_meta(cohort or {}, hr) if cohort else {}

    return {
        "results": results,
        "cohort": {**cohort, **meta} if cohort else None,
        "summary": {
            "created": sum(1 for r in results if r.get("status") == "created"),
            "existing": sum(1 for r in results if r.get("status") == "existing"),
            "failed": sum(1 for r in results if r.get("status") == "failed"),
            **welcome_summary,
        },
    }


@router.post("/hr/cohorts/{cohort_id}/welcome/send")
async def hr_cohorts_welcome_send(request: Request, cohort_id: int):
    """Send welcome message(s) after HR review (profile-complete now; others stay queued)."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    user_ids = _parse_doctor_user_ids(body.get("doctor_user_ids"))
    if not user_ids:
        raise HTTPException(status_code=400, detail="doctor_user_ids is required")
    if len(user_ids) > MAX_HR_COHORT_LINES:
        raise HTTPException(
            status_code=400,
            detail=f"Too many recipients (maximum {MAX_HR_COHORT_LINES})",
        )
    if "welcome_message_template" in body:
        tmpl = _normalize_welcome_template(body.get("welcome_message_template"))
        db.cohort_set_welcome_template(int(cohort_id), trust, tmpl)
    stream = bool(body.get("stream"))
    cid = int(cohort_id)
    if stream:
        return StreamingResponse(
            _ndjson_stream_wrap(_hr_welcome_send_stream(cid, trust, hr, user_ids)),
            media_type="application/x-ndjson",
            headers=NDJSON_STREAM_HEADERS,
        )
    welcome_summary = _hr_after_cohort_welcome_queue(user_ids)
    cohort = db.cohort_get(cid, trust)
    meta = _welcome_template_meta(cohort or {}, hr) if cohort else {}
    return {
        "cohort": {**cohort, **meta} if cohort else None,
        **welcome_summary,
    }


@router.post("/hr/cohorts/{cohort_id}/welcome/skip")
async def hr_cohorts_welcome_skip(request: Request, cohort_id: int):
    """Do not send a welcome message to these newly added members."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    user_ids = _parse_doctor_user_ids(body.get("doctor_user_ids"))
    if not user_ids:
        raise HTTPException(status_code=400, detail="doctor_user_ids is required")
    skipped = db.cohort_skip_welcome_for_users(int(cohort_id), trust, user_ids)
    return {"skipped": skipped, "doctor_user_ids": user_ids}


@router.get("/hr/cohorts/{cohort_id}/pending-verification")
def hr_cohort_pending_verification(request: Request, cohort_id: int):
    """Cohort members who still have training awaiting HR verification at this trust."""
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    members = db.cohort_members_pending_verification(int(cohort_id), trust)
    return {"members": members, "count": len(members)}


async def _cohort_message_payload(request: Request) -> tuple[str, list[tuple[str, str, bytes]], list[int]]:
    """Parse cohort broadcast body; optional doctor_user_ids limits recipients."""
    ct = (request.headers.get("content-type") or "").lower()
    subset: list[int] = []
    if "multipart/form-data" in ct:
        form = await request.form()
        subset = _parse_doctor_user_ids(form.get("doctor_user_ids"))
        text = str(form.get("body") or "").strip()
        attachments: list[tuple[str, str, bytes]] = []
        for uf in form.getlist("files"):
            if not hasattr(uf, "read"):
                continue
            raw = await uf.read()
            name = (getattr(uf, "filename", None) or "attachment").strip()
            mime = _hr_evidence_content_type(getattr(uf, "content_type", None), name)
            if not mime:
                raise HTTPException(
                    status_code=400,
                    detail=f"Unsupported file type for {name}. Use PDF or image (JPEG, PNG, WebP).",
                )
            if len(raw) > MAX_MESSAGE_ATTACHMENT_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail=f"File too large (max 5 MB): {name}",
                )
            attachments.append((name, mime, raw))
        if len(attachments) > MAX_MESSAGE_ATTACHMENTS:
            raise HTTPException(
                status_code=400,
                detail=f"Maximum {MAX_MESSAGE_ATTACHMENTS} attachments per message.",
            )
        return text, attachments, subset
    try:
        raw = await request.json()
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    subset = _parse_doctor_user_ids(raw.get("doctor_user_ids"))
    return str(raw.get("body") or "").strip(), [], subset


@router.post("/hr/cohorts/{cohort_id}/message")
async def hr_cohorts_message(
    request: Request,
    cohort_id: int,
    stream: bool = Query(False),
):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    if not db.cohort_get(int(cohort_id), trust):
        raise HTTPException(status_code=404, detail="Cohort not found")
    text, attachments, subset_ids = await _cohort_message_payload(request)
    _require_message_content(text, attachments)
    doctor_ids = db.cohort_member_user_ids(int(cohort_id), trust)
    if not doctor_ids:
        raise HTTPException(status_code=400, detail="Cohort has no members")
    if subset_ids:
        member_set = set(doctor_ids)
        doctor_ids = [d for d in subset_ids if d in member_set]
        if not doctor_ids:
            raise HTTPException(
                status_code=400,
                detail="No selected recipients are members of this cohort",
            )
    if len(doctor_ids) > MAX_HR_COHORT_LINES:
        raise HTTPException(status_code=400, detail="Cohort is too large to message in one request")
    if stream:
        return StreamingResponse(
            _ndjson_stream_wrap(
                _hr_broadcast_stream(
                    int(hr["id"]),
                    trust,
                    doctor_ids,
                    text,
                    attachments=attachments or None,
                )
            ),
            media_type="application/x-ndjson",
            headers=NDJSON_STREAM_HEADERS,
        )
    return _hr_broadcast_to_doctors(
        int(hr["id"]), trust, doctor_ids, text, attachments=attachments or None
    )
