"""
Credential issue, verify, revoke — core Phase 2 logic.
"""
import uuid
from datetime import datetime, date

from . import db
from . import crypto
from . import pdf_gen
from .models import CompletionRecord, CredentialPayload, VerifyResponse


def get_verification_url_base(base_url: str) -> str:
    base = base_url.rstrip("/")
    return f"{base}/api/credentials/verify"


def issue_credentials(records: list[CompletionRecord], base_url: str) -> list[dict]:
    """Issue one credential per completion record; return list of { credential_id, verification_url, jwt, pdf_base64 }."""
    issuer_did = crypto.get_issuer_did(base_url)
    verify_base = get_verification_url_base(base_url)
    results = []

    for rec in records:
        credential_id = f"nhs-el-{uuid.uuid4().hex[:24]}"
        issued_at = datetime.utcnow().isoformat() + "Z"
        payload = {
            "sub": rec.staff_identifier,
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

        db.init_db()
        db.register_credential(credential_id, rec.expiry_date.isoformat())

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
    return results


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
