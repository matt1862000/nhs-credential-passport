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


_BASE_SIGNALS = {
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


def _signals(**overrides):
    s = dict(_BASE_SIGNALS)
    s.update(overrides)
    return s


class ExplanationStyleTests(unittest.TestCase):
    """Reason is 2-3 plain-English sentences, no numbers or technical strings."""

    def _assert_clean(self, reason: str):
        self.assertNotIn("similarity_score", reason)
        self.assertNotIn("+", reason)
        self.assertNotIn("%", reason)
        n = reason.count(".")
        self.assertIn(n, (2, 3))

    def test_explanation_all_match_types(self):
        cases = [
            ("exact", de.DECISION_MEETS, "exactly matches"),
            ("alias", de.DECISION_MEETS, "recognised equivalent"),
            ("semantic", de.DECISION_REQUIRES_REVIEW, "similar content"),
            ("semantic_low", de.DECISION_REQUIRES_REVIEW, "limited certainty"),
            ("partial", de.DECISION_REQUIRES_REVIEW, "partially overlaps"),
            ("none", de.DECISION_DOES_NOT_MEET, "No record"),
        ]
        for mt, decision, fragment in cases:
            with self.subTest(match_type=mt):
                s = _signals(match_type=mt)
                out = de.generate_explanation(s, decision, 60)
                self._assert_clean(out["reason"])
                self.assertIn(fragment, out["reason"])

    def test_explanation_semantic_drops_category_phrase(self):
        s = _signals(match_type="semantic", category_match=False)
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("similar content", out["reason"])
        self.assertNotIn("classification", out["reason"])

    def test_explanation_validity_sentences(self):
        out_exp = de.generate_explanation(
            _signals(is_expired=True), de.DECISION_DOES_NOT_MEET, 0
        )
        self.assertIn("expired", out_exp["reason"])
        out_soon = de.generate_explanation(
            _signals(days_to_expiry=15), de.DECISION_REQUIRES_REVIEW, 50
        )
        self.assertIn("30 days", out_soon["reason"])
        out_valid = de.generate_explanation(
            _signals(days_to_expiry=300), de.DECISION_MEETS, 80
        )
        self.assertIn("validity period", out_valid["reason"])

    def test_explanation_decision_framing(self):
        out_meets = de.generate_explanation(_signals(), de.DECISION_MEETS, 80)
        self.assertIn("No further HR review", out_meets["reason"])
        out_review = de.generate_explanation(_signals(), de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("HR review is recommended", out_review["reason"])
        out_fail = de.generate_explanation(_signals(), de.DECISION_DOES_NOT_MEET, 10)
        self.assertIn("cannot be treated as meeting", out_fail["reason"])

    def test_reason_short_drops_decision_framing(self):
        """reason_short must contain match + validity sentences only,
        never the decision-routing sentence."""
        s = _signals(match_type="exact")
        out_meets = de.generate_explanation(s, de.DECISION_MEETS, 100)
        self.assertIn("exactly matches", out_meets["reason_short"])
        self.assertIn("within the required validity period", out_meets["reason_short"])
        self.assertNotIn("No further HR review", out_meets["reason_short"])

        out_review = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertNotIn("HR review", out_review["reason_short"])
        self.assertNotIn("trust's standard", out_review["reason_short"])

        out_fail = de.generate_explanation(
            _signals(match_type="none"), de.DECISION_DOES_NOT_MEET, 0
        )
        self.assertNotIn("cannot be treated", out_fail["reason_short"])
        self.assertIn("No record", out_fail["reason_short"])

    def test_reason_full_still_contains_framing(self):
        """Full reason (kept for HR + audit) still has all 3 sentences."""
        s = _signals(match_type="exact")
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("HR review is recommended", out["reason"])

    def test_no_contradiction_exact_match_in_review_band(self):
        """An exact-match credential in REQUIRES_REVIEW must not be told
        'this is not an exact match' — that contradicts sentence 1."""
        s = _signals(match_type="exact")
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("exactly matches", out["reason"])
        self.assertNotIn("not an exact match", out["reason"])
        self.assertIn("trust's standard", out["reason"])

    def test_no_contradiction_alias_match_in_review_band(self):
        s = _signals(match_type="alias")
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("recognised equivalent", out["reason"])
        self.assertNotIn("not an exact match", out["reason"])

    def test_review_framing_cites_expired(self):
        s = _signals(match_type="exact", is_expired=True)
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("expired", out["reason"])

    def test_review_framing_cites_policy_violation(self):
        s = _signals(match_type="exact", violates_trust_policy=True)
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("trust policy", out["reason"])

    def test_review_framing_cites_prior_rejections(self):
        s = _signals(
            match_type="exact",
            previously_accepted_count=1,
            previously_rejected_count=5,
        )
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("previously been rejected", out["reason"])

    def test_review_framing_cites_imminent_expiry(self):
        s = _signals(match_type="exact", days_to_expiry=10)
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("close to expiry", out["reason"])

    def test_review_framing_non_exact_keeps_original_sentence(self):
        s = _signals(match_type="partial")
        out = de.generate_explanation(s, de.DECISION_REQUIRES_REVIEW, 50)
        self.assertIn("not an exact match", out["reason"])


class HistoricalContextTests(unittest.TestCase):
    def test_flat_keys_present(self):
        hc = de.historical_context_block(
            {"accepted_count": 14, "rejected_count": 1},
            {"accepted_count": 47, "rejected_count": 6},
        )
        self.assertEqual(hc["trust_accept_count"], 14)
        self.assertEqual(hc["trust_reject_count"], 1)
        self.assertEqual(hc["cross_trust_sample_size"], 53)
        self.assertAlmostEqual(hc["cross_trust_accept_rate"], 47 / 53, places=3)
        self.assertEqual(hc["this_trust"]["accepted"], 14)
        self.assertEqual(hc["cross_trust"]["sample_size"], 53)

    def test_flat_keys_when_no_stats(self):
        hc = de.historical_context_block(None, None)
        self.assertEqual(hc["trust_accept_count"], 0)
        self.assertIsNone(hc["cross_trust_accept_rate"])
        self.assertEqual(hc["cross_trust_sample_size"], 0)


class HistoricalHintTests(unittest.TestCase):
    def test_trust_threshold_inclusive_at_five(self):
        hc = {"trust_accept_count": 5, "trust_reject_count": 0,
              "cross_trust_accept_rate": None, "cross_trust_sample_size": 0}
        self.assertEqual(
            de.historical_acceptance_hint(hc),
            "Accepted 5 times at this organisation",
        )

    def test_cross_trust_message_with_sample_guard(self):
        hc = {"trust_accept_count": 4, "trust_reject_count": 0,
              "cross_trust_accept_rate": 0.82, "cross_trust_sample_size": 5}
        self.assertEqual(
            de.historical_acceptance_hint(hc),
            "Accepted 82% across NHS organisations",
        )

    def test_cross_trust_message_blocked_by_low_sample(self):
        hc = {"trust_accept_count": 4, "trust_reject_count": 0,
              "cross_trust_accept_rate": 0.9, "cross_trust_sample_size": 4}
        self.assertEqual(
            de.historical_acceptance_hint(hc),
            "Limited historical data available",
        )

    def test_fallback_when_no_data(self):
        hc = {"trust_accept_count": 0, "trust_reject_count": 0,
              "cross_trust_accept_rate": None, "cross_trust_sample_size": 0}
        self.assertEqual(
            de.historical_acceptance_hint(hc),
            "Limited historical data available",
        )


class ConfidenceLabelTests(unittest.TestCase):
    def test_boundary_values(self):
        cases = [
            (0.0, "low"),
            (0.39, "low"),
            (0.40, "medium"),
            (0.69, "medium"),
            (0.70, "high"),
            (1.0, "high"),
        ]
        for value, expected_label in cases:
            with self.subTest(value=value):
                label, reason = de.confidence_label_and_reason(value)
                self.assertEqual(label, expected_label)
                self.assertTrue(reason)

    def test_reason_strings(self):
        self.assertEqual(
            de.confidence_label_and_reason(0.9)[1],
            "Clear match with strong supporting evidence",
        )
        self.assertEqual(
            de.confidence_label_and_reason(0.5)[1],
            "Likely match but requires confirmation",
        )
        self.assertEqual(
            de.confidence_label_and_reason(0.1)[1],
            "Weak or unclear match",
        )


class MatchLabelTests(unittest.TestCase):
    def test_is_exact_match(self):
        self.assertTrue(de.is_exact_match(_signals(match_type="exact")))
        self.assertTrue(de.is_exact_match(_signals(match_type="alias")))
        for mt in ("semantic", "semantic_low", "partial", "hr_confirmed", "none"):
            self.assertFalse(de.is_exact_match(_signals(match_type=mt)))

    def test_match_label_mapping(self):
        expected = {
            "exact": "Exact match",
            "alias": "Equivalent training (interpreted)",
            "semantic": "Likely equivalent training (interpreted)",
            "semantic_low": "Possible equivalent training (interpreted)",
            "partial": "Partial match",
            "hr_confirmed": "HR confirmed match",
            "none": "Unclear match",
        }
        for mt, label in expected.items():
            self.assertEqual(de.match_label(_signals(match_type=mt)), label)


class EnvelopeShapeTests(unittest.TestCase):
    def test_envelope_includes_new_keys(self):
        matcher = {
            "match_type": "semantic",
            "confidence_score": 0.86,
            "expiry_status": "met",
            "expiry_date": "2027-06-01",
            "module_name": "Fire Awareness",
            "credential": {"module_name": "Fire Awareness"},
        }
        topic = {"topic_name": "Fire Safety", "category": "CSTF"}
        env = de.build_decision_envelope(
            matcher,
            topic,
            {"issuing_trust_name": "NHS e-LfH"},
            trust_stats={"accepted_count": 14, "rejected_count": 1},
            cross_trust_stats={"accepted_count": 47, "rejected_count": 6},
        )
        for key in (
            "decision",
            "decision_confidence",
            "decision_confidence_label",
            "decision_confidence_reason",
            "decision_reason",
            "decision_factors",
            "is_exact_match",
            "match_label",
            "historical_context",
            "historical_acceptance_hint",
            "decision_engine_version",
        ):
            self.assertIn(key, env, f"missing {key}")
        self.assertEqual(env["decision_engine_version"], "1.7.2")
        self.assertIn("decision_reason_short", env)
        self.assertTrue(env["decision_reason_short"])
        self.assertNotIn("HR review", env["decision_reason_short"])
        self.assertNotIn("cannot be treated", env["decision_reason_short"])
        self.assertIn("trust_accept_count", env["historical_context"])
        self.assertIn("this_trust", env["historical_context"])
        self.assertEqual(
            env["historical_acceptance_hint"],
            "Accepted 14 times at this organisation",
        )


if __name__ == "__main__":
    unittest.main()
