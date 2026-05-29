"""
Compliance snapshot: mandatory topics vs wallet, expiry, HR verification status.
Shared by doctor and HR cohort APIs (Phase 0).
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
from . import decision_engine
from . import mandatory_matching
from . import trust_packs


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
        "completion_date": (c.get("completion_date") or c.get("completed_at") or "").strip()[:10] or None,
        "credential_id": c.get("credential_id"),
        "module_name_display": c.get("module_name"),
        "issuing_trust_name": c.get("issuing_trust_name"),
        "_raw": c,
    }


def _wallet_payloads(wallet: list[dict]) -> list[dict]:
    out: list[dict] = []
    for c in wallet:
        pl = _cred_payload(c)
        if pl:
            out.append(pl)
    return out


def _expiry_status(expiry_date: Optional[str], *, warn_days: int = 90) -> str:
    return mandatory_matching._expiry_bucket(expiry_date, warn_days=warn_days)


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


def _decision_lookup_key(topic_id: Optional[int], topic_name: str, credential_id: str) -> str:
    tid = topic_id if topic_id is not None else (topic_name or "").strip()
    return f"{tid}::{credential_id}"


def _apply_hr_fit_decision(row: dict[str, Any], decision: Optional[dict]) -> dict[str, Any]:
    if not decision:
        return row
    dec = (decision.get("decision") or "").lower()
    topic_name = (row.get("topic_name") or "").strip()
    module_name = (row.get("module_name") or "").strip()
    expiry_bucket = row.get("expiry_status") or "met"
    out = dict(row)
    out["hr_fit_decision"] = dec
    out["hr_fit_decided_at"] = decision.get("decided_at")
    if dec == "accepted":
        if expiry_bucket == "expired":
            out.update(
                {
                    "status": "gap",
                    "status_label": "Expired",
                    "match_type": "hr_confirmed",
                    "reason": f"HR confirmed requirement fit, but record expired: {module_name or topic_name}",
                }
            )
        elif expiry_bucket == "expiring":
            out.update(
                {
                    "status": "expiring",
                    "status_label": "Met (expiring soon)",
                    "match_type": "hr_confirmed",
                    "reason": f"HR confirmed {module_name or 'this record'} satisfies {topic_name}",
                }
            )
        else:
            out.update(
                {
                    "status": "met",
                    "status_label": "Met (HR confirmed)",
                    "match_type": "hr_confirmed",
                    "reason": f"HR confirmed {module_name or 'this record'} satisfies {topic_name}",
                }
            )
    elif dec == "rejected":
        out.update(
            {
                "status": "gap",
                "status_label": "No match",
                "match_type": "none",
                "reason": f"HR confirmed {module_name or 'this record'} does not satisfy {topic_name}",
            }
        )
    return out


def _topic_needs_hr_fit_review_row(tr: dict) -> bool:
    if tr.get("hr_fit_decision"):
        return False
    # Anything the decision engine flagged as REQUIRES_REVIEW needs an
    # explicit HR fit decision — including HR-verified exact matches
    # whose status_label is "Met (exact match)". Evidence verification
    # is not fit confirmation.
    if tr.get("decision") == decision_engine.DECISION_REQUIRES_REVIEW:
        return True
    return mandatory_matching.topic_needs_hr_fit_review(
        tr.get("match_type"),
        tr.get("status_label"),
    )


def _summary_counts(topic_rows: list[dict]) -> dict[str, int]:
    n_met = n_expiring = n_gap = n_needs_review = n_possible = 0
    for tr in topic_rows:
        legacy = tr.get("status") or "gap"
        label = tr.get("status_label") or ""
        if legacy == "met":
            n_met += 1
            if label == "Met (possible match)":
                n_possible += 1
        elif legacy == "expiring":
            n_expiring += 1
        else:
            n_gap += 1
            if _topic_needs_hr_fit_review_row(tr):
                n_needs_review += 1
    return {
        "met": n_met,
        "expiring": n_expiring,
        "gap": n_gap,
        "needs_review": n_needs_review,
        "possible_match": n_possible,
    }


def _decision_stats_for_match(
    topic: dict,
    result: dict[str, Any],
    trust_name: Optional[str],
) -> tuple[Optional[dict], Optional[dict]]:
    """Trust-scoped and cross-trust rollup stats for one topic + credential title."""
    if not trust_name:
        return None, None
    module_name = (result.get("module_name") or "").strip()
    topic_name = (topic.get("topic_name") or "").strip()
    if not module_name or not topic_name:
        return None, None
    trust_stats = db.training_decision_stats_lookup(topic_name, module_name, trust_name)
    cross_stats = db.training_decision_acceptance_rate_cross_trust(topic_name, module_name)
    return trust_stats, cross_stats


def _topic_result_row(
    t: dict,
    result: dict[str, Any],
    verified_map: dict,
    *,
    rec_hints: Optional[dict] = None,
    trust_name: Optional[str] = None,
    include_decision_envelope: bool = False,
) -> dict[str, Any]:
    cid = result.get("credential_id")
    hr_st = _hr_status_for_credential(verified_map, cid)
    reason = result.get("reason") or ""
    from_leaving = False
    cred = result.get("credential")
    if cred and rec_hints:
        pl = _cred_payload(cred)
        if pl and _credential_from_leaving_trust(pl, rec_hints):
            from_leaving = True
            if (result.get("status_label") or "").startswith("Met") and "leaving trust" not in reason.lower():
                reason = f"{reason} Issuer matches your leaving trust."
    row: dict[str, Any] = {
        "topic_id": t.get("id"),
        "topic_name": t.get("topic_name"),
        "category": t.get("category"),
        "delivery_channel": t.get("delivery_channel"),
        "resource_url": t.get("resource_url"),
        "status": result.get("status"),
        "status_label": result.get("status_label"),
        "match_type": result.get("match_type"),
        "confidence_score": result.get("confidence_score"),
        "confidence_label": result.get("confidence_label"),
        "reason": reason,
        "portability": result.get("portability"),
        "partial_hint": result.get("partial_hint"),
        "credential_id": cid,
        "module_name": result.get("module_name"),
        "expiry_date": result.get("expiry_date"),
        "expiry_status": result.get("expiry_status"),
        "hr_status": hr_st,
        "from_leaving_trust": from_leaving,
    }
    if include_decision_envelope:
        trust_stats, cross_stats = _decision_stats_for_match(t, result, trust_name)
        cred_raw = cred if isinstance(cred, dict) else None
        row.update(
            decision_engine.build_decision_envelope(
                result,
                t,
                cred_raw,
                trust_name=trust_name,
                trust_stats=trust_stats,
                cross_trust_stats=cross_stats,
                hr_verified=(hr_st == "VERIFIED"),
            )
        )
    return row


def _pack_example_to_topic(ex: dict) -> dict:
    label = (ex.get("label") or ex.get("id") or "").strip()
    subs = list(ex.get("match_name_substrings") or [])
    if label and label not in subs:
        subs.insert(0, label)
    rules = ex.get("rules") if isinstance(ex.get("rules"), dict) else {}
    return {
        "topic_name": label,
        "category": ex.get("category"),
        "rules": rules,
        "match_hints": {
            "match_module_codes": ex.get("match_module_codes") or [],
            "match_name_substrings": subs,
            "partial_module_codes": ex.get("partial_module_codes") or [],
            "partial_name_substrings": ex.get("partial_name_substrings") or [],
            "partial_hint": ex.get("partial_hint"),
        },
    }


def _recognition_hints_for_leaving(pack: dict, leaving_trust: Optional[str]) -> dict:
    rec_map = pack.get("recognition_when_joining") or {}
    leaving = (leaving_trust or "").strip()
    if leaving:
        leave_pack = trust_packs.pack_id_for_trust_name(leaving)
        if leave_pack and leave_pack in rec_map:
            return rec_map[leave_pack] or {}
        low = leaving.lower()
        for key, val in rec_map.items():
            if str(key).startswith("_"):
                continue
            if str(key).lower() in low or low in str(key).lower():
                return val or {}
    return rec_map.get("_default") or {}


def _credential_from_leaving_trust(pl: dict, rec_hints: dict) -> bool:
    if not pl or not rec_hints:
        return False
    blob = f"{pl.get('issuing_trust_name') or ''} {pl.get('issuing_trust_ods') or ''}".lower()
    for hint in rec_hints.get("issuer_trust_name_hints") or []:
        if str(hint).lower() in blob:
            return True
    ods = (pl.get("issuing_trust_ods") or "").upper()
    for hint in rec_hints.get("issuer_ods_hints") or []:
        if ods == str(hint).upper():
            return True
    return False


def pack_checklist_preview(
    doctor_user_id: int,
    pack_id: str,
    *,
    leaving_trust: Optional[str] = None,
) -> Optional[dict]:
    """Match destination trust pack mandatory examples against doctor wallet."""
    pack = trust_packs.load_trust_pack((pack_id or "").strip())
    if not pack:
        return None
    wallet = _parse_wallet(db.user_wallet_get(int(doctor_user_id)))
    payloads = _wallet_payloads(wallet)
    verified_map = db.doctor_verified_map(int(doctor_user_id))
    rec_hints = _recognition_hints_for_leaving(pack, leaving_trust)

    pack_key = (pack_id or "").strip()
    topics = [_pack_example_to_topic(ex) for ex in pack.get("mandatory_examples") or []]
    mandatory_matching.prepare_semantic_match_cache(pack_key, topics)
    topic_rows: list[dict] = []
    for ex in pack.get("mandatory_examples") or []:
        topic = _pack_example_to_topic(ex)
        result = mandatory_matching.match_topic_to_wallet(
            topic, payloads, pack_key=pack_key, pack_topics=topics
        )
        dest_trust = (pack.get("display_name") or pack.get("pack_id") or "").strip() or None
        topic_rows.append(
            _topic_result_row(
                topic,
                result,
                verified_map,
                rec_hints=rec_hints,
                trust_name=dest_trust,
                include_decision_envelope=True,
            )
        )

    summary = _summary_counts(topic_rows)
    summary["total_topics"] = len(topic_rows)
    rec = _recognition_hints_for_leaving(pack, leaving_trust)

    return {
        "pack_id": (pack_id or "").strip(),
        "display_name": pack.get("display_name"),
        "disclaimer": pack.get("disclaimer"),
        "leaving_trust": (leaving_trust or "").strip() or None,
        "recognition_summary": rec.get("summary"),
        "topics": topic_rows,
        "summary": summary,
        "decision_engine_version": decision_engine.ENGINE_VERSION,
    }


def doctor_compliance_snapshot(
    doctor_user_id: int,
    trust_name: str,
    *,
    include_decision_envelope: bool = False,
) -> dict:
    """Mandatory topics vs wallet for one doctor at a trust."""
    trust = (trust_name or "").strip()
    topics = db.mandatory_topics_list(trust) if trust else []
    wallet = _parse_wallet(db.user_wallet_get(int(doctor_user_id)))
    payloads = _wallet_payloads(wallet)
    verified_map = db.doctor_verified_map(int(doctor_user_id))

    pack_key = trust
    mandatory_matching.prepare_semantic_match_cache(pack_key, topics)
    fit_decisions = db.mandatory_match_decisions_map(int(doctor_user_id), trust)
    topic_rows: list[dict] = []
    for t in topics:
        result = mandatory_matching.match_topic_to_wallet(
            t, payloads, pack_key=pack_key, pack_topics=topics
        )
        row = _topic_result_row(
            t,
            result,
            verified_map,
            trust_name=trust,
            include_decision_envelope=include_decision_envelope,
        )
        cid = row.get("credential_id")
        if cid:
            dkey = _decision_lookup_key(row.get("topic_id"), row.get("topic_name") or "", str(cid))
            row = _apply_hr_fit_decision(row, fit_decisions.get(dkey))
        topic_rows.append(row)

    summary = _summary_counts(topic_rows)
    summary["total_topics"] = len(topics)

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

    out: dict[str, Any] = {
        "trust": trust or None,
        "topics": topic_rows,
        "summary": summary,
        "expiring_credentials": expiring_creds,
        "hr_verification": vm_counts,
    }
    if include_decision_envelope:
        out["decision_engine_version"] = decision_engine.ENGINE_VERSION
    return out


def fit_review_wallet_items(
    doctor_user_id: int,
    fit_map: dict[str, list[dict]],
    existing_credential_ids: set[str],
) -> list[dict]:
    """Share-style rows for wallet credentials needing fit review but absent from the inbox queue."""
    wallet = _parse_wallet(db.user_wallet_get(int(doctor_user_id)))
    verified_map = db.doctor_verified_map(int(doctor_user_id))
    out: list[dict] = []
    for cid, topics in (fit_map or {}).items():
        cid_s = str(cid)
        if cid_s in existing_credential_ids:
            continue
        wallet_row = next(
            (
                c
                for c in wallet
                if isinstance(c, dict)
                and not c.get("revoked")
                and str(c.get("credential_id") or "") == cid_s
            ),
            None,
        )
        if not wallet_row:
            continue
        ent = verified_map.get(cid_s) or verified_map.get(cid) or {}
        st = (ent.get("status") or "NOT_SHARED").upper()
        if st not in ("VERIFIED", "DECLINED", "PENDING"):
            st = "NOT_SHARED"
        out.append(
            {
                "credential_id": cid_s,
                "module_name": wallet_row.get("module_name"),
                "expiry_date": wallet_row.get("expiry_date"),
                "status": st,
                "issuing_trust_name": wallet_row.get("issuing_trust_name"),
                "certificate_base64": wallet_row.get("certificate_base64"),
                "certificate_filename": wallet_row.get("certificate_filename"),
                "mandatory_needs_review": topics,
                "fit_review_only": True,
            }
        )
    return out


def fit_review_pending_credential_ids(
    doctor_user_id: int, trust_name: str
) -> list[str]:
    """Credential IDs that are HR-VERIFIED at this trust AND still have at least
    one mandatory topic awaiting HR fit-review (post-verification portability
    check). Used by the doctor's training wallet to show a "HR confirming fit"
    chip next to "Verified by HR" while HR is still judging whether the
    credential satisfies a trust requirement.
    """
    trust = (trust_name or "").strip()
    if not trust:
        return []
    verified_map = db.doctor_verified_map(int(doctor_user_id))
    verified_ids: set[str] = set()
    for k, v in (verified_map or {}).items():
        ent = v or {}
        status = str(ent.get("status") or "").upper().strip()
        if ent.get("shared") and status == "VERIFIED":
            verified_ids.add(str(k))
    if not verified_ids:
        return []
    fit_map = mandatory_needs_review_by_credential(int(doctor_user_id), trust)
    return sorted(verified_ids & {str(k) for k in (fit_map or {}).keys()})


def mandatory_needs_review_by_credential(doctor_user_id: int, trust_name: str) -> dict[str, list[dict]]:
    """Map credential_id → mandatory topics where requirement fit is uncertain (partial/semantic)."""
    snap = doctor_compliance_snapshot(
        int(doctor_user_id), trust_name, include_decision_envelope=True
    )
    out: dict[str, list[dict]] = {}
    for tr in snap.get("topics") or []:
        if not _topic_needs_hr_fit_review_row(tr):
            continue
        cid = tr.get("credential_id")
        if not cid:
            continue
        key = str(cid)
        out.setdefault(key, []).append(
            {
                "topic_id": tr.get("topic_id"),
                "topic_name": tr.get("topic_name"),
                "reason": tr.get("reason"),
                "module_name": tr.get("module_name"),
                "match_type": tr.get("match_type"),
                "status_label": tr.get("status_label"),
                # Full decision envelope — HR needs the same detail as doctors
                # (they're the ones making the accept/reject call).
                "decision": tr.get("decision"),
                "decision_confidence": tr.get("decision_confidence"),
                "decision_confidence_label": tr.get("decision_confidence_label"),
                "decision_confidence_reason": tr.get("decision_confidence_reason"),
                "decision_score": tr.get("decision_score"),
                "decision_reason": tr.get("decision_reason"),
                "decision_factors": tr.get("decision_factors"),
                "is_exact_match": tr.get("is_exact_match"),
                "match_label": tr.get("match_label"),
                "historical_context": tr.get("historical_context"),
                "historical_acceptance_hint": tr.get("historical_acceptance_hint"),
                "decision_engine_version": tr.get("decision_engine_version"),
                # Raw signal block — surfaced to HR only so the
                # "How this was assessed" audit panel can show category
                # alignment, validity, provider trust and similarity.
                # Doctor surfaces never receive this field.
                "signals": tr.get("signals"),
            }
        )
    return out


def trust_mandatory_needs_review_summary(hr_trust: str) -> dict[str, int]:
    """Trust-wide counts for mandatory topics needing HR requirement-fit judgement."""
    trust = (hr_trust or "").strip()
    if not trust:
        return {"clinicians_needing_review": 0, "mandatory_topics_needing_review": 0}
    clinicians = 0
    topic_items = 0
    with __import__("sqlite3").connect(db.DB_PATH) as conn:
        conn.row_factory = __import__("sqlite3").Row
        rows = conn.execute(
            """
            SELECT id FROM users
            WHERE premium = 0 AND LOWER(TRIM(COALESCE(current_trust, ''))) = ?
            """,
            (trust.lower(),),
        ).fetchall()
    for r in rows:
        summary = (doctor_compliance_snapshot(int(r["id"]), trust).get("summary") or {})
        n = int(summary.get("needs_review") or 0)
        if n > 0:
            clinicians += 1
            topic_items += n
    return {
        "clinicians_needing_review": clinicians,
        "mandatory_topics_needing_review": topic_items,
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
            "needs_review": 0,
        }

    fully_compliant = 0
    has_gaps = 0
    expiring_any = 0
    needs_review_any = 0

    for m in members:
        snap = doctor_compliance_snapshot(int(m["user_id"]), trust)
        summary = snap.get("summary") or {}
        gaps = int(summary.get("gap") or 0) + int(summary.get("expiring") or 0)
        needs_review_n = int(summary.get("needs_review") or 0)
        if needs_review_n > 0:
            needs_review_any += 1
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
                if _topic_needs_hr_fit_review_row(tr):
                    topic_agg[tkey]["needs_review"] += 1
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
            "needs_review_any": needs_review_any,
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


def mandatory_expiring_credentials(
    snap: dict,
    *,
    window_days: Optional[int] = None,
    topic_id: Optional[int] = None,
    module_query: Optional[str] = None,
) -> list[dict]:
    """
    Wallet credentials tied to mandatory topics that are expiring or expired.
    Dedupes by credential_id; optional filters by expiry window, topic, or name substring.
    """
    mq = (module_query or "").strip().lower() or None
    items: list[dict] = []
    seen: set[str] = set()
    for tr in snap.get("topics") or []:
        cid = tr.get("credential_id")
        if not cid:
            continue
        cid_s = str(cid)
        if cid_s in seen:
            continue
        if tr.get("expiry_status") not in ("expiring", "expired"):
            continue
        tid = tr.get("topic_id")
        if topic_id is not None and tid is not None and int(tid) != int(topic_id):
            continue
        topic_name = (tr.get("topic_name") or "").strip()
        module_name = (tr.get("module_name") or topic_name or "Training").strip()
        if mq:
            hay = f"{topic_name} {module_name}".lower()
            if mq not in hay:
                continue
        expiry_date = tr.get("expiry_date")
        days = _days_until(expiry_date)
        cred = {
            "credential_id": cid_s,
            "module_name": module_name,
            "topic_id": tid,
            "topic_name": topic_name,
            "expiry_date": expiry_date,
            "status": "expired" if tr.get("expiry_status") == "expired" else "expiring",
            "days_until": days,
        }
        if window_days is not None and not _credential_in_expiry_window(cred, window_days):
            continue
        seen.add(cid_s)
        items.append(cred)
    items.sort(key=lambda x: (x.get("days_until") is None, x.get("days_until") or 99999))
    return items


def mandatory_matched_credential_ids(snap: dict) -> set[str]:
    """Credential IDs linked to any mandatory topic match (exact, alias, or partial)."""
    ids: set[str] = set()
    for tr in snap.get("topics") or []:
        cid = tr.get("credential_id")
        if not cid:
            continue
        if (tr.get("match_type") or "none") == "none":
            continue
        ids.add(str(cid))
    return ids


def non_mandatory_expiring_credentials(
    snap: dict,
    *,
    window_days: Optional[int] = None,
    module_query: Optional[str] = None,
) -> list[dict]:
    """
    Wallet records expiring or expired that do not match any mandatory topic.
    These are not covered by automatic mandatory reminders.
    """
    mq = (module_query or "").strip().lower() or None
    mandatory_ids = mandatory_matched_credential_ids(snap)
    items: list[dict] = []
    seen: set[str] = set()
    for c in snap.get("expiring_credentials") or []:
        cid_s = str(c.get("credential_id") or "")
        if not cid_s or cid_s in seen or cid_s in mandatory_ids:
            continue
        module_name = (c.get("module_name") or "Training").strip()
        if mq and mq not in module_name.lower():
            continue
        if window_days is not None and not _credential_in_expiry_window(c, window_days):
            continue
        seen.add(cid_s)
        items.append(
            {
                "credential_id": cid_s,
                "module_name": module_name,
                "expiry_date": c.get("expiry_date"),
                "status": c.get("status"),
                "days_until": c.get("days_until"),
            }
        )
    items.sort(key=lambda x: (x.get("days_until") is None, x.get("days_until") or 99999))
    return items


def trust_mandatory_topics_summary(trust: str) -> list[dict]:
    """Lightweight topic list for HR expiring report filters."""
    return [
        {"id": int(t["id"]), "topic_name": t.get("topic_name") or ""}
        for t in db.mandatory_topics_list(trust)
        if t.get("id") is not None
    ]


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
        by_key = {_topic_row_key(tr): tr.get("status_label") or tr.get("status") or "gap" for tr in doc.get("topics") or []}
        rows.append(
            {
                "user_id": uid,
                "display_name": m.get("display_name"),
                "email": m.get("email"),
                "gmc_number": m.get("gmc_number"),
                "topic_statuses": {k: by_key.get(k, "No match") for k in topic_keys},
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
    header = ["Name", "Email", "GMC"] + topic_names + ["Needs review", "Gaps", "Expiring topics", "Fully compliant"]
    writer.writerow(header)
    for row in matrix.get("rows") or []:
        summary = row.get("summary") or {}
        gaps = int(summary.get("gap") or 0)
        expiring = int(summary.get("expiring") or 0)
        needs_review = int(summary.get("needs_review") or 0)
        fully = gaps == 0 and expiring == 0 and (summary.get("total_topics") or 0) > 0
        statuses = row.get("topic_statuses") or {}
        cells = [
            row.get("display_name") or "",
            row.get("email") or "",
            row.get("gmc_number") or "",
        ]
        for t in topics:
            cells.append(statuses.get(_topic_row_key(t), "No match"))
        cells.extend([needs_review, gaps, expiring, "yes" if fully else "no"])
        writer.writerow(cells)
    slug = re.sub(r"[^a-z0-9]+", "-", (matrix.get("cohort_name") or "cohort").lower()).strip("-") or "cohort"
    filename = f"{slug}-mandatory-compliance.csv"
    return filename, buf.getvalue()


def trust_expiring_report(
    hr_trust: str,
    *,
    window_days: int = 90,
    cohort_id: Optional[int] = None,
    module_query: Optional[str] = None,
    topic_id: Optional[int] = None,
    scope: str = "mandatory",
) -> dict:
    """Doctors at trust with expiring training in the chosen scope (mandatory or other)."""
    trust = (hr_trust or "").strip()
    mq = (module_query or "").strip().lower() or None
    scope_key = (scope or "mandatory").strip().lower()
    if scope_key not in ("mandatory", "other"):
        scope_key = "mandatory"
    if not trust:
        return {
            "trust": None,
            "items": [],
            "window_days": window_days,
            "cohort_id": cohort_id,
            "module_query": module_query,
            "topic_id": topic_id,
            "scope": scope_key,
            "mandatory_topics": [],
        }
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
        if scope_key == "other":
            exp = non_mandatory_expiring_credentials(
                snap,
                window_days=window_days,
                module_query=mq,
            )
        else:
            exp = mandatory_expiring_credentials(
                snap,
                window_days=window_days,
                topic_id=topic_id,
                module_query=mq,
            )
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
        "module_query": module_query,
        "topic_id": topic_id,
        "scope": scope_key,
        "mandatory_topics": trust_mandatory_topics_summary(trust) if scope_key == "mandatory" else [],
        "items": items,
        "doctor_count": len(items),
        "auto_reminders_enabled": db.trust_expiry_reminders_enabled(trust),
        "manual_send_available": scope_key == "other",
    }
