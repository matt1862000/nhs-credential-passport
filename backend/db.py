"""
Minimal storage: credential_id -> revocation and expiry.
No full PII stored; JWT holds the claims.
"""
import os
import sqlite3
from pathlib import Path
from datetime import datetime

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "credentials.db"


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS credential_registry (
                credential_id TEXT PRIMARY KEY,
                revoked INTEGER NOT NULL DEFAULT 0,
                revoked_at TEXT,
                expiry_date TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT NOT NULL UNIQUE COLLATE NOCASE,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL,
                premium INTEGER NOT NULL DEFAULT 0
            )
        """)
        _ensure_users_premium_column(conn)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS user_wallets (
                user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                wallet_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        conn.commit()


def _ensure_users_premium_column(conn: sqlite3.Connection) -> None:
    """SQLite: add premium flag for trust-tier accounts (existing DBs)."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "premium" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN premium INTEGER NOT NULL DEFAULT 0")


def register_credential(credential_id: str, expiry_date: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """INSERT OR REPLACE INTO credential_registry 
               (credential_id, revoked, expiry_date, created_at) VALUES (?, 0, ?, ?)""",
            (credential_id, expiry_date, datetime.utcnow().isoformat()),
        )
        conn.commit()


def set_revoked(credential_id: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """UPDATE credential_registry SET revoked = 1, revoked_at = ? WHERE credential_id = ?""",
            (datetime.utcnow().isoformat(), credential_id),
        )
        conn.commit()


def get_registry_entry(credential_id: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT credential_id, revoked, expiry_date FROM credential_registry WHERE credential_id = ?",
            (credential_id,),
        ).fetchone()
    if not row:
        return None
    return {
        "credential_id": row["credential_id"],
        "revoked": bool(row["revoked"]),
        "expiry_date": row["expiry_date"],
    }


def is_revoked(credential_id: str) -> bool:
    entry = get_registry_entry(credential_id)
    return entry is not None and entry["revoked"]


# ---------- Accounts (wallet sync; JWT payloads still not stored in registry) ----------


def user_create(email: str, password_hash: str) -> int:
    """Insert user; raises sqlite3.IntegrityError if email exists."""
    premium = 1 if _email_in_premium_env(email) else 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        cur = conn.execute(
            "INSERT INTO users (email, password_hash, created_at, premium) VALUES (?, ?, ?, ?)",
            (email, password_hash, datetime.utcnow().isoformat(), premium),
        )
        conn.commit()
        return int(cur.lastrowid)


def user_get_by_email(email: str):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT id, email, password_hash, premium FROM users WHERE email = ?", (email,)
        ).fetchone()
    if not row:
        return None
    return {
        "id": row["id"],
        "email": row["email"],
        "password_hash": row["password_hash"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
    }


def user_get_by_id(user_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT id, email, premium FROM users WHERE id = ?", (user_id,)).fetchone()
    if not row:
        return None
    return {
        "id": row["id"],
        "email": row["email"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
    }


def _email_in_premium_env(email: str) -> bool:
    raw = (os.environ.get("PREMIUM_EMAILS") or "").strip()
    if not raw or not email:
        return False
    e = email.strip().lower()
    for part in raw.split(","):
        p = part.strip().lower()
        if p and p == e:
            return True
    return False


def user_is_premium(user: dict) -> bool:
    if not user:
        return False
    if user.get("premium"):
        return True
    return _email_in_premium_env(user.get("email") or "")


def user_wallet_get(user_id: int) -> str:
    """JSON string of wallet array; default '[]'."""
    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute(
            "SELECT wallet_json FROM user_wallets WHERE user_id = ?",
            (user_id,),
        ).fetchone()
    if not row or row[0] is None:
        return "[]"
    return row[0]


def user_wallet_put(user_id: int, wallet_json: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """INSERT INTO user_wallets (user_id, wallet_json, updated_at) VALUES (?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET wallet_json = excluded.wallet_json, updated_at = excluded.updated_at""",
            (user_id, wallet_json, datetime.utcnow().isoformat()),
        )
        conn.commit()
