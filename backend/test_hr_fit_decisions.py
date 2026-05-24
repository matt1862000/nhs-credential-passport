"""Tests for HR mandatory requirement-fit decisions."""
import unittest

from backend import compliance_snapshot as cs
from backend import db
from backend import mandatory_matching as mm


class HrFitDecisionTests(unittest.TestCase):
    def test_topic_needs_hr_fit_review(self):
        self.assertTrue(mm.topic_needs_hr_fit_review("partial", "Needs review"))
        self.assertTrue(mm.topic_needs_hr_fit_review("semantic_low", "Needs review (possible semantic match)"))
        self.assertFalse(mm.topic_needs_hr_fit_review("exact", "Met (exact match)"))
        self.assertFalse(mm.topic_needs_hr_fit_review("semantic", "Met (semantic match)"))

    def test_apply_hr_fit_decision_accepted(self):
        row = {
            "topic_name": "Information Governance",
            "module_name": "Protecting patient confidentiality and NHS data",
            "expiry_status": "met",
            "status": "gap",
            "status_label": "Needs review (possible semantic match)",
            "match_type": "semantic_low",
        }
        out = cs._apply_hr_fit_decision(row, {"decision": "accepted", "decided_at": "2026-05-24T00:00:00"})
        self.assertEqual(out["status_label"], "Met (HR confirmed)")
        self.assertEqual(out["status"], "met")
        self.assertEqual(out["hr_fit_decision"], "accepted")

    def test_apply_hr_fit_decision_rejected(self):
        row = {
            "topic_name": "Information Governance",
            "module_name": "Safeguarding Adults and Children Level 2",
            "expiry_status": "met",
            "status": "gap",
            "status_label": "Needs review (possible semantic match)",
            "match_type": "semantic_low",
        }
        out = cs._apply_hr_fit_decision(row, {"decision": "rejected", "decided_at": "2026-05-24T00:00:00"})
        self.assertEqual(out["status_label"], "No match")
        self.assertEqual(out["status"], "gap")
        self.assertEqual(out["hr_fit_decision"], "rejected")

    def test_mandatory_match_decision_roundtrip(self):
        db.init_db()
        saved = db.mandatory_match_decision_upsert(
            doctor_user_id=999001,
            trust_name="Test Trust",
            topic_id=42,
            topic_name="Fire Safety",
            credential_id="cred-test-1",
            decision="accepted",
            hr_user_id=999002,
        )
        self.assertEqual(saved["decision"], "accepted")
        decisions = db.mandatory_match_decisions_map(999001, "Test Trust")
        self.assertIn("42::cred-test-1", decisions)
        self.assertEqual(decisions["42::cred-test-1"]["decision"], "accepted")


if __name__ == "__main__":
    unittest.main()
