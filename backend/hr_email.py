"""HR email digests and instant alerts for verification inbox activity."""
import html
import logging
import os
from typing import Optional

from . import db
from .email_service import send_email

logger = logging.getLogger(__name__)


def _app_base_url() -> str:
    return (os.environ.get("BASE_URL") or "https://docpass.co.uk").rstrip("/")


def _inbox_url() -> str:
    return f"{_app_base_url()}/static/hr/"


def _messages_url() -> str:
    return f"{_app_base_url()}/static/hr/messages/"


def _prefs_url() -> str:
    return f"{_app_base_url()}/static/profile/#email-notifications"


def _hr_recipient_name(hr_user: dict) -> str:
    name = (hr_user.get("display_name") or "").strip()
    if name:
        return name
    email = (hr_user.get("email") or "").strip()
    return email.split("@")[0] if email else "HR colleague"


def _trust_label(hr_user: dict) -> str:
    return (hr_user.get("current_trust") or "").strip() or "your trust"


def _format_digest_bodies(hr_user: dict, stats: dict) -> tuple[str, str, str]:
    """Return (subject, text_body, html_body)."""
    trust = _trust_label(hr_user)
    pending_sessions = int(stats.get("pending_sessions") or 0)
    pending_items = int(stats.get("pending_items") or 0)
    unread_messages = int(stats.get("unread_messages") or 0)
    inbox = _inbox_url()
    messages = _messages_url()
    prefs = _prefs_url()

    subject = f"DocPass daily summary — {pending_items} pending, {unread_messages} unread messages"

    lines = [
        f"Hello {_hr_recipient_name(hr_user)},",
        "",
        f"Your DocPass summary for {trust}:",
        "",
        f"• Pending verifications: {pending_items} record(s) across {pending_sessions} shared set(s)",
        f"• Unread messages from clinicians: {unread_messages}",
        "",
        f"Open verification inbox: {inbox}",
        f"Open messages: {messages}",
        "",
        f"Manage email preferences: {prefs}",
        "",
        "— DocPass",
    ]
    text_body = "\n".join(lines)

    html_body = f"""<!DOCTYPE html>
<html><body style="font-family: Arial, sans-serif; line-height: 1.5; color: #212b32;">
<p>Hello {html.escape(_hr_recipient_name(hr_user))},</p>
<p>Your DocPass summary for <strong>{html.escape(trust)}</strong>:</p>
<ul>
  <li><strong>{pending_items}</strong> training record(s) awaiting verification across <strong>{pending_sessions}</strong> shared set(s)</li>
  <li><strong>{unread_messages}</strong> unread message(s) from clinicians</li>
</ul>
<p>
  <a href="{html.escape(inbox)}">Open verification inbox</a><br>
  <a href="{html.escape(messages)}">Open messages</a>
</p>
<p style="font-size: 0.875rem; color: #4c6272;">
  <a href="{html.escape(prefs)}">Email notification preferences</a>
</p>
<p>— DocPass</p>
</body></html>"""

    return subject, text_body, html_body


def _format_instant_bodies(
    hr_user: dict,
    *,
    pending_items: int,
    session_id: int,
) -> tuple[str, str, str]:
    trust = _trust_label(hr_user)
    inbox = f"{_inbox_url()}?session={int(session_id)}"
    prefs = _prefs_url()
    subject = f"DocPass: new training shared for verification ({pending_items} record(s))"
    text_body = "\n".join(
        [
            f"Hello {_hr_recipient_name(hr_user)},",
            "",
            f"A clinician has shared {pending_items} training record(s) for HR verification at {trust}.",
            "",
            f"Review now: {inbox}",
            "",
            f"Manage email preferences: {prefs}",
            "",
            "— DocPass",
        ]
    )
    html_body = f"""<!DOCTYPE html>
<html><body style="font-family: Arial, sans-serif; line-height: 1.5; color: #212b32;">
<p>Hello {html.escape(_hr_recipient_name(hr_user))},</p>
<p>A clinician has shared <strong>{pending_items}</strong> training record(s) for HR verification at {html.escape(trust)}.</p>
<p><a href="{html.escape(inbox)}">Review in DocPass</a></p>
<p style="font-size: 0.875rem; color: #4c6272;">
  <a href="{html.escape(prefs)}">Email notification preferences</a>
</p>
<p>— DocPass</p>
</body></html>"""
    return subject, text_body, html_body


def send_daily_digests(*, skip_if_empty: bool = True) -> int:
    """Email all HR users with digest enabled. Returns count of emails sent."""
    sent = 0
    for hr_user in db.hr_premium_users_list():
        if not hr_user.get("hr_email_digest_enabled", True):
            continue
        trust = (hr_user.get("current_trust") or "").strip()
        if not trust:
            continue
        stats = db.hr_inbox_activity_summary(trust)
        pending_items = int(stats.get("pending_items") or 0)
        unread_messages = int(stats.get("unread_messages") or 0)
        if skip_if_empty and pending_items == 0 and unread_messages == 0:
            continue
        subject, text_body, html_body = _format_digest_bodies(hr_user, stats)
        if send_email(to=hr_user["email"], subject=subject, text_body=text_body, html_body=html_body):
            sent += 1
    return sent


def notify_new_share_for_hr(
    *,
    target_trust: Optional[str],
    session_id: int,
    pending_items: int,
    share_kind: str = "review",
) -> int:
    """
    Instant email to HR users at target_trust when a clinician submits for verification.
    Returns count of emails sent.
    """
    if (share_kind or "review").strip().lower() != "review":
        return 0
    if int(pending_items) <= 0:
        return 0
    trust = (target_trust or "").strip()
    if not trust:
        return 0

    sent = 0
    for hr_user in db.hr_premium_users_for_trust(trust):
        if not hr_user.get("hr_email_instant_enabled", True):
            continue
        subject, text_body, html_body = _format_instant_bodies(
            hr_user,
            pending_items=int(pending_items),
            session_id=int(session_id),
        )
        if send_email(to=hr_user["email"], subject=subject, text_body=text_body, html_body=html_body):
            sent += 1
    return sent
