"""Automatic and manual in-app expiry reminders for mandatory training topics."""
from __future__ import annotations

import logging
import os
from typing import Callable, Optional

from . import compliance_snapshot, db
from .trust_packs import trust_display_name

logger = logging.getLogger(__name__)

REMINDER_STAGES: list[tuple[str, Callable[[Optional[int]], bool]]] = [
    ("30d", lambda d: d is not None and 7 < d <= 30),
    ("7d", lambda d: d is not None and 0 <= d <= 7),
    ("expired", lambda d: d is not None and d < 0),
]


def reminder_stage_for_days(days_until: Optional[int]) -> Optional[str]:
    if days_until is None:
        return None
    for stage, pred in REMINDER_STAGES:
        if pred(days_until):
            return stage
    return None


def _doctor_first_name(doc: dict) -> str:
    display = (doc.get("display_name") or "").strip()
    if display:
        return display.split()[0]
    email = (doc.get("email") or "").strip()
    if email and "@" in email:
        local = email.split("@", 1)[0]
        for sep in (".", "_", "-"):
            if sep in local:
                return local.split(sep, 1)[0].capitalize()
        return local.capitalize()
    return "there"


def _format_cred_line(cred: dict) -> str:
    topic = (cred.get("topic_name") or "").strip()
    name = (cred.get("module_name") or topic or "Training").strip()
    label = name if not topic or topic.lower() == name.lower() else f"{topic} ({name})"
    when = (cred.get("expiry_date") or "")[:10]
    days = cred.get("days_until")
    if days is not None and days < 0:
        extra = " (expired)"
    elif days is not None:
        extra = f" ({days} days remaining)"
    else:
        extra = ""
    return f"• {label} — expires {when}{extra}" if when else f"• {label}{extra}"


def build_expiry_reminder_body(
    doc: dict,
    hr_trust: str,
    due_items: list[tuple[str, dict]],
    *,
    manual: bool = False,
) -> str:
    """Build one consolidated message for mandatory training due at this run."""
    name = _doctor_first_name(doc)
    trust = trust_display_name(hr_trust) or "your trust"

    if manual:
        parts: list[str] = [
            f"Hi {name},",
            "",
            "The following mandatory training is expiring soon or already expired:",
        ]
        parts.extend(_format_cred_line(c) for _, c in due_items)
        parts.append("")
        parts.append(
            "Please complete renewal and add updated evidence to DocPass. "
            "Reply to this message if you need help."
        )
        parts.append("")
        parts.append(f"— {trust} (via DocPass)")
        return "\n".join(parts).strip()

    by_stage: dict[str, list[dict]] = {"30d": [], "7d": [], "expired": []}
    for stage, cred in due_items:
        by_stage.setdefault(stage, []).append(cred)

    parts = [f"Hi {name},"]
    if by_stage["30d"]:
        parts.append("")
        parts.append(
            "The following mandatory training on your DocPass wallet is due to expire within 30 days:"
        )
        parts.extend(_format_cred_line(c) for c in by_stage["30d"])
    if by_stage["7d"]:
        parts.append("")
        parts.append("The following mandatory training expires within 7 days — please renew soon:")
        parts.extend(_format_cred_line(c) for c in by_stage["7d"])
    if by_stage["expired"]:
        parts.append("")
        parts.append("The following mandatory training has expired and needs renewal:")
        parts.extend(_format_cred_line(c) for c in by_stage["expired"])
    parts.append("")
    parts.append(
        "Please complete renewal and add updated evidence to DocPass. "
        "Reply to this message if you need help."
    )
    parts.append("")
    parts.append(f"— {trust} (via DocPass)")
    return "\n".join(parts).strip()


def _due_mandatory_for_auto(
    snap: dict,
    *,
    module_query: Optional[str] = None,
    topic_id: Optional[int] = None,
) -> list[tuple[str, dict]]:
    """Mandatory credentials hitting an automatic reminder milestone."""
    due: list[tuple[str, dict]] = []
    for cred in compliance_snapshot.mandatory_expiring_credentials(
        snap, module_query=module_query, topic_id=topic_id
    ):
        cid = (cred.get("credential_id") or "").strip()
        if not cid:
            continue
        stage = reminder_stage_for_days(cred.get("days_until"))
        if not stage:
            continue
        due.append((stage, cred))
    return due


def _clinicians_in_scope(
    trust: str,
    *,
    cohort_id: Optional[int] = None,
    doctor_user_ids: Optional[list[int]] = None,
) -> list[dict]:
    if doctor_user_ids:
        out: list[dict] = []
        for raw_id in doctor_user_ids:
            doc = db.user_get_by_id(int(raw_id))
            if not doc or db.user_is_premium(doc):
                continue
            if (doc.get("current_trust") or "").strip().lower() != trust.lower():
                continue
            out.append(
                {
                    "id": int(doc["id"]),
                    "email": doc.get("email"),
                    "display_name": doc.get("display_name"),
                    "gmc_number": doc.get("gmc_number"),
                }
            )
        return out

    if cohort_id is not None:
        if not db.cohort_get(int(cohort_id), trust):
            return []
        member_ids = {int(m["user_id"]) for m in db.cohort_members_list(int(cohort_id), trust)}
        return [c for c in db.clinicians_at_trust(trust) if int(c["id"]) in member_ids]

    return db.clinicians_at_trust(trust)


def send_automatic_expiry_reminders(
    *,
    module_query: Optional[str] = None,
    topic_id: Optional[int] = None,
) -> dict:
    """
    Daily job: message clinicians when mandatory training hits 30d, 7d, or expired milestones.
    """
    if os.environ.get("HR_EXPIRY_REMINDERS_ENABLED", "1").strip().lower() in (
        "0",
        "false",
        "no",
        "off",
    ):
        return {"skipped": True, "reason": "HR_EXPIRY_REMINDERS_ENABLED is off"}

    env_filter = (os.environ.get("EXPIRY_REMINDER_MODULE_QUERY") or "").strip() or None
    effective_filter = module_query if module_query is not None else env_filter

    trusts_seen: set[str] = set()
    messages_sent = 0
    credentials_reminded = 0
    clinicians_messaged = 0
    errors = 0

    for hr_user in db.hr_premium_users_list():
        trust = (hr_user.get("current_trust") or "").strip()
        if not trust:
            continue
        trust_key = trust.lower()
        if trust_key in trusts_seen:
            continue
        trusts_seen.add(trust_key)

        if not db.trust_expiry_reminders_enabled(trust):
            continue

        sender = db.hr_message_sender_for_trust(trust)
        if not sender:
            continue

        for clinician in db.clinicians_at_trust(trust):
            uid = int(clinician["id"])
            doc = db.user_get_by_id(uid)
            if not doc:
                continue

            snap = compliance_snapshot.doctor_compliance_snapshot(uid, trust)
            due: list[tuple[str, dict]] = []
            for stage, cred in _due_mandatory_for_auto(
                snap, module_query=effective_filter, topic_id=topic_id
            ):
                cid = (cred.get("credential_id") or "").strip()
                if db.expiry_reminder_was_sent(uid, cid, stage):
                    continue
                due.append((stage, cred))

            if not due:
                continue

            body = build_expiry_reminder_body(doc, trust, due)
            try:
                conv = db.conversation_get_or_create(uid, trust)
                db.message_send_body(int(conv["id"]), int(sender["id"]), body)
                messages_sent += 1
                clinicians_messaged += 1
                for stage, cred in due:
                    db.expiry_reminder_mark_sent(
                        hr_trust=trust,
                        doctor_user_id=uid,
                        credential_id=cred.get("credential_id") or "",
                        stage=stage,
                        module_name=cred.get("module_name"),
                    )
                    credentials_reminded += 1
            except Exception:
                errors += 1
                logger.exception(
                    "Failed expiry reminder for doctor %s at trust %s", uid, trust
                )

    return {
        "trusts_processed": len(trusts_seen),
        "messages_sent": messages_sent,
        "clinicians_messaged": clinicians_messaged,
        "credentials_reminded": credentials_reminded,
        "errors": errors,
        "module_filter": effective_filter,
        "scope": "mandatory",
    }


def send_manual_expiry_reminders(
    hr_trust: str,
    hr_user_id: int,
    *,
    window_days: int = 30,
    cohort_id: Optional[int] = None,
    module_query: Optional[str] = None,
    topic_id: Optional[int] = None,
    doctor_user_ids: Optional[list[int]] = None,
) -> dict:
    """
    HR-triggered reminders for mandatory training in the selected expiry window.
    Does not affect automatic milestone deduplication.
    """
    trust = (hr_trust or "").strip()
    if not trust:
        return {"sent": 0, "failed": [], "scope": "mandatory"}

    clinicians = _clinicians_in_scope(
        trust, cohort_id=cohort_id, doctor_user_ids=doctor_user_ids
    )
    sent = 0
    failed: list[dict] = []
    credentials_included = 0

    for clinician in clinicians:
        uid = int(clinician["id"])
        doc = db.user_get_by_id(uid)
        if not doc:
            failed.append({"doctor_user_id": uid, "error": "clinician not found"})
            continue

        snap = compliance_snapshot.doctor_compliance_snapshot(uid, trust)
        creds = compliance_snapshot.mandatory_expiring_credentials(
            snap,
            window_days=window_days,
            topic_id=topic_id,
            module_query=module_query,
        )
        if not creds:
            continue

        due = [("manual", c) for c in creds]
        body = build_expiry_reminder_body(doc, trust, due, manual=True)
        try:
            conv = db.conversation_get_or_create(uid, trust)
            db.message_send_body(int(conv["id"]), int(hr_user_id), body)
            sent += 1
            credentials_included += len(creds)
        except Exception as e:
            failed.append({"doctor_user_id": uid, "error": str(e)})

    return {
        "sent": sent,
        "failed": failed,
        "credentials_included": credentials_included,
        "scope": "mandatory",
    }
