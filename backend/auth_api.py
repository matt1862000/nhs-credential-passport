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


@router.get("/me/trust-requirements")
def me_trust_requirements(request: Request):
    uid = require_user_id(request)
    u = db.user_get_by_id(uid)
    if not u:
        raise HTTPException(status_code=401, detail="Not signed in")
    trust = (u.get("current_trust") or "").strip()
    if not trust:
        return {"topics": [], "trust": None}
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
    return q


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


# ── Mandatory topics ──────────────────────────────────────────────────────────

def _hr_trust_required(hr_user: dict) -> str:
    trust = (hr_user.get("current_trust") or "").strip()
    if not trust:
        raise HTTPException(status_code=400, detail="Your HR account must have a current trust set in your profile.")
    return trust


@router.get("/hr/mandatory-topics")
def hr_mandatory_topics_list(request: Request):
    hr = require_premium_user(request)
    trust = _hr_trust_required(hr)
    return {"topics": db.mandatory_topics_list(trust)}


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
        topic = db.mandatory_topic_add(trust, topic_name, category)
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
    updated = db.mandatory_topic_update(int(topic_id), trust, topic_name, category)
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
    conv = db.conversation_get_or_create(uid, trust)
    return conv


@router.post("/me/messages/{conv_id}/send")
async def me_messages_send(request: Request, conv_id: int):
    uid = require_user_id(request)
    _get_conversation_assert_doctor(conv_id, uid)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    text = str(body.get("body") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Message body cannot be empty")
    msg = db.message_send_body(int(conv_id), uid, text)
    return msg


# HR endpoints
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
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    text = str(body.get("body") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Message body cannot be empty")
    msg = db.message_send_body(int(conv_id), int(hr["id"]), text)
    return msg
