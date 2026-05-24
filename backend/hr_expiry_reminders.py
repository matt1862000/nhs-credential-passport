"""Automatic in-app expiry reminders from HR to clinicians (no manual send)."""
from __future__ import annotations

import logging
import os
from typing import Callable, Optional

from . import compliance_snapshot, db
from .trust_packs import trust_display_name

logger = logging.getLogger(__name__)

# (stage_key, human label for message section)
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
    name = (cred.get("module_name") or "Training").strip()
    when = (cred.get("expiry_date") or "")[:10]
    days = cred.get("days_until")
    if days is not None and days < 0:
        extra = " (expired)"
    elif days is not None:
        extra = f" ({days} days remaining)"
    else:
        extra = ""
    return f"• {name} — expires {when}{extra}" if when else f"• {name}{extra}"


def build_expiry_reminder_body(
    doc: dict,
    hr_trust: str,
    due_items: list[tuple[str, dict]],
) -> str:
    """Build one consolidated message for all credentials due at this run."""
    name = _doctor_first_name(doc)
    trust = trust_display_name(hr_trust) or "your trust"
    by_stage: dict[str, list[dict]] = {"30d": [], "7d": [], "expired": []}
    for stage, cred in due_items:
        by_stage.setdefault(stage, []).append(cred)

    parts: list[str] = [f"Hi {name},"]
    if by_stage["30d"]:
        parts.append("")
        parts.append("The following training on your DocPass wallet is due to expire within 30 days:")
        parts.extend(_format_cred_line(c) for c in by_stage["30d"])
    if by_stage["7d"]:
        parts.append("")
        parts.append("The following training expires within 7 days — please renew soon:")
        parts.extend(_format_cred_line(c) for c in by_stage["7d"])
    if by_stage["expired"]:
        parts.append("")
        parts.append("The following training has expired and needs renewal:")
        parts.extend(_format_cred_line(c) for c in by_stage["expired"])
    parts.append("")
    parts.append(
        "Please complete renewal and add updated evidence to DocPass. "
        "Reply to this message if you need help."
    )
    parts.append("")
    parts.append(f"— {trust} (via DocPass)")
    return "\n".join(parts).strip()


def _module_matches_filter(module_name: Optional[str], module_query: Optional[str]) -> bool:
    q = (module_query or "").strip().lower()
    if not q:
        return True
    nm = (module_name or "").lower()
    return q in nm


def send_automatic_expiry_reminders(
    *,
    module_query: Optional[str] = None,
) -> dict:
    """
    Daily job: message clinicians whose wallet records hit 30d, 7d, or expired milestones.
    Returns summary counts for logging/monitoring.
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
            for cred in snap.get("expiring_credentials") or []:
                cid = (cred.get("credential_id") or "").strip()
                if not cid:
                    continue
                if not _module_matches_filter(cred.get("module_name"), effective_filter):
                    continue
                stage = reminder_stage_for_days(cred.get("days_until"))
                if not stage:
                    continue
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
    }
