"""
Explainable compliance decision engine (rule-based scoring on matcher signals).

Embeddings from mandatory_matching feed similarity_score only; all decisions
are deterministic and auditable. See ENGINE_VERSION for audit pinning.
"""
from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Optional

from . import mandatory_matching
from .models import CSTF_MODULES

ENGINE_VERSION = "1.6.0"

DECISION_MEETS = "MEETS"
DECISION_REQUIRES_REVIEW = "REQUIRES_REVIEW"
DECISION_DOES_NOT_MEET = "DOES_NOT_MEET"

TRUSTED_PROVIDER_MARKERS = (
    "nhs",
    "e-lfh",
    "elearning for healthcare",
    "e-lf h",
    "trust lms",
)

# CSTF module code -> category label (from pack topic categories)
_CATEGORY_BY_CODE: dict[str, str] = {}
for _code, _display in CSTF_MODULES:
    if _code == "non_cstf":
        continue
    _cat = "CSTF"
    _CATEGORY_BY_CODE[_code] = _cat


def normalize_key(text: Optional[str]) -> str:
    return mandatory_matching.normalize(text)


def _days_until_expiry(expiry_date: Optional[str], today: date) -> Optional[int]:
    if not expiry_date:
        return None
    try:
        exp = date.fromisoformat(str(expiry_date)[:10])
    except ValueError:
        return None
    return (exp - today).days


def _days_since_completion(completion_date: Optional[str], today: date) -> Optional[int]:
    if not completion_date:
        return None
    try:
        comp = date.fromisoformat(str(completion_date)[:10])
    except ValueError:
        return None
    return (today - comp).days


def _is_trusted_provider(credential_raw: Optional[dict], module_name: Optional[str]) -> bool:
    blob = " ".join(
        [
            str((credential_raw or {}).get("issuing_trust_name") or ""),
            str((credential_raw or {}).get("issuer") or ""),
            str(module_name or ""),
        ]
    ).lower()
    return any(marker in blob for marker in TRUSTED_PROVIDER_MARKERS)


def _category_match(topic: dict, credential_raw: Optional[dict], module_code: str) -> bool:
    topic_cat = (topic.get("category") or "").strip().lower()
    if not topic_cat:
        return False
    code = (module_code or "").strip().lower()
    if code and _CATEGORY_BY_CODE.get(code):
        return topic_cat in ("cstf",) and "cstf" in topic_cat
    topic_norm = normalize_key(topic.get("topic_name"))
    if not topic_norm or not code:
        return False
    inferred_codes, _ = mandatory_matching._infer_cstf_hints(topic_norm)
    return bool(inferred_codes) and "cstf" in topic_cat


def _policy_violations(
    topic: dict,
    *,
    days_to_expiry: Optional[int],
    days_since_completion: Optional[int],
    trusted_provider: bool,
    is_expired: bool,
) -> tuple[bool, list[str]]:
    rules = topic.get("rules") if isinstance(topic.get("rules"), dict) else {}
    if not rules:
        return False, []
    reasons: list[str] = []
    max_valid = rules.get("max_valid_days")
    if max_valid is not None:
        try:
            max_valid_i = int(max_valid)
        except (TypeError, ValueError):
            max_valid_i = None
        if max_valid_i is not None:
            if is_expired:
                reasons.append(f"Record is past validity (trust policy: {max_valid_i} days)")
            elif days_since_completion is not None and days_since_completion > max_valid_i:
                reasons.append(
                    f"Completion is older than trust policy allows ({max_valid_i} days)"
                )
    if rules.get("require_trusted_provider") and not trusted_provider:
        reasons.append("Provider is not on the trust trusted-provider list")
    min_age = rules.get("min_completion_age_days")
    if min_age is not None and days_since_completion is not None:
        try:
            min_age_i = int(min_age)
            if days_since_completion < min_age_i:
                reasons.append(
                    f"Completion is too recent for this trust policy (minimum {min_age_i} days)"
                )
        except (TypeError, ValueError):
            pass
    return bool(reasons), reasons


def extract_signals(
    matcher_result: dict[str, Any],
    credential_raw: Optional[dict],
    topic: dict,
    *,
    today: Optional[date] = None,
    trust_name: Optional[str] = None,
    trust_stats: Optional[dict] = None,
    cross_trust_stats: Optional[dict] = None,
) -> dict[str, Any]:
    """Derive structured signals from matcher output + credential metadata."""
    today = today or date.today()
    match_type = (matcher_result.get("match_type") or "none").strip().lower()
    expiry_status = (matcher_result.get("expiry_status") or "").strip().lower()
    expiry_date = matcher_result.get("expiry_date")
    module_name = matcher_result.get("module_name")
    cred = credential_raw if isinstance(credential_raw, dict) else {}
    module_code = ""
    if cred.get("module_code"):
        module_code = str(cred.get("module_code")).strip().lower()
    elif matcher_result.get("credential"):
        pl = matcher_result.get("credential")
        if isinstance(pl, dict) and pl.get("module_code"):
            module_code = str(pl["module_code"]).strip().lower()

    days_to_expiry = _days_until_expiry(expiry_date, today)
    completion_date = cred.get("completion_date") or cred.get("completed_at")
    days_since_completion = _days_since_completion(
        str(completion_date)[:10] if completion_date else None, today
    )
    is_expired = expiry_status == "expired" or (
        days_to_expiry is not None and days_to_expiry < 0
    )
    trusted = _is_trusted_provider(cred, module_name)
    cat_match = _category_match(topic, cred, module_code)

    raw_conf = float(matcher_result.get("confidence_score") or 0.0)
    if match_type in ("semantic", "semantic_low"):
        similarity_score = raw_conf
    else:
        similarity_score = 0.0

    violates_policy, policy_reasons = _policy_violations(
        topic,
        days_to_expiry=days_to_expiry,
        days_since_completion=days_since_completion,
        trusted_provider=trusted,
        is_expired=is_expired,
    )

    ts = trust_stats or {}
    accepted_count = int(ts.get("accepted_count") or 0)
    rejected_count = int(ts.get("rejected_count") or 0)
    previously_accepted = accepted_count > 0 and rejected_count == 0

    cts = cross_trust_stats or {}
    ct_accepted = int(cts.get("accepted_count") or 0)
    ct_rejected = int(cts.get("rejected_count") or 0)
    ct_total = ct_accepted + ct_rejected
    cross_trust_rate: Optional[float] = None
    if ct_total >= 5:
        cross_trust_rate = ct_accepted / ct_total if ct_total else None

    return {
        "match_type": match_type,
        "similarity_score": round(similarity_score, 4),
        "category_match": cat_match,
        "is_expired": is_expired,
        "days_to_expiry": days_to_expiry,
        "days_since_completion": days_since_completion,
        "trusted_provider": trusted,
        "violates_trust_policy": violates_policy,
        "policy_reasons": policy_reasons,
        "previously_accepted_count": accepted_count,
        "previously_rejected_count": rejected_count,
        "previously_accepted": previously_accepted,
        "cross_trust_acceptance_rate": cross_trust_rate,
        "cross_trust_sample_size": ct_total,
        "trust_name": (trust_name or "").strip() or None,
    }


def _score_contributions(signals: dict[str, Any]) -> list[tuple[str, int]]:
    """Return ordered (label, points) for every non-zero rule."""
    out: list[tuple[str, int]] = []
    mt = signals.get("match_type") or "none"

    if mt == "exact":
        out.append(("Exact module match", 50))
    elif mt == "alias":
        out.append(("Alias / equivalent match", 40))
    elif mt in ("semantic", "semantic_low"):
        sim = float(signals.get("similarity_score") or 0.0)
        pts = int(round(sim * 30))
        if pts:
            out.append((f"Semantic similarity ({int(round(sim * 100))}%)", pts))
    elif mt == "partial":
        out.append(("Partial title match", 15))
    elif mt == "hr_confirmed":
        out.append(("HR confirmed requirement fit", 45))

    if signals.get("category_match"):
        out.append(("Category alignment", 25))
    if signals.get("is_expired"):
        out.append(("Expired", -100))
    else:
        dte = signals.get("days_to_expiry")
        if dte is not None:
            if dte > 180:
                out.append(("Valid for more than 180 days", 15))
            elif dte < 30:
                out.append(("Expiring within 30 days", -10))

    if signals.get("trusted_provider"):
        out.append(("Trusted provider", 10))

    if signals.get("previously_accepted"):
        out.append(("Previously accepted at this trust", 30))
    elif int(signals.get("previously_rejected_count") or 0) > int(
        signals.get("previously_accepted_count") or 0
    ):
        out.append(("Previously rejected more than accepted at this trust", -30))

    if signals.get("violates_trust_policy"):
        out.append(("Trust policy not met", -40))

    rate = signals.get("cross_trust_acceptance_rate")
    sample = int(signals.get("cross_trust_sample_size") or 0)
    if rate is not None and sample >= 5:
        if rate >= 0.8:
            out.append((f"High cross-trust acceptance ({int(round(rate * 100))}%)", 15))
        elif rate <= 0.3:
            out.append((f"Low cross-trust acceptance ({int(round(rate * 100))}%)", -15))

    return out


def evaluate_decision(signals: dict[str, Any]) -> tuple[int, str, float]:
    """Return (score, decision, confidence 0-1)."""
    score = sum(pts for _, pts in _score_contributions(signals))
    if score >= 70:
        decision = DECISION_MEETS
    elif score >= 40:
        decision = DECISION_REQUIRES_REVIEW
    else:
        decision = DECISION_DOES_NOT_MEET
    confidence = min(1.0, max(0.0, score / 100.0))
    return score, decision, confidence


def generate_explanation(
    signals: dict[str, Any],
    decision: str,
    score: int,
) -> dict[str, Any]:
    contributions = _score_contributions(signals)
    factors = [f"{label} ({pts:+d})" for label, pts in contributions]

    policy_reasons = signals.get("policy_reasons") or []
    for pr in policy_reasons:
        if pr and pr not in factors:
            factors.append(str(pr))

    if decision == DECISION_MEETS:
        reason = "This record likely meets the requirement based on the factors below."
    elif decision == DECISION_REQUIRES_REVIEW:
        reason = "This match needs HR review before it can be treated as meeting the requirement."
    else:
        reason = "This record does not appear to meet the requirement based on the factors below."

    if contributions:
        top_label, top_pts = max(contributions, key=lambda x: abs(x[1]))
        if top_pts <= -40:
            reason = f"Primary concern: {top_label.lower()}."
        elif top_pts >= 40:
            reason = f"Strongest factor: {top_label.lower()}."

    return {"reason": reason, "factors": factors}


def historical_context_block(
    trust_stats: Optional[dict],
    cross_trust_stats: Optional[dict],
) -> dict[str, Any]:
    ts = trust_stats or {}
    cts = cross_trust_stats or {}
    ct_a = int(cts.get("accepted_count") or 0)
    ct_r = int(cts.get("rejected_count") or 0)
    ct_total = ct_a + ct_r
    rate = (ct_a / ct_total) if ct_total else None
    return {
        "this_trust": {
            "accepted": int(ts.get("accepted_count") or 0),
            "rejected": int(ts.get("rejected_count") or 0),
        },
        "cross_trust": {
            "accepted": ct_a,
            "rejected": ct_r,
            "rate": round(rate, 4) if rate is not None else None,
            "sample_size": ct_total,
        },
    }


def build_decision_envelope(
    matcher_result: dict[str, Any],
    topic: dict,
    credential_raw: Optional[dict],
    *,
    trust_name: Optional[str] = None,
    trust_stats: Optional[dict] = None,
    cross_trust_stats: Optional[dict] = None,
    today: Optional[date] = None,
) -> dict[str, Any]:
    """Full decision block to merge into compliance topic rows."""
    signals = extract_signals(
        matcher_result,
        credential_raw,
        topic,
        today=today,
        trust_name=trust_name,
        trust_stats=trust_stats,
        cross_trust_stats=cross_trust_stats,
    )
    score, decision, confidence = evaluate_decision(signals)
    explanation = generate_explanation(signals, decision, score)
    hist = historical_context_block(trust_stats, cross_trust_stats)
    return {
        "decision": decision,
        "decision_confidence": round(confidence, 4),
        "decision_score": score,
        "decision_reason": explanation["reason"],
        "decision_factors": explanation["factors"],
        "signals": signals,
        "historical_context": hist,
        "decision_engine_version": ENGINE_VERSION,
    }


def engine_version_payload() -> dict[str, Any]:
    """Public metadata for GET /api/decision-engine/version."""
    return {
        "engine_version": ENGINE_VERSION,
        "rules": [
            {"id": "exact_match", "points": 50},
            {"id": "alias_match", "points": 40},
            {"id": "semantic_match", "points": "similarity_score * 30"},
            {"id": "partial_match", "points": 15},
            {"id": "category_match", "points": 25},
            {"id": "expired", "points": -100},
            {"id": "days_to_expiry_gt_180", "points": 15},
            {"id": "days_to_expiry_lt_30", "points": -10},
            {"id": "trusted_provider", "points": 10},
            {"id": "previously_accepted_at_trust", "points": 30},
            {"id": "previously_rejected_dominant", "points": -30},
            {"id": "trust_policy_violation", "points": -40},
            {"id": "cross_trust_high_acceptance", "points": 15, "min_sample": 5, "min_rate": 0.8},
            {"id": "cross_trust_low_acceptance", "points": -15, "min_sample": 5, "max_rate": 0.3},
        ],
        "thresholds": {
            "MEETS": 70,
            "REQUIRES_REVIEW": 40,
            "DOES_NOT_MEET": 0,
        },
    }
