"""Outbound email via SMTP (optional — skipped when SMTP_HOST is unset)."""
import logging
import os
import smtplib
from email.message import EmailMessage
from typing import Optional

logger = logging.getLogger(__name__)


def _smtp_configured() -> bool:
    return bool((os.environ.get("SMTP_HOST") or "").strip())


def _email_from() -> str:
    return (os.environ.get("EMAIL_FROM") or "DocPass <noreply@docpass.co.uk>").strip()


def send_email(*, to: str, subject: str, text_body: str, html_body: Optional[str] = None) -> bool:
    """
    Send one email. Returns True if sent, False if skipped or failed.
    Never raises — callers should not fail HTTP requests on email errors.
    """
    recipient = (to or "").strip()
    if not recipient:
        logger.warning("send_email: missing recipient")
        return False
    if not _smtp_configured():
        logger.info("send_email: SMTP_HOST not set; skipping email to %s", recipient)
        return False

    host = os.environ.get("SMTP_HOST", "").strip()
    port = int(os.environ.get("SMTP_PORT") or "587")
    user = (os.environ.get("SMTP_USER") or "").strip()
    password = (os.environ.get("SMTP_PASSWORD") or "").strip()
    use_tls = (os.environ.get("SMTP_USE_TLS") or "true").strip().lower() not in (
        "0",
        "false",
        "no",
    )

    msg = EmailMessage()
    msg["From"] = _email_from()
    msg["To"] = recipient
    msg["Subject"] = subject
    msg.set_content(text_body)
    if html_body:
        msg.add_alternative(html_body, subtype="html")

    try:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            if use_tls:
                smtp.starttls()
            if user:
                smtp.login(user, password)
            smtp.send_message(msg)
        logger.info("send_email: sent to %s subject=%r", recipient, subject)
        return True
    except Exception:
        logger.exception("send_email: failed to %s", recipient)
        return False
