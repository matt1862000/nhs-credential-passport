"""Unit tests for automatic expiry reminder logic."""
from backend.hr_expiry_reminders import (
    build_expiry_reminder_body,
    reminder_stage_for_days,
)


def test_reminder_stage_30d():
    assert reminder_stage_for_days(30) == "30d"
    assert reminder_stage_for_days(15) == "30d"
    assert reminder_stage_for_days(8) == "30d"
    assert reminder_stage_for_days(7) != "30d"


def test_reminder_stage_7d():
    assert reminder_stage_for_days(7) == "7d"
    assert reminder_stage_for_days(1) == "7d"
    assert reminder_stage_for_days(0) == "7d"


def test_reminder_stage_expired():
    assert reminder_stage_for_days(-1) == "expired"
    assert reminder_stage_for_days(-30) == "expired"


def test_reminder_stage_outside_windows():
    assert reminder_stage_for_days(31) is None
    assert reminder_stage_for_days(90) is None
    assert reminder_stage_for_days(None) is None


def test_build_expiry_reminder_body_groups_stages():
    doc = {"display_name": "Alex Smith", "email": "alex@example.com"}
    due = [
        (
            "30d",
            {
                "module_name": "Safeguarding Adults and Children Level 3",
                "topic_name": "Safeguarding Adults and Children Level 3",
                "expiry_date": "2026-07-16",
                "days_until": 20,
            },
        ),
        (
            "7d",
            {
                "module_name": "Moving and Handling",
                "topic_name": "Moving and Handling",
                "expiry_date": "2026-05-25",
                "days_until": 3,
            },
        ),
    ]
    body = build_expiry_reminder_body(doc, "ROTHERHAM NHS FT", due)
    assert "Hi Alex" in body
    assert "mandatory" in body.lower()
    assert "Safeguarding Adults and Children Level 3" in body
    assert "within 30 days" in body
    assert "within 7 days" in body
    assert "Moving and Handling" in body
    assert "via DocPass" in body


def test_build_manual_expiry_reminder_body():
    doc = {"display_name": "Alex Smith"}
    due = [
        (
            "manual",
            {
                "module_name": "Safeguarding Level 3",
                "topic_name": "Safeguarding Adults and Children Level 3",
                "expiry_date": "2026-07-16",
                "days_until": 53,
            },
        ),
    ]
    body = build_expiry_reminder_body(doc, "ROTHERHAM NHS FT", due, manual=True)
    assert "mandatory training is expiring soon" in body.lower() or "training on your docpass" in body.lower()
    assert "Safeguarding" in body
