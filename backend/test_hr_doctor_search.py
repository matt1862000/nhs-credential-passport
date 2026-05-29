"""Tests for HR doctor search auto-enrolment into All Doctors."""
import unittest
from unittest.mock import MagicMock, patch

from backend import db


class HrDoctorSearchAutoEnrolTests(unittest.TestCase):
    @patch.object(db, "_ensure_user_in_default_cohort")
    @patch.object(db, "_doctor_member_of_trust_cohort", return_value=False)
    @patch.object(db, "_doctor_visible_to_trust", return_value=True)
    @patch("backend.db.sqlite3.connect")
    def test_visible_doctor_without_cohort_is_auto_enrolled(
        self, mock_connect, _visible, _member, mock_ensure
    ):
        row = MagicMock()
        row.__getitem__ = lambda self, k: {
            "id": 42,
            "email": "pud@pud.com",
            "display_name": "Pud Pudding",
            "gmc_number": "9999999",
            "current_trust": "Sheffield Health Partnership",
        }[k]
        conn = MagicMock()
        conn.row_factory = None
        conn.execute.return_value.fetchall.return_value = [row]
        mock_connect.return_value.__enter__.return_value = conn

        out = db.hr_doctor_search("pud", "Sheffield Trust", hr_user_id=7)

        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["id"], 42)
        mock_ensure.assert_called_once_with(
            "Sheffield Trust", 42, 7, welcome_pending=False
        )

    @patch.object(db, "_ensure_user_in_default_cohort")
    @patch.object(db, "_doctor_member_of_trust_cohort", return_value=True)
    @patch.object(db, "_doctor_visible_to_trust", return_value=True)
    @patch("backend.db.sqlite3.connect")
    def test_existing_cohort_member_is_not_re_enrolled(
        self, mock_connect, _visible, _member, mock_ensure
    ):
        row = MagicMock()
        row.__getitem__ = lambda self, k: {
            "id": 42,
            "email": "pud@pud.com",
            "display_name": "Pud Pudding",
            "gmc_number": "9999999",
            "current_trust": "Sheffield Health Partnership",
        }[k]
        conn = MagicMock()
        conn.execute.return_value.fetchall.return_value = [row]
        mock_connect.return_value.__enter__.return_value = conn

        db.hr_doctor_search("pud", "Sheffield Trust", hr_user_id=7)

        mock_ensure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
