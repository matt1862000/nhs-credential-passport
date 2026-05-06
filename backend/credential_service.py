"""
Credential issue, verify, revoke — core Phase 2 logic.
"""
import json
import re
import uuid
from datetime import datetime, date
from typing import Optional

from jose import jwt as jose_jwt

from . import db
from . import crypto
from . import pdf_gen
from .models import CompletionRecord, CredentialPayload, VerifyResponse


def normalize_staff_id(raw: str) -> str:
    """Normalize identifier for duplicate detection (GMC uses last 7 digits)."""
    s = (raw or "").strip()
    digits = re.sub(r"\D", "", s)
    if len(digits) >= 7:
        return digits[-7:]
    return re.sub(r"\s+", "", s.lower())


def completion_dedupe_key(rec: CompletionRecord) -> str:
    sid = normalize_staff_id(rec.staff_identifier)
    mc = (rec.module_code or "").strip().lower()
    cd = rec.completion_date.isoformat()
    ed = rec.expiry_date.isoformat()
    ods = (rec.issuing_trust_ods_code or "").strip().upper()
    return f"{sid}|{mc}|{cd}|{ed}|{ods}"


def _dedupe_key_from_claims(payload: dict) -> Optional[str]:
    try:
        sid = normalize_staff_id(str(payload.get("sub") or payload.get("esr_id") or ""))
        mc = str(payload.get("module_code") or "").strip().lower()
        cd = str(payload.get("completion_date") or "")[:10]
        ed = str(payload.get("expiry_date") or "")[:10]
        ods = str(payload.get("issuing_trust_ods") or "").strip().upper()
        if not (sid and mc and cd and ed and ods):
            return None
        return f"{sid}|{mc}|{cd}|{ed}|{ods}"
    except Exception:
        return None


def wallet_dedupe_keys(wallet_json: str) -> set[str]:
    """Build dedupe keys from stored wallet JWTs (same logic as new completions)."""
    keys: set[str] = set()
    try:
        arr = json.loads(wallet_json)
    except Exception:
        return keys
    if not isinstance(arr, list):
        return keys
    for item in arr:
        if not isinstance(item, dict):
            continue
        jwt_str = item.get("jwt")
        if not jwt_str:
            continue
        try:
            claims = jose_jwt.get_unverified_claims(jwt_str)
        except Exception:
            continue
        k = _dedupe_key_from_claims(claims)
        if k:
            keys.add(k)
    return keys


def get_verification_url_base(base_url: str) -> str:
    base = base_url.rstrip("/")
    return f"{base}/api/credentials/verify"


def issue_credentials(
    records: list[CompletionRecord],
    base_url: str,
    *,
    include_pdf: bool = True,
    skip_duplicate_keys: Optional[set[str]] = None,
) -> tuple[list[Optional[dict]], int]:
    """Issue one credential per completion record.

    When skip_duplicate_keys is provided, rows matching an existing key (wallet or
    earlier in this batch) are skipped — returns None in that slot.

    Returns (results aligned with records, number_skipped).
    Set include_pdf=False for large bulk issues (e.g. CSV import) to avoid huge responses and gateway timeouts.
    """
    issuer_did = crypto.get_issuer_did(base_url)
    verify_base = get_verification_url_base(base_url)
    results: list[Optional[dict]] = []
    skipped = 0
    skip_duplicate_keys = set(skip_duplicate_keys or ())
    seen_in_batch: set[str] = set()
    # Ensure DB schema once (avoid per-record DDL/locks during bulk import).
    db.init_db()

    for rec in records:
        key = completion_dedupe_key(rec)
        if key in skip_duplicate_keys or key in seen_in_batch:
            results.append(None)
            skipped += 1
            continue
        seen_in_batch.add(key)

        credential_id = f"nhs-el-{uuid.uuid4().hex[:24]}"
        issued_at = datetime.utcnow().isoformat() + "Z"
        sid = (rec.staff_identifier or "").strip()
        payload = {
            "sub": sid,
            "esr_id": sid,
            "name": rec.staff_full_name,
            "module_code": rec.module_code,
            "module_name": rec.module_name,
            "completion_date": rec.completion_date.isoformat(),
            "expiry_date": rec.expiry_date.isoformat(),
            "issuing_trust_ods": rec.issuing_trust_ods_code,
            "issuing_trust_name": rec.issuing_trust_name,
            "credential_id": credential_id,
            "issued_at": issued_at,
            "iss": issuer_did,
        }
        jwt_str = crypto.sign_credential(payload, credential_id)
        verification_url = f"{verify_base}/{credential_id}?jwt={jwt_str}"

        db.register_credential(credential_id, rec.expiry_date.isoformat())

        pdf_b64 = None
        if include_pdf:
            pdf_b64 = pdf_gen.credential_to_pdf_base64(
                staff_name=rec.staff_full_name,
                module_name=rec.module_name,
                completion_date=rec.completion_date.isoformat(),
                expiry_date=rec.expiry_date.isoformat(),
                issuing_trust_name=rec.issuing_trust_name,
                verification_url=verification_url,
                credential_id=credential_id,
            )

        results.append({
            "credential_id": credential_id,
            "verification_url": verification_url,
            "jwt": jwt_str,
            "pdf_base64": pdf_b64,
        })
        skip_duplicate_keys.add(key)
    return results, skipped


def verify_credential(credential_id=None, jwt_str=None) -> VerifyResponse:
    """
    Verify by credential_id (lookup in DB) and optionally verify JWT signature.
    If jwt_str is provided, decode and cross-check credential_id and expiry from payload.
    """
    db.init_db()

    # Prefer JWT if provided (covers QR/link flow)
    if jwt_str:
        payload, err = crypto.verify_jwt(jwt_str)
        if err:
            return VerifyResponse(
                status="UNVERIFIED",
                credential_id=credential_id or "unknown",
                message=f"Signature verification failed: {err}",
            )
        cred_id_from_jwt = payload.get("credential_id")
        if credential_id and cred_id_from_jwt != credential_id:
            return VerifyResponse(
                status="UNVERIFIED",
                credential_id=credential_id,
                message="Credential ID does not match token.",
            )
        credential_id = cred_id_from_jwt
        expiry_str = payload.get("expiry_date")
        claims = {k: v for k, v in payload.items() if not k.startswith("_")}
    else:
        if not credential_id:
            return VerifyResponse(
                status="UNVERIFIED",
                credential_id="unknown",
                message="No credential ID or JWT provided.",
            )
        entry = db.get_registry_entry(credential_id)
        if not entry:
            return VerifyResponse(
                status="UNVERIFIED",
                credential_id=credential_id,
                message="Credential not found in registry.",
            )
        expiry_str = entry["expiry_date"]
        claims = None

    if db.is_revoked(credential_id):
        return VerifyResponse(
            status="REVOKED",
            credential_id=credential_id,
            message="This credential has been revoked by the holder.",
            claims=claims,
        )

    if expiry_str:
        try:
            exp_date = date.fromisoformat(expiry_str)
            if exp_date < date.today():
                return VerifyResponse(
                    status="EXPIRED",
                    credential_id=credential_id,
                    message=f"Credential expired on {expiry_str}.",
                    claims=claims,
                )
        except Exception:
            pass

    return VerifyResponse(
        status="VALID",
        credential_id=credential_id,
        message="Credential is valid.",
        claims=claims,
    )


def revoke_credential(credential_id: str) -> bool:
    db.init_db()
    entry = db.get_registry_entry(credential_id)
    if not entry:
        return False
    db.set_revoked(credential_id)
    return True
