"""
Compliance snapshot: mandatory topics vs wallet, expiry, HR verification status.
Shared by clinician and HR cohort APIs (Phase 0).
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import date, timedelta
from typing import Any, Optional

from jose import jwt as jose_jwt

from . import db


def _parse_wallet(raw: str) -> list[dict]:
    try:
        data = json.loads(raw or "[]")
    except Exception:
        return []
    return data if isinstance(data, list) else []


def _cred_payload(c: dict) -> Optional[dict]:
    if not isinstance(c, dict) or c.get("revoked"):
        return None
    code = (c.get("module_code") or "").strip().lower()
    name = (c.get("module_name") or "").strip().lower()
    if not code and c.get("jwt"):
        try:
            claims = jose_jwt.get_unverified_claims(str(c["jwt"]))
            if isinstance(claims, dict):
                code = (claims.get("module_code") or "").strip().lower()
                if not name:
                    name = (claims.get("module_name") or "").strip().lower()
        except Exception:
            pass
    return {
        "module_code": code,
        "module_name": name,
        "expiry_date": (c.get("expiry_date") or "").strip()[:10] or None,
        "credential_id": c.get("credential_id"),
        "module_name_display": c.get("module_name"),
        "issuing_trust_name": c.get("issuing_trust_name"),
    }


def _hints_from_topic(topic: dict) -> dict:
    h = topic.get("match_hints")
    if isinstance(h, dict):
        return h
    return {
        "match_module_codes": [],
        "match_name_substrings": [topic.get("topic_name") or ""],
    }


def _cred_matches_requirement(req: dict, pl: dict) -> bool:
    code = pl.get("module_code") or ""
    name = pl.get("module_name") or ""
    for mc in req.get("match_module_codes") or []:
        if code == str(mc).strip().lower():
            return True
    for sub in req.get("match_name_substrings") or []:
        s = str(sub).strip().lower()
        if s and s in name:
            return True
    return False


def _find_best_match(topic: dict, wallet: list[dict]) -> Optional[dict]:
    req = _hints_from_topic(topic)
    label = (topic.get("topic_name") or "").strip().lower()
    matches: list[tuple[str, dict]] = []
    for c in wallet:
        pl = _cred_payload(c)
        if not pl:
            continue
        if _cred_matches_requirement(req, pl):
            matches.append((pl.get("expiry_date") or "9999-99-99", c))
            continue
        name = pl.get("module_name") or ""
        if label and (label in name or name in label):
            matches.append((pl.get("expiry_date") or "9999-99-99", c))
    if not matches:
        return None
    matches.sort(key=lambda x: x[0], reverse=True)
    return matches[0][1]


def _expiry_status(expiry_date: Optional[str], *, warn_days: int = 90) -> str:
    if not expiry_date:
        return "met"
    try:
        exp = date.fromisoformat(str(expiry_date)[:10])
    except ValueError:
        return "met"
    today = date.today()
    if exp < today:
        return "expired"
    warn = today + timedelta(days=warn_days)
    if exp <= warn:
        return "expiring"
    return "met"


def _days_until(expiry_date: Optional[str]) -> Optional[int]:
    if not expiry_date:
        return None
    try:
        exp = date.fromisoformat(str(expiry_date)[:10])
    except ValueError:
        return None
    return (exp - date.today()).days


def _hr_status_for_credential(verified_map: dict, credential_id: Optional[str]) -> Optional[str]:
    if not credential_id:
        return None
    ent = verified_map.get(str(credential_id)) or verified_map.get(credential_id)
    if not ent:
        return None
    return (ent.get("status") or "").upper() or None


def doctor_compliance_snapshot(doctor_user_id: int, trust_name: str) -> dict:
    """Mandatory topics vs wallet for one clinician at a trust."""
    trust = (trust_name or "").strip()
    topics = db.mandatory_topics_list(trust) if trust else []
    wallet = _parse_wallet(db.user_wallet_get(int(doctor_user_id)))
    verified_map = db.doctor_verified_map(int(doctor_user_id))

    topic_rows: list[dict] = []
    n_met = n_expiring = n_gap = 0
    for t in topics:
        match = _find_best_match(t, wallet)
        if match:
            pl = _cred_payload(match) or {}
            st = _expiry_status(pl.get("expiry_date"))
            cid = match.get("credential_id")
            hr_st = _hr_status_for_credential(verified_map, cid)
        else:
            st = "gap"
            pl = {}
            cid = None
            hr_st = None
        if st == "met":
            n_met += 1
        elif st == "expiring":
            n_expiring += 1
        else:
            n_gap += 1
        topic_rows.append(
            {
                "topic_id": t.get("id"),
                "topic_name": t.get("topic_name"),
                "category": t.get("category"),
                "status": st,
                "credential_id": cid,
                "module_name": (match or {}).get("module_name"),
                "expiry_date": pl.get("expiry_date"),
                "hr_status": hr_st,
            }
        )

    expiring_creds: list[dict] = []
    seen: set[str] = set()
    for c in wallet:
        pl = _cred_payload(c)
        if not pl or not pl.get("expiry_date"):
            continue
        st = _expiry_status(pl.get("expiry_date"))
        if st not in ("expiring", "expired"):
            continue
        cid = str(pl.get("credential_id") or "")
        if cid in seen:
            continue
        seen.add(cid)
        expiring_creds.append(
            {
                "credential_id": cid,
                "module_name": c.get("module_name") or pl.get("module_name_display"),
                "expiry_date": pl.get("expiry_date"),
                "status": st,
                "days_until": _days_until(pl.get("expiry_date")),
                "hr_status": _hr_status_for_credential(verified_map, cid),
            }
        )
    expiring_creds.sort(key=lambda x: (x.get("days_until") is None, x.get("days_until") or 99999))

    vm_counts = {"verified": 0, "pending": 0, "declined": 0}
    for ent in verified_map.values():
        st = (ent.get("status") or "").upper()
        if st == "VERIFIED":
            vm_counts["verified"] += 1
        elif st == "DECLINED":
            vm_counts["declined"] += 1
        elif st == "PENDING":
            vm_counts["pending"] += 1

    return {
        "trust": trust or None,
        "topics": topic_rows,
        "summary": {
            "total_topics": len(topics),
            "met": n_met,
            "expiring": n_expiring,
            "gap": n_gap,
        },
        "expiring_credentials": expiring_creds,
        "hr_verification": vm_counts,
    }


def cohort_compliance_snapshot(cohort_id: int, hr_trust: str) -> Optional[dict]:
    """Aggregate mandatory compliance for all members of a cohort."""
    cohort = db.cohort_get(int(cohort_id), hr_trust)
    if not cohort:
        return None
    members = db.cohort_members_list(int(cohort_id), hr_trust)
    trust = (hr_trust or "").strip()
    topics = db.mandatory_topics_list(trust) if trust else []

    member_rows: list[dict] = []
    topic_agg: dict[str, dict] = {}
    for t in topics:
        key = str(t.get("id") if t.get("id") is not None else t.get("topic_name") or "")
        topic_agg[key] = {
            "topic_id": t.get("id"),
            "topic_name": t.get("topic_name"),
            "met": 0,
            "gap": 0,
            "expiring": 0,
        }

    fully_compliant = 0
    has_gaps = 0
    expiring_any = 0

    for m in members:
        snap = doctor_compliance_snapshot(int(m["user_id"]), trust)
        summary = snap.get("summary") or {}
        gaps = int(summary.get("gap") or 0) + int(summary.get("expiring") or 0)
        if gaps == 0 and summary.get("total_topics", 0) > 0:
            fully_compliant += 1
        elif gaps > 0:
            has_gaps += 1
        exp_n = len(snap.get("expiring_credentials") or [])
        if exp_n > 0:
            expiring_any += 1
        for tr in snap.get("topics") or []:
            tkey = str(
                tr.get("topic_id")
                if tr.get("topic_id") is not None
                else tr.get("topic_name") or ""
            )
            if tkey not in topic_agg:
                continue
            st = tr.get("status") or "gap"
            if st == "met":
                topic_agg[tkey]["met"] += 1
            elif st == "expiring":
                topic_agg[tkey]["expiring"] += 1
            else:
                topic_agg[tkey]["gap"] += 1
        member_rows.append(
            {
                "user_id": m["user_id"],
                "display_name": m.get("display_name"),
                "email": m.get("email"),
                "summary": summary,
                "expiring_count": exp_n,
                "fully_compliant": gaps == 0 and (summary.get("total_topics") or 0) > 0,
            }
        )

    return {
        "cohort_id": int(cohort_id),
        "cohort_name": cohort.get("name"),
        "trust": trust,
        "member_count": len(members),
        "summary": {
            "fully_compliant": fully_compliant,
            "has_gaps": has_gaps,
            "expiring_any": expiring_any,
            "total_members": len(members),
        },
        "topics": list(topic_agg.values()),
        "members": member_rows,
    }


def _topic_row_key(tr: dict) -> str:
    return str(
        tr.get("topic_id") if tr.get("topic_id") is not None else tr.get("topic_name") or ""
    )


def _credential_in_expiry_window(cred: dict, window_days: int) -> bool:
    days = cred.get("days_until")
    if days is None:
        return False
    if days < 0:
        return True
    return days <= window_days


def cohort_compliance_matrix(cohort_id: int, hr_trust: str) -> Optional[dict]:
    """Per-member mandatory topic status matrix for cohort CSV export."""
    snap = cohort_compliance_snapshot(cohort_id, hr_trust)
    if not snap:
        return None
    trust = (hr_trust or "").strip()
    topics = sorted(snap.get("topics") or [], key=lambda t: (t.get("topic_name") or "").lower())
    topic_keys = [_topic_row_key(t) for t in topics]
    rows: list[dict] = []
    for m in snap.get("members") or []:
        uid = int(m["user_id"])
        doc = doctor_compliance_snapshot(uid, trust)
        by_key = {_topic_row_key(tr): tr.get("status") or "gap" for tr in doc.get("topics") or []}
        rows.append(
            {
                "user_id": uid,
                "display_name": m.get("display_name"),
                "email": m.get("email"),
                "gmc_number": m.get("gmc_number"),
                "topic_statuses": {k: by_key.get(k, "gap") for k in topic_keys},
                "summary": m.get("summary") or {},
                "expiring_count": m.get("expiring_count") or 0,
            }
        )
    return {
        "cohort_id": snap.get("cohort_id"),
        "cohort_name": snap.get("cohort_name"),
        "trust": trust,
        "topics": topics,
        "rows": rows,
        "summary": snap.get("summary"),
    }


def cohort_compliance_csv(cohort_id: int, hr_trust: str) -> Optional[tuple[str, str]]:
    """Return (filename, csv_text) for cohort mandatory matrix."""
    matrix = cohort_compliance_matrix(cohort_id, hr_trust)
    if not matrix:
        return None
    topics = matrix.get("topics") or []
    topic_names = [(t.get("topic_name") or "Topic").strip() for t in topics]
    buf = io.StringIO()
    writer = csv.writer(buf)
    header = ["Name", "Email", "GMC"] + topic_names + ["Gaps", "Expiring topics", "Fully compliant"]
    writer.writerow(header)
    for row in matrix.get("rows") or []:
        summary = row.get("summary") or {}
        gaps = int(summary.get("gap") or 0)
        expiring = int(summary.get("expiring") or 0)
        fully = gaps == 0 and expiring == 0 and (summary.get("total_topics") or 0) > 0
        statuses = row.get("topic_statuses") or {}
        cells = [
            row.get("display_name") or "",
            row.get("email") or "",
            row.get("gmc_number") or "",
        ]
        for t in topics:
            cells.append(statuses.get(_topic_row_key(t), "gap"))
        cells.extend([gaps, expiring, "yes" if fully else "no"])
        writer.writerow(cells)
    slug = re.sub(r"[^a-z0-9]+", "-", (matrix.get("cohort_name") or "cohort").lower()).strip("-") or "cohort"
    filename = f"{slug}-mandatory-compliance.csv"
    return filename, buf.getvalue()


def trust_expiring_report(
    hr_trust: str,
    *,
    window_days: int = 90,
    cohort_id: Optional[int] = None,
) -> dict:
    """Doctors at trust with credentials expiring within window (from wallet)."""
    trust = (hr_trust or "").strip()
    if not trust:
        return {"trust": None, "items": [], "window_days": window_days, "cohort_id": cohort_id}
    member_ids: Optional[set[int]] = None
    if cohort_id is not None:
        if not db.cohort_get(int(cohort_id), trust):
            return {"trust": trust, "window_days": window_days, "cohort_id": cohort_id, "items": [], "doctor_count": 0}
        member_ids = {int(m["user_id"]) for m in db.cohort_members_list(int(cohort_id), trust)}
    items: list[dict] = []
    with __import__("sqlite3").connect(db.DB_PATH) as conn:
        conn.row_factory = __import__("sqlite3").Row
        rows = conn.execute(
            """
            SELECT id, email, display_name, gmc_number
            FROM users
            WHERE premium = 0 AND LOWER(TRIM(COALESCE(current_trust, ''))) = ?
            """,
            (trust.lower(),),
        ).fetchall()
    for r in rows:
        uid = int(r["id"])
        if member_ids is not None and uid not in member_ids:
            continue
        snap = doctor_compliance_snapshot(uid, trust)
        exp = [
            c
            for c in (snap.get("expiring_credentials") or [])
            if _credential_in_expiry_window(c, window_days)
        ]
        if not exp:
            continue
        items.append(
            {
                "user_id": uid,
                "display_name": r["display_name"],
                "email": r["email"],
                "gmc_number": r["gmc_number"],
                "expiring_credentials": exp,
            }
        )
    items.sort(key=lambda x: (x.get("display_name") or x.get("email") or "").lower())
    return {
        "trust": trust,
        "window_days": window_days,
        "cohort_id": cohort_id,
        "items": items,
        "doctor_count": len(items),
    }
