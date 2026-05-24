"""HR email digests and instant alerts for verification inbox activity."""
import html
import logging
import os
from typing import Optional

from . import compliance_snapshot, db
from .email_service import send_email

logger = logging.getLogger(__name__)


def _app_base_url() -> str:
    return (os.environ.get("BASE_URL") or "https://docpass.co.uk").rstrip("/")


def hr_delivery_email(hr_user: dict) -> str:
    """Resolve where to send HR notification email for one user."""
    custom = (hr_user.get("hr_notification_email") or "").strip()
    if custom:
        return custom
    env_override = (os.environ.get("HR_EMAIL_OVERRIDE") or "").strip()
    if env_override:
        return env_override
    return (hr_user.get("email") or "").strip()


def _inbox_url() -> str:
    return f"{_app_base_url()}/static/hr/"


def _messages_url() -> str:
    return f"{_app_base_url()}/static/hr/messages/"


def _prefs_url() -> str:
    return f"{_app_base_url()}/static/profile/#email-notifications"


_EMAIL_FONT = "Arial, Helvetica, sans-serif"
_EMAIL_TEXT = "#212b32"
_EMAIL_LINK = "#005eb8"
_EMAIL_BODY = (
    f"font-family: {_EMAIL_FONT}; font-size: 16px; line-height: 1.5; "
    f"color: {_EMAIL_TEXT}; margin: 0 0 16px 0;"
)
_EMAIL_LINK_STYLE = (
    f"color: {_EMAIL_LINK}; font-size: 16px; line-height: 1.5; text-decoration: underline;"
)
_EMAIL_LIST_STYLE = (
    f"font-family: {_EMAIL_FONT}; font-size: 16px; line-height: 1.5; "
    f"color: {_EMAIL_TEXT}; margin: 0 0 16px 0; padding-left: 20px;"
)


def _email_html_document(content: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body style="font-family: {_EMAIL_FONT}; font-size: 16px; line-height: 1.5; color: {_EMAIL_TEXT}; margin: 0; padding: 16px;">
{content}
</body>
</html>"""


def _email_p(text: str) -> str:
    return f'<p style="{_EMAIL_BODY}">{text}</p>'


def _email_link(href: str, label: str) -> str:
    return (
        f'<a href="{html.escape(href)}" style="{_EMAIL_LINK_STYLE}">'
        f"{html.escape(label)}</a>"
    )


def _email_actions(*links: tuple[str, str]) -> str:
    joined = "<br>".join(_email_link(href, label) for href, label in links)
    return f'<p style="{_EMAIL_BODY}">{joined}</p>'


def _email_signoff() -> str:
    return _email_p("— DocPass")


def _hr_recipient_name(hr_user: dict) -> str:
    name = (hr_user.get("display_name") or "").strip()
    if name:
        return name
    email = (hr_user.get("email") or "").strip()
    return email.split("@")[0] if email else "HR colleague"


def _trust_label(hr_user: dict) -> str:
    return (hr_user.get("current_trust") or "").strip() or "your trust"


def _clinician_label(session: dict) -> str:
    name = (session.get("doctor_name") or "").strip()
    gmc = (session.get("doctor_gmc") or "").strip()
    email = (session.get("doctor_email") or "").strip()
    if name and gmc:
        return f"{name} (GMC {gmc})"
    if name:
        return name
    if email:
        return email
    return "A clinician"


def _pending_share_items(session: dict) -> list[dict]:
    out = []
    for it in session.get("items") or []:
        if (it.get("status") or "").upper() == "PENDING":
            out.append(it)
    return out


def _module_label(it: dict) -> str:
    name = (it.get("module_name") or "").strip()
    if name:
        expiry = (it.get("expiry_date") or "").strip()
        if expiry:
            return f"{name} (expires {expiry})"
        return name
    cid = (it.get("credential_id") or "").strip()
    if len(cid) > 20:
        return f"{cid[:20]}…"
    return cid or "Training record"


def _format_record_lines(items: list[dict], *, max_listed: int = 20) -> tuple[str, str]:
    """Return (text_block, html_block) listing training records."""
    if not items:
        return "", ""
    listed = items[:max_listed]
    extra = len(items) - len(listed)
    text_lines = [f"• {_module_label(it)}" for it in listed]
    if extra > 0:
        text_lines.append(f"• … and {extra} more record(s)")
    text_block = "Training records for verification:\n" + "\n".join(text_lines)

    html_items = "".join(
        f'<li style="margin-bottom: 4px;">{html.escape(_module_label(it))}</li>' for it in listed
    )
    if extra > 0:
        html_items += f'<li style="margin-bottom: 4px;">… and {extra} more record(s)</li>'
    html_block = (
        f'<p style="{_EMAIL_BODY}"><strong>Training records for verification:</strong></p>'
        f'<ul style="{_EMAIL_LIST_STYLE}">{html_items}</ul>'
    )
    return text_block, html_block


def _cohorts_url() -> str:
    return f"{_app_base_url()}/static/hr/cohorts/"


def _format_digest_bodies(hr_user: dict, stats: dict) -> tuple[str, str, str]:
    """Return (subject, text_body, html_body)."""
    trust = _trust_label(hr_user)
    pending_sessions = int(stats.get("pending_sessions") or 0)
    pending_items = int(stats.get("pending_items") or 0)
    unread_messages = int(stats.get("unread_messages") or 0)
    clinicians_review = int(stats.get("clinicians_needing_review") or 0)
    topics_review = int(stats.get("mandatory_topics_needing_review") or 0)
    inbox = _inbox_url()
    messages = _messages_url()
    cohorts = _cohorts_url()
    prefs = _prefs_url()

    subject = f"DocPass daily summary — {pending_items} pending, {unread_messages} unread messages"
    if clinicians_review > 0:
        subject = (
            f"DocPass daily summary — {pending_items} pending, "
            f"{clinicians_review} clinician(s) need requirement review"
        )

    lines = [
        f"Hello {_hr_recipient_name(hr_user)},",
        "",
        f"Your DocPass summary for {trust}:",
        "",
        f"• Pending verifications: {pending_items} record(s) across {pending_sessions} shared set(s)",
        f"• Unread messages from clinicians: {unread_messages}",
    ]
    if clinicians_review > 0:
        lines.append(
            f"• Mandatory requirement fit: {clinicians_review} clinician(s) with "
            f"{topics_review} topic(s) needing your judgement"
        )
    lines.extend(
        [
            "",
            f"Open verification inbox: {inbox}",
            f"Open messages: {messages}",
        ]
    )
    if clinicians_review > 0:
        lines.append(f"Review cohort compliance: {cohorts}")
    lines.extend(
        [
            "",
            f"Manage email preferences: {prefs}",
            "",
            "— DocPass",
        ]
    )
    text_body = "\n".join(lines)

    html_items = (
        f"<li><strong>{pending_items}</strong> training record(s) awaiting verification across "
        f"<strong>{pending_sessions}</strong> shared set(s)</li>"
        f"<li><strong>{unread_messages}</strong> unread message(s) from clinicians</li>"
    )
    if clinicians_review > 0:
        html_items += (
            f"<li><strong>{clinicians_review}</strong> clinician(s) with "
            f"<strong>{topics_review}</strong> mandatory topic(s) needing requirement-fit review</li>"
        )
    html_actions: list[tuple[str, str]] = [
        (inbox, "Open verification inbox"),
        (messages, "Open messages"),
    ]
    if clinicians_review > 0:
        html_actions.append((cohorts, "Review cohort compliance"))
    html_actions.append((prefs, "Email notification preferences"))

    html_body = _email_html_document(
        _email_p(f"Hello {html.escape(_hr_recipient_name(hr_user))},")
        + _email_p(f"Your DocPass summary for <strong>{html.escape(trust)}</strong>:")
        + f'<ul style="{_EMAIL_LIST_STYLE}">{html_items}</ul>'
        + _email_actions(*html_actions)
        + _email_signoff()
    )

    return subject, text_body, html_body


def _format_instant_bodies(
    hr_user: dict,
    *,
    pending_items: int,
    session_id: int,
    session: Optional[dict] = None,
) -> tuple[str, str, str]:
    trust = _trust_label(hr_user)
    inbox = f"{_inbox_url()}?session={int(session_id)}"
    prefs = _prefs_url()
    session = session or {}
    clinician = _clinician_label(session)
    pending = _pending_share_items(session) if session else []
    if not pending and pending_items > 0:
        pending = session.get("items") or []
    record_text, record_html = _format_record_lines(pending)

    subject = f"DocPass: {clinician} shared {pending_items} training record(s) for verification"
    text_parts = [
        f"Hello {_hr_recipient_name(hr_user)},",
        "",
        f"{clinician} has shared {pending_items} training record(s) for HR verification at {trust}.",
    ]
    if record_text:
        text_parts.extend(["", record_text])
    text_parts.extend(
        [
            "",
            f"Review now: {inbox}",
            "",
            f"Manage email preferences: {prefs}",
            "",
            "— DocPass",
        ]
    )
    text_body = "\n".join(text_parts)

    html_body = _email_html_document(
        _email_p(f"Hello {html.escape(_hr_recipient_name(hr_user))},")
        + _email_p(
            f"<strong>{html.escape(clinician)}</strong> has shared "
            f"<strong>{pending_items}</strong> training record(s) for HR verification at "
            f"{html.escape(trust)}."
        )
        + record_html
        + _email_actions(
            (inbox, "Review in DocPass"),
            (prefs, "Email notification preferences"),
        )
        + _email_signoff()
    )
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
        stats = {**stats, **compliance_snapshot.trust_mandatory_needs_review_summary(trust)}
        pending_items = int(stats.get("pending_items") or 0)
        unread_messages = int(stats.get("unread_messages") or 0)
        clinicians_review = int(stats.get("clinicians_needing_review") or 0)
        if skip_if_empty and pending_items == 0 and unread_messages == 0 and clinicians_review == 0:
            continue
        subject, text_body, html_body = _format_digest_bodies(hr_user, stats)
        if send_email(
            to=hr_delivery_email(hr_user),
            subject=subject,
            text_body=text_body,
            html_body=html_body,
        ):
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

    session = db.share_session_get(int(session_id))

    sent = 0
    for hr_user in db.hr_premium_users_for_trust(trust):
        if not hr_user.get("hr_email_instant_enabled", True):
            continue
        subject, text_body, html_body = _format_instant_bodies(
            hr_user,
            pending_items=int(pending_items),
            session_id=int(session_id),
            session=session,
        )
        if send_email(
            to=hr_delivery_email(hr_user),
            subject=subject,
            text_body=text_body,
            html_body=html_body,
        ):
            sent += 1
    return sent
