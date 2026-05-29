"""Unit tests for the explainable compliance decision engine."""
import unittest
from datetime import date

from backend import decision_engine as de


class DecisionEngineTests(unittest.TestCase):
    def test_exact_match_meets(self):
        signals = {
            "match_type": "exact",
            "similarity_score": 0.0,
            "category_match": True,
            "is_expired": False,
            "days_to_expiry": 200,
            "trusted_provider": True,
            "violates_trust_policy": False,
            "policy_reasons": [],
            "previously_accepted_count": 0,
            "previously_rejected_count": 0,
            "previously_accepted": False,
            "cross_trust_acceptance_rate": None,
            "cross_trust_sample_size": 0,
        }
        score, decision, conf = de.evaluate_decision(signals)
        self.assertEqual(decision, de.DECISION_MEETS)
        self.assertGreaterEqual(score, 70)
        self.assertGreater(conf, 0.69)

    def test_expired_overrides_strong_match(self):
        signals = {
            "match_type": "exact",
            "similarity_score": 0.0,
            "category_match": True,
            "is_expired": True,
            "days_to_expiry": -5,
            "trusted_provider": True,
            "violates_trust_policy": False,
            "policy_reasons": [],
            "previously_accepted_count": 0,
            "previously_rejected_count": 0,
            "previously_accepted": False,
            "cross_trust_acceptance_rate": None,
            "cross_trust_sample_size": 0,
        }
        score, decision, _ = de.evaluate_decision(signals)
        self.assertEqual(decision, de.DECISION_DOES_NOT_MEET)
        self.assertLess(score, 40)

    def test_no_match_does_not_meet(self):
        signals = {
            "match_type": "none",
            "similarity_score": 0.0,
            "category_match": False,
            "is_expired": False,
            "days_to_expiry": None,
            "trusted_provider": False,
            "violates_trust_policy": False,
            "policy_reasons": [],
            "previously_accepted_count": 0,
            "previously_rejected_count": 0,
            "previously_accepted": False,
            "cross_trust_acceptance_rate": None,
            "cross_trust_sample_size": 0,
        }
        _, decision, _ = de.evaluate_decision(signals)
        self.assertEqual(decision, de.DECISION_DOES_NOT_MEET)

    def test_requires_review_band(self):
        signals = {
            "match_type": "partial",
            "similarity_score": 0.0,
            "category_match": True,
            "is_expired": False,
            "days_to_expiry": 60,
            "trusted_provider": False,
            "violates_trust_policy": False,
            "policy_reasons": [],
            "previously_accepted_count": 0,
            "previously_rejected_count": 0,
            "previously_accepted": False,
            "cross_trust_acceptance_rate": None,
            "cross_trust_sample_size": 0,
        }
        score, decision, _ = de.evaluate_decision(signals)
        self.assertEqual(decision, de.DECISION_REQUIRES_REVIEW)
        self.assertGreaterEqual(score, 40)
        self.assertLess(score, 70)

    def test_previously_accepted_boost(self):
        signals = {
            "match_type": "semantic_low",
            "similarity_score": 0.75,
            "category_match": False,
            "is_expired": False,
            "days_to_expiry": 100,
            "trusted_provider": False,
            "violates_trust_policy": False,
            "policy_reasons": [],
            "previously_accepted_count": 3,
            "previously_rejected_count": 0,
            "previously_accepted": True,
            "cross_trust_acceptance_rate": None,
            "cross_trust_sample_size": 0,
        }
        score, decision, _ = de.evaluate_decision(signals)
        self.assertGreaterEqual(score, 40)

    def test_extract_signals_semantic_only(self):
        matcher = {
            "match_type": "semantic",
            "confidence_score": 0.92,
            "expiry_status": "met",
            "expiry_date": "2027-01-01",
            "module_name": "Fire Awareness",
        }
        topic = {"topic_name": "Fire Safety", "category": "CSTF", "rules": {}}
        cred = {"issuing_trust_name": "NHS e-LfH", "completion_date": "2025-06-01"}
        signals = de.extract_signals(matcher, cred, topic, today=date(2026, 5, 1))
        self.assertEqual(signals["similarity_score"], 0.92)
        self.assertFalse(signals["is_expired"])

    def test_trust_policy_violation(self):
        topic = {
            "topic_name": "Fire Safety",
            "rules": {"max_valid_days": 365, "require_trusted_provider": True},
        }
        cred = {"issuing_trust_name": "Unknown College", "completion_date": "2020-01-01"}
        matcher = {
            "match_type": "partial",
            "confidence_score": 0.0,
            "expiry_status": "expired",
            "expiry_date": "2024-01-01",
            "module_name": "Fire course",
        }
        signals = de.extract_signals(matcher, cred, topic, today=date(2026, 5, 1))
        self.assertTrue(signals["violates_trust_policy"])
        score, decision, _ = de.evaluate_decision(signals)
        self.assertEqual(decision, de.DECISION_DOES_NOT_MEET)

    def test_build_envelope_has_factors(self):
        matcher = {
            "match_type": "alias",
            "confidence_score": 0.8,
            "expiry_status": "met",
            "expiry_date": "2027-06-01",
            "module_name": "IPC Level 1",
            "credential": {"module_name": "IPC Level 1"},
        }
        topic = {"topic_name": "Infection Prevention and Control", "category": "CSTF"}
        env = de.build_decision_envelope(matcher, topic, {"issuing_trust_name": "NHS"})
        self.assertIn("decision", env)
        self.assertIn("decision_factors", env)
        self.assertTrue(env["decision_factors"])


if __name__ == "__main__":
    unittest.main()
