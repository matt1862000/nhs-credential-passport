"""Tests for training_decision_stats rollup."""
import unittest

from backend import db


class DecisionStatsTests(unittest.TestCase):
    def setUp(self):
        db.init_db()
        import uuid

        self._suffix = uuid.uuid4().hex[:8]

    def test_rollup_accept_reject(self):
        trust = "Test Trust Alpha " + self._suffix
        db.training_decision_stats_apply(
            topic_name="Fire Safety",
            credential_title="Fire Awareness Level 1",
            trust_name=trust,
            decision="accepted",
            decided_at="2026-05-01T00:00:00",
        )
        db.training_decision_stats_apply(
            topic_name="Fire Safety",
            credential_title="Fire Awareness Level 1",
            trust_name=trust,
            decision="accepted",
            decided_at="2026-05-02T00:00:00",
            previous_decision="accepted",
        )
        row = db.training_decision_stats_lookup(
            "Fire Safety", "Fire Awareness Level 1", trust
        )
        # Re-upsert with the same decision is idempotent (no double-count).
        self.assertEqual(row["accepted_count"], 1)
        self.assertEqual(row["rejected_count"], 0)

        db.training_decision_stats_apply(
            topic_name="Fire Safety",
            credential_title="Fire Awareness Level 1",
            trust_name=trust,
            decision="rejected",
            decided_at="2026-05-03T00:00:00",
            previous_decision="accepted",
        )
        row2 = db.training_decision_stats_lookup(
            "Fire Safety", "Fire Awareness Level 1", trust
        )
        self.assertEqual(row2["accepted_count"], 0)
        self.assertEqual(row2["rejected_count"], 1)

    def test_cross_trust_rate(self):
        db.training_decision_stats_apply(
            topic_name="IG Training",
            credential_title="Data Security",
            trust_name="Trust One",
            decision="accepted",
            decided_at="2026-05-01T00:00:00",
        )
        db.training_decision_stats_apply(
            topic_name="IG Training",
            credential_title="Data Security",
            trust_name="Trust Two",
            decision="accepted",
            decided_at="2026-05-01T00:00:00",
        )
        cross = db.training_decision_acceptance_rate_cross_trust("IG Training", "Data Security")
        self.assertGreaterEqual(cross["accepted_count"], 2)


if __name__ == "__main__":
    unittest.main()
