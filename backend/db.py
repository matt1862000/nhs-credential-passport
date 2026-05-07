"""
Minimal storage: credential_id -> revocation and expiry.
No full PII stored; JWT holds the claims.
"""
import os
import sqlite3
from pathlib import Path
from datetime import datetime
from typing import Optional
import secrets

try:
    import bcrypt  # type: ignore
except Exception:  # pragma: no cover
    bcrypt = None

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "credentials.db"
DEV_SEED_EMAIL = "sheffieldhr@nhs.net"
DEV_SEED_EMAIL_ROTHERHAM = "rotherhamhr@nhs.net"
DEV_SEED_PASSWORD = "password"
DEV_SEED_TRUST_SHEFFIELD = "SHEFFIELD HEALTH PARTNERSHIP UNIVERSITY NHS FOUNDATION TRUST"
DEV_SEED_TRUST_ROTHERHAM = "ROTHERHAM DONCASTER AND SOUTH HUMBER NHS FOUNDATION TRUST"


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
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS user_wallets (
                user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                wallet_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        _ensure_share_tables(conn)
        _ensure_csv_import_evidence_table(conn)
        _ensure_seed_privileged_user(conn)
        _ensure_seed_rotherham_user(conn)
        conn.commit()


def _ensure_csv_import_evidence_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS csv_import_evidence (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            filename TEXT NOT NULL,
            content_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            credentials_issued INTEGER NOT NULL DEFAULT 0,
            data BLOB NOT NULL
        )
        """
    )


def csv_import_evidence_save(
    user_id: int,
    filename: str,
    content_type: str,
    data: bytes,
    *,
    credentials_issued: int,
) -> int:
    """Store one evidence file per CSV import attempt (audit). Returns row id."""
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_csv_import_evidence_table(conn)
        cur = conn.execute(
            """
            INSERT INTO csv_import_evidence
            (user_id, created_at, filename, content_type, size_bytes, credentials_issued, data)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                int(user_id),
                now,
                (filename or "evidence").strip()[:255],
                (content_type or "application/octet-stream").strip()[:128],
                len(data),
                int(credentials_issued),
                data,
            ),
        )
        conn.commit()
        return int(cur.lastrowid)


def _ensure_share_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS share_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            doctor_email TEXT NOT NULL,
            share_token TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL DEFAULT 'OPEN'
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS share_items (
            session_id INTEGER NOT NULL REFERENCES share_sessions(id) ON DELETE CASCADE,
            credential_id TEXT NOT NULL,
            module_name TEXT,
            expiry_date TEXT,
            status TEXT NOT NULL DEFAULT 'PENDING',
            decision_at TEXT,
            decision_by_user_id INTEGER REFERENCES users(id),
            decline_reason TEXT,
            PRIMARY KEY (session_id, credential_id)
        )
    """)
    # Migrate older schema (verified/verified_at/verified_by_user_id) if present.
    cols = [row[1] for row in conn.execute("PRAGMA table_info(share_items)").fetchall()]
    if "status" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN status TEXT NOT NULL DEFAULT 'PENDING'")
    if "decision_at" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN decision_at TEXT")
    if "decision_by_user_id" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN decision_by_user_id INTEGER REFERENCES users(id)")
    if "decline_reason" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN decline_reason TEXT")
    if "certificate_base64" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN certificate_base64 TEXT")
    if "certificate_filename" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN certificate_filename TEXT")
    cols_s = [row[1] for row in conn.execute("PRAGMA table_info(share_sessions)").fetchall()]
    if "share_kind" not in cols_s:
        conn.execute(
            "ALTER TABLE share_sessions ADD COLUMN share_kind TEXT NOT NULL DEFAULT 'review'"
        )
    cols_i = [row[1] for row in conn.execute("PRAGMA table_info(share_items)").fetchall()]
    if "issuing_trust_name" not in cols_i:
        conn.execute("ALTER TABLE share_items ADD COLUMN issuing_trust_name TEXT")
    if "verified_by_trust_name" not in cols_i:
        conn.execute("ALTER TABLE share_items ADD COLUMN verified_by_trust_name TEXT")


def share_portfolio_prior_decision_at(doctor_user_id: int, credential_id: str) -> Optional[str]:
    """Latest HR decision_at from a normal (review) share session, for portfolio snapshot dating."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        r = conn.execute(
            """
            SELECT MAX(i.decision_at) AS d
            FROM share_items i
            INNER JOIN share_sessions s ON s.id = i.session_id
            WHERE s.doctor_user_id = ?
              AND i.credential_id = ?
              AND i.status = 'VERIFIED'
              AND IFNULL(s.share_kind, 'review') = 'review'
            """,
            (int(doctor_user_id), str(credential_id)),
        ).fetchone()
    if not r or r["d"] is None:
        return None
    return str(r["d"])


def share_portfolio_prior_verifier_trust(doctor_user_id: int, credential_id: str) -> Optional[str]:
    """Trust name from HR user profile at time of prior review share (Sheffield-style verifying employer)."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        r = conn.execute(
            """
            SELECT u.current_trust
            FROM share_items i
            INNER JOIN share_sessions s ON s.id = i.session_id
            LEFT JOIN users u ON u.id = i.decision_by_user_id
            WHERE s.doctor_user_id = ?
              AND i.credential_id = ?
              AND i.status = 'VERIFIED'
              AND IFNULL(s.share_kind, 'review') = 'review'
              AND i.decision_by_user_id IS NOT NULL
            ORDER BY datetime(COALESCE(i.decision_at, '')) DESC
            LIMIT 1
            """,
            (int(doctor_user_id), str(credential_id)),
        ).fetchone()
    if not r or not r["current_trust"]:
        return None
    t = str(r["current_trust"]).strip()
    return t or None


def share_session_create(
    *,
    doctor_user_id: int,
    doctor_email: str,
    items: list[dict],
    share_kind: str = "review",
) -> dict:
    """
    Create a share session containing credential ids.
    items: [{ credential_id, module_name?, expiry_date?, certificate_base64?, certificate_filename?,
             portfolio_verified_at?, issuing_trust_name?, verified_by_trust_name? }, ...]
    share_kind: 'review' (HR must verify) or 'portfolio' (already HR-verified elsewhere; snapshot only).
    """
    token = secrets.token_urlsafe(24)
    now = datetime.utcnow().isoformat()
    sk = (share_kind or "review").strip().lower()
    if sk not in ("review", "portfolio"):
        sk = "review"
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        cur = conn.execute(
            "INSERT INTO share_sessions (created_at, doctor_user_id, doctor_email, share_token, status, share_kind) VALUES (?, ?, ?, ?, 'OPEN', ?)",
            (now, doctor_user_id, (doctor_email or "").strip().lower(), token, sk),
        )
        session_id = int(cur.lastrowid)
        for it in items or []:
            cid = (it.get("credential_id") or "").strip()
            if not cid:
                continue
            if sk == "portfolio":
                dec_at = (it.get("portfolio_verified_at") or "").strip() or now
                conn.execute(
                    """
                    INSERT OR IGNORE INTO share_items (
                        session_id, credential_id, module_name, expiry_date, status,
                        certificate_base64, certificate_filename, decision_at, decision_by_user_id, decline_reason,
                        issuing_trust_name, verified_by_trust_name
                    ) VALUES (?, ?, ?, ?, 'VERIFIED', ?, ?, ?, NULL, NULL, ?, ?)
                    """,
                    (
                        session_id,
                        cid,
                        it.get("module_name"),
                        it.get("expiry_date"),
                        it.get("certificate_base64"),
                        it.get("certificate_filename"),
                        dec_at,
                        (it.get("issuing_trust_name") or "").strip() or None,
                        (it.get("verified_by_trust_name") or "").strip() or None,
                    ),
                )
            else:
                conn.execute(
                    """
                    INSERT OR IGNORE INTO share_items (
                        session_id, credential_id, module_name, expiry_date, status,
                        certificate_base64, certificate_filename,
                        issuing_trust_name
                    ) VALUES (?, ?, ?, ?, 'PENDING', ?, ?, ?)
                    """,
                    (
                        session_id,
                        cid,
                        it.get("module_name"),
                        it.get("expiry_date"),
                        it.get("certificate_base64"),
                        it.get("certificate_filename"),
                        (it.get("issuing_trust_name") or "").strip() or None,
                    ),
                )
        conn.commit()
    return {"session_id": session_id, "share_token": token, "created_at": now}


def share_inbox_list(limit: int = 50, hr_trust: Optional[str] = None) -> list[dict]:
    trust_filter = (hr_trust or "").strip().lower()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        if trust_filter:
            rows = conn.execute(
                """
                SELECT
                  s.id as session_id,
                  s.created_at as created_at,
                  s.doctor_user_id as doctor_user_id,
                  s.doctor_email as doctor_email,
                  u.display_name as doctor_name,
                  u.gmc_number as doctor_gmc,
                  u.current_trust as doctor_trust,
                  s.status as status,
                  IFNULL(s.share_kind, 'review') as share_kind,
                  COUNT(i.credential_id) as total_count,
                  SUM(CASE WHEN i.status = 'VERIFIED' THEN 1 ELSE 0 END) as verified_count,
                  SUM(CASE WHEN i.status = 'DECLINED' THEN 1 ELSE 0 END) as declined_count,
                  SUM(CASE WHEN i.status = 'PENDING' THEN 1 ELSE 0 END) as pending_count
                FROM share_sessions s
                JOIN users u ON u.id = s.doctor_user_id
                LEFT JOIN share_items i ON i.session_id = s.id
                WHERE LOWER(TRIM(COALESCE(u.current_trust, ''))) = ?
                GROUP BY s.id
                ORDER BY s.id DESC
                LIMIT ?
                """,
                (trust_filter, max(1, min(int(limit or 50), 200))),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT
                  s.id as session_id,
                  s.created_at as created_at,
                  s.doctor_user_id as doctor_user_id,
                  s.doctor_email as doctor_email,
                  u.display_name as doctor_name,
                  u.gmc_number as doctor_gmc,
                  u.current_trust as doctor_trust,
                  s.status as status,
                  IFNULL(s.share_kind, 'review') as share_kind,
                  COUNT(i.credential_id) as total_count,
                  SUM(CASE WHEN i.status = 'VERIFIED' THEN 1 ELSE 0 END) as verified_count,
                  SUM(CASE WHEN i.status = 'DECLINED' THEN 1 ELSE 0 END) as declined_count,
                  SUM(CASE WHEN i.status = 'PENDING' THEN 1 ELSE 0 END) as pending_count
                FROM share_sessions s
                JOIN users u ON u.id = s.doctor_user_id
                LEFT JOIN share_items i ON i.session_id = s.id
                GROUP BY s.id
                ORDER BY s.id DESC
                LIMIT ?
                """,
                (max(1, min(int(limit or 50), 200)),),
            ).fetchall()
    out = []
    for r in rows:
        out.append(
            {
                "session_id": r["session_id"],
                "created_at": r["created_at"],
                "doctor_user_id": int(r["doctor_user_id"]),
                "doctor_email": r["doctor_email"],
                "doctor_name": r["doctor_name"],
                "doctor_gmc": r["doctor_gmc"],
                "doctor_trust": r["doctor_trust"],
                "status": r["status"],
                "share_kind": str(r["share_kind"] or "review"),
                "total_count": int(r["total_count"] or 0),
                "verified_count": int(r["verified_count"] or 0),
                "declined_count": int(r["declined_count"] or 0),
                "pending_count": int(r["pending_count"] or 0),
            }
        )
    return out


def share_doctor_queue(doctor_user_id: int, hr_trust: Optional[str] = None) -> Optional[dict]:
    """All share items across every session for one clinician (for merged HR review)."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        doc = conn.execute(
            """
            SELECT
              u.id as doctor_user_id, u.email as doctor_email, u.display_name as doctor_name,
              u.gmc_number as doctor_gmc, u.current_trust as doctor_trust
            FROM users u
            WHERE u.id = ?
            """,
            (int(doctor_user_id),),
        ).fetchone()
        if not doc:
            return None
        # Trust-scoping: if the HR user's trust is set, doctor must belong to the same trust.
        if hr_trust:
            doc_trust = (doc["doctor_trust"] or "").strip().lower()
            if doc_trust != hr_trust.strip().lower():
                return None
        rows = conn.execute(
            """
            SELECT
              i.session_id,
              s.created_at as session_created_at,
              IFNULL(s.share_kind, 'review') as session_share_kind,
              i.credential_id, i.module_name, i.expiry_date, i.status, i.decision_at,
              i.decline_reason, i.certificate_base64, i.certificate_filename,
              i.issuing_trust_name, i.verified_by_trust_name
            FROM share_sessions s
            JOIN share_items i ON i.session_id = s.id
            WHERE s.doctor_user_id = ?
            ORDER BY s.id DESC, i.credential_id
            """,
            (int(doctor_user_id),),
        ).fetchall()
    items = [
        {
            "session_id": int(r["session_id"]),
            "session_created_at": r["session_created_at"],
            "session_share_kind": str(r["session_share_kind"] or "review"),
            "credential_id": r["credential_id"],
            "module_name": r["module_name"],
            "expiry_date": r["expiry_date"],
            "status": r["status"],
            "decision_at": r["decision_at"],
            "decline_reason": r["decline_reason"],
            "certificate_base64": r["certificate_base64"],
            "certificate_filename": r["certificate_filename"],
            "issuing_trust_name": r["issuing_trust_name"],
            "verified_by_trust_name": r["verified_by_trust_name"],
        }
        for r in rows
    ]
    session_ids = sorted({int(r["session_id"]) for r in rows}, reverse=True)
    return {
        "doctor_user_id": int(doc["doctor_user_id"]),
        "doctor_email": doc["doctor_email"],
        "doctor_name": doc["doctor_name"],
        "doctor_gmc": doc["doctor_gmc"],
        "doctor_trust": doc["doctor_trust"],
        "session_ids": session_ids,
        "items": items,
    }


def share_session_get(session_id: int) -> Optional[dict]:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        s = conn.execute(
            """
            SELECT
              s.id as session_id, s.created_at, s.doctor_user_id, s.doctor_email, s.share_token, s.status,
              IFNULL(s.share_kind, 'review') as share_kind,
              u.display_name as doctor_name, u.gmc_number as doctor_gmc, u.current_trust as doctor_trust
            FROM share_sessions s
            JOIN users u ON u.id = s.doctor_user_id
            WHERE s.id = ?
            """,
            (int(session_id),),
        ).fetchone()
        if not s:
            return None
        items = conn.execute(
            """
            SELECT credential_id, module_name, expiry_date, status, decision_at, decision_by_user_id, decline_reason,
                   certificate_base64, certificate_filename,
                   issuing_trust_name, verified_by_trust_name
            FROM share_items
            WHERE session_id = ?
            ORDER BY credential_id
            """,
            (int(session_id),),
        ).fetchall()
    return {
        "session_id": s["session_id"],
        "created_at": s["created_at"],
        "doctor_user_id": s["doctor_user_id"],
        "doctor_email": s["doctor_email"],
        "doctor_name": s["doctor_name"],
        "doctor_gmc": s["doctor_gmc"],
        "doctor_trust": s["doctor_trust"],
        "share_token": s["share_token"],
        "status": s["status"],
        "share_kind": str(s["share_kind"] or "review"),
        "items": [
            {
                "credential_id": r["credential_id"],
                "module_name": r["module_name"],
                "expiry_date": r["expiry_date"],
                "status": r["status"],
                "decision_at": r["decision_at"],
                "decision_by_user_id": r["decision_by_user_id"],
                "decline_reason": r["decline_reason"],
                "certificate_base64": r["certificate_base64"],
                "certificate_filename": r["certificate_filename"],
                "issuing_trust_name": r["issuing_trust_name"],
                "verified_by_trust_name": r["verified_by_trust_name"],
            }
            for r in items
        ],
    }

def share_item_set_decision(
    session_id: int,
    credential_id: str,
    hr_user_id: int,
    *,
    status: str,
    decline_reason: Optional[str] = None,
) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        st = (status or "").upper().strip()
        if st not in ("PENDING", "VERIFIED", "DECLINED"):
            st = "PENDING"
        conn.execute(
            """
            UPDATE share_items
            SET status = ?, decision_at = ?, decision_by_user_id = ?, decline_reason = ?
            WHERE session_id = ? AND credential_id = ?
            """,
            (
                st,
                datetime.utcnow().isoformat(),
                int(hr_user_id),
                (decline_reason or "").strip() if st == "DECLINED" else None,
                int(session_id),
                str(credential_id),
            ),
        )
        if st == "VERIFIED":
            ut = conn.execute(
                "SELECT current_trust FROM users WHERE id = ?", (int(hr_user_id),)
            ).fetchone()
            trust_name = (ut[0] if ut else None) or None
            if trust_name:
                conn.execute(
                    """
                    UPDATE share_items
                    SET verified_by_trust_name = ?
                    WHERE session_id = ? AND credential_id = ?
                    """,
                    (str(trust_name).strip(), int(session_id), str(credential_id)),
                )
        conn.commit()


def doctor_verified_map(doctor_user_id: int) -> dict:
    """Return { credential_id: { shared, status, decision_at, decline_reason } } for a doctor."""
    out: dict = {}
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT i.credential_id, i.status, i.decision_at, i.decline_reason
            FROM share_sessions s
            JOIN share_items i ON i.session_id = s.id
            WHERE s.doctor_user_id = ?
            """,
            (int(doctor_user_id),),
        ).fetchall()
    for r in rows:
        cid = r["credential_id"]
        prev = out.get(cid) or {"shared": True, "status": "PENDING", "decision_at": None, "decline_reason": None}
        prev["shared"] = True
        # Prefer terminal statuses over pending, and carry decline reason
        st = (r["status"] or "").upper()
        if st in ("VERIFIED", "DECLINED"):
            prev["status"] = st
            prev["decision_at"] = r["decision_at"]
            prev["decline_reason"] = r["decline_reason"]
        elif prev.get("status") not in ("VERIFIED", "DECLINED"):
            prev["status"] = "PENDING"
        out[cid] = prev
    return out

def _ensure_seed_privileged_user(conn: sqlite3.Connection) -> None:
    """
    Dev/demo seed account so Render deployments have a privileged login.
    WARNING: This is insecure and should be removed before real use.
    """
    if bcrypt is None:
        return
    email = DEV_SEED_EMAIL.strip().lower()
    pw = DEV_SEED_PASSWORD
    trust = DEV_SEED_TRUST_SHEFFIELD
    if not email or not pw:
        return
    _ensure_users_premium_column(conn)
    _ensure_users_gmc_number_column(conn)
    _ensure_users_profile_extra_columns(conn)
    h = bcrypt.hashpw(pw.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    existing = conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    if existing and existing[0]:
        conn.execute(
            "UPDATE users SET password_hash = ?, premium = 1, current_trust = ? WHERE email = ?",
            (h, trust, email),
        )
        return
    conn.execute(
        "INSERT INTO users (email, password_hash, created_at, premium, gmc_number, display_name, current_trust) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (email, h, datetime.utcnow().isoformat(), 1, None, None, trust),
    )


def _ensure_seed_rotherham_user(conn: sqlite3.Connection) -> None:
    """Demo premium HR login for Rotherham."""
    if bcrypt is None:
        return
    email = DEV_SEED_EMAIL_ROTHERHAM.strip().lower()
    pw = DEV_SEED_PASSWORD
    trust = DEV_SEED_TRUST_ROTHERHAM
    if not email or not pw:
        return
    _ensure_users_premium_column(conn)
    _ensure_users_gmc_number_column(conn)
    _ensure_users_profile_extra_columns(conn)
    h = bcrypt.hashpw(pw.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    existing = conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    if existing and existing[0]:
        conn.execute(
            "UPDATE users SET password_hash = ?, premium = 1, current_trust = ? WHERE email = ?",
            (h, trust, email),
        )
        return
    conn.execute(
        "INSERT INTO users (email, password_hash, created_at, premium, gmc_number, display_name, current_trust) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (email, h, datetime.utcnow().isoformat(), 1, None, None, trust),
    )


def _ensure_users_premium_column(conn: sqlite3.Connection) -> None:
    """SQLite: add premium flag for trust-tier accounts (existing DBs)."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "premium" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN premium INTEGER NOT NULL DEFAULT 0")


def _ensure_users_gmc_number_column(conn: sqlite3.Connection) -> None:
    """SQLite: add GMC number collected at registration (existing DBs)."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "gmc_number" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN gmc_number TEXT")


def _ensure_users_profile_extra_columns(conn: sqlite3.Connection) -> None:
    """Optional profile: full name, current trust (GMC uses gmc_number column)."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "display_name" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN display_name TEXT")
    if "current_trust" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN current_trust TEXT")


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


def user_create(email: str, password_hash: str, gmc_number: Optional[str] = None) -> int:
    """Insert user; raises sqlite3.IntegrityError if email exists."""
    premium = 1 if _email_in_premium_env(email) else 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        cur = conn.execute(
            "INSERT INTO users (email, password_hash, created_at, premium, gmc_number, display_name, current_trust) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (email, password_hash, datetime.utcnow().isoformat(), premium, gmc_number, None, None),
        )
        conn.commit()
        return int(cur.lastrowid)


def user_get_by_email(email: str):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT id, email, password_hash, premium, gmc_number, display_name, current_trust FROM users WHERE email = ?",
            (email,),
        ).fetchone()
    if not row:
        return None
    return {
        "id": row["id"],
        "email": row["email"],
        "password_hash": row["password_hash"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
        "gmc_number": row["gmc_number"],
        "display_name": row["display_name"],
        "current_trust": row["current_trust"],
    }


def user_get_by_id(user_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT id, email, premium, gmc_number, display_name, current_trust FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
    if not row:
        return None
    return {
        "id": row["id"],
        "email": row["email"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
        "gmc_number": row["gmc_number"],
        "display_name": row["display_name"],
        "current_trust": row["current_trust"],
    }


def user_set_profile(
    user_id: int,
    display_name: Optional[str],
    gmc_number: Optional[str],
    current_trust: Optional[str],
) -> None:
    """Replace optional profile fields (None clears)."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        conn.execute(
            "UPDATE users SET display_name = ?, gmc_number = ?, current_trust = ? WHERE id = ?",
            (display_name, gmc_number, current_trust, user_id),
        )
        conn.commit()


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
