"""
Optional staff accounts: email + password, HttpOnly session cookie, server-stored wallet JSON.
PII in wallet entries is the same as localStorage today (JWT payloads); registry table still has no PII.
"""
import json
import os
import re
from datetime import datetime
import sqlite3
from typing import Optional

import bcrypt
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from . import crypto, db, session_auth

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
    email = _normalize_email(body.get("email") or "")
    password = body.get("password") or ""
    _reserved = {
        db.DEV_SEED_EMAIL.strip().lower(),
        db.DEV_SEED_EMAIL_ROTHERHAM.strip().lower(),
    }
    if email in _reserved:
        raise HTTPException(status_code=403, detail="This email is reserved. Use sign in.")
    if not EMAIL_RE.match(email):
        raise HTTPException(status_code=400, detail="Invalid email")
    if len(str(password)) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters")
    h = bcrypt.hashpw(str(password).encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    try:
        uid = db.user_create(email, h, None)
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="Email already registered")
    return _session_response({"ok": True, "email": email}, uid, email, request)


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
    return {
        "id": u["id"],
        "email": u["email"],
        "premium": db.user_is_premium(u),
        "gmc_number": u.get("gmc_number"),
        "display_name": u.get("display_name"),
        "current_trust": u.get("current_trust"),
    }


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
        current_trust = (body.get("current_trust") or "").strip() or None
    else:
        current_trust = u.get("current_trust")

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

    db.user_set_profile(uid, display_name, gmc, current_trust)
    return {"ok": True}


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
    for cid in ids:
        w = wallet_by_id.get(cid) or {}
        b64 = w.get("certificate_base64") or fallback_b64
        fn = w.get("certificate_filename") or fallback_fn
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


def _hr_trust(hr_user: dict) -> Optional[str]:
    """Normalised current_trust of an HR user, used for trust-scoping inbox queries."""
    t = (hr_user.get("current_trust") or "").strip().lower()
    return t or None


def _assert_same_trust(hr_user: dict, session: dict) -> None:
    """Raise 403 if the session's doctor is not from the HR user's trust."""
    trust = _hr_trust(hr_user)
    if not trust:
        return  # HR account has no trust set — don't block (edge case / admin)
    doc_trust = (session.get("doctor_trust") or "").strip().lower()
    if doc_trust != trust:
        raise HTTPException(status_code=403, detail="This submission is not from your trust.")


@router.get("/hr/shares")
def hr_shares_list(request: Request, limit: int = 50):
    hr = require_premium_user(request)
    return {"sessions": db.share_inbox_list(limit=limit, hr_trust=_hr_trust(hr))}


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
    if not any(it.get("credential_id") == credential_id for it in (s.get("items") or [])):
        raise HTTPException(status_code=404, detail="Item not found in share")
    db.share_item_set_decision(int(session_id), str(credential_id), int(hr["id"]), status="VERIFIED")
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
    db.share_item_set_decision(int(session_id), str(credential_id), int(hr["id"]), status="DECLINED", decline_reason=reason)
    return {"ok": True}
