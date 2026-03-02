"""
Minimal storage: credential_id -> revocation and expiry.
No full PII stored; JWT holds the claims.
"""
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
        conn.commit()


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
