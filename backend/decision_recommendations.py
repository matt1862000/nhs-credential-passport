"""
HR-facing recommendation helpers built on training_decision_stats rollups.
"""
from __future__ import annotations

from typing import Optional

from . import db
from . import decision_engine


def trust_similarity(trust_a: str, trust_b: str) -> float:
    """Jaccard similarity of accepted (topic, credential) pairs between two trusts."""
    a = db.training_decision_trust_accepted_pairs(trust_a)
    b = db.training_decision_trust_accepted_pairs(trust_b)
    if not a and not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def similar_trusts(hr_trust: str, *, limit: int = 5) -> list[dict]:
    """Other trusts ranked by overlap of accepted training↔topic pairs."""
    hr_norm = decision_engine.normalize_key(hr_trust)
    if not hr_norm:
        return []
    with __import__("sqlite3").connect(db.DB_PATH) as conn:
        conn.row_factory = __import__("sqlite3").Row
        rows = conn.execute(
            """
            SELECT DISTINCT trust_name_norm FROM training_decision_stats
            WHERE accepted_count > 0
            """
        ).fetchall()
    others = [str(r["trust_name_norm"]) for r in rows if r["trust_name_norm"] != hr_norm]
    scored: list[tuple[float, str]] = []
    for other in others:
        sim = trust_similarity(hr_trust, other)
        if sim > 0:
            scored.append((sim, other))
    scored.sort(key=lambda x: -x[0])
    return [
        {"trust": name, "similarity": round(sim, 4)}
        for sim, name in scored[:limit]
    ]


def recommended_alternatives(
    topic_name: str,
    trust_name: Optional[str] = None,
    *,
    limit: int = 5,
) -> list[dict]:
    return db.training_decision_stats_alternatives_for_topic(
        topic_name, trust_name, limit=limit
    )


def cross_trust_acceptance_message(
    topic_name: str,
    credential_title: str,
) -> Optional[str]:
    """Human-readable line for HR verify UI."""
    stats = db.training_decision_acceptance_rate_cross_trust(topic_name, credential_title)
    a = int(stats.get("accepted_count") or 0)
    r = int(stats.get("rejected_count") or 0)
    total = a + r
    if total < 5:
        return None
    rate = int(round(100 * a / total))
    return f"Accepted by {rate}% of similar trusts ({a} of {total} decisions)"


def recommendations_payload(
    *,
    topic_name: str,
    trust_name: str,
    credential_title: Optional[str] = None,
) -> dict:
    alts = recommended_alternatives(topic_name, trust_name=None, limit=5)
    cross_msg = None
    if credential_title:
        cross_msg = cross_trust_acceptance_message(topic_name, credential_title)
    return {
        "topic_name": topic_name,
        "trust": trust_name,
        "accepted_by_similar_trusts": [
            {
                "title": a.get("title") or a.get("credential_title_norm"),
                "acceptance_rate": a.get("acceptance_rate"),
                "sample_size": a.get("sample_size"),
            }
            for a in alts
        ],
        "cross_trust_message": cross_msg,
        "similar_trusts": similar_trusts(trust_name),
    }
