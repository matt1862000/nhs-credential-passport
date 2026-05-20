"""
Minimal storage: credential_id -> revocation and expiry.
No full PII stored; JWT holds the claims.
"""
import os
import re
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
# Demo-only: HR-provisioned clinicians start with this password; never returned via API.
PROVISIONED_DEMO_PASSWORD = "password"
DEV_SEED_TRUST_SHEFFIELD = "SHEFFIELD HEALTH PARTNERSHIP UNIVERSITY NHS FOUNDATION TRUST"
DEV_SEED_TRUST_ROTHERHAM = "ROTHERHAM DONCASTER AND SOUTH HUMBER NHS FOUNDATION TRUST"
DEV_SEED_DISPLAY_SHEFFIELD = "Sheffield HR"
DEV_SEED_DISPLAY_ROTHERHAM = "Rotherham HR"
_LEGACY_SHEFFIELD_PARTNERSHIP_TRUST_LABELS = (
    "Sheffield Health and Social Care NHS Foundation Trust",
)


def default_hr_display_name(email: str) -> Optional[str]:
    """Demo HR account labels when profile full name is unset."""
    e = (email or "").strip().lower()
    if e == DEV_SEED_EMAIL.strip().lower():
        return DEV_SEED_DISPLAY_SHEFFIELD
    if e == DEV_SEED_EMAIL_ROTHERHAM.strip().lower():
        return DEV_SEED_DISPLAY_ROTHERHAM
    return None


def user_effective_display_name(u: dict) -> Optional[str]:
    """Preferred UI name: profile display_name, else known HR demo labels."""
    dn = (u.get("display_name") or "").strip()
    if dn:
        return dn
    if user_is_premium(u):
        return default_hr_display_name(str(u.get("email") or ""))
    return None


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
        _ensure_visibility_tables(conn)
        _ensure_mandatory_topics_table(conn)
        _ensure_messaging_tables(conn)
        _ensure_hr_attestations_table(conn)
        _ensure_users_provision_columns(conn)
        _ensure_hr_cohorts_tables(conn)
        _ensure_seed_privileged_user(conn)
        _ensure_seed_rotherham_user(conn)
        _backfill_sheffield_partnership_trust_labels(conn)
        conn.commit()


def _backfill_sheffield_partnership_trust_labels(conn: sqlite3.Connection) -> None:
    """Fix clinicians provisioned with the old wrong SHSC label instead of Sheffield Partnership."""
    from . import trust_packs

    new_label = trust_packs.trust_display_name(DEV_SEED_TRUST_SHEFFIELD)
    if not new_label:
        return
    for old in _LEGACY_SHEFFIELD_PARTNERSHIP_TRUST_LABELS:
        conn.execute(
            "UPDATE users SET current_trust = ? WHERE TRIM(COALESCE(current_trust, '')) = ?",
            (new_label, old),
        )


def _ensure_visibility_tables(conn: sqlite3.Connection) -> None:
    """Doctor training visibility: who can see their verified training via HR search."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS doctor_visibility (
            doctor_user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            mode TEXT NOT NULL DEFAULT 'all'
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS doctor_visibility_allowlist (
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            trust_name TEXT NOT NULL,
            trust_ods TEXT,
            PRIMARY KEY (doctor_user_id, trust_name)
        )
    """)


# ── Visibility helpers ────────────────────────────────────────────────────────

def visibility_get(doctor_user_id: int) -> dict:
    """Return { mode, allowlist: [{trust_name, trust_ods}] } for a doctor."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_visibility_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT mode FROM doctor_visibility WHERE doctor_user_id = ?",
            (int(doctor_user_id),),
        ).fetchone()
        mode = str(row["mode"]) if row else "all"
        al_rows = conn.execute(
            "SELECT trust_name, trust_ods FROM doctor_visibility_allowlist WHERE doctor_user_id = ? ORDER BY trust_name",
            (int(doctor_user_id),),
        ).fetchall()
    return {
        "mode": mode,
        "allowlist": [{"trust_name": r["trust_name"], "trust_ods": r["trust_ods"]} for r in al_rows],
    }


def visibility_set(doctor_user_id: int, mode: str, allowlist: list[dict]) -> None:
    """Upsert visibility mode and replace allowlist."""
    valid_modes = {"all", "current", "allowlist"}
    mode = mode if mode in valid_modes else "all"
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_visibility_tables(conn)
        conn.execute(
            "INSERT INTO doctor_visibility (doctor_user_id, mode) VALUES (?, ?) ON CONFLICT(doctor_user_id) DO UPDATE SET mode = excluded.mode",
            (int(doctor_user_id), mode),
        )
        conn.execute("DELETE FROM doctor_visibility_allowlist WHERE doctor_user_id = ?", (int(doctor_user_id),))
        for entry in allowlist or []:
            tn = (entry.get("trust_name") or "").strip()
            ods = (entry.get("trust_ods") or "").strip() or None
            if tn:
                conn.execute(
                    "INSERT OR IGNORE INTO doctor_visibility_allowlist (doctor_user_id, trust_name, trust_ods) VALUES (?, ?, ?)",
                    (int(doctor_user_id), tn, ods),
                )
        conn.commit()


def _doctor_visible_to_trust(doctor_user_id: int, hr_trust: str, conn: sqlite3.Connection) -> bool:
    """Check if a doctor has permitted this HR trust to view their training."""
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT mode FROM doctor_visibility WHERE doctor_user_id = ?",
        (int(doctor_user_id),),
    ).fetchone()
    mode = str(row["mode"]) if row else "all"
    if mode == "all":
        return True
    if mode == "current":
        doc = conn.execute("SELECT current_trust FROM users WHERE id = ?", (int(doctor_user_id),)).fetchone()
        doc_trust = (doc["current_trust"] or "").strip().lower() if doc else ""
        return doc_trust == hr_trust.strip().lower()
    if mode == "allowlist":
        match = conn.execute(
            "SELECT 1 FROM doctor_visibility_allowlist WHERE doctor_user_id = ? AND LOWER(TRIM(trust_name)) = ?",
            (int(doctor_user_id), hr_trust.strip().lower()),
        ).fetchone()
        return match is not None
    return False


def hr_doctor_search(q: str, hr_trust: str, limit: int = 30) -> list[dict]:
    """
    Search doctors by name / email / GMC.
    Only returns doctors whose visibility settings allow hr_trust to see them.
    """
    q = (q or "").strip()
    if not q:
        return []
    pat = "%" + q.lower() + "%"
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_visibility_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT DISTINCT u.id, u.email, u.display_name, u.gmc_number, u.current_trust
            FROM users u
            WHERE u.premium = 0
              AND (
                LOWER(COALESCE(u.display_name,'')) LIKE ?
                OR LOWER(u.email) LIKE ?
                OR LOWER(COALESCE(u.gmc_number,'')) LIKE ?
              )
            ORDER BY u.display_name, u.email
            LIMIT ?
            """,
            (pat, pat, pat, max(1, min(int(limit), 100))),
        ).fetchall()
        out = []
        for r in rows:
            if _doctor_visible_to_trust(int(r["id"]), hr_trust, conn):
                out.append(
                    {
                        "id": int(r["id"]),
                        "email": r["email"],
                        "display_name": r["display_name"],
                        "gmc_number": r["gmc_number"],
                        "current_trust": r["current_trust"],
                    }
                )
        return out


def hr_doctors_search_messaging(q: str, limit: int = 30) -> list[dict]:
    """
    Search any non-premium DocPass account by name / email / GMC (no visibility filter).
    Used when HR starts a new message thread.
    """
    q = (q or "").strip()
    if not q:
        return []
    pat = "%" + q.lower() + "%"
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT u.id, u.email, u.display_name, u.gmc_number, u.current_trust
            FROM users u
            WHERE u.premium = 0
              AND (
                LOWER(COALESCE(u.display_name, '')) LIKE ?
                OR LOWER(u.email) LIKE ?
                OR LOWER(COALESCE(u.gmc_number, '')) LIKE ?
              )
            ORDER BY u.display_name, u.email
            LIMIT ?
            """,
            (pat, pat, pat, max(1, min(int(limit), 100))),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "email": r["email"],
            "display_name": r["display_name"],
            "gmc_number": r["gmc_number"],
            "current_trust": r["current_trust"],
        }
        for r in rows
    ]


def _ensure_hr_attestations_table(conn: sqlite3.Connection) -> None:
    """HR-issued credentials on behalf of doctors: drives verified-map + HR training view."""
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS hr_attested_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            credential_id TEXT NOT NULL,
            hr_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            verified_by_trust_name TEXT NOT NULL,
            module_name TEXT,
            expiry_date TEXT,
            attested_at TEXT NOT NULL,
            UNIQUE(doctor_user_id, credential_id)
        )
        """
    )


def hr_lookup_doctor_by_roster_line(identifier: str) -> Optional[dict]:
    """
    Resolve a single roster token (email or GMC) to a non-premium user row.
    Returns dict with id, email, display_name, gmc_number, current_trust, premium or None.
    """
    ident = (identifier or "").strip()
    if not ident:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        row = None
        if "@" in ident:
            row = conn.execute(
                "SELECT id, email, display_name, gmc_number, current_trust, premium FROM users WHERE email = ?",
                (ident.lower(),),
            ).fetchone()
        else:
            digits = re.sub(r"\D", "", ident)
            if not digits:
                return None
            row = conn.execute(
                """
                SELECT id, email, display_name, gmc_number, current_trust, premium
                FROM users
                WHERE premium = 0
                  AND REPLACE(REPLACE(REPLACE(COALESCE(gmc_number,''),' ',''),'-',''),'/','') = ?
                """,
                (digits,),
            ).fetchone()
            if row is None and len(digits) >= 7:
                g7 = digits[-7:]
                row = conn.execute(
                    """
                    SELECT id, email, display_name, gmc_number, current_trust, premium
                    FROM users
                    WHERE premium = 0
                      AND LENGTH(REPLACE(REPLACE(REPLACE(COALESCE(gmc_number,''),' ',''),'-',''),'/','')) >= 7
                      AND SUBSTR(REPLACE(REPLACE(REPLACE(COALESCE(gmc_number,''),' ',''),'-',''),'/',''), -7) = ?
                    """,
                    (g7,),
                ).fetchone()
        if not row:
            return None
        return {
            "id": int(row["id"]),
            "email": row["email"],
            "display_name": row["display_name"],
            "gmc_number": row["gmc_number"],
            "current_trust": row["current_trust"],
            "premium": int(row["premium"] or 0),
        }


def hr_attestation_upsert(
    doctor_user_id: int,
    credential_id: str,
    hr_user_id: int,
    verified_by_trust_name: str,
    module_name: Optional[str],
    expiry_date: Optional[str],
) -> None:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_attestations_table(conn)
        conn.execute(
            """
            INSERT INTO hr_attested_credentials (
                doctor_user_id, credential_id, hr_user_id, verified_by_trust_name,
                module_name, expiry_date, attested_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(doctor_user_id, credential_id) DO UPDATE SET
                hr_user_id = excluded.hr_user_id,
                verified_by_trust_name = excluded.verified_by_trust_name,
                module_name = excluded.module_name,
                expiry_date = excluded.expiry_date,
                attested_at = excluded.attested_at
            """,
            (
                int(doctor_user_id),
                str(credential_id),
                int(hr_user_id),
                str(verified_by_trust_name).strip(),
                (module_name or "").strip() or None,
                (expiry_date or "").strip() or None,
                now,
            ),
        )
        conn.commit()


def hr_attested_rows_for_doctor_trust(doctor_user_id: int, hr_trust: str) -> list[dict]:
    """Attestations visible to an HR trust (same trust name as stored at issue time)."""
    t = (hr_trust or "").strip().lower()
    if not t:
        return []
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_attestations_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT credential_id, module_name, expiry_date, attested_at, verified_by_trust_name
            FROM hr_attested_credentials
            WHERE doctor_user_id = ?
              AND LOWER(TRIM(verified_by_trust_name)) = ?
            ORDER BY datetime(COALESCE(attested_at, '')) DESC
            """,
            (int(doctor_user_id), t),
        ).fetchall()
    return [
        {
            "credential_id": r["credential_id"],
            "module_name": r["module_name"],
            "expiry_date": r["expiry_date"],
            "attested_at": r["attested_at"],
            "verified_by_trust_name": r["verified_by_trust_name"],
        }
        for r in rows
    ]


_DEFAULT_MANDATORY_TOPICS = [
    ("Information Governance",                    "UK CSTF / statutory"),
    ("Fire Safety",                               "UK CSTF / statutory"),
    ("Infection Prevention and Control",          "UK CSTF / statutory"),
    ("Safeguarding (adults & children) Level 3",  "UK CSTF / trust policy"),
    ("Health, Safety and Welfare",                "UK CSTF / statutory"),
    ("Equality, Diversity and Human Rights",      "UK CSTF / statutory"),
    ("Trust / local induction (destination-specific)", "Local — usually not portable"),
]


def _ensure_mandatory_topics_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS trust_mandatory_topics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trust_name TEXT NOT NULL,
            topic_name TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT '',
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tmt_trust ON trust_mandatory_topics(trust_name)")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(trust_mandatory_topics)").fetchall()}
    if "delivery_channel" not in cols:
        conn.execute("ALTER TABLE trust_mandatory_topics ADD COLUMN delivery_channel TEXT")
    if "resource_url" not in cols:
        conn.execute("ALTER TABLE trust_mandatory_topics ADD COLUMN resource_url TEXT")
    if "match_hints_json" not in cols:
        conn.execute("ALTER TABLE trust_mandatory_topics ADD COLUMN match_hints_json TEXT")


def _mandatory_topic_row_to_dict(r: sqlite3.Row) -> dict:
    import json as _json

    hints = None
    raw = r["match_hints_json"] if "match_hints_json" in r.keys() else None
    if raw:
        try:
            hints = _json.loads(raw)
        except (_json.JSONDecodeError, TypeError):
            hints = None
    return {
        "id": r["id"],
        "topic_name": r["topic_name"],
        "category": r["category"],
        "sort_order": r["sort_order"],
        "delivery_channel": r["delivery_channel"] if "delivery_channel" in r.keys() else None,
        "resource_url": r["resource_url"] if "resource_url" in r.keys() else None,
        "match_hints": hints,
    }


_MANDATORY_TOPIC_SELECT = """
    SELECT id, topic_name, category, sort_order, delivery_channel, resource_url, match_hints_json
    FROM trust_mandatory_topics WHERE trust_name = ? ORDER BY sort_order, id
"""


# ── Mandatory topics helpers ─────────────────────────────────────────────────

def mandatory_topics_count(trust_name: str) -> int:
    trust_name = (trust_name or "").strip()
    if not trust_name:
        return 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        n = conn.execute(
            "SELECT COUNT(*) FROM trust_mandatory_topics WHERE trust_name = ?",
            (trust_name,),
        ).fetchone()[0]
    return int(n)


def mandatory_topics_list(trust_name: str, *, seed_defaults: bool = True) -> list[dict]:
    """Return topics for a trust; optionally seeds generic CSTF defaults when empty."""
    trust_name = (trust_name or "").strip()
    if not trust_name:
        return []
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(_MANDATORY_TOPIC_SELECT, (trust_name,)).fetchall()
        if not rows and seed_defaults:
            now = datetime.utcnow().isoformat()
            for idx, (topic, cat) in enumerate(_DEFAULT_MANDATORY_TOPICS):
                conn.execute(
                    """INSERT INTO trust_mandatory_topics
                       (trust_name, topic_name, category, sort_order, created_at)
                       VALUES (?, ?, ?, ?, ?)""",
                    (trust_name, topic, cat, idx, now),
                )
            conn.commit()
            rows = conn.execute(_MANDATORY_TOPIC_SELECT, (trust_name,)).fetchall()
    return [_mandatory_topic_row_to_dict(r) for r in rows]


def mandatory_topics_insert_batch(trust_name: str, rows: list[dict]) -> int:
    """Insert mandatory topic rows; returns count inserted."""
    trust_name = (trust_name or "").strip()
    if not trust_name or not rows:
        return 0
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        for row in rows:
            conn.execute(
                """INSERT INTO trust_mandatory_topics
                   (trust_name, topic_name, category, sort_order, delivery_channel, resource_url, match_hints_json, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    trust_name,
                    row["topic_name"],
                    row.get("category") or "",
                    int(row.get("sort_order", 0)),
                    row.get("delivery_channel"),
                    row.get("resource_url"),
                    row.get("match_hints_json"),
                    now,
                ),
            )
        conn.commit()
    return len(rows)


def seed_mandatory_from_trust_pack(trust_name: str, pack: dict) -> tuple[int, str]:
    """
    Seed topics from a trust pack JSON dict when trust has no rows yet.
    Returns (rows_inserted, message).
    """
    from . import trust_packs

    trust_name = (trust_name or "").strip()
    if not trust_name:
        return 0, "trust_name required"
    if mandatory_topics_count(trust_name) > 0:
        return 0, "Trust already has mandatory topics; seed skipped to preserve HR edits."
    batch = trust_packs.mandatory_examples_to_rows(pack)
    if not batch:
        return 0, "Pack has no mandatory topics."
    n = mandatory_topics_insert_batch(trust_name, batch)
    return n, f"Seeded {n} mandatory topic(s) from trust pack."


def mandatory_topic_add(
    trust_name: str,
    topic_name: str,
    category: str,
    *,
    delivery_channel: Optional[str] = None,
    resource_url: Optional[str] = None,
    match_hints: Optional[dict] = None,
) -> dict:
    import json as _json

    trust_name = (trust_name or "").strip()
    topic_name = (topic_name or "").strip()
    category = (category or "").strip()
    if not trust_name or not topic_name:
        raise ValueError("trust_name and topic_name are required")
    hints_json = _json.dumps(match_hints) if match_hints else None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        max_order = conn.execute(
            "SELECT COALESCE(MAX(sort_order), -1) FROM trust_mandatory_topics WHERE trust_name = ?",
            (trust_name,),
        ).fetchone()[0]
        cursor = conn.execute(
            """INSERT INTO trust_mandatory_topics
               (trust_name, topic_name, category, sort_order, delivery_channel, resource_url, match_hints_json)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                trust_name,
                topic_name,
                category,
                max_order + 1,
                (delivery_channel or "").strip() or None,
                (resource_url or "").strip() or None,
                hints_json,
            ),
        )
        conn.commit()
        tid = int(cursor.lastrowid)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT id, topic_name, category, sort_order, delivery_channel, resource_url, match_hints_json FROM trust_mandatory_topics WHERE id = ?",
            (tid,),
        ).fetchone()
    return _mandatory_topic_row_to_dict(row)


def mandatory_topic_update(
    topic_id: int,
    trust_name: str,
    topic_name: str,
    category: str,
    *,
    delivery_channel: Optional[str] = None,
    resource_url: Optional[str] = None,
    match_hints: Optional[dict] = None,
    update_delivery_channel: bool = False,
    update_resource_url: bool = False,
    update_match_hints: bool = False,
) -> bool:
    import json as _json

    trust_name = (trust_name or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        existing = conn.execute(
            "SELECT delivery_channel, resource_url, match_hints_json FROM trust_mandatory_topics WHERE id = ? AND trust_name = ?",
            (int(topic_id), trust_name),
        ).fetchone()
        if not existing:
            return False
        ch = existing[0]
        url = existing[1]
        hints_json = existing[2]
        if update_delivery_channel:
            ch = (delivery_channel or "").strip() or None
        if update_resource_url:
            url = (resource_url or "").strip() or None
        if update_match_hints:
            hints_json = _json.dumps(match_hints) if match_hints else None
        cursor = conn.execute(
            """UPDATE trust_mandatory_topics SET
               topic_name = ?, category = ?, delivery_channel = ?, resource_url = ?, match_hints_json = ?
               WHERE id = ? AND trust_name = ?""",
            (
                (topic_name or "").strip(),
                (category or "").strip(),
                ch,
                url,
                hints_json,
                int(topic_id),
                trust_name,
            ),
        )
        conn.commit()
    return cursor.rowcount > 0


def mandatory_topic_delete(topic_id: int, trust_name: str) -> bool:
    trust_name = (trust_name or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        cursor = conn.execute(
            "DELETE FROM trust_mandatory_topics WHERE id = ? AND trust_name = ?",
            (int(topic_id), trust_name),
        )
        conn.commit()
    return cursor.rowcount > 0


def mandatory_topic_reorder(trust_name: str, ordered_ids: list[int]) -> None:
    """Update sort_order to match the given id sequence."""
    trust_name = (trust_name or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_topics_table(conn)
        for idx, tid in enumerate(ordered_ids):
            conn.execute(
                "UPDATE trust_mandatory_topics SET sort_order = ? WHERE id = ? AND trust_name = ?",
                (idx, int(tid), trust_name),
            )
        conn.commit()


def _ensure_messaging_tables(conn: sqlite3.Connection) -> None:
    """Free-form messaging between a doctor and an HR trust (one thread per pair)."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            hr_trust TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_message_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(doctor_user_id, hr_trust)
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_conv_trust ON conversations(hr_trust)")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            sender_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            sent_at TEXT NOT NULL DEFAULT (datetime('now')),
            read_at TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, sent_at)")


# ── Messaging helpers ────────────────────────────────────────────────────────

def _conv_row(r) -> dict:
    return {
        "id": int(r["id"]),
        "doctor_user_id": int(r["doctor_user_id"]),
        "doctor_name": r["doctor_name"],
        "doctor_email": r["doctor_email"],
        "doctor_gmc": r["doctor_gmc"],
        "hr_trust": r["hr_trust"],
        "created_at": r["created_at"],
        "last_message_at": r["last_message_at"],
        "unread_count": int(r["unread_count"] or 0),
        "last_body": r["last_body"],
    }


def _msg_row(r) -> dict:
    return {
        "id": int(r["id"]),
        "conversation_id": int(r["conversation_id"]),
        "sender_user_id": int(r["sender_user_id"]),
        "sender_name": r["sender_name"],
        "sender_email": r["sender_email"],
        "body": r["body"],
        "sent_at": r["sent_at"],
        "read_at": r["read_at"],
    }


def hr_messageable_trusts_search(query: str, limit: int = 40) -> list[dict]:
    """Premium (HR) users as messaging targets: match trust name or HR contact display_name."""
    q = (query or "").strip()
    lim = max(1, min(int(limit), 80))
    ql = q.lower()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        conn.row_factory = sqlite3.Row
        if q:
            rows = conn.execute(
                """
                SELECT TRIM(current_trust) AS trust_name,
                       TRIM(COALESCE(display_name, '')) AS contact_name
                FROM users
                WHERE premium = 1 AND TRIM(COALESCE(current_trust, '')) != ''
                  AND (
                    LOWER(TRIM(current_trust)) LIKE '%' || ? || '%'
                    OR LOWER(TRIM(COALESCE(display_name, ''))) LIKE '%' || ? || '%'
                  )
                ORDER BY (TRIM(COALESCE(display_name, '')) != '') DESC,
                         contact_name COLLATE NOCASE,
                         trust_name COLLATE NOCASE
                LIMIT ?
                """,
                (ql, ql, lim),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT TRIM(current_trust) AS trust_name,
                       TRIM(COALESCE(display_name, '')) AS contact_name
                FROM users
                WHERE premium = 1 AND TRIM(COALESCE(current_trust, '')) != ''
                ORDER BY trust_name COLLATE NOCASE,
                         contact_name COLLATE NOCASE
                LIMIT ?
                """,
                (lim,),
            ).fetchall()
    out = []
    seen = set()
    for r in rows:
        tn = (r["trust_name"] or "").strip()
        if not tn:
            continue
        cn = (r["contact_name"] or "").strip()
        key = (tn.lower(), cn.lower())
        if key in seen:
            continue
        seen.add(key)
        label = f"{cn} — {tn}" if cn else tn
        row = {"trust_name": tn, "label": label}
        if cn:
            row["contact_name"] = cn
        out.append(row)
    return out


def hr_messageable_trust_canonical(trust_input: str) -> Optional[str]:
    """Return stored trust string for matching premium HR inbox, or None."""
    raw = (trust_input or "").strip()
    if not raw:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT TRIM(current_trust) AS trust_name FROM users
            WHERE premium = 1 AND TRIM(COALESCE(current_trust, '')) != ''
              AND LOWER(TRIM(current_trust)) = LOWER(TRIM(?))
            LIMIT 1
            """,
            (raw,),
        ).fetchone()
        if not row:
            row = conn.execute(
                """
                SELECT TRIM(current_trust) AS trust_name FROM users
                WHERE premium = 1 AND TRIM(COALESCE(current_trust, '')) != ''
                  AND LOWER(TRIM(COALESCE(display_name, ''))) = LOWER(TRIM(?))
                LIMIT 1
                """,
                (raw,),
            ).fetchone()
    if not row:
        return None
    return (row["trust_name"] or "").strip() or None


def conversation_get_or_create(doctor_user_id: int, hr_trust: str) -> dict:
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        conn.execute(
            "INSERT OR IGNORE INTO conversations (doctor_user_id, hr_trust, created_at, last_message_at) VALUES (?, ?, datetime('now'), datetime('now'))",
            (int(doctor_user_id), hr_trust),
        )
        conn.commit()
        row = conn.execute(
            """
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   0 as unread_count,
                   (SELECT body FROM messages WHERE conversation_id = c.id ORDER BY sent_at DESC LIMIT 1) as last_body
            FROM conversations c JOIN users u ON u.id = c.doctor_user_id
            WHERE c.doctor_user_id = ? AND c.hr_trust = ?
            """,
            (int(doctor_user_id), hr_trust),
        ).fetchone()
    return _conv_row(row)


def conversations_for_doctor(doctor_user_id: int) -> list[dict]:
    """All conversation threads for a doctor (one per HR trust they've messaged)."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id
                    AND m.sender_user_id != ? AND m.read_at IS NULL) as unread_count,
                   (SELECT body FROM messages WHERE conversation_id = c.id ORDER BY sent_at DESC LIMIT 1) as last_body
            FROM conversations c JOIN users u ON u.id = c.doctor_user_id
            WHERE c.doctor_user_id = ?
            ORDER BY c.last_message_at DESC
            """,
            (int(doctor_user_id), int(doctor_user_id)),
        ).fetchall()
    return [_conv_row(r) for r in rows]


def conversations_for_hr_trust(hr_trust: str) -> list[dict]:
    """All conversation threads where the HR trust is the recipient side."""
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   (SELECT COUNT(*) FROM messages m
                    JOIN users su ON su.id = m.sender_user_id
                    WHERE m.conversation_id = c.id AND su.premium = 0 AND m.read_at IS NULL) as unread_count,
                   (SELECT body FROM messages WHERE conversation_id = c.id ORDER BY sent_at DESC LIMIT 1) as last_body
            FROM conversations c JOIN users u ON u.id = c.doctor_user_id
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            ORDER BY c.last_message_at DESC
            """,
            (hr_trust,),
        ).fetchall()
    return [_conv_row(r) for r in rows]


def messages_list(conversation_id: int, viewer_user_id: int, viewer_is_hr: bool) -> list[dict]:
    """Return all messages in a conversation, marking unread ones as read."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        # Mark messages from the other party as read
        now = datetime.utcnow().isoformat()
        if viewer_is_hr:
            # HR reads messages sent by the doctor (premium=0)
            conn.execute(
                """UPDATE messages SET read_at = ? WHERE conversation_id = ? AND read_at IS NULL
                   AND sender_user_id IN (SELECT id FROM users WHERE premium = 0)""",
                (now, int(conversation_id)),
            )
        else:
            # Doctor reads messages not sent by themselves
            conn.execute(
                "UPDATE messages SET read_at = ? WHERE conversation_id = ? AND read_at IS NULL AND sender_user_id != ?",
                (now, int(conversation_id), int(viewer_user_id)),
            )
        conn.commit()
        rows = conn.execute(
            """
            SELECT m.id, m.conversation_id, m.sender_user_id, m.body, m.sent_at, m.read_at,
                   u.display_name as sender_name, u.email as sender_email
            FROM messages m JOIN users u ON u.id = m.sender_user_id
            WHERE m.conversation_id = ?
            ORDER BY m.sent_at ASC
            """,
            (int(conversation_id),),
        ).fetchall()
    return [_msg_row(r) for r in rows]


def message_send(conversation_id: int, sender_user_id: int) -> dict:
    """Insert a message — called after the body is validated in the API layer."""
    # Note: body is passed via a separate parameter to avoid circular import confusion
    raise NotImplementedError("Use message_send_body instead")


def message_send_body(conversation_id: int, sender_user_id: int, body: str) -> dict:
    body = (body or "").strip()
    if not body:
        raise ValueError("Message body cannot be empty")
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            "INSERT INTO messages (conversation_id, sender_user_id, body, sent_at) VALUES (?, ?, ?, ?)",
            (int(conversation_id), int(sender_user_id), body, now),
        )
        conn.execute(
            "UPDATE conversations SET last_message_at = ? WHERE id = ?",
            (now, int(conversation_id)),
        )
        conn.commit()
        row = conn.execute(
            """SELECT m.id, m.conversation_id, m.sender_user_id, m.body, m.sent_at, m.read_at,
                      u.display_name as sender_name, u.email as sender_email
               FROM messages m JOIN users u ON u.id = m.sender_user_id
               WHERE m.id = ?""",
            (cursor.lastrowid,),
        ).fetchone()
    return _msg_row(row)


def messages_unread_count_for_doctor(doctor_user_id: int) -> int:
    """Total unread messages from HR across all conversations."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        row = conn.execute(
            """SELECT COUNT(*) FROM messages m
               JOIN conversations c ON c.id = m.conversation_id
               JOIN users su ON su.id = m.sender_user_id
               WHERE c.doctor_user_id = ? AND su.premium = 1 AND m.read_at IS NULL""",
            (int(doctor_user_id),),
        ).fetchone()
    return int(row[0]) if row else 0


def messages_unread_count_for_hr(hr_trust: str) -> int:
    """Total unread messages from doctors for an HR trust."""
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        row = conn.execute(
            """SELECT COUNT(*) FROM messages m
               JOIN conversations c ON c.id = m.conversation_id
               JOIN users su ON su.id = m.sender_user_id
               WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
                 AND su.premium = 0 AND m.read_at IS NULL""",
            (hr_trust,),
        ).fetchone()
    return int(row[0]) if row else 0


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
    if "target_trust" not in cols_s:
        conn.execute("ALTER TABLE share_sessions ADD COLUMN target_trust TEXT")
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
    target_trust: Optional[str] = None,
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
            "INSERT INTO share_sessions (created_at, doctor_user_id, doctor_email, share_token, status, share_kind, target_trust) VALUES (?, ?, ?, ?, 'OPEN', ?, ?)",
            (
                now,
                doctor_user_id,
                (doctor_email or "").strip().lower(),
                token,
                sk,
                (target_trust or "").strip() or None,
            ),
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
                  s.target_trust as target_trust,
                  s.status as status,
                  IFNULL(s.share_kind, 'review') as share_kind,
                  COUNT(i.credential_id) as total_count,
                  SUM(CASE WHEN i.status = 'VERIFIED' THEN 1 ELSE 0 END) as verified_count,
                  SUM(CASE WHEN i.status = 'DECLINED' THEN 1 ELSE 0 END) as declined_count,
                  SUM(CASE WHEN i.status = 'PENDING' THEN 1 ELSE 0 END) as pending_count
                FROM share_sessions s
                JOIN users u ON u.id = s.doctor_user_id
                LEFT JOIN share_items i ON i.session_id = s.id
                WHERE LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
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
                  s.target_trust as target_trust,
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
                "target_trust": r["target_trust"],
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
              s.target_trust as target_trust,
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
        "target_trust": s["target_trust"],
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
    """Return { credential_id: { shared, status, decision_at, decline_reason, pending_target_trust? } } for a doctor."""
    out: dict = {}
    attest_rows: list = []
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        _ensure_hr_attestations_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT i.credential_id, i.status, i.decision_at, i.decline_reason,
                   s.target_trust, s.created_at
            FROM share_sessions s
            JOIN share_items i ON i.session_id = s.id
            WHERE s.doctor_user_id = ?
            ORDER BY datetime(COALESCE(s.created_at, '')) DESC
            """,
            (int(doctor_user_id),),
        ).fetchall()
        attest_rows = conn.execute(
            """
            SELECT credential_id, attested_at
            FROM hr_attested_credentials
            WHERE doctor_user_id = ?
            """,
            (int(doctor_user_id),),
        ).fetchall()
    for r in rows:
        cid = r["credential_id"]
        prev = out.get(cid) or {
            "shared": True,
            "status": "PENDING",
            "decision_at": None,
            "decline_reason": None,
            "pending_target_trust": None,
        }
        prev["shared"] = True
        # Prefer terminal statuses over pending, and carry decline reason
        st = (r["status"] or "").upper()
        if st in ("VERIFIED", "DECLINED"):
            prev["status"] = st
            prev["decision_at"] = r["decision_at"]
            prev["decline_reason"] = r["decline_reason"]
            prev["pending_target_trust"] = None
        elif prev.get("status") not in ("VERIFIED", "DECLINED"):
            prev["status"] = "PENDING"
            # Rows are ordered by newest session first; keep the newest pending target trust.
            if not prev.get("pending_target_trust"):
                prev["pending_target_trust"] = (r["target_trust"] or "").strip() or None
        out[cid] = prev
    for ar in attest_rows:
        cid = ar["credential_id"]
        prev = out.get(cid) or {
            "shared": True,
            "status": "PENDING",
            "decision_at": None,
            "decline_reason": None,
            "pending_target_trust": None,
        }
        if prev.get("status") == "DECLINED":
            continue
        prev["shared"] = True
        prev["status"] = "VERIFIED"
        prev["decision_at"] = ar["attested_at"]
        prev["decline_reason"] = None
        prev["pending_target_trust"] = None
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
            "UPDATE users SET password_hash = ?, premium = 1, current_trust = ?, display_name = ? WHERE email = ?",
            (h, trust, DEV_SEED_DISPLAY_SHEFFIELD, email),
        )
        return
    conn.execute(
        "INSERT INTO users (email, password_hash, created_at, premium, gmc_number, display_name, current_trust) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (email, h, datetime.utcnow().isoformat(), 1, None, DEV_SEED_DISPLAY_SHEFFIELD, trust),
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
            "UPDATE users SET password_hash = ?, premium = 1, current_trust = ?, display_name = ? WHERE email = ?",
            (h, trust, DEV_SEED_DISPLAY_ROTHERHAM, email),
        )
        return
    conn.execute(
        "INSERT INTO users (email, password_hash, created_at, premium, gmc_number, display_name, current_trust) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (email, h, datetime.utcnow().isoformat(), 1, None, DEV_SEED_DISPLAY_ROTHERHAM, trust),
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


def _ensure_users_provision_columns(conn: sqlite3.Connection) -> None:
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "must_change_password" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN must_change_password INTEGER NOT NULL DEFAULT 0"
        )
    if "provisioned_by_hr" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN provisioned_by_hr INTEGER")


def _ensure_hr_cohorts_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS hr_cohorts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hr_trust TEXT NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            created_by_user_id INTEGER NOT NULL REFERENCES users(id)
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_hr_cohorts_trust ON hr_cohorts(hr_trust)"
    )
    conn.execute("""
        CREATE TABLE IF NOT EXISTS hr_cohort_members (
            cohort_id INTEGER NOT NULL REFERENCES hr_cohorts(id) ON DELETE CASCADE,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            added_at TEXT NOT NULL,
            PRIMARY KEY (cohort_id, user_id)
        )
    """)
    _ensure_hr_cohort_members_welcome_columns(conn)


def _ensure_hr_cohort_members_welcome_columns(conn: sqlite3.Connection) -> None:
    cols = [row[1] for row in conn.execute("PRAGMA table_info(hr_cohort_members)").fetchall()]
    if "welcome_pending" not in cols:
        conn.execute(
            "ALTER TABLE hr_cohort_members ADD COLUMN welcome_pending INTEGER NOT NULL DEFAULT 0"
        )
    if "welcome_sent_at" not in cols:
        conn.execute("ALTER TABLE hr_cohort_members ADD COLUMN welcome_sent_at TEXT")


def _provisioned_password_hash() -> str:
    if bcrypt is None:
        raise RuntimeError("bcrypt required for account provisioning")
    return bcrypt.hashpw(
        PROVISIONED_DEMO_PASSWORD.encode("utf-8"),
        bcrypt.gensalt(),
    ).decode("ascii")


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


def _user_public_dict(row: sqlite3.Row, include_password_hash: bool = False) -> dict:
    out = {
        "id": row["id"],
        "email": row["email"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
        "gmc_number": row["gmc_number"],
        "display_name": row["display_name"],
        "current_trust": row["current_trust"],
        "must_change_password": bool(row["must_change_password"])
        if "must_change_password" in row.keys() and row["must_change_password"] is not None
        else False,
    }
    if include_password_hash:
        out["password_hash"] = row["password_hash"]
    return out


def user_get_by_email(email: str):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_provision_columns(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """SELECT id, email, password_hash, premium, gmc_number, display_name, current_trust,
                      must_change_password FROM users WHERE email = ?""",
            (email,),
        ).fetchone()
    if not row:
        return None
    return _user_public_dict(row, include_password_hash=True)


def user_get_by_id(user_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_provision_columns(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """SELECT id, email, premium, gmc_number, display_name, current_trust,
                      must_change_password FROM users WHERE id = ?""",
            (user_id,),
        ).fetchone()
    if not row:
        return None
    return _user_public_dict(row)


def user_must_change_password(user_id: int) -> bool:
    u = user_get_by_id(user_id)
    return bool(u and u.get("must_change_password"))


def user_set_password(user_id: int, password_hash: str, clear_must_change: bool = False) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_provision_columns(conn)
        if clear_must_change:
            conn.execute(
                "UPDATE users SET password_hash = ?, must_change_password = 0 WHERE id = ?",
                (password_hash, int(user_id)),
            )
        else:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, int(user_id)),
            )
        conn.commit()


def user_set_current_trust_if_empty(user_id: int, trust: str) -> None:
    """Set current_trust only when the clinician has not chosen one yet."""
    trust = (trust or "").strip() or None
    if not trust:
        return
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_profile_extra_columns(conn)
        conn.execute(
            """UPDATE users SET current_trust = ?
               WHERE id = ? AND (current_trust IS NULL OR TRIM(current_trust) = '')""",
            (trust, int(user_id)),
        )
        conn.commit()


def user_create_provisioned(
    email: str,
    provisioned_by_hr_user_id: int,
    default_trust: Optional[str] = None,
) -> int:
    """Create non-premium clinician with demo password and must_change_password=1."""
    email = (email or "").strip().lower()
    trust = (default_trust or "").strip() or None
    h = _provisioned_password_hash()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_provision_columns(conn)
        cur = conn.execute(
            """INSERT INTO users (
                   email, password_hash, created_at, premium, gmc_number, display_name, current_trust,
                   must_change_password, provisioned_by_hr
               ) VALUES (?, ?, ?, 0, NULL, NULL, ?, 1, ?)""",
            (email, h, datetime.utcnow().isoformat(), trust, int(provisioned_by_hr_user_id)),
        )
        uid = int(cur.lastrowid)
        conn.execute(
            """INSERT INTO user_wallets (user_id, wallet_json, updated_at) VALUES (?, '[]', ?)
               ON CONFLICT(user_id) DO NOTHING""",
            (uid, datetime.utcnow().isoformat()),
        )
        conn.commit()
        return uid


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


# ---------- HR cohorts (provision clinicians + group messaging) ----------


def cohort_create(hr_trust: str, name: str, created_by_user_id: int) -> int:
    hr_trust = (hr_trust or "").strip()
    name = (name or "").strip()
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        cur = conn.execute(
            "INSERT INTO hr_cohorts (hr_trust, name, created_at, created_by_user_id) VALUES (?, ?, ?, ?)",
            (hr_trust, name, now, int(created_by_user_id)),
        )
        conn.commit()
        return int(cur.lastrowid)


def cohort_list_for_trust(hr_trust: str) -> list[dict]:
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   (SELECT COUNT(*) FROM hr_cohort_members m WHERE m.cohort_id = c.id) AS member_count
            FROM hr_cohorts c
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            ORDER BY c.created_at DESC
            """,
            (hr_trust,),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "hr_trust": r["hr_trust"],
            "name": r["name"],
            "created_at": r["created_at"],
            "created_by_user_id": int(r["created_by_user_id"]),
            "member_count": int(r["member_count"] or 0),
        }
        for r in rows
    ]


def cohort_get(cohort_id: int, hr_trust: str) -> Optional[dict]:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   (SELECT COUNT(*) FROM hr_cohort_members m WHERE m.cohort_id = c.id) AS member_count
            FROM hr_cohorts c
            WHERE c.id = ? AND LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            """,
            (int(cohort_id), (hr_trust or "").strip()),
        ).fetchone()
    if not row:
        return None
    return {
        "id": int(row["id"]),
        "hr_trust": row["hr_trust"],
        "name": row["name"],
        "created_at": row["created_at"],
        "created_by_user_id": int(row["created_by_user_id"]),
        "member_count": int(row["member_count"] or 0),
    }


def cohort_members_list(cohort_id: int, hr_trust: str) -> list[dict]:
    if not cohort_get(cohort_id, hr_trust):
        return []
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_users_provision_columns(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT u.id, u.email, u.display_name, u.gmc_number, u.current_trust,
                   u.must_change_password, u.provisioned_by_hr, m.added_at,
                   m.welcome_pending, m.welcome_sent_at
            FROM hr_cohort_members m
            JOIN users u ON u.id = m.user_id
            WHERE m.cohort_id = ?
            ORDER BY u.display_name, u.email
            """,
            (int(cohort_id),),
        ).fetchall()
    return [
        {
            "user_id": int(r["id"]),
            "email": r["email"],
            "display_name": r["display_name"],
            "gmc_number": r["gmc_number"],
            "current_trust": r["current_trust"],
            "must_change_password": bool(r["must_change_password"]),
            "provisioned_by_hr": r["provisioned_by_hr"],
            "added_at": r["added_at"],
            "welcome_pending": bool(r["welcome_pending"])
            if r["welcome_pending"] is not None
            else False,
            "welcome_sent_at": r["welcome_sent_at"],
        }
        for r in rows
    ]


def cohort_member_user_ids(cohort_id: int, hr_trust: str) -> list[int]:
    members = cohort_members_list(cohort_id, hr_trust)
    return [int(m["user_id"]) for m in members]


def cohort_roster_lines(cohort_id: int, hr_trust: str) -> list[str]:
    """Roster identifiers for bulk training: work email, else GMC number."""
    lines: list[str] = []
    for m in cohort_members_list(cohort_id, hr_trust):
        email = (m.get("email") or "").strip()
        gmc = (m.get("gmc_number") or "").strip()
        if email:
            lines.append(email)
        elif gmc:
            lines.append(gmc)
    return lines


def cohort_add_member(
    cohort_id: int, user_id: int, welcome_pending: bool = False
) -> None:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_hr_cohort_members_welcome_columns(conn)
        conn.execute(
            """INSERT OR IGNORE INTO hr_cohort_members
               (cohort_id, user_id, added_at, welcome_pending, welcome_sent_at)
               VALUES (?, ?, ?, ?, NULL)""",
            (int(cohort_id), int(user_id), now, 1 if welcome_pending else 0),
        )
        if welcome_pending:
            conn.execute(
                """UPDATE hr_cohort_members SET welcome_pending = 1
                   WHERE cohort_id = ? AND user_id = ? AND welcome_sent_at IS NULL""",
                (int(cohort_id), int(user_id)),
            )
        conn.commit()


def cohort_set_welcome_pending(cohort_id: int, user_id: int) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_hr_cohort_members_welcome_columns(conn)
        conn.execute(
            """UPDATE hr_cohort_members SET welcome_pending = 1
               WHERE cohort_id = ? AND user_id = ? AND welcome_sent_at IS NULL""",
            (int(cohort_id), int(user_id)),
        )
        conn.commit()


def cohort_pending_welcomes_for_user(user_id: int) -> list[dict]:
    """Pending welcome rows for a user (one row per cohort membership)."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_hr_cohort_members_welcome_columns(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT m.cohort_id, m.user_id, c.hr_trust, c.created_by_user_id
            FROM hr_cohort_members m
            JOIN hr_cohorts c ON c.id = m.cohort_id
            WHERE m.user_id = ?
              AND m.welcome_pending = 1
              AND m.welcome_sent_at IS NULL
            """,
            (int(user_id),),
        ).fetchall()
    return [
        {
            "cohort_id": int(r["cohort_id"]),
            "user_id": int(r["user_id"]),
            "hr_trust": r["hr_trust"],
            "created_by_user_id": int(r["created_by_user_id"]),
        }
        for r in rows
    ]


def cohort_mark_welcome_sent_for_user(user_id: int, cohort_ids: Optional[list[int]] = None) -> None:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_hr_cohort_members_welcome_columns(conn)
        if cohort_ids:
            for cid in cohort_ids:
                conn.execute(
                    """UPDATE hr_cohort_members
                       SET welcome_pending = 0, welcome_sent_at = ?
                       WHERE user_id = ? AND cohort_id = ?""",
                    (now, int(user_id), int(cid)),
                )
        else:
            conn.execute(
                """UPDATE hr_cohort_members
                   SET welcome_pending = 0, welcome_sent_at = ?
                   WHERE user_id = ? AND welcome_pending = 1 AND welcome_sent_at IS NULL""",
                (now, int(user_id)),
            )
        conn.commit()


def cohort_add_members_from_emails(
    cohort_id: int,
    hr_trust: str,
    emails: list[str],
    hr_user_id: int,
    reserved_emails: set[str],
    queue_welcome: bool = False,
) -> list[dict]:
    """
    For each email: create provisioned user or link existing; add to cohort.
    Returns per-row result dicts (email, status, user_id, error).
    """
    from . import trust_packs

    cohort = cohort_get(cohort_id, hr_trust)
    if not cohort:
        raise ValueError("cohort_not_found")
    default_trust = trust_packs.trust_display_name(hr_trust) or None
    results: list[dict] = []
    for raw in emails:
        email = (raw or "").strip().lower()
        if not email:
            continue
        if email in reserved_emails:
            results.append(
                {"email": email, "status": "failed", "user_id": None, "error": "reserved email"}
            )
            continue
        existing = user_get_by_email(email)
        if existing:
            if user_is_premium(existing):
                results.append(
                    {
                        "email": email,
                        "status": "failed",
                        "user_id": None,
                        "error": "premium account",
                    }
                )
                continue
            uid = int(existing["id"])
            user_set_current_trust_if_empty(uid, default_trust or "")
            cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
            results.append({"email": email, "status": "existing", "user_id": uid, "error": None})
            continue
        try:
            uid = user_create_provisioned(email, hr_user_id, default_trust=default_trust)
            cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
            results.append({"email": email, "status": "created", "user_id": uid, "error": None})
        except sqlite3.IntegrityError:
            existing = user_get_by_email(email)
            if existing and not user_is_premium(existing):
                uid = int(existing["id"])
                user_set_current_trust_if_empty(uid, default_trust or "")
                cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
                results.append({"email": email, "status": "existing", "user_id": uid, "error": None})
            else:
                results.append(
                    {
                        "email": email,
                        "status": "failed",
                        "user_id": None,
                        "error": "could not create account",
                    }
                )
    return results
