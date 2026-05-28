"""
Minimal storage: credential_id -> revocation and expiry.
No full PII stored; JWT holds the claims.
"""
import json
import os
import re
import sqlite3
from pathlib import Path
from datetime import datetime, timedelta
from typing import Callable, Optional
import secrets

try:
    import bcrypt  # type: ignore
except Exception:  # pragma: no cover
    bcrypt = None

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "credentials.db"
DEV_SEED_EMAIL = "sheffieldhr@nhs.net"
DEV_SEED_EMAIL_ROTHERHAM = "rotherhamhr@nhs.net"
DEV_SEED_PASSWORD = "password"
# Demo-only: HR-provisioned doctors start with this password; never returned via API.
PROVISIONED_DEMO_PASSWORD = "password"
DEV_SEED_TRUST_SHEFFIELD = "Sheffield Health Partnership University NHS Foundation Trust"
DEV_SEED_TRUST_ROTHERHAM = "Rotherham Doncaster and South Humber NHS Foundation Trust"
DEV_SEED_DISPLAY_SHEFFIELD = "Sheffield HR"
DEV_SEED_DISPLAY_ROTHERHAM = "Rotherham HR"
DEFAULT_COHORT_NAME = "All Doctors"
LEGACY_DEFAULT_COHORT_NAMES = ("Ad-Hoc",)
# Count only members whose user account still exists (SQLite FK cascades are off by default).
_COHORT_ACTIVE_MEMBER_COUNT_SQL = """
(SELECT COUNT(*) FROM hr_cohort_members m
 INNER JOIN users u ON u.id = m.user_id
 WHERE m.cohort_id = c.id)
"""


def _default_cohort_name_sql_predicate(column: str) -> str:
    names = [DEFAULT_COHORT_NAME, *LEGACY_DEFAULT_COHORT_NAMES]
    parts = " OR ".join(
        f"LOWER(TRIM({column})) = LOWER({repr(n)})" for n in names
    )
    return f"({parts})"


# All Doctors counts every distinct doctor across all trust groups.
_COHORT_MEMBER_COUNT_SQL = f"""
CASE
  WHEN {_default_cohort_name_sql_predicate("c.name")} THEN (
    SELECT COUNT(DISTINCT m.user_id)
    FROM hr_cohort_members m
    INNER JOIN hr_cohorts c2 ON c2.id = m.cohort_id
    INNER JOIN users u ON u.id = m.user_id
    WHERE LOWER(TRIM(c2.hr_trust)) = LOWER(TRIM(c.hr_trust))
  )
  ELSE (
    SELECT COUNT(*)
    FROM hr_cohort_members m
    INNER JOIN users u ON u.id = m.user_id
    WHERE m.cohort_id = c.id
  )
END
"""
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
        _ensure_expiry_reminder_sent_table(conn)
        _ensure_hr_attestations_table(conn)
        _ensure_mandatory_match_decisions_table(conn)
        _ensure_users_provision_columns(conn)
        _ensure_hr_cohorts_tables(conn)
        _ensure_notifications_table(conn)
        _ensure_hr_audit_log_table(conn)
        _ensure_hr_verifier_links_table(conn)
        _ensure_hr_welcome_templates_table(conn)
        _ensure_password_resets_table(conn)
        _ensure_mfa_tables(conn)
        _ensure_seed_privileged_user(conn)
        _ensure_seed_rotherham_user(conn)
        _ensure_default_cohorts_for_premium_hr(conn)
        _backfill_sheffield_partnership_trust_labels(conn)
        _backfill_uppercase_current_trust(conn)
        _migrate_provisioned_personal_email_login(conn)
        _migrate_merge_duplicate_conversation_trusts(conn)
        _migrate_normalize_conversation_trust_labels(conn)
        _backfill_onboarding_completed(conn)
        _cleanup_orphan_cohort_members(conn)
        _backfill_all_doctors_membership(conn)
        _migrate_hr_welcome_auto_default(conn)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.commit()


def _backfill_sheffield_partnership_trust_labels(conn: sqlite3.Connection) -> None:
    """Fix doctors provisioned with the old wrong SHSC label instead of Sheffield Partnership."""
    from . import trust_packs

    new_label = trust_packs.normalize_stored_trust_name(DEV_SEED_TRUST_SHEFFIELD)
    if not new_label:
        return
    for old in _LEGACY_SHEFFIELD_PARTNERSHIP_TRUST_LABELS:
        conn.execute(
            "UPDATE users SET current_trust = ? WHERE TRIM(COALESCE(current_trust, '')) = ?",
            (new_label, old),
        )
    conn.execute(
        "UPDATE users SET current_trust = ? WHERE TRIM(COALESCE(current_trust, '')) = ?",
        (
            new_label,
            "SHEFFIELD HEALTH PARTNERSHIP UNIVERSITY NHS FOUNDATION TRUST",
        ),
    )


def _backfill_uppercase_current_trust(conn: sqlite3.Connection) -> None:
    """Replace ODS-style ALL CAPS current_trust with readable display labels."""
    from . import trust_packs

    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT id, current_trust FROM users WHERE TRIM(COALESCE(current_trust, '')) != ''"
    ).fetchall()
    for row in rows:
        raw = (row["current_trust"] or "").strip()
        if not raw or raw != raw.upper() or len(raw) <= 3:
            continue
        normalized = trust_packs.normalize_stored_trust_name(raw)
        if normalized and normalized != raw:
            conn.execute(
                "UPDATE users SET current_trust = ? WHERE id = ?",
                (normalized, int(row["id"])),
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
    """Return { mode, allowlist, messaged_trusts } for a doctor."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_visibility_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT mode FROM doctor_visibility WHERE doctor_user_id = ?",
            (int(doctor_user_id),),
        ).fetchone()
        mode = str(row["mode"]) if row else "messaged"
        al_rows = conn.execute(
            "SELECT trust_name, trust_ods FROM doctor_visibility_allowlist WHERE doctor_user_id = ? ORDER BY trust_name",
            (int(doctor_user_id),),
        ).fetchall()
        messaged = sorted(_doctor_messaged_trust_names(int(doctor_user_id), conn))
    return {
        "mode": mode,
        "allowlist": [{"trust_name": r["trust_name"], "trust_ods": r["trust_ods"]} for r in al_rows],
        "messaged_trusts": messaged,
    }


def visibility_set(doctor_user_id: int, mode: str, allowlist: list[dict]) -> None:
    """Upsert visibility mode and replace allowlist."""
    valid_modes = {"all", "current", "allowlist", "messaged"}
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


def _doctor_messaged_trust_names(doctor_user_id: int, conn: sqlite3.Connection) -> set[str]:
    """Trust names where doctor has a DocPass message thread with HR."""
    _ensure_messaging_tables(conn)
    rows = conn.execute(
        """
        SELECT DISTINCT TRIM(hr_trust) AS t
        FROM conversations
        WHERE doctor_user_id = ? AND TRIM(COALESCE(hr_trust, '')) != ''
        """,
        (int(doctor_user_id),),
    ).fetchall()
    return {str(r["t"]).strip().lower() for r in rows if r["t"]}


def share_credential_was_declined(
    doctor_user_id: int,
    credential_id: str,
    hr_trust: Optional[str] = None,
    *,
    conn: Optional[sqlite3.Connection] = None,
) -> bool:
    """True if this credential was previously DECLINED for the doctor (optionally at a trust)."""
    cid = (credential_id or "").strip()
    if not cid:
        return False
    trust = (hr_trust or "").strip().lower()

    def _query(c: sqlite3.Connection) -> bool:
        _ensure_share_tables(c)
        if trust:
            row = c.execute(
                """
                SELECT 1 FROM share_items i
                JOIN share_sessions s ON s.id = i.session_id
                WHERE s.doctor_user_id = ? AND i.credential_id = ?
                  AND i.status = 'DECLINED'
                  AND LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
                LIMIT 1
                """,
                (int(doctor_user_id), cid, trust),
            ).fetchone()
        else:
            row = c.execute(
                """
                SELECT 1 FROM share_items i
                JOIN share_sessions s ON s.id = i.session_id
                WHERE s.doctor_user_id = ? AND i.credential_id = ? AND i.status = 'DECLINED'
                LIMIT 1
                """,
                (int(doctor_user_id), cid),
            ).fetchone()
        return row is not None

    if conn is not None:
        return _query(conn)
    with sqlite3.connect(DB_PATH, timeout=30) as own:
        return _query(own)


def _doctor_visible_to_trust(doctor_user_id: int, hr_trust: str, conn: sqlite3.Connection) -> bool:
    """Check if a doctor has permitted this HR trust to view their training."""
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT mode FROM doctor_visibility WHERE doctor_user_id = ?",
        (int(doctor_user_id),),
    ).fetchone()
    mode = str(row["mode"]) if row else "messaged"
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
    if mode == "messaged":
        return hr_trust.strip().lower() in _doctor_messaged_trust_names(int(doctor_user_id), conn)
    return False


def _doctor_member_of_trust_cohort(
    doctor_user_id: int, hr_trust: str, conn: sqlite3.Connection
) -> bool:
    """True if the doctor belongs to any cohort owned by this HR trust."""
    row = conn.execute(
        """
        SELECT 1 FROM hr_cohort_members m
        JOIN hr_cohorts c ON c.id = m.cohort_id
        WHERE m.user_id = ? AND LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
        LIMIT 1
        """,
        (int(doctor_user_id), (hr_trust or "").strip()),
    ).fetchone()
    return row is not None


def _doctor_deletable_by_trust(
    doctor_user_id: int, hr_trust: str, conn: sqlite3.Connection
) -> bool:
    """HR may delete if the doctor is searchable-visible or in one of the trust's groups."""
    if _doctor_visible_to_trust(int(doctor_user_id), hr_trust, conn):
        return True
    return _doctor_member_of_trust_cohort(int(doctor_user_id), hr_trust, conn)


def _user_trust_fields(current_trust: Optional[str]) -> dict:
    from . import trust_packs

    ct = (current_trust or "").strip() or None
    return {
        "current_trust": ct,
        "current_trust_display": trust_packs.trust_display_name(ct) if ct else None,
    }


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
                        **_user_trust_fields(r["current_trust"]),
                    }
                )
        return out


def hr_cohort_search_by_name(hr_trust: str, q: str, limit: int = 10) -> list[dict]:
    """Match cohorts by name for the HR user's trust (messages / search UI)."""
    q = (q or "").strip()
    hr_trust = (hr_trust or "").strip()
    if not q or not hr_trust:
        return []
    pat = "%" + q.lower() + "%"
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.name,
                   """ + _COHORT_MEMBER_COUNT_SQL.strip() + """ AS member_count
            FROM hr_cohorts c
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
              AND LOWER(c.name) LIKE ?
            ORDER BY c.name
            LIMIT ?
            """,
            (hr_trust, pat, max(1, min(int(limit), 30))),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "name": r["name"],
            "member_count": int(r["member_count"] or 0),
        }
        for r in rows
    ]


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
            **_user_trust_fields(r["current_trust"]),
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
            ident_l = ident.lower()
            row = conn.execute(
                "SELECT id, email, display_name, gmc_number, current_trust, premium FROM users WHERE email = ?",
                (ident_l,),
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


def hr_attestation_delete(doctor_user_id: int, credential_id: str, hr_trust: str) -> bool:
    """Remove HR attestation for a credential at this trust (bulk/single HR issue)."""
    t = (hr_trust or "").strip().lower()
    if not t:
        return False
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_attestations_table(conn)
        cur = conn.execute(
            """
            DELETE FROM hr_attested_credentials
            WHERE doctor_user_id = ? AND credential_id = ?
              AND LOWER(TRIM(verified_by_trust_name)) = ?
            """,
            (int(doctor_user_id), str(credential_id), t),
        )
        conn.commit()
        return cur.rowcount > 0


def _ensure_mandatory_match_decisions_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS mandatory_match_decisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            trust_name TEXT NOT NULL,
            topic_id INTEGER,
            topic_name TEXT NOT NULL,
            credential_id TEXT NOT NULL,
            decision TEXT NOT NULL CHECK(decision IN ('accepted', 'rejected')),
            hr_user_id INTEGER NOT NULL REFERENCES users(id),
            decided_at TEXT NOT NULL,
            UNIQUE(doctor_user_id, trust_name, topic_name, credential_id)
        )
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_mandatory_match_decisions_doctor_trust
        ON mandatory_match_decisions(doctor_user_id, trust_name)
        """
    )


def mandatory_match_decision_upsert(
    *,
    doctor_user_id: int,
    trust_name: str,
    topic_id: Optional[int],
    topic_name: str,
    credential_id: str,
    decision: str,
    hr_user_id: int,
) -> dict:
    dec = (decision or "").strip().lower()
    if dec not in ("accepted", "rejected"):
        raise ValueError("decision must be accepted or rejected")
    trust = (trust_name or "").strip()
    topic = (topic_name or "").strip()
    cid = (credential_id or "").strip()
    if not trust or not topic or not cid:
        raise ValueError("trust_name, topic_name, and credential_id are required")
    now = datetime.utcnow().isoformat()
    tid = int(topic_id) if topic_id is not None else None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_match_decisions_table(conn)
        conn.execute(
            """
            INSERT INTO mandatory_match_decisions (
                doctor_user_id, trust_name, topic_id, topic_name, credential_id,
                decision, hr_user_id, decided_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(doctor_user_id, trust_name, topic_name, credential_id) DO UPDATE SET
                topic_id = excluded.topic_id,
                decision = excluded.decision,
                hr_user_id = excluded.hr_user_id,
                decided_at = excluded.decided_at
            """,
            (int(doctor_user_id), trust, tid, topic, cid, dec, int(hr_user_id), now),
        )
        conn.commit()
    return {
        "doctor_user_id": int(doctor_user_id),
        "trust_name": trust,
        "topic_id": tid,
        "topic_name": topic,
        "credential_id": cid,
        "decision": dec,
        "hr_user_id": int(hr_user_id),
        "decided_at": now,
    }


def mandatory_match_decisions_map(doctor_user_id: int, trust_name: str) -> dict[str, dict]:
    """Map decision lookup keys to decision rows for one doctor at a trust."""
    trust = (trust_name or "").strip()
    if not trust:
        return {}
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mandatory_match_decisions_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT topic_id, topic_name, credential_id, decision, hr_user_id, decided_at
            FROM mandatory_match_decisions
            WHERE doctor_user_id = ? AND LOWER(TRIM(trust_name)) = LOWER(TRIM(?))
            """,
            (int(doctor_user_id), trust),
        ).fetchall()
    out: dict[str, dict] = {}
    for r in rows:
        tid = r["topic_id"]
        tname = (r["topic_name"] or "").strip()
        cid = str(r["credential_id"] or "")
        key = f"{tid if tid is not None else tname}::{cid}"
        out[key] = {
            "topic_id": tid,
            "topic_name": tname,
            "credential_id": cid,
            "decision": (r["decision"] or "").lower(),
            "hr_user_id": r["hr_user_id"],
            "decided_at": r["decided_at"],
        }
    return out


def share_item_find_verified_for_trust(
    doctor_user_id: int, credential_id: str, hr_trust: str
) -> Optional[dict]:
    """Most recent VERIFIED share_items row for this doctor/credential at the HR trust."""
    t = (hr_trust or "").strip().lower()
    if not t:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT i.session_id, i.status, IFNULL(s.share_kind, 'review') as share_kind
            FROM share_items i
            JOIN share_sessions s ON s.id = i.session_id
            WHERE s.doctor_user_id = ?
              AND i.credential_id = ?
              AND UPPER(TRIM(i.status)) = 'VERIFIED'
              AND LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
            ORDER BY s.id DESC
            LIMIT 1
            """,
            (int(doctor_user_id), str(credential_id), t),
        ).fetchone()
    if not row:
        return None
    return {
        "session_id": int(row["session_id"]),
        "status": row["status"],
        "share_kind": str(row["share_kind"] or "review"),
    }


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
    _ensure_message_attachments_table(conn)


def _ensure_message_attachments_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS message_attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            filename TEXT NOT NULL,
            content_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            data BLOB NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_msg_attach_message ON message_attachments(message_id)"
    )


def _ensure_expiry_reminder_sent_table(conn: sqlite3.Connection) -> None:
    """Track automatic in-app expiry reminders so doctors are not nudged repeatedly."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS expiry_reminder_sent (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hr_trust TEXT NOT NULL,
            doctor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            credential_id TEXT NOT NULL,
            reminder_stage TEXT NOT NULL,
            module_name TEXT,
            sent_at TEXT NOT NULL,
            UNIQUE(doctor_user_id, credential_id, reminder_stage)
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_expiry_reminder_trust ON expiry_reminder_sent(hr_trust, sent_at DESC)"
    )


def expiry_reminder_was_sent(doctor_user_id: int, credential_id: str, stage: str) -> bool:
    cid = (credential_id or "").strip()
    st = (stage or "").strip()
    if not cid or not st:
        return False
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_expiry_reminder_sent_table(conn)
        row = conn.execute(
            """
            SELECT 1 FROM expiry_reminder_sent
            WHERE doctor_user_id = ? AND credential_id = ? AND reminder_stage = ?
            LIMIT 1
            """,
            (int(doctor_user_id), cid, st),
        ).fetchone()
    return bool(row)


def expiry_reminder_mark_sent(
    *,
    hr_trust: str,
    doctor_user_id: int,
    credential_id: str,
    stage: str,
    module_name: Optional[str] = None,
) -> None:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_expiry_reminder_sent_table(conn)
        conn.execute(
            """
            INSERT OR IGNORE INTO expiry_reminder_sent
                (hr_trust, doctor_user_id, credential_id, reminder_stage, module_name, sent_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                (hr_trust or "").strip(),
                int(doctor_user_id),
                (credential_id or "").strip(),
                (stage or "").strip(),
                (module_name or "").strip() or None,
                now,
            ),
        )
        conn.commit()


def trust_expiry_reminders_enabled(trust: str) -> bool:
    """True when at least one premium HR user at the trust has automatic reminders on."""
    users = hr_premium_users_for_trust(trust)
    if not users:
        return False
    return any(u.get("hr_expiry_reminders_enabled", True) for u in users)


def hr_message_sender_for_trust(trust: str) -> Optional[dict]:
    """Premium HR account used as sender for automated trust messages."""
    users = hr_premium_users_for_trust(trust)
    for u in users:
        if u.get("hr_expiry_reminders_enabled", True):
            return u
    return users[0] if users else None


def clinicians_at_trust(trust: str) -> list[dict]:
    """Non-premium users whose current_trust matches (case-insensitive)."""
    trust_key = (trust or "").strip().lower()
    if not trust_key:
        return []
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT id, email, display_name, gmc_number
            FROM users
            WHERE premium = 0 AND LOWER(TRIM(COALESCE(current_trust, ''))) = ?
            ORDER BY display_name COLLATE NOCASE, email COLLATE NOCASE
            """,
            (trust_key,),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "email": r["email"],
            "display_name": r["display_name"],
            "gmc_number": r["gmc_number"],
        }
        for r in rows
    ]


# ── Messaging helpers ────────────────────────────────────────────────────────

_CONV_LAST_BODY_SQL = """(
    SELECT COALESCE(
        NULLIF(TRIM(m2.body), ''),
        (SELECT '📎 ' || filename FROM message_attachments ma
         WHERE ma.message_id = m2.id ORDER BY ma.id ASC LIMIT 1)
    )
    FROM messages m2 WHERE m2.conversation_id = c.id ORDER BY m2.sent_at DESC LIMIT 1
) as last_body"""


def _hr_trust_display_label(hr_trust: str) -> str:
    from . import trust_packs

    raw = (hr_trust or "").strip()
    if not raw:
        return "HR"
    return trust_packs.trust_display_name(raw) or raw


def conversation_trust_canonical(trust_input: str) -> str:
    """
    One stored trust key per HR inbox: prefer the premium HR account's current_trust
    when the input matches case-insensitively; otherwise a stable display label.
    """
    raw = (trust_input or "").strip()
    if not raw:
        return raw
    canonical = hr_messageable_trust_canonical(raw)
    if canonical:
        return canonical
    from . import trust_packs

    displayed = (trust_packs.trust_display_name(raw) or "").strip()
    return displayed or raw


def _conv_row(r) -> dict:
    hr_trust = r["hr_trust"]
    return {
        "id": int(r["id"]),
        "doctor_user_id": int(r["doctor_user_id"]),
        "doctor_name": r["doctor_name"],
        "doctor_email": r["doctor_email"],
        "doctor_gmc": r["doctor_gmc"],
        "hr_trust": hr_trust,
        "hr_trust_display": _hr_trust_display_label(hr_trust),
        "created_at": r["created_at"],
        "last_message_at": r["last_message_at"],
        "unread_count": int(r["unread_count"] or 0),
        "last_body": r["last_body"],
    }


def _msg_row(r, attachments: Optional[list[dict]] = None) -> dict:
    return {
        "id": int(r["id"]),
        "conversation_id": int(r["conversation_id"]),
        "sender_user_id": int(r["sender_user_id"]),
        "sender_name": r["sender_name"],
        "sender_email": r["sender_email"],
        "body": r["body"],
        "sent_at": r["sent_at"],
        "read_at": r["read_at"],
        "attachments": attachments or [],
    }


def _attachment_meta_row(r: sqlite3.Row) -> dict:
    return {
        "id": int(r["id"]),
        "filename": r["filename"],
        "content_type": r["content_type"],
        "size_bytes": int(r["size_bytes"]),
    }


def message_attachments_meta_for_messages(message_ids: list[int]) -> dict[int, list[dict]]:
    if not message_ids:
        return {}
    ids = [int(x) for x in message_ids]
    placeholders = ",".join("?" * len(ids))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_message_attachments_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            f"""
            SELECT id, message_id, filename, content_type, size_bytes
            FROM message_attachments
            WHERE message_id IN ({placeholders})
            ORDER BY id ASC
            """,
            ids,
        ).fetchall()
    out: dict[int, list[dict]] = {}
    for r in rows:
        mid = int(r["message_id"])
        out.setdefault(mid, []).append(_attachment_meta_row(r))
    return out


def conversation_assert_participant(
    conversation_id: int,
    *,
    doctor_user_id: Optional[int] = None,
    hr_trust: Optional[str] = None,
) -> bool:
    """True if the doctor or HR trust may access this conversation."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT doctor_user_id, hr_trust FROM conversations WHERE id = ?",
            (int(conversation_id),),
        ).fetchone()
    if not row:
        return False
    if doctor_user_id is not None and int(row["doctor_user_id"]) == int(doctor_user_id):
        return True
    if hr_trust is not None:
        stored = conversation_trust_canonical((row["hr_trust"] or "").strip())
        incoming = conversation_trust_canonical((hr_trust or "").strip())
        if stored and incoming and stored == incoming:
            return True
    return False


def message_attachment_get_for_viewer(attachment_id: int, viewer_user_id: int) -> Optional[tuple[dict, bytes]]:
    """Return attachment metadata and bytes if viewer is in the conversation."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_message_attachments_table(conn)
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT a.id, a.message_id, a.filename, a.content_type, a.size_bytes, a.data,
                   c.doctor_user_id, c.hr_trust, m.conversation_id
            FROM message_attachments a
            JOIN messages m ON m.id = a.message_id
            JOIN conversations c ON c.id = m.conversation_id
            WHERE a.id = ?
            """,
            (int(attachment_id),),
        ).fetchone()
    if not row:
        return None
    u = user_get_by_id(int(viewer_user_id))
    if not u:
        return None
    conv_id = int(row["conversation_id"])
    if user_is_premium(u):
        trust = (u.get("current_trust") or "").strip()
        if not conversation_assert_participant(conv_id, hr_trust=trust):
            return None
    else:
        if not conversation_assert_participant(conv_id, doctor_user_id=int(viewer_user_id)):
            return None
    meta = _attachment_meta_row(row)
    return meta, bytes(row["data"])


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


def _migrate_merge_duplicate_conversation_trusts(conn: sqlite3.Connection) -> None:
    """Merge threads that share the same doctor and trust name differing only by case/spelling."""
    _ensure_messaging_tables(conn)
    conn.row_factory = sqlite3.Row
    groups = conn.execute(
        """
        SELECT doctor_user_id, LOWER(TRIM(hr_trust)) AS trust_key
        FROM conversations
        GROUP BY doctor_user_id, trust_key
        HAVING COUNT(*) > 1
        """
    ).fetchall()
    for g in groups:
        did = int(g["doctor_user_id"])
        key = g["trust_key"]
        convs = conn.execute(
            """
            SELECT c.id,
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS msg_count,
                   c.last_message_at
            FROM conversations c
            WHERE c.doctor_user_id = ? AND LOWER(TRIM(c.hr_trust)) = ?
            ORDER BY msg_count DESC, c.last_message_at DESC, c.id ASC
            """,
            (did, key),
        ).fetchall()
        if len(convs) < 2:
            continue
        keeper_id = int(convs[0]["id"])
        for c in convs[1:]:
            dup_id = int(c["id"])
            conn.execute(
                "UPDATE messages SET conversation_id = ? WHERE conversation_id = ?",
                (keeper_id, dup_id),
            )
            conn.execute("DELETE FROM conversations WHERE id = ?", (dup_id,))
        conn.execute(
            """
            UPDATE conversations
            SET last_message_at = COALESCE(
                (SELECT MAX(sent_at) FROM messages WHERE conversation_id = ?),
                last_message_at
            )
            WHERE id = ?
            """,
            (keeper_id, keeper_id),
        )


def _migrate_normalize_conversation_trust_labels(conn: sqlite3.Connection) -> None:
    """Align stored hr_trust with conversation_trust_canonical; merge on UNIQUE conflicts."""
    _ensure_messaging_tables(conn)
    conn.row_factory = sqlite3.Row
    for _ in range(32):
        changed = False
        rows = conn.execute(
            "SELECT id, doctor_user_id, hr_trust FROM conversations ORDER BY id"
        ).fetchall()
        for r in rows:
            cid = int(r["id"])
            did = int(r["doctor_user_id"])
            stored = (r["hr_trust"] or "").strip()
            canonical = conversation_trust_canonical(stored)
            if not canonical or canonical == stored:
                continue
            other = conn.execute(
                "SELECT id FROM conversations WHERE doctor_user_id = ? AND hr_trust = ?",
                (did, canonical),
            ).fetchone()
            if other and int(other["id"]) != cid:
                keeper_id = int(other["id"])
                conn.execute(
                    "UPDATE messages SET conversation_id = ? WHERE conversation_id = ?",
                    (keeper_id, cid),
                )
                conn.execute("DELETE FROM conversations WHERE id = ?", (cid,))
            else:
                conn.execute(
                    "UPDATE conversations SET hr_trust = ? WHERE id = ?",
                    (canonical, cid),
                )
            changed = True
        if not changed:
            break


def conversation_get_or_create(doctor_user_id: int, hr_trust: str) -> dict:
    hr_trust = conversation_trust_canonical((hr_trust or "").strip())
    if not hr_trust:
        raise ValueError("hr_trust is required")
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        conn.execute(
            "INSERT OR IGNORE INTO conversations (doctor_user_id, hr_trust, created_at, last_message_at) VALUES (?, ?, datetime('now'), datetime('now'))",
            (int(doctor_user_id), hr_trust),
        )
        conn.commit()
        row = conn.execute(
            f"""
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   0 as unread_count,
                   {_CONV_LAST_BODY_SQL}
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
            f"""
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id
                    AND m.sender_user_id != ? AND m.read_at IS NULL) as unread_count,
                   {_CONV_LAST_BODY_SQL}
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
            f"""
            SELECT c.id, c.doctor_user_id, c.hr_trust, c.created_at, c.last_message_at,
                   u.display_name as doctor_name, u.email as doctor_email, u.gmc_number as doctor_gmc,
                   (SELECT COUNT(*) FROM messages m
                    JOIN users su ON su.id = m.sender_user_id
                    WHERE m.conversation_id = c.id AND su.premium = 0 AND m.read_at IS NULL) as unread_count,
                   {_CONV_LAST_BODY_SQL}
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
    msg_ids = [int(r["id"]) for r in rows]
    meta_by_id = message_attachments_meta_for_messages(msg_ids)
    return [_msg_row(r, meta_by_id.get(int(r["id"]), [])) for r in rows]


def message_send(conversation_id: int, sender_user_id: int) -> dict:
    """Insert a message — called after the body is validated in the API layer."""
    # Note: body is passed via a separate parameter to avoid circular import confusion
    raise NotImplementedError("Use message_send_body instead")


def message_send_body(
    conversation_id: int,
    sender_user_id: int,
    body: str,
    attachments: Optional[list[tuple[str, str, bytes]]] = None,
) -> dict:
    body = (body or "").strip()
    att_list = list(attachments or [])
    if not body and not att_list:
        raise ValueError("Message must include text or at least one attachment")
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_messaging_tables(conn)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            "INSERT INTO messages (conversation_id, sender_user_id, body, sent_at) VALUES (?, ?, ?, ?)",
            (int(conversation_id), int(sender_user_id), body, now),
        )
        msg_id = int(cursor.lastrowid)
        for filename, content_type, data in att_list:
            conn.execute(
                """
                INSERT INTO message_attachments (message_id, filename, content_type, size_bytes, data)
                VALUES (?, ?, ?, ?, ?)
                """,
                (msg_id, filename, content_type, len(data), data),
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
            (msg_id,),
        ).fetchone()
    meta = message_attachments_meta_for_messages([msg_id]).get(msg_id, [])
    return _msg_row(row, meta)


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


def csv_import_evidence_get(user_id: int, evidence_id: int) -> Optional[dict]:
    """Return one stored CSV import evidence file for the signed-in user."""
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        _ensure_csv_import_evidence_table(conn)
        row = conn.execute(
            """
            SELECT id, filename, content_type, size_bytes, data
            FROM csv_import_evidence
            WHERE id = ? AND user_id = ?
            """,
            (int(evidence_id), int(user_id)),
        ).fetchone()
    if not row:
        return None
    return {
        "id": int(row["id"]),
        "filename": row["filename"],
        "content_type": row["content_type"],
        "size_bytes": int(row["size_bytes"]),
        "data": bytes(row["data"]),
    }


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
    if "is_resubmission" not in cols:
        conn.execute("ALTER TABLE share_items ADD COLUMN is_resubmission INTEGER NOT NULL DEFAULT 0")
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
                resub = 1 if share_credential_was_declined(
                    doctor_user_id, cid, target_trust, conn=conn
                ) else 0
                conn.execute(
                    """
                    INSERT OR IGNORE INTO share_items (
                        session_id, credential_id, module_name, expiry_date, status,
                        certificate_base64, certificate_filename,
                        issuing_trust_name, is_resubmission
                    ) VALUES (?, ?, ?, ?, 'PENDING', ?, ?, ?, ?)
                    """,
                    (
                        session_id,
                        cid,
                        it.get("module_name"),
                        it.get("expiry_date"),
                        it.get("certificate_base64"),
                        it.get("certificate_filename"),
                        (it.get("issuing_trust_name") or "").strip() or None,
                        resub,
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
                  SUM(CASE WHEN UPPER(TRIM(i.status)) = 'PENDING' THEN 1 ELSE 0 END) as pending_count,
                  GROUP_CONCAT(DISTINCT NULLIF(TRIM(i.module_name), '')) as module_names_raw,
                  GROUP_CONCAT(DISTINCT CASE WHEN UPPER(TRIM(i.status)) = 'PENDING'
                    THEN NULLIF(TRIM(i.module_name), '') END) as pending_module_names_raw
                FROM share_sessions s
                JOIN users u ON u.id = s.doctor_user_id
                LEFT JOIN share_items i ON i.session_id = s.id
                WHERE LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
                GROUP BY s.id
                ORDER BY
                  CASE
                    WHEN LOWER(TRIM(COALESCE(s.share_kind, 'review'))) != 'portfolio'
                     AND SUM(CASE WHEN UPPER(TRIM(i.status)) = 'PENDING' THEN 1 ELSE 0 END) > 0
                    THEN 0 ELSE 1
                  END,
                  s.id DESC
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
                  SUM(CASE WHEN i.status = 'PENDING' THEN 1 ELSE 0 END) as pending_count,
                  GROUP_CONCAT(DISTINCT NULLIF(TRIM(i.module_name), '')) as module_names_raw,
                  GROUP_CONCAT(DISTINCT CASE WHEN i.status = 'PENDING'
                    THEN NULLIF(TRIM(i.module_name), '') END) as pending_module_names_raw
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
                "module_names": _split_group_concat(r["module_names_raw"]),
                "pending_module_names": _split_group_concat(r["pending_module_names_raw"]),
            }
        )
    return out


def _split_group_concat(raw: Optional[str]) -> list[str]:
    if not raw:
        return []
    seen: set[str] = set()
    out: list[str] = []
    for part in str(raw).split(","):
        name = part.strip()
        if not name or name in seen:
            continue
        seen.add(name)
        out.append(name)
    return sorted(out, key=lambda x: x.lower())


def cohort_members_pending_verification(cohort_id: int, hr_trust: str) -> list[dict]:
    """Cohort members with at least one PENDING HR share item at this trust (excludes portfolio)."""
    trust = (hr_trust or "").strip().lower()
    member_ids = cohort_member_user_ids(int(cohort_id), hr_trust)
    if not member_ids or not trust:
        return []
    placeholders = ",".join("?" * len(member_ids))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            f"""
            SELECT DISTINCT
              s.doctor_user_id AS user_id,
              u.display_name AS display_name,
              u.email AS email,
              COUNT(i.credential_id) AS pending_items
            FROM share_sessions s
            JOIN share_items i ON i.session_id = s.id AND i.status = 'PENDING'
            JOIN users u ON u.id = s.doctor_user_id
            WHERE s.doctor_user_id IN ({placeholders})
              AND LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
              AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) != 'portfolio'
            GROUP BY s.doctor_user_id
            ORDER BY u.display_name COLLATE NOCASE, u.email
            """,
            (*member_ids, trust),
        ).fetchall()
    return [
        {
            "user_id": int(r["user_id"]),
            "display_name": r["display_name"],
            "email": r["email"],
            "pending_items": int(r["pending_items"] or 0),
        }
        for r in rows
    ]


def share_doctor_queue(doctor_user_id: int, hr_trust: Optional[str] = None) -> Optional[dict]:
    """All share items across every session for one doctor (for merged HR review)."""
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
              i.issuing_trust_name, i.verified_by_trust_name,
              IFNULL(i.is_resubmission, 0) as is_resubmission
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
            "is_resubmission": bool(r["is_resubmission"]),
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
                   issuing_trust_name, verified_by_trust_name,
                   IFNULL(is_resubmission, 0) as is_resubmission
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
                "is_resubmission": bool(r["is_resubmission"]),
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
        decision_at = datetime.utcnow().isoformat() if st in ("VERIFIED", "DECLINED") else None
        decision_by = int(hr_user_id) if st in ("VERIFIED", "DECLINED") else None
        decline = (decline_reason or "").strip() if st == "DECLINED" else None
        verified_trust: Optional[str] = None
        if st == "VERIFIED":
            ut = conn.execute(
                "SELECT current_trust FROM users WHERE id = ?", (int(hr_user_id),)
            ).fetchone()
            verified_trust = (str(ut[0]).strip() if ut and ut[0] else None) or None
        conn.execute(
            """
            UPDATE share_items
            SET status = ?, decision_at = ?, decision_by_user_id = ?, decline_reason = ?,
                verified_by_trust_name = ?
            WHERE session_id = ? AND credential_id = ?
            """,
            (
                st,
                decision_at,
                decision_by,
                decline,
                verified_trust,
                int(session_id),
                str(credential_id),
            ),
        )
        conn.commit()


def share_reset_declined_for_doctor(
    doctor_user_id: int,
    credential_id: str,
    *,
    certificate_base64: Optional[str],
    certificate_filename: Optional[str],
    hr_trust: Optional[str] = None,
) -> int:
    """Flip DECLINED share items for one of the doctor's credentials back to PENDING.

    Used by the doctor's Fix-and-reshare flow: rather than minting a new credential,
    the existing share row keeps its identity and cycles PENDING -> DECLINED -> PENDING
    so HR sees a single row that has been re-submitted with updated evidence.

    Returns the number of share rows that were reset.
    """
    cid = (credential_id or "").strip()
    if not cid:
        return 0
    trust_key = (hr_trust or "").strip().lower()
    params: list = [cid, int(doctor_user_id)]
    extra_where = ""
    if trust_key:
        extra_where = " AND LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?"
        params.append(trust_key)
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        cur = conn.execute(
            f"""
            UPDATE share_items
            SET status = 'PENDING',
                decision_at = NULL,
                decision_by_user_id = NULL,
                decline_reason = NULL,
                certificate_base64 = ?,
                certificate_filename = ?,
                is_resubmission = 0
            WHERE credential_id = ?
              AND UPPER(TRIM(status)) = 'DECLINED'
              AND session_id IN (
                SELECT s.id FROM share_sessions s
                WHERE s.doctor_user_id = ?
                  AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) = 'review'
                  {extra_where}
              )
            """,
            (certificate_base64, certificate_filename, *params),
        )
        conn.commit()
    return int(cur.rowcount or 0)


def share_withdraw_pending_for_doctor(doctor_user_id: int, credential_ids: list[str]) -> int:
    """
    Drop PENDING review share items when a doctor removes credentials from their wallet.
    Empty share sessions are deleted afterwards.
    """
    ids = list({str(x).strip() for x in credential_ids if str(x).strip()})
    if not ids:
        return 0
    removed = 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        placeholders = ",".join("?" * len(ids))
        cur = conn.execute(
            f"""
            DELETE FROM share_items
            WHERE credential_id IN ({placeholders})
              AND UPPER(TRIM(status)) = 'PENDING'
              AND session_id IN (
                SELECT s.id FROM share_sessions s
                WHERE s.doctor_user_id = ?
                  AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) = 'review'
              )
            """,
            (*ids, int(doctor_user_id)),
        )
        removed = int(cur.rowcount or 0)
        conn.execute(
            """
            DELETE FROM share_sessions
            WHERE doctor_user_id = ?
              AND id NOT IN (SELECT session_id FROM share_items)
            """,
            (int(doctor_user_id),),
        )
        conn.commit()
    return removed


def _wallet_credential_ids(doctor_user_id: int) -> set[str]:
    try:
        wallet = json.loads(user_wallet_get(int(doctor_user_id)) or "[]")
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        return set()
    return {
        str(entry.get("credential_id") or "").strip()
        for entry in wallet
        if isinstance(entry, dict) and str(entry.get("credential_id") or "").strip()
    }


def share_reconcile_stale_pending(hr_trust: Optional[str] = None) -> dict[str, int]:
    """
    Drop PENDING review share items that HR can no longer action:
    orphaned sessions (doctor account removed) or credentials no longer in the wallet.
    """
    trust_key = (hr_trust or "").strip().lower()
    trust_clause = ""
    params: list = []
    if trust_key:
        trust_clause = "AND LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?"
        params.append(trust_key)

    removed_orphan_user = 0
    removed_not_in_wallet = 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            f"""
            DELETE FROM share_items
            WHERE (session_id, credential_id) IN (
              SELECT i.session_id, i.credential_id
              FROM share_items i
              JOIN share_sessions s ON s.id = i.session_id
              LEFT JOIN users u ON u.id = s.doctor_user_id
              WHERE UPPER(TRIM(i.status)) = 'PENDING'
                AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) = 'review'
                {trust_clause}
                AND u.id IS NULL
            )
            """,
            params,
        )
        removed_orphan_user = int(cur.rowcount or 0)

        rows = conn.execute(
            f"""
            SELECT i.session_id, i.credential_id, s.doctor_user_id
            FROM share_items i
            JOIN share_sessions s ON s.id = i.session_id
            JOIN users u ON u.id = s.doctor_user_id
            WHERE UPPER(TRIM(i.status)) = 'PENDING'
              AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) = 'review'
              {trust_clause}
            """,
            params,
        ).fetchall()
        wallet_cache: dict[int, set[str]] = {}
        stale: list[tuple[int, str]] = []
        for row in rows:
            uid = int(row["doctor_user_id"])
            cid = str(row["credential_id"] or "").strip()
            if not cid:
                continue
            if uid not in wallet_cache:
                wallet_cache[uid] = _wallet_credential_ids(uid)
            if cid not in wallet_cache[uid]:
                stale.append((int(row["session_id"]), cid))
        for session_id, cid in stale:
            cur = conn.execute(
                """
                DELETE FROM share_items
                WHERE session_id = ? AND credential_id = ?
                  AND UPPER(TRIM(status)) = 'PENDING'
                """,
                (session_id, cid),
            )
            removed_not_in_wallet += int(cur.rowcount or 0)

        conn.execute(
            """
            DELETE FROM share_sessions
            WHERE id NOT IN (SELECT session_id FROM share_items)
            """
        )
        conn.commit()
    return {
        "removed_orphan_user": removed_orphan_user,
        "removed_not_in_wallet": removed_not_in_wallet,
    }


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


def doctor_getting_started_progress(doctor_user_id: int) -> dict:
    """
    Doctor onboarding checklist steps that must be done by the doctor, not HR on their behalf.
    - doctor_added_training: at least one wallet credential not HR-attested
    - doctor_shared_with_hr: at least one share session created by the doctor
    """
    attested_ids: set[str] = set()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_attestations_table(conn)
        _ensure_share_tables(conn)
        conn.row_factory = sqlite3.Row
        for row in conn.execute(
            "SELECT credential_id FROM hr_attested_credentials WHERE doctor_user_id = ?",
            (int(doctor_user_id),),
        ).fetchall():
            attested_ids.add(str(row["credential_id"]))
        share_row = conn.execute(
            "SELECT 1 FROM share_sessions WHERE doctor_user_id = ? LIMIT 1",
            (int(doctor_user_id),),
        ).fetchone()
    try:
        wallet = json.loads(user_wallet_get(int(doctor_user_id)))
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    doctor_added = False
    for entry in wallet:
        if not isinstance(entry, dict):
            continue
        cid = (entry.get("credential_id") or "").strip()
        if cid and cid not in attested_ids:
            doctor_added = True
            break
    return {
        "doctor_added_training": doctor_added,
        "doctor_shared_with_hr": share_row is not None,
    }


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
    if "personal_email" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN personal_email TEXT")
    _ensure_users_hr_welcome_template_column(conn)
    _ensure_users_hr_auto_send_welcome_column(conn)
    _ensure_users_hr_email_columns(conn)


def _ensure_users_hr_welcome_template_column(conn: sqlite3.Connection) -> None:
    """HR accounts: default welcome message template for new cohort members."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "hr_welcome_message_template" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN hr_welcome_message_template TEXT")


def _ensure_users_hr_auto_send_welcome_column(conn: sqlite3.Connection) -> None:
    """HR accounts: send welcome automatically when adding doctors (review modal is opt-in)."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "hr_auto_send_welcome" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN hr_auto_send_welcome INTEGER NOT NULL DEFAULT 1"
        )


def _migrate_hr_welcome_auto_default(conn: sqlite3.Connection) -> None:
    """One-time: default existing HR accounts to automatic welcome (review is opt-in in Profile)."""
    _ensure_users_hr_auto_send_welcome_column(conn)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    key = "hr_welcome_auto_default_v1"
    if conn.execute("SELECT 1 FROM app_settings WHERE key = ?", (key,)).fetchone():
        return
    conn.execute("UPDATE users SET hr_auto_send_welcome = 1 WHERE premium = 1")
    conn.execute("INSERT INTO app_settings (key, value) VALUES (?, ?)", (key, "1"))


def _ensure_users_hr_email_columns(conn: sqlite3.Connection) -> None:
    """HR accounts: email digest and instant notification preferences."""
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "hr_email_digest_enabled" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN hr_email_digest_enabled INTEGER NOT NULL DEFAULT 1"
        )
    if "hr_email_instant_enabled" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN hr_email_instant_enabled INTEGER NOT NULL DEFAULT 1"
        )
    if "hr_notification_email" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN hr_notification_email TEXT")
    if "hr_expiry_reminders_enabled" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN hr_expiry_reminders_enabled INTEGER NOT NULL DEFAULT 1"
        )


def _ensure_users_nhs_work_email_column(conn: sqlite3.Connection) -> None:
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "nhs_work_email" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN nhs_work_email TEXT")


def _looks_nhs_work_email(email: str) -> bool:
    e = (email or "").strip().lower()
    return e.endswith("@nhs.net") or e.endswith("@nhs.uk") or e.endswith("@nhs.scot")


def _migrate_provisioned_personal_email_login(conn: sqlite3.Connection) -> None:
    """
    Doctors provisioned with NHS work email as login and personal_email on file:
    move work address to nhs_work_email and use personal_email for users.email.
    """
    _ensure_users_nhs_work_email_column(conn)
    _ensure_users_provision_columns(conn)
    rows = conn.execute(
        """
        SELECT id, email, personal_email FROM users
        WHERE provisioned_by_hr = 1
          AND personal_email IS NOT NULL
          AND TRIM(personal_email) != ''
          AND LOWER(TRIM(personal_email)) != LOWER(TRIM(email))
        """
    ).fetchall()
    for row in rows:
        uid = int(row[0])
        login = (row[1] or "").strip().lower()
        personal = (row[2] or "").strip().lower()
        if not personal or personal == login:
            continue
        if _looks_nhs_work_email(login):
            conn.execute(
                """UPDATE users SET nhs_work_email = ?
                   WHERE id = ? AND (nhs_work_email IS NULL OR TRIM(nhs_work_email) = '')""",
                (login, uid),
            )
        try:
            conn.execute("UPDATE users SET email = ? WHERE id = ?", (personal, uid))
        except sqlite3.IntegrityError:
            pass


def _ensure_users_provision_columns(conn: sqlite3.Connection) -> None:
    cols = [row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()]
    if "must_change_password" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN must_change_password INTEGER NOT NULL DEFAULT 0"
        )
    if "provisioned_by_hr" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN provisioned_by_hr INTEGER")
    if "onboarding_completed" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN onboarding_completed INTEGER NOT NULL DEFAULT 0"
        )


def _backfill_onboarding_completed(conn: sqlite3.Connection) -> None:
    """Existing doctors with a full profile skip the one-time onboarding screen."""
    _ensure_users_provision_columns(conn)
    conn.execute(
        """
        UPDATE users SET onboarding_completed = 1
        WHERE COALESCE(premium, 0) = 0
          AND COALESCE(must_change_password, 0) = 0
          AND TRIM(COALESCE(display_name, '')) != ''
          AND TRIM(COALESCE(gmc_number, '')) != ''
          AND TRIM(COALESCE(current_trust, '')) != ''
        """
    )


def _ensure_notifications_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS user_notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            link_path TEXT,
            meta_json TEXT,
            read_at TEXT,
            created_at TEXT NOT NULL
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_notifications_user ON user_notifications(user_id, created_at DESC)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_notifications_unread ON user_notifications(user_id, read_at)"
    )


def _ensure_hr_audit_log_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS hr_audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hr_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            action TEXT NOT NULL,
            trust_name TEXT,
            doctor_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
            credential_id TEXT,
            session_id INTEGER,
            detail TEXT,
            meta_json TEXT,
            created_at TEXT NOT NULL
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_hr_audit_trust ON hr_audit_log(trust_name, created_at DESC)"
    )


def notification_create(
    user_id: int,
    *,
    kind: str,
    title: str,
    body: str,
    link_path: Optional[str] = None,
    meta: Optional[dict] = None,
) -> int:
    now = datetime.utcnow().isoformat()
    meta_json = json.dumps(meta) if meta else None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_notifications_table(conn)
        cur = conn.execute(
            """
            INSERT INTO user_notifications (user_id, kind, title, body, link_path, meta_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                int(user_id),
                str(kind).strip(),
                str(title).strip(),
                str(body).strip(),
                (link_path or "").strip() or None,
                meta_json,
                now,
            ),
        )
        conn.commit()
        return int(cur.lastrowid)


def notifications_list(
    user_id: int,
    *,
    limit: int = 50,
    unread_only: bool = False,
) -> list[dict]:
    lim = max(1, min(int(limit), 200))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_notifications_table(conn)
        conn.row_factory = sqlite3.Row
        q = """
            SELECT id, kind, title, body, link_path, meta_json, read_at, created_at
            FROM user_notifications
            WHERE user_id = ?
        """
        params: list = [int(user_id)]
        if unread_only:
            q += " AND read_at IS NULL"
        q += " ORDER BY datetime(created_at) DESC LIMIT ?"
        params.append(lim)
        rows = conn.execute(q, params).fetchall()
    out = []
    for r in rows:
        meta = None
        if r["meta_json"]:
            try:
                meta = json.loads(r["meta_json"])
            except Exception:
                meta = None
        out.append(
            {
                "id": int(r["id"]),
                "kind": r["kind"],
                "title": r["title"],
                "body": r["body"],
                "link_path": r["link_path"],
                "meta": meta,
                "read_at": r["read_at"],
                "created_at": r["created_at"],
                "unread": r["read_at"] is None,
            }
        )
    return out


def notifications_unread_count(user_id: int) -> int:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_notifications_table(conn)
        row = conn.execute(
            "SELECT COUNT(*) FROM user_notifications WHERE user_id = ? AND read_at IS NULL",
            (int(user_id),),
        ).fetchone()
    return int(row[0] or 0)


def notification_mark_read(notification_id: int, user_id: int) -> bool:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_notifications_table(conn)
        cur = conn.execute(
            """
            UPDATE user_notifications SET read_at = ?
            WHERE id = ? AND user_id = ? AND read_at IS NULL
            """,
            (now, int(notification_id), int(user_id)),
        )
        conn.commit()
        return cur.rowcount > 0


def notifications_mark_all_read(user_id: int) -> int:
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_notifications_table(conn)
        cur = conn.execute(
            """
            UPDATE user_notifications SET read_at = ?
            WHERE user_id = ? AND read_at IS NULL
            """,
            (now, int(user_id)),
        )
        conn.commit()
        return cur.rowcount


def hr_audit_log_append(
    hr_user_id: int,
    action: str,
    *,
    trust_name: Optional[str] = None,
    doctor_user_id: Optional[int] = None,
    credential_id: Optional[str] = None,
    session_id: Optional[int] = None,
    detail: Optional[str] = None,
    meta: Optional[dict] = None,
) -> int:
    now = datetime.utcnow().isoformat()
    meta_json = json.dumps(meta) if meta else None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_audit_log_table(conn)
        cur = conn.execute(
            """
            INSERT INTO hr_audit_log (
                hr_user_id, action, trust_name, doctor_user_id, credential_id,
                session_id, detail, meta_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                int(hr_user_id),
                str(action).strip(),
                (trust_name or "").strip() or None,
                int(doctor_user_id) if doctor_user_id is not None else None,
                str(credential_id).strip() if credential_id else None,
                int(session_id) if session_id is not None else None,
                (detail or "").strip() or None,
                meta_json,
                now,
            ),
        )
        conn.commit()
        return int(cur.lastrowid)


def hr_audit_log_list(
    hr_trust: str,
    *,
    limit: int = 100,
    offset: int = 0,
    action: Optional[str] = None,
) -> list[dict]:
    t = (hr_trust or "").strip().lower()
    lim = max(1, min(int(limit), 500))
    off = max(0, int(offset))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_audit_log_table(conn)
        conn.row_factory = sqlite3.Row
        q = """
            SELECT a.id, a.hr_user_id, a.action, a.trust_name, a.doctor_user_id,
                   a.credential_id, a.session_id, a.detail, a.meta_json, a.created_at,
                   u.email as hr_email, u.display_name as hr_display_name
            FROM hr_audit_log a
            JOIN users u ON u.id = a.hr_user_id
            WHERE LOWER(TRIM(COALESCE(a.trust_name, ''))) = ?
        """
        params: list = [t]
        if action:
            q += " AND a.action = ?"
            params.append(str(action).strip())
        q += " ORDER BY datetime(a.created_at) DESC LIMIT ? OFFSET ?"
        params.extend([lim, off])
        rows = conn.execute(q, params).fetchall()
    out = []
    for r in rows:
        meta = None
        if r["meta_json"]:
            try:
                meta = json.loads(r["meta_json"])
            except Exception:
                meta = None
        out.append(
            {
                "id": int(r["id"]),
                "hr_user_id": int(r["hr_user_id"]),
                "hr_email": r["hr_email"],
                "hr_display_name": r["hr_display_name"],
                "action": r["action"],
                "trust_name": r["trust_name"],
                "doctor_user_id": r["doctor_user_id"],
                "credential_id": r["credential_id"],
                "session_id": r["session_id"],
                "detail": r["detail"],
                "meta": meta,
                "created_at": r["created_at"],
            }
        )
    return out


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
    _ensure_hr_cohorts_welcome_template_column(conn)


def _ensure_hr_cohorts_welcome_template_column(conn: sqlite3.Connection) -> None:
    cols = [row[1] for row in conn.execute("PRAGMA table_info(hr_cohorts)").fetchall()]
    if "welcome_message_template" not in cols:
        conn.execute("ALTER TABLE hr_cohorts ADD COLUMN welcome_message_template TEXT")


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
    keys = row.keys()
    out = {
        "id": row["id"],
        "email": row["email"],
        "premium": bool(row["premium"]) if row["premium"] is not None else False,
        "gmc_number": row["gmc_number"],
        "display_name": row["display_name"],
        "current_trust": row["current_trust"],
        "personal_email": row["personal_email"] if "personal_email" in keys else None,
        "must_change_password": bool(row["must_change_password"])
        if "must_change_password" in row.keys() and row["must_change_password"] is not None
        else False,
        "onboarding_completed": bool(row["onboarding_completed"])
        if "onboarding_completed" in keys and row["onboarding_completed"] is not None
        else False,
        "hr_welcome_message_template": row["hr_welcome_message_template"]
        if "hr_welcome_message_template" in keys
        else None,
        "hr_auto_send_welcome": bool(row["hr_auto_send_welcome"])
        if "hr_auto_send_welcome" in keys and row["hr_auto_send_welcome"] is not None
        else True,
        "hr_email_digest_enabled": bool(row["hr_email_digest_enabled"])
        if "hr_email_digest_enabled" in keys and row["hr_email_digest_enabled"] is not None
        else True,
        "hr_email_instant_enabled": bool(row["hr_email_instant_enabled"])
        if "hr_email_instant_enabled" in keys and row["hr_email_instant_enabled"] is not None
        else True,
        "hr_notification_email": row["hr_notification_email"]
        if "hr_notification_email" in keys
        else None,
        "hr_expiry_reminders_enabled": bool(row["hr_expiry_reminders_enabled"])
        if "hr_expiry_reminders_enabled" in keys and row["hr_expiry_reminders_enabled"] is not None
        else True,
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
                      personal_email, must_change_password, onboarding_completed
               FROM users WHERE email = ?""",
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
        _ensure_users_hr_welcome_template_column(conn)
        _ensure_users_hr_auto_send_welcome_column(conn)
        _ensure_users_hr_email_columns(conn)
        row = conn.execute(
            """SELECT id, email, premium, gmc_number, display_name, current_trust,
                      personal_email, must_change_password, onboarding_completed,
                      hr_welcome_message_template, hr_auto_send_welcome,
                      hr_email_digest_enabled, hr_email_instant_enabled,
                      hr_notification_email, hr_expiry_reminders_enabled
               FROM users WHERE id = ?""",
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
    """Set current_trust only when the doctor has not chosen one yet."""
    from . import trust_packs

    trust = trust_packs.normalize_stored_trust_name(trust)
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


def _normalize_provision_gmc(raw: Optional[str]) -> Optional[str]:
    gmc = re.sub(r"\D", "", raw or "")
    return gmc if len(gmc) == 7 else None


def user_apply_hr_roster_row(
    user_id: int,
    *,
    display_name: Optional[str] = None,
    gmc_number: Optional[str] = None,
    default_trust: Optional[str] = None,
) -> None:
    """Apply name/GMC from an HR cohort roster row (non-premium doctors only)."""
    u = user_get_by_id(int(user_id))
    if not u or user_is_premium(u):
        return
    dn = (display_name or "").strip() or None
    gmc = _normalize_provision_gmc(str(gmc_number or "")) if gmc_number is not None else None
    trust = (default_trust or "").strip() or None
    if trust:
        from . import trust_packs

        trust = trust_packs.normalize_stored_trust_name(trust)
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        if dn:
            conn.execute(
                "UPDATE users SET display_name = ? WHERE id = ?",
                (dn, int(user_id)),
            )
        if gmc_number is not None and str(gmc_number).strip():
            conn.execute(
                "UPDATE users SET gmc_number = ? WHERE id = ?",
                (gmc, int(user_id)),
            )
        if trust and not (u.get("current_trust") or "").strip():
            conn.execute(
                "UPDATE users SET current_trust = ? WHERE id = ?",
                (trust, int(user_id)),
            )
        conn.commit()


def user_apply_provisioned_profile(
    user_id: int,
    *,
    display_name: Optional[str] = None,
    gmc_number: Optional[str] = None,
    default_trust: Optional[str] = None,
) -> None:
    """Fill empty profile fields from HR roster import (never overwrite doctor edits)."""
    u = user_get_by_id(int(user_id))
    if not u:
        return
    dn = (display_name or "").strip() or None
    gmc = _normalize_provision_gmc(gmc_number)
    trust = (default_trust or "").strip() or None
    if trust:
        from . import trust_packs

        trust = trust_packs.normalize_stored_trust_name(trust)
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        if dn and not (u.get("display_name") or "").strip():
            conn.execute(
                "UPDATE users SET display_name = ? WHERE id = ?",
                (dn, int(user_id)),
            )
        if gmc and not (u.get("gmc_number") or "").strip():
            conn.execute(
                "UPDATE users SET gmc_number = ? WHERE id = ?",
                (gmc, int(user_id)),
            )
        if trust and not (u.get("current_trust") or "").strip():
            conn.execute(
                "UPDATE users SET current_trust = ? WHERE id = ?",
                (trust, int(user_id)),
            )
        conn.commit()


def user_set_personal_email(user_id: int, personal_email: Optional[str]) -> None:
    """Legacy column; login address is users.email."""
    pe = (personal_email or "").strip().lower() or None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_profile_extra_columns(conn)
        conn.execute(
            "UPDATE users SET personal_email = ? WHERE id = ?",
            (pe, int(user_id)),
        )
        conn.commit()


def user_mark_onboarding_complete(user_id: int) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_provision_columns(conn)
        conn.execute(
            "UPDATE users SET onboarding_completed = 1 WHERE id = ?",
            (int(user_id),),
        )
        conn.commit()


def user_create_provisioned(
    personal_email: str,
    provisioned_by_hr_user_id: int,
    default_trust: Optional[str] = None,
    display_name: Optional[str] = None,
    gmc_number: Optional[str] = None,
) -> int:
    """Create non-premium doctor; users.email is personal (login) address."""
    personal_email = (personal_email or "").strip().lower()
    trust = (default_trust or "").strip() or None
    dn = (display_name or "").strip() or None
    gmc = _normalize_provision_gmc(gmc_number)
    h = _provisioned_password_hash()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_provision_columns(conn)
        cur = conn.execute(
            """INSERT INTO users (
                   email, password_hash, created_at, premium, gmc_number, display_name, current_trust,
                   must_change_password, provisioned_by_hr, onboarding_completed
               ) VALUES (?, ?, ?, 0, ?, ?, ?, 1, ?, 0)""",
            (
                personal_email,
                h,
                datetime.utcnow().isoformat(),
                gmc,
                dn,
                trust,
                int(provisioned_by_hr_user_id),
            ),
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
    hr_welcome_message_template: Optional[str] = None,
    *,
    update_hr_welcome_template: bool = False,
) -> None:
    """Replace optional profile fields (None clears)."""
    from . import trust_packs

    if current_trust is not None:
        current_trust = trust_packs.normalize_stored_trust_name(current_trust)
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_gmc_number_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_hr_welcome_template_column(conn)
        if update_hr_welcome_template:
            conn.execute(
                """UPDATE users SET display_name = ?, gmc_number = ?, current_trust = ?,
                          hr_welcome_message_template = ? WHERE id = ?""",
                (
                    display_name,
                    gmc_number,
                    current_trust,
                    hr_welcome_message_template,
                    user_id,
                ),
            )
        else:
            conn.execute(
                "UPDATE users SET display_name = ?, gmc_number = ?, current_trust = ? WHERE id = ?",
                (display_name, gmc_number, current_trust, user_id),
            )
        conn.commit()


def user_set_hr_welcome_template(user_id: int, template: Optional[str]) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_hr_welcome_template_column(conn)
        conn.execute(
            "UPDATE users SET hr_welcome_message_template = ? WHERE id = ?",
            (template, int(user_id)),
        )
        conn.commit()


def user_set_hr_auto_send_welcome(user_id: int, enabled: bool) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_hr_auto_send_welcome_column(conn)
        conn.execute(
            "UPDATE users SET hr_auto_send_welcome = ? WHERE id = ?",
            (1 if enabled else 0, int(user_id)),
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


# ---------- HR cohorts (provision doctors + group messaging) ----------


def is_default_cohort_name(name: str) -> bool:
    n = (name or "").strip().casefold()
    if n == DEFAULT_COHORT_NAME.casefold():
        return True
    return n in {x.casefold() for x in LEGACY_DEFAULT_COHORT_NAMES}


def _cleanup_orphan_cohort_members(conn: sqlite3.Connection) -> int:
    """Remove cohort rows left behind when users were deleted without FK cascade."""
    _ensure_hr_cohorts_tables(conn)
    cur = conn.execute(
        """
        DELETE FROM hr_cohort_members
        WHERE user_id NOT IN (SELECT id FROM users)
        """
    )
    return int(cur.rowcount or 0)


def cohort_get_by_name(hr_trust: str, name: str) -> Optional[dict]:
    hr_trust = (hr_trust or "").strip()
    name = (name or "").strip()
    if not hr_trust or not name:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   c.welcome_message_template,
                   """ + _COHORT_MEMBER_COUNT_SQL.strip() + """ AS member_count
            FROM hr_cohorts c
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
              AND LOWER(TRIM(c.name)) = LOWER(TRIM(?))
            LIMIT 1
            """,
            (hr_trust, name),
        ).fetchone()
    if not row:
        return None
    return _cohort_row_dict(row)


def cohort_get_default_for_trust(hr_trust: str) -> Optional[dict]:
    """Return the trust's default All Doctors cohort, including legacy Ad-Hoc name."""
    existing = cohort_get_by_name(hr_trust, DEFAULT_COHORT_NAME)
    if existing:
        return existing
    for legacy in LEGACY_DEFAULT_COHORT_NAMES:
        existing = cohort_get_by_name(hr_trust, legacy)
        if existing:
            return existing
    return None


def ensure_default_cohort(hr_trust: str, created_by_user_id: int) -> int:
    """Ensure each trust has a default All Doctors cohort for one-off provisioning."""
    existing = cohort_get_default_for_trust(hr_trust)
    if existing:
        return int(existing["id"])
    return cohort_create(hr_trust, DEFAULT_COHORT_NAME, int(created_by_user_id))


def _ensure_default_cohorts_for_premium_hr(conn: sqlite3.Connection) -> None:
    """Backfill default All Doctors cohort for every trust with a premium HR account."""
    _ensure_hr_cohorts_tables(conn)
    _ensure_users_premium_column(conn)
    for legacy in LEGACY_DEFAULT_COHORT_NAMES:
        conn.execute(
            """UPDATE hr_cohorts SET name = ?
               WHERE LOWER(TRIM(name)) = LOWER(TRIM(?))""",
            (DEFAULT_COHORT_NAME, legacy),
        )
    rows = conn.execute(
        """
        SELECT MIN(u.id) AS user_id, TRIM(u.current_trust) AS trust
        FROM users u
        WHERE u.premium = 1 AND TRIM(COALESCE(u.current_trust, '')) != ''
        GROUP BY LOWER(TRIM(u.current_trust))
        """
    ).fetchall()
    now = datetime.utcnow().isoformat()
    for row in rows:
        trust = (row[1] or "").strip()
        user_id = int(row[0])
        if not trust:
            continue
        exists = conn.execute(
            """
            SELECT id FROM hr_cohorts
            WHERE LOWER(TRIM(hr_trust)) = LOWER(TRIM(?))
              AND LOWER(TRIM(name)) = LOWER(TRIM(?))
            LIMIT 1
            """,
            (trust, DEFAULT_COHORT_NAME),
        ).fetchone()
        if exists:
            continue
        conn.execute(
            """INSERT INTO hr_cohorts
               (hr_trust, name, created_at, created_by_user_id, welcome_message_template)
               VALUES (?, ?, ?, ?, NULL)""",
            (trust, DEFAULT_COHORT_NAME, now, user_id),
        )


def cohort_create(
    hr_trust: str,
    name: str,
    created_by_user_id: int,
    welcome_message_template: Optional[str] = None,
) -> int:
    hr_trust = (hr_trust or "").strip()
    name = (name or "").strip()
    tmpl = (welcome_message_template or "").strip() or None
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        cur = conn.execute(
            """INSERT INTO hr_cohorts
               (hr_trust, name, created_at, created_by_user_id, welcome_message_template)
               VALUES (?, ?, ?, ?, ?)""",
            (hr_trust, name, now, int(created_by_user_id), tmpl),
        )
        conn.commit()
        return int(cur.lastrowid)


def _cohort_row_dict(row: sqlite3.Row) -> dict:
    keys = row.keys()
    return {
        "id": int(row["id"]),
        "hr_trust": row["hr_trust"],
        "name": row["name"],
        "created_at": row["created_at"],
        "created_by_user_id": int(row["created_by_user_id"]),
        "member_count": int(row["member_count"] or 0)
        if "member_count" in keys
        else 0,
        "welcome_message_template": row["welcome_message_template"]
        if "welcome_message_template" in keys
        else None,
        "is_default": is_default_cohort_name(row["name"]),
    }


def cohort_set_welcome_template(
    cohort_id: int, hr_trust: str, template: Optional[str]
) -> Optional[dict]:
    if not cohort_get(cohort_id, hr_trust):
        return None
    tmpl = (template or "").strip() or None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.execute(
            """UPDATE hr_cohorts SET welcome_message_template = ?
               WHERE id = ? AND LOWER(TRIM(hr_trust)) = LOWER(TRIM(?))""",
            (tmpl, int(cohort_id), (hr_trust or "").strip()),
        )
        conn.commit()
    return cohort_get(cohort_id, hr_trust)


def cohort_list_for_trust(hr_trust: str) -> list[dict]:
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   c.welcome_message_template,
                   """ + _COHORT_MEMBER_COUNT_SQL.strip() + """ AS member_count
            FROM hr_cohorts c
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            ORDER BY CASE
                       WHEN LOWER(TRIM(c.name)) IN (LOWER(?), 'ad-hoc') THEN 0
                       ELSE 1
                     END,
                     c.created_at DESC
            """,
            (hr_trust, DEFAULT_COHORT_NAME),
        ).fetchall()
    return [_cohort_row_dict(r) for r in rows]


def _default_cohort_id_for_trust(hr_trust: str, hr_user_id: int) -> int:
    existing = cohort_get_default_for_trust(hr_trust)
    if existing:
        return int(existing["id"])
    return int(ensure_default_cohort(hr_trust, hr_user_id))


def user_custom_cohort_memberships(user_id: int, hr_trust: str) -> list[dict]:
    """Non-default groups the user belongs to for this trust, newest membership first."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT c.id, c.name, m.added_at
            FROM hr_cohort_members m
            JOIN hr_cohorts c ON c.id = m.cohort_id
            WHERE m.user_id = ? AND LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            ORDER BY m.added_at DESC
            """,
            (int(user_id), (hr_trust or "").strip()),
        ).fetchall()
    out: list[dict] = []
    for r in rows:
        if is_default_cohort_name(r["name"]):
            continue
        out.append({"id": int(r["id"]), "name": r["name"], "added_at": r["added_at"]})
    return out


def cohort_suggest_target_for_email(
    email: str, hr_trust: str, hr_user_id: int
) -> dict:
    """Suggest which group to add a doctor to (default All Doctors, or existing custom group)."""
    default_id = _default_cohort_id_for_trust(hr_trust, hr_user_id)
    default = cohort_get(default_id, hr_trust) or {
        "id": default_id,
        "name": DEFAULT_COHORT_NAME,
    }
    personal = (email or "").strip().lower()
    if not personal:
        return {
            "cohort_id": default_id,
            "cohort_name": default["name"],
            "reason": "default",
        }
    user = user_get_by_email(personal)
    if not user:
        return {
            "cohort_id": default_id,
            "cohort_name": default["name"],
            "reason": "default",
        }
    custom = user_custom_cohort_memberships(int(user["id"]), hr_trust)
    if custom:
        pick = custom[0]
        return {
            "cohort_id": int(pick["id"]),
            "cohort_name": pick["name"],
            "reason": "existing_membership",
        }
    return {
        "cohort_id": default_id,
        "cohort_name": default["name"],
        "reason": "default",
    }


def cohort_suggest_targets_for_emails(
    emails: list[str], hr_trust: str, hr_user_id: int
) -> dict[str, dict]:
    out: dict[str, dict] = {}
    seen: set[str] = set()
    for raw in emails or []:
        personal = (raw or "").strip().lower()
        if not personal or personal in seen:
            continue
        seen.add(personal)
        out[personal] = cohort_suggest_target_for_email(personal, hr_trust, hr_user_id)
    return out


def cohort_get_by_id(cohort_id: int) -> Optional[dict]:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   c.welcome_message_template,
                   """ + _COHORT_MEMBER_COUNT_SQL.strip() + """ AS member_count
            FROM hr_cohorts c
            WHERE c.id = ?
            """,
            (int(cohort_id),),
        ).fetchone()
    if not row:
        return None
    return _cohort_row_dict(row)


def cohort_get(cohort_id: int, hr_trust: str) -> Optional[dict]:
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT c.id, c.hr_trust, c.name, c.created_at, c.created_by_user_id,
                   c.welcome_message_template,
                   """ + _COHORT_MEMBER_COUNT_SQL.strip() + """ AS member_count
            FROM hr_cohorts c
            WHERE c.id = ? AND LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            """,
            (int(cohort_id), (hr_trust or "").strip()),
        ).fetchone()
    if not row:
        return None
    return _cohort_row_dict(row)


def _backfill_all_doctors_membership(conn: sqlite3.Connection) -> None:
    """Ensure All Doctors includes every doctor who belongs to any trust cohort."""
    _ensure_hr_cohorts_tables(conn)
    default_dc = _default_cohort_name_sql_predicate("dc.name")
    non_default_c = _default_cohort_name_sql_predicate("c.name")
    conn.execute(
        f"""
        INSERT OR IGNORE INTO hr_cohort_members
          (cohort_id, user_id, added_at, welcome_pending, welcome_sent_at)
        SELECT dc.id, m.user_id, MIN(m.added_at), 0, MAX(m.welcome_sent_at)
        FROM hr_cohort_members m
        JOIN hr_cohorts c ON c.id = m.cohort_id
        JOIN hr_cohorts dc ON LOWER(TRIM(dc.hr_trust)) = LOWER(TRIM(c.hr_trust))
                          AND {default_dc}
        WHERE NOT {non_default_c}
        GROUP BY dc.id, m.user_id
        """
    )


def _ensure_user_in_default_cohort(
    hr_trust: str, user_id: int, hr_user_id: int, *, welcome_pending: bool = False
) -> None:
    """Keep All Doctors in sync when doctors are added to custom groups."""
    default_id = _default_cohort_id_for_trust(hr_trust, hr_user_id)
    cohort_add_member(default_id, int(user_id), welcome_pending=welcome_pending)


def _cohort_members_list_all_doctors(hr_trust: str) -> list[dict]:
    """All distinct doctors across every group for this trust."""
    hr_trust = (hr_trust or "").strip()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_users_provision_columns(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT u.id, u.email, u.display_name, u.gmc_number, u.current_trust,
                   u.must_change_password, u.provisioned_by_hr,
                   MIN(m.added_at) AS added_at,
                   MAX(COALESCE(m.welcome_pending, 0)) AS welcome_pending,
                   MAX(m.welcome_sent_at) AS welcome_sent_at
            FROM hr_cohort_members m
            JOIN hr_cohorts c ON c.id = m.cohort_id
            JOIN users u ON u.id = m.user_id
            WHERE LOWER(TRIM(c.hr_trust)) = LOWER(TRIM(?))
            GROUP BY u.id
            ORDER BY u.display_name, u.email
            """,
            (hr_trust,),
        ).fetchall()
    return [
        {
            "user_id": int(r["id"]),
            "email": r["email"],
            "personal_email": r["email"],
            "display_name": r["display_name"],
            "gmc_number": r["gmc_number"],
            "current_trust": r["current_trust"],
            "must_change_password": bool(r["must_change_password"]),
            "provisioned_by_hr": r["provisioned_by_hr"],
            "added_at": r["added_at"],
            "welcome_pending": bool(r["welcome_pending"]),
            "welcome_sent_at": r["welcome_sent_at"],
        }
        for r in rows
    ]


def cohort_delete(cohort_id: int, hr_trust: str) -> bool:
    """Remove a cohort and its membership rows (doctor accounts are kept)."""
    cohort = cohort_get(cohort_id, hr_trust)
    if not cohort:
        return False
    if is_default_cohort_name(cohort.get("name")):
        return False
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        cur = conn.execute(
            "DELETE FROM hr_cohorts WHERE id = ? AND LOWER(TRIM(hr_trust)) = LOWER(TRIM(?))",
            (int(cohort_id), (hr_trust or "").strip()),
        )
        conn.commit()
        return cur.rowcount > 0


def cohort_members_list(cohort_id: int, hr_trust: str) -> list[dict]:
    cohort = cohort_get(cohort_id, hr_trust)
    if not cohort:
        return []
    if is_default_cohort_name(cohort.get("name")):
        return _cohort_members_list_all_doctors(hr_trust)
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
            "personal_email": r["email"],
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


def cohort_member_remove(cohort_id: int, user_id: int, hr_trust: str) -> bool:
    """Remove a doctor from a cohort without deleting their account."""
    if not cohort_get(cohort_id, hr_trust):
        return False
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        cur = conn.execute(
            "DELETE FROM hr_cohort_members WHERE cohort_id = ? AND user_id = ?",
            (int(cohort_id), int(user_id)),
        )
        conn.commit()
        return cur.rowcount > 0


def cohort_members_remove_bulk(
    cohort_id: int, user_ids: list[int], hr_trust: str
) -> Optional[dict]:
    """Remove multiple doctors from a cohort without deleting their accounts."""
    if not cohort_get(cohort_id, hr_trust):
        return None
    ids: list[int] = []
    seen: set[int] = set()
    for uid in user_ids or []:
        try:
            n = int(uid)
        except (TypeError, ValueError):
            continue
        if n <= 0 or n in seen:
            continue
        seen.add(n)
        ids.append(n)
    if not ids:
        return {"removed_count": 0, "removed_user_ids": []}
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        placeholders = ",".join("?" * len(ids))
        rows = conn.execute(
            f"""
            SELECT user_id FROM hr_cohort_members
            WHERE cohort_id = ? AND user_id IN ({placeholders})
            """,
            [int(cohort_id), *ids],
        ).fetchall()
        to_remove = [int(r[0]) for r in rows]
        if not to_remove:
            return {"removed_count": 0, "removed_user_ids": []}
        rm_placeholders = ",".join("?" * len(to_remove))
        conn.execute(
            f"""
            DELETE FROM hr_cohort_members
            WHERE cohort_id = ? AND user_id IN ({rm_placeholders})
            """,
            [int(cohort_id), *to_remove],
        )
        conn.commit()
        return {"removed_count": len(to_remove), "removed_user_ids": to_remove}


def hr_doctor_delete(doctor_user_id: int, hr_trust: str) -> Optional[dict]:
    """
    Permanently delete a non-premium doctor account managed by hr_trust.
    Cohort memberships and related records are removed via ON DELETE CASCADE.
    """
    hr_trust = (hr_trust or "").strip()
    if not hr_trust:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_visibility_tables(conn)
        _ensure_hr_cohorts_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT id, email, display_name, gmc_number, premium
            FROM users WHERE id = ?
            """,
            (int(doctor_user_id),),
        ).fetchone()
        if not row or int(row["premium"] or 0) != 0:
            return None
        if not _doctor_deletable_by_trust(int(doctor_user_id), hr_trust, conn):
            return None
        cohort_rows = conn.execute(
            """
            SELECT c.id, c.name, c.hr_trust
            FROM hr_cohort_members m
            JOIN hr_cohorts c ON c.id = m.cohort_id
            WHERE m.user_id = ?
            ORDER BY c.name
            """,
            (int(doctor_user_id),),
        ).fetchall()
        cohorts = [
            {"id": int(r["id"]), "name": r["name"], "hr_trust": r["hr_trust"]}
            for r in cohort_rows
        ]
        conn.execute(
            "DELETE FROM hr_cohort_members WHERE user_id = ?",
            (int(doctor_user_id),),
        )
        cur = conn.execute(
            "DELETE FROM users WHERE id = ? AND COALESCE(premium, 0) = 0",
            (int(doctor_user_id),),
        )
        if cur.rowcount <= 0:
            return None
        conn.commit()
        return {
            "deleted_user_id": int(doctor_user_id),
            "email": row["email"],
            "display_name": row["display_name"],
            "gmc_number": row["gmc_number"],
            "cohorts_removed": cohorts,
        }


def hr_doctors_delete_bulk(user_ids: list[int], hr_trust: str) -> dict:
    """Permanently delete multiple doctor accounts; skips ids that cannot be deleted."""
    ids: list[int] = []
    seen: set[int] = set()
    for uid in user_ids or []:
        try:
            n = int(uid)
        except (TypeError, ValueError):
            continue
        if n <= 0 or n in seen:
            continue
        seen.add(n)
        ids.append(n)
    deleted: list[dict] = []
    not_deleted: list[int] = []
    for uid in ids:
        result = hr_doctor_delete(uid, hr_trust)
        if result:
            deleted.append(result)
        else:
            not_deleted.append(uid)
    return {
        "deleted_count": len(deleted),
        "deleted": deleted,
        "not_deleted_user_ids": not_deleted,
    }


def cohort_member_update_profile(
    cohort_id: int,
    user_id: int,
    hr_trust: str,
    *,
    display_name: Optional[str] = None,
    gmc_number: Optional[str] = None,
) -> Optional[dict]:
    """Update roster name/GMC for a cohort member (login email is unchanged)."""
    members = cohort_members_list(cohort_id, hr_trust)
    member = next((m for m in members if int(m["user_id"]) == int(user_id)), None)
    if not member:
        return None
    u = user_get_by_id(int(user_id))
    if not u or user_is_premium(u):
        return None
    dn = u.get("display_name")
    if display_name is not None:
        dn = (display_name or "").strip() or None
    gmc = u.get("gmc_number")
    if gmc_number is not None:
        gmc = _normalize_provision_gmc(str(gmc_number or "")) or None
    user_set_profile(int(user_id), dn, gmc, u.get("current_trust"))
    members = cohort_members_list(cohort_id, hr_trust)
    return next((m for m in members if int(m["user_id"]) == int(user_id)), None)


def cohort_roster_lines(cohort_id: int, hr_trust: str) -> list[str]:
    """Roster identifiers for bulk training: personal login email, else GMC."""
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


def cohort_skip_welcome_for_users(
    cohort_id: int, hr_trust: str, user_ids: list[int]
) -> int:
    """Clear welcome_pending without sending (HR chose to skip welcome)."""
    if not cohort_get(cohort_id, hr_trust) or not user_ids:
        return 0
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_cohorts_tables(conn)
        _ensure_hr_cohort_members_welcome_columns(conn)
        n = 0
        for uid in user_ids:
            cur = conn.execute(
                """UPDATE hr_cohort_members
                   SET welcome_pending = 0
                   WHERE cohort_id = ? AND user_id = ?
                     AND welcome_sent_at IS NULL AND welcome_pending = 1""",
                (int(cohort_id), int(uid)),
            )
            n += cur.rowcount
        conn.commit()
        return n


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
    """Backward-compatible wrapper: email strings only."""
    members = [{"email": e} for e in emails]
    return cohort_add_members(
        cohort_id,
        hr_trust,
        members,
        hr_user_id,
        reserved_emails,
        queue_welcome=queue_welcome,
    )


def cohort_processable_members(members: list[dict]) -> list[dict]:
    out: list[dict] = []
    for row in members:
        if not isinstance(row, dict):
            continue
        personal = (
            row.get("personal_email") or row.get("email") or ""
        ).strip().lower()
        if personal:
            out.append(row)
    return out


def cohort_add_single_member(
    cohort_id: int,
    row: dict,
    *,
    hr_user_id: int,
    reserved_emails: set[str],
    queue_welcome: bool,
    default_trust: Optional[str],
) -> dict:
    personal = (
        row.get("personal_email") or row.get("email") or ""
    ).strip().lower()
    dn = (row.get("display_name") or "").strip() or None
    gmc_raw = row.get("gmc_number")
    prefilled: list[str] = []
    if dn:
        prefilled.append("name")
    if _normalize_provision_gmc(str(gmc_raw or "")):
        prefilled.append("GMC")
    if default_trust:
        prefilled.append("trust")

    if personal in reserved_emails:
        return {
            "email": personal,
            "status": "failed",
            "user_id": None,
            "error": "reserved email",
            "prefilled": prefilled,
        }
    existing = user_get_by_email(personal)
    if existing:
        if user_is_premium(existing):
            return {
                "email": personal,
                "status": "failed",
                "user_id": None,
                "error": "premium account",
                "prefilled": prefilled,
            }
        uid = int(existing["id"])
        user_apply_hr_roster_row(
            uid,
            display_name=dn,
            gmc_number=gmc_raw,
            default_trust=default_trust,
        )
        cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
        cohort_row = cohort_get_by_id(cohort_id)
        if cohort_row and not is_default_cohort_name(cohort_row.get("name")):
            _ensure_user_in_default_cohort(
                cohort_row["hr_trust"], uid, hr_user_id, welcome_pending=False
            )
        row_out = {
            "email": personal,
            "status": "existing",
            "user_id": uid,
            "error": None,
            "prefilled": prefilled,
        }
        if dn:
            row_out["display_name"] = dn
        return row_out
    try:
        uid = user_create_provisioned(
            personal,
            hr_user_id,
            default_trust=default_trust,
            display_name=dn,
            gmc_number=str(gmc_raw or ""),
        )
        cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
        cohort_row = cohort_get_by_id(cohort_id)
        if cohort_row and not is_default_cohort_name(cohort_row.get("name")):
            _ensure_user_in_default_cohort(
                cohort_row["hr_trust"], uid, hr_user_id, welcome_pending=False
            )
        row_out = {
            "email": personal,
            "status": "created",
            "user_id": uid,
            "error": None,
            "prefilled": prefilled,
        }
        if dn:
            row_out["display_name"] = dn
        return row_out
    except sqlite3.IntegrityError:
        existing = user_get_by_email(personal)
        if existing and not user_is_premium(existing):
            uid = int(existing["id"])
            user_apply_provisioned_profile(
                uid,
                display_name=dn,
                gmc_number=str(gmc_raw or ""),
                default_trust=default_trust,
            )
            cohort_add_member(cohort_id, uid, welcome_pending=queue_welcome)
            cohort_row = cohort_get_by_id(cohort_id)
            if cohort_row and not is_default_cohort_name(cohort_row.get("name")):
                _ensure_user_in_default_cohort(
                    cohort_row["hr_trust"], uid, hr_user_id, welcome_pending=False
                )
            row_out = {
                "email": personal,
                "status": "existing",
                "user_id": uid,
                "error": None,
                "prefilled": prefilled,
            }
            if dn:
                row_out["display_name"] = dn
            return row_out
        return {
            "email": personal,
            "status": "failed",
            "user_id": None,
            "error": "could not create account",
            "prefilled": prefilled,
        }


def cohort_add_members(
    cohort_id: int,
    hr_trust: str,
    members: list[dict],
    hr_user_id: int,
    reserved_emails: set[str],
    queue_welcome: bool = False,
    on_progress: Optional[Callable[[str, str, int, int], None]] = None,
) -> list[dict]:
    """
    For each roster row: create provisioned user or link existing; add to cohort.
    Each member dict must include personal_email (login); optional display_name, gmc_number.
    Returns per-row result dicts (email = personal login, status, user_id, error, prefilled).
    """
    from . import trust_packs

    cohort = cohort_get(cohort_id, hr_trust)
    if not cohort:
        raise ValueError("cohort_not_found")
    default_trust = trust_packs.trust_display_name(hr_trust) or None
    processable = cohort_processable_members(members)
    total = len(processable)
    results: list[dict] = []
    for idx, row in enumerate(processable):
        if on_progress:
            on_progress(
                "provision",
                f"Adding doctor {idx + 1} of {total}…",
                idx + 1,
                total,
            )
        results.append(
            cohort_add_single_member(
                cohort_id,
                row,
                hr_user_id=hr_user_id,
                reserved_emails=reserved_emails,
                queue_welcome=queue_welcome,
                default_trust=default_trust,
            )
        )
    return results


# ── Phase 3: verifier links, welcome templates ───────────────


def _ensure_hr_verifier_links_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS hr_verifier_links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE,
            hr_trust TEXT NOT NULL,
            created_by_user_id INTEGER NOT NULL REFERENCES users(id),
            doctor_user_id INTEGER REFERENCES users(id),
            cohort_id INTEGER REFERENCES hr_cohorts(id),
            label TEXT,
            expires_at TEXT NOT NULL,
            revoked_at TEXT,
            created_at TEXT NOT NULL
        )
    """)


def _ensure_hr_welcome_templates_table(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS hr_welcome_templates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hr_trust TEXT NOT NULL,
            name TEXT NOT NULL,
            topic_id INTEGER,
            body TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    """)


def _ensure_password_resets_table(conn: sqlite3.Connection) -> None:
    """One-time reset tokens for forgot-password flow.

    The token shown to the user is a high-entropy random string sent by email;
    we only persist its SHA-256 hash so a DB leak does not let an attacker
    consume outstanding tokens.
    """
    conn.execute("""
        CREATE TABLE IF NOT EXISTS password_resets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            ip_hint TEXT
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_password_resets_user_id ON password_resets(user_id)"
    )


def password_reset_create(
    user_id: int,
    token_hash: str,
    expires_at: str,
    ip_hint: Optional[str] = None,
) -> int:
    """Insert a new reset token. Returns the row id."""
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_password_resets_table(conn)
        cur = conn.execute(
            """
            INSERT INTO password_resets (user_id, token_hash, created_at, expires_at, ip_hint)
            VALUES (?, ?, ?, ?, ?)
            """,
            (int(user_id), token_hash, now, expires_at, ip_hint),
        )
        conn.commit()
        return int(cur.lastrowid or 0)


def password_reset_consume(token_hash: str) -> Optional[int]:
    """Atomically claim an unused, unexpired token. Returns user_id or None."""
    if not token_hash:
        return None
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_password_resets_table(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT id, user_id, expires_at, used_at
            FROM password_resets
            WHERE token_hash = ?
            """,
            (token_hash,),
        ).fetchone()
        if not row:
            return None
        if row["used_at"]:
            return None
        if (row["expires_at"] or "") <= now_iso:
            return None
        cur = conn.execute(
            "UPDATE password_resets SET used_at = ? WHERE id = ? AND used_at IS NULL",
            (now_iso, int(row["id"])),
        )
        if cur.rowcount != 1:
            return None
        conn.commit()
        return int(row["user_id"])


def password_reset_invalidate_outstanding(user_id: int) -> int:
    """Mark all unused tokens for this user as consumed (called after a successful reset)."""
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_password_resets_table(conn)
        cur = conn.execute(
            "UPDATE password_resets SET used_at = ? WHERE user_id = ? AND used_at IS NULL",
            (now_iso, int(user_id)),
        )
        conn.commit()
        return int(cur.rowcount or 0)


# ── Email-OTP MFA for sign-in ─────────────────────────────────────────────
#
# `mfa_codes` rows pair a one-time 6-digit code with an opaque challenge
# token issued via HttpOnly cookie at password-OK time. The verify endpoint
# requires both the cookie token and the emailed code, so an attacker who
# only sees the email cannot complete sign-in (and vice versa).
#
# `mfa_trusted_devices` lets a successful login persist a long-lived
# HttpOnly device cookie so we don't ask for a code on every sign-in from
# that browser.

def _ensure_mfa_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS mfa_codes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            code_hash TEXT NOT NULL,
            challenge_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            ip_hint TEXT
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_mfa_codes_challenge ON mfa_codes(challenge_hash)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_mfa_codes_user ON mfa_codes(user_id)"
    )

    conn.execute("""
        CREATE TABLE IF NOT EXISTS mfa_trusted_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            last_used_at TEXT,
            user_agent_hint TEXT,
            revoked_at TEXT
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_mfa_trusted_devices_user ON mfa_trusted_devices(user_id)"
    )


def mfa_code_create(
    user_id: int,
    code_hash: str,
    challenge_hash: str,
    expires_at: str,
    ip_hint: Optional[str] = None,
) -> int:
    """Insert a fresh challenge. Invalidates any earlier unused codes for the user."""
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        conn.execute(
            "UPDATE mfa_codes SET used_at = ? WHERE user_id = ? AND used_at IS NULL",
            (now, int(user_id)),
        )
        cur = conn.execute(
            """
            INSERT INTO mfa_codes (user_id, code_hash, challenge_hash, created_at, expires_at, ip_hint)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (int(user_id), code_hash, challenge_hash, now, expires_at, ip_hint),
        )
        conn.commit()
        return int(cur.lastrowid or 0)


def mfa_code_lookup_active(challenge_hash: str) -> Optional[dict]:
    """Return { id, user_id, code_hash, attempts } for an unused, unexpired challenge."""
    if not challenge_hash:
        return None
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT id, user_id, code_hash, expires_at, used_at, attempts
            FROM mfa_codes
            WHERE challenge_hash = ?
            ORDER BY id DESC
            LIMIT 1
            """,
            (challenge_hash,),
        ).fetchone()
    if not row:
        return None
    if row["used_at"]:
        return None
    if (row["expires_at"] or "") <= now_iso:
        return None
    return {
        "id": int(row["id"]),
        "user_id": int(row["user_id"]),
        "code_hash": str(row["code_hash"]),
        "attempts": int(row["attempts"] or 0),
    }


def mfa_code_consume(code_id: int) -> bool:
    """Atomically mark a single code row as consumed. Returns True on success."""
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        cur = conn.execute(
            "UPDATE mfa_codes SET used_at = ? WHERE id = ? AND used_at IS NULL",
            (now_iso, int(code_id)),
        )
        conn.commit()
        return bool(cur.rowcount == 1)


MFA_MAX_ATTEMPTS = 5


def mfa_code_record_attempt(code_id: int) -> int:
    """Increment attempt counter; auto-burn the row once MFA_MAX_ATTEMPTS reached."""
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        conn.execute(
            "UPDATE mfa_codes SET attempts = attempts + 1 WHERE id = ? AND used_at IS NULL",
            (int(code_id),),
        )
        row = conn.execute(
            "SELECT attempts FROM mfa_codes WHERE id = ?",
            (int(code_id),),
        ).fetchone()
        attempts = int(row[0]) if row else 0
        if attempts >= MFA_MAX_ATTEMPTS:
            conn.execute(
                "UPDATE mfa_codes SET used_at = ? WHERE id = ? AND used_at IS NULL",
                (now_iso, int(code_id)),
            )
        conn.commit()
        return attempts


def mfa_trusted_device_create(
    user_id: int,
    token_hash: str,
    expires_at: str,
    user_agent_hint: Optional[str] = None,
) -> int:
    """Persist a trusted-device record. Returns row id."""
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        cur = conn.execute(
            """
            INSERT INTO mfa_trusted_devices
                (user_id, token_hash, created_at, expires_at, user_agent_hint)
            VALUES (?, ?, ?, ?, ?)
            """,
            (int(user_id), token_hash, now, expires_at, user_agent_hint),
        )
        conn.commit()
        return int(cur.lastrowid or 0)


def mfa_trusted_device_valid(user_id: int, token_hash: str) -> bool:
    """Return True if the device token is unrevoked and unexpired for this user."""
    if not token_hash:
        return False
    now_iso = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_mfa_tables(conn)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            """
            SELECT id, expires_at, revoked_at
            FROM mfa_trusted_devices
            WHERE user_id = ? AND token_hash = ?
            """,
            (int(user_id), token_hash),
        ).fetchone()
        if not row:
            return False
        if row["revoked_at"]:
            return False
        if (row["expires_at"] or "") <= now_iso:
            return False
        conn.execute(
            "UPDATE mfa_trusted_devices SET last_used_at = ? WHERE id = ?",
            (now_iso, int(row["id"])),
        )
        conn.commit()
        return True


def hr_welcome_templates_list(hr_trust: str) -> list[dict]:
    t = (hr_trust or "").strip().lower()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_welcome_templates_table(conn)
        _ensure_mandatory_topics_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT w.id, w.name, w.topic_id, w.body, w.created_at, w.updated_at,
                   m.topic_name
            FROM hr_welcome_templates w
            LEFT JOIN trust_mandatory_topics m ON m.id = w.topic_id
            WHERE LOWER(TRIM(w.hr_trust)) = ?
            ORDER BY w.name
            """,
            (t,),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "name": r["name"],
            "topic_id": r["topic_id"],
            "topic_name": r["topic_name"],
            "body": r["body"],
            "created_at": r["created_at"],
            "updated_at": r["updated_at"],
        }
        for r in rows
    ]


def hr_welcome_template_save(
    hr_trust: str,
    name: str,
    body: str,
    *,
    topic_id: Optional[int] = None,
    template_id: Optional[int] = None,
) -> dict:
    now = datetime.utcnow().isoformat()
    name = (name or "").strip() or "Template"
    body = (body or "").strip()
    t = (hr_trust or "").strip()
    tid_topic = int(topic_id) if topic_id is not None else None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_welcome_templates_table(conn)
        if template_id is not None:
            conn.execute(
                """
                UPDATE hr_welcome_templates
                SET name = ?, topic_id = ?, body = ?, updated_at = ?
                WHERE id = ? AND LOWER(TRIM(hr_trust)) = ?
                """,
                (name, tid_topic, body, now, int(template_id), t.lower()),
            )
            tid = int(template_id)
        else:
            cur = conn.execute(
                """
                INSERT INTO hr_welcome_templates (hr_trust, name, topic_id, body, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (t, name, tid_topic, body, now, now),
            )
            tid = int(cur.lastrowid)
        conn.commit()
    rows = hr_welcome_templates_list(hr_trust)
    return next((x for x in rows if x["id"] == tid), {"id": tid, "name": name, "body": body})


def hr_welcome_template_delete(template_id: int, hr_trust: str) -> bool:
    t = (hr_trust or "").strip().lower()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_welcome_templates_table(conn)
        cur = conn.execute(
            "DELETE FROM hr_welcome_templates WHERE id = ? AND LOWER(TRIM(hr_trust)) = ?",
            (int(template_id), t),
        )
        conn.commit()
        return cur.rowcount > 0


def doctor_verified_bundle_items(doctor_user_id: int) -> list[dict]:
    """Wallet rows verified by HR (for portfolio / read-only verifier links)."""
    try:
        wallet = json.loads(user_wallet_get(int(doctor_user_id)) or "[]")
    except Exception:
        wallet = []
    if not isinstance(wallet, list):
        wallet = []
    vmap = doctor_verified_map(int(doctor_user_id))
    items: list[dict] = []
    for c in wallet:
        if not isinstance(c, dict) or c.get("revoked"):
            continue
        cid = str(c.get("credential_id") or "").strip()
        if not cid:
            continue
        vm = vmap.get(cid) or {}
        if str(vm.get("status") or "").upper() != "VERIFIED":
            continue
        if not c.get("jwt"):
            continue
        items.append(
            {
                "credential_id": cid,
                "jwt": c.get("jwt"),
                "module_name": c.get("module_name"),
                "expiry_date": c.get("expiry_date"),
                "issuing_trust_name": c.get("issuing_trust_name"),
            }
        )
    return items


def verifier_link_create(
    *,
    hr_trust: str,
    created_by_user_id: int,
    doctor_user_id: Optional[int] = None,
    cohort_id: Optional[int] = None,
    label: Optional[str] = None,
    expires_days: int = 14,
) -> dict:
    import secrets

    if not doctor_user_id and not cohort_id:
        raise ValueError("doctor_user_id or cohort_id required")
    if doctor_user_id and cohort_id:
        raise ValueError("Specify doctor_user_id or cohort_id, not both")
    if cohort_id and not cohort_get(int(cohort_id), hr_trust):
        raise ValueError("Cohort not found")
    days = max(1, min(int(expires_days), 90))
    token = secrets.token_urlsafe(32)
    now = datetime.utcnow().isoformat()
    exp = (datetime.utcnow() + timedelta(days=days)).isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_verifier_links_table(conn)
        cur = conn.execute(
            """
            INSERT INTO hr_verifier_links (
                token, hr_trust, created_by_user_id, doctor_user_id, cohort_id,
                label, expires_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                token,
                (hr_trust or "").strip(),
                int(created_by_user_id),
                int(doctor_user_id) if doctor_user_id else None,
                int(cohort_id) if cohort_id else None,
                (label or "").strip() or None,
                exp,
                now,
            ),
        )
        conn.commit()
        link_id = int(cur.lastrowid)
    return verifier_link_get_by_id(link_id, hr_trust) or {"id": link_id, "token": token}


def verifier_link_get_by_token(token: str) -> Optional[dict]:
    tok = (token or "").strip()
    if not tok:
        return None
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_verifier_links_table(conn)
        conn.row_factory = sqlite3.Row
        r = conn.execute(
            "SELECT * FROM hr_verifier_links WHERE token = ?",
            (tok,),
        ).fetchone()
    if not r:
        return None
    return dict(r)


def verifier_link_get_by_id(link_id: int, hr_trust: str) -> Optional[dict]:
    t = (hr_trust or "").strip().lower()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_verifier_links_table(conn)
        conn.row_factory = sqlite3.Row
        r = conn.execute(
            """
            SELECT id, token, hr_trust, doctor_user_id, cohort_id, label,
                   expires_at, revoked_at, created_at, created_by_user_id
            FROM hr_verifier_links
            WHERE id = ? AND LOWER(TRIM(hr_trust)) = ?
            """,
            (int(link_id), t),
        ).fetchone()
    if not r:
        return None
    return {
        "id": int(r["id"]),
        "token": r["token"],
        "hr_trust": r["hr_trust"],
        "doctor_user_id": r["doctor_user_id"],
        "cohort_id": r["cohort_id"],
        "label": r["label"],
        "expires_at": r["expires_at"],
        "revoked_at": r["revoked_at"],
        "created_at": r["created_at"],
        "created_by_user_id": int(r["created_by_user_id"]),
    }


def verifier_links_list(hr_trust: str, *, limit: int = 50) -> list[dict]:
    t = (hr_trust or "").strip().lower()
    lim = max(1, min(int(limit), 100))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_verifier_links_table(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT id, token, doctor_user_id, cohort_id, label, expires_at, revoked_at, created_at
            FROM hr_verifier_links
            WHERE LOWER(TRIM(hr_trust)) = ?
            ORDER BY id DESC
            LIMIT ?
            """,
            (t, lim),
        ).fetchall()
    return [
        {
            "id": int(r["id"]),
            "token": r["token"],
            "doctor_user_id": r["doctor_user_id"],
            "cohort_id": r["cohort_id"],
            "label": r["label"],
            "expires_at": r["expires_at"],
            "revoked_at": r["revoked_at"],
            "created_at": r["created_at"],
        }
        for r in rows
    ]


def verifier_link_revoke(link_id: int, hr_trust: str) -> bool:
    t = (hr_trust or "").strip().lower()
    now = datetime.utcnow().isoformat()
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_hr_verifier_links_table(conn)
        cur = conn.execute(
            """
            UPDATE hr_verifier_links SET revoked_at = ?
            WHERE id = ? AND LOWER(TRIM(hr_trust)) = ? AND revoked_at IS NULL
            """,
            (now, int(link_id), t),
        )
        conn.commit()
        return cur.rowcount > 0


def verifier_link_bundle_payload(link_row: dict) -> Optional[dict]:
    """Build read-only bundle JSON for a valid verifier link."""
    if not link_row or link_row.get("revoked_at"):
        return None
    exp = link_row.get("expires_at")
    if exp:
        try:
            if datetime.fromisoformat(str(exp)[:19]) < datetime.utcnow():
                return None
        except ValueError:
            pass
    trust = (link_row.get("hr_trust") or "").strip()
    title = (link_row.get("label") or "").strip() or "Verified training"
    credentials: list[dict] = []
    doctors: list[dict] = []
    if link_row.get("doctor_user_id"):
        uid = int(link_row["doctor_user_id"])
        u = user_get_by_id(uid)
        doctors.append(
            {
                "user_id": uid,
                "display_name": (u or {}).get("display_name"),
                "gmc_number": (u or {}).get("gmc_number"),
            }
        )
        for it in doctor_verified_bundle_items(uid):
            credentials.append(
                {
                    "id": it["credential_id"],
                    "credential_id": it["credential_id"],
                    "jwt": it["jwt"],
                    "module_name": it.get("module_name"),
                    "expiry_date": it.get("expiry_date"),
                }
            )
        if title == "Verified training":
            title = ((u or {}).get("display_name") or "Doctor") + " — verified training"
    elif link_row.get("cohort_id"):
        cohort = cohort_get(int(link_row["cohort_id"]), trust)
        if not cohort:
            return None
        title = title if title != "Verified training" else (cohort.get("name") or "Cohort") + " — verified training"
        for m in cohort_members_list(int(link_row["cohort_id"]), trust):
            uid = int(m["user_id"])
            items = doctor_verified_bundle_items(uid)
            if not items:
                continue
            doctors.append(
                {
                    "user_id": uid,
                    "display_name": m.get("display_name"),
                    "gmc_number": m.get("gmc_number"),
                }
            )
            for it in items:
                credentials.append(
                    {
                        "id": it["credential_id"],
                        "credential_id": it["credential_id"],
                        "jwt": it["jwt"],
                        "module_name": it.get("module_name"),
                        "expiry_date": it.get("expiry_date"),
                        "doctor_user_id": uid,
                    }
                )
    return {
        "title": title,
        "trust": trust,
        "doctors": doctors,
        "credentials": credentials,
    }


def _hr_user_row_to_dict(row: sqlite3.Row) -> dict:
    keys = row.keys()
    return {
        "id": int(row["id"]),
        "email": row["email"],
        "display_name": row["display_name"],
        "current_trust": row["current_trust"],
        "hr_email_digest_enabled": bool(row["hr_email_digest_enabled"]),
        "hr_email_instant_enabled": bool(row["hr_email_instant_enabled"]),
        "hr_notification_email": row["hr_notification_email"],
        "hr_expiry_reminders_enabled": bool(row["hr_expiry_reminders_enabled"])
        if "hr_expiry_reminders_enabled" in keys and row["hr_expiry_reminders_enabled"] is not None
        else True,
    }


def hr_effective_notification_email(user: dict) -> str:
    """Delivery address for HR digests/alerts: custom notification email, else login email."""
    custom = (user.get("hr_notification_email") or "").strip()
    if custom:
        return custom
    return (user.get("email") or "").strip()


def hr_premium_users_list() -> list[dict]:
    """All premium (HR) users with a trust set — for daily digest iteration."""
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_premium_column(conn)
        _ensure_users_profile_extra_columns(conn)
        _ensure_users_hr_email_columns(conn)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT id, email, display_name, current_trust,
                   hr_email_digest_enabled, hr_email_instant_enabled,
                   hr_notification_email, hr_expiry_reminders_enabled
            FROM users
            WHERE premium = 1 AND TRIM(COALESCE(current_trust, '')) != ''
            ORDER BY current_trust COLLATE NOCASE, email COLLATE NOCASE
            """
        ).fetchall()
    return [_hr_user_row_to_dict(r) for r in rows]


def hr_premium_users_for_trust(trust: str) -> list[dict]:
    """Premium HR users whose current_trust matches the given trust (case-insensitive)."""
    trust_key = (trust or "").strip().lower()
    if not trust_key:
        return []
    return [
        u
        for u in hr_premium_users_list()
        if (u.get("current_trust") or "").strip().lower() == trust_key
    ]


def hr_inbox_activity_summary(hr_trust: str) -> dict:
    """Actionable pending verification counts and unread doctor messages for one HR trust."""
    trust_key = (hr_trust or "").strip().lower()
    pending_sessions = 0
    pending_items = 0
    unread_messages = 0
    if not trust_key:
        return {
            "pending_sessions": 0,
            "pending_items": 0,
            "unread_messages": 0,
        }
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_share_tables(conn)
        row = conn.execute(
            """
            SELECT COUNT(DISTINCT s.id) AS sessions,
                   COUNT(i.credential_id) AS items
            FROM share_sessions s
            JOIN share_items i ON i.session_id = s.id AND UPPER(TRIM(i.status)) = 'PENDING'
            JOIN users u ON u.id = s.doctor_user_id
            WHERE LOWER(TRIM(COALESCE(s.target_trust, ''))) = ?
              AND LOWER(TRIM(COALESCE(s.share_kind, 'review'))) = 'review'
            """,
            (trust_key,),
        ).fetchone()
        if row:
            pending_sessions = int(row[0] or 0)
            pending_items = int(row[1] or 0)
    unread_messages = messages_unread_count_for_hr(hr_trust)
    return {
        "pending_sessions": pending_sessions,
        "pending_items": pending_items,
        "unread_messages": unread_messages,
    }


def hr_email_prefs_get(user_id: int) -> Optional[dict]:
    u = user_get_by_id(int(user_id))
    if not u or not user_is_premium(u):
        return None
    return {
        "digest_enabled": bool(u.get("hr_email_digest_enabled", True)),
        "instant_enabled": bool(u.get("hr_email_instant_enabled", True)),
        "expiry_reminders_enabled": bool(u.get("hr_expiry_reminders_enabled", True)),
        "login_email": u.get("email"),
        "notification_email": (u.get("hr_notification_email") or "").strip() or None,
        "email": hr_effective_notification_email(u),
    }


def hr_email_prefs_set(
    user_id: int,
    *,
    digest_enabled: Optional[bool] = None,
    instant_enabled: Optional[bool] = None,
    expiry_reminders_enabled: Optional[bool] = None,
    notification_email: Optional[str] = None,
    set_notification_email: bool = False,
) -> Optional[dict]:
    u = user_get_by_id(int(user_id))
    if not u or not user_is_premium(u):
        return None
    digest = 1 if (digest_enabled if digest_enabled is not None else u.get("hr_email_digest_enabled", True)) else 0
    instant = 1 if (instant_enabled if instant_enabled is not None else u.get("hr_email_instant_enabled", True)) else 0
    expiry = 1 if (
        expiry_reminders_enabled
        if expiry_reminders_enabled is not None
        else u.get("hr_expiry_reminders_enabled", True)
    ) else 0
    sets = [
        "hr_email_digest_enabled = ?",
        "hr_email_instant_enabled = ?",
        "hr_expiry_reminders_enabled = ?",
    ]
    params: list = [digest, instant, expiry]
    if set_notification_email:
        norm = (notification_email or "").strip().lower()
        sets.append("hr_notification_email = ?")
        params.append(norm or None)
    params.append(int(user_id))
    with sqlite3.connect(DB_PATH) as conn:
        _ensure_users_hr_email_columns(conn)
        conn.execute(
            f"UPDATE users SET {', '.join(sets)} WHERE id = ?",
            params,
        )
        conn.commit()
    return hr_email_prefs_get(int(user_id))

