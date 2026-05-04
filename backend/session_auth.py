"""
HttpOnly session JWT (HS256) for staff accounts — separate from VC issuer keys.
Set SESSION_SECRET in production (min 32 characters).
"""
import os
from datetime import datetime, timedelta
from typing import Optional, Tuple

from jose import JWTError, jwt

SESSION_COOKIE = "nhs_session"
SESSION_DAYS = 14


def _secret() -> str:
    s = (os.environ.get("SESSION_SECRET") or "").strip()
    if s:
        return s
    return "dev-only-session-secret-do-not-use-in-production-min-32-chars!!"


def create_session_token(user_id: int, email: str) -> str:
    now = datetime.utcnow()
    payload = {
        "sub": str(user_id),
        "email": email,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=SESSION_DAYS)).timestamp()),
    }
    return jwt.encode(payload, _secret(), algorithm="HS256")


def decode_session_token(token: str) -> Optional[Tuple[int, str]]:
    try:
        p = jwt.decode(token, _secret(), algorithms=["HS256"])
        return int(p["sub"]), str(p["email"])
    except (JWTError, ValueError, KeyError, TypeError):
        return None
