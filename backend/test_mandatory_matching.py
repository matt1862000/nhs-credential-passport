"""Tests for mandatory topic matching."""
import unittest
from datetime import date, timedelta

from backend import mandatory_matching as mm


def _topic(name: str, category: str = "UK CSTF / statutory", hints=None):
    return {
        "topic_name": name,
        "category": category,
        "match_hints": hints or {},
    }


def _cred(module_name: str, *, module_code: str = "", expiry_date: str = "2027-01-01"):
    return {
        "module_code": module_code,
        "module_name": module_name.lower(),
        "module_name_display": module_name,
        "expiry_date": expiry_date,
        "credential_id": "c1",
    }


class MandatoryMatchingTests(unittest.TestCase):
    def test_exact_topic_name_match(self):
        topic = _topic("Fire Safety", hints={"match_name_substrings": ["fire safety"]})
        result = mm.match_topic_to_wallet(topic, [_cred("Fire Safety Level 1")])
        self.assertEqual(result["match_type"], "exact")
        self.assertEqual(result["status_label"], "Met (exact match)")
        self.assertEqual(result["confidence_score"], 1.0)

    def test_alias_fire_awareness(self):
        topic = _topic("Fire Safety")
        result = mm.match_topic_to_wallet(topic, [_cred("Fire Awareness Refresher")])
        self.assertEqual(result["match_type"], "alias")
        self.assertEqual(result["status_label"], "Met (possible match)")
        self.assertIn("equivalent", result["reason"].lower())

    def test_ipc_alias(self):
        topic = _topic("Infection Prevention and Control")
        result = mm.match_topic_to_wallet(topic, [_cred("IPC Annual Update")])
        self.assertEqual(result["match_type"], "alias")

    def test_partial_from_hints(self):
        topic = _topic(
            "Safeguarding (adults & children) Level 3",
            hints={
                "match_name_substrings": ["safeguarding level 3"],
                "partial_name_substrings": ["safeguarding level 2"],
            },
        )
        result = mm.match_topic_to_wallet(topic, [_cred("Safeguarding Level 2")])
        self.assertEqual(result["match_type"], "partial")
        self.assertEqual(result["status_label"], "Needs review")

    def test_expired_overrides_match(self):
        topic = _topic("Fire Safety")
        result = mm.match_topic_to_wallet(topic, [_cred("Fire Safety Level 1", expiry_date="2020-01-01")])
        self.assertEqual(result["status_label"], "Expired")
        self.assertEqual(result["status"], "gap")
        self.assertIn("expired", result["reason"].lower())

    def test_expiring_exact_match_label(self):
        topic = _topic("Fire Safety")
        soon = (date.today() + timedelta(days=30)).isoformat()
        result = mm.match_topic_to_wallet(topic, [_cred("Fire Safety Level 1", expiry_date=soon)])
        self.assertEqual(result["match_type"], "exact")
        self.assertEqual(result["status_label"], "Met (expiring soon)")
        self.assertEqual(result["status"], "expiring")

    def test_expiring_alias_match_label(self):
        topic = _topic("Fire Safety")
        soon = (date.today() + timedelta(days=30)).isoformat()
        result = mm.match_topic_to_wallet(topic, [_cred("Fire Awareness Refresher", expiry_date=soon)])
        self.assertEqual(result["match_type"], "alias")
        self.assertEqual(result["status_label"], "Met (expiring soon)")
        self.assertEqual(result["status"], "expiring")

    def test_no_match(self):
        topic = _topic("Fire Safety")
        result = mm.match_topic_to_wallet(topic, [_cred("Manual Handling")])
        self.assertEqual(result["match_type"], "none")
        self.assertEqual(result["status_label"], "No match")

    def test_safeguarding_level3_without_db_hints(self):
        """Wallet CSTF title vs trust topic label with (&) and no match_hints in DB."""
        topic = _topic("Safeguarding (adults & children) Level 3", category="UK CSTF / trust policy")
        result = mm.match_topic_to_wallet(
            topic,
            [_cred("Safeguarding Adults and Children Level 3", module_code="safeguarding_level_3")],
        )
        self.assertEqual(result["match_type"], "exact")
        self.assertEqual(result["status_label"], "Met (exact match)")

    def test_portability_local(self):
        topic = _topic("Trust induction", category="Local — usually not portable")
        result = mm.match_topic_to_wallet(topic, [])
        self.assertEqual(result["portability"], "local_only")

    def test_portability_cstf(self):
        topic = _topic("Fire Safety", category="UK CSTF / statutory")
        result = mm.match_topic_to_wallet(topic, [])
        self.assertEqual(result["portability"], "portable")


if __name__ == "__main__":
    unittest.main()
