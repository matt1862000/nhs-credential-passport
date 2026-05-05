"""
Optional staff accounts: email + password, HttpOnly session cookie, server-stored wallet JSON.
PII in wallet entries is the same as localStorage today (JWT payloads); registry table still has no PII.
"""
import json
import re
import sqlite3
from typing import Optional

import bcrypt
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from . import db, session_auth

router = APIRouter(prefix="/api")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
GMC_RE = re.compile(r"^\d{7}$")
MAX_WALLET_BYTES = 4 * 1024 * 1024


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
