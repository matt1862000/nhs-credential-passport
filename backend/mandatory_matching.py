"""
Mandatory topic ↔ wallet credential matching (shared rules for compliance snapshots).
"""
from __future__ import annotations

import re
from datetime import date, timedelta
from typing import Any, Optional

from .models import CSTF_MODULES

# Global aliases keyed by normalized topic name (extends per-topic match_hints).
ALIAS_MAP: dict[str, list[str]] = {
    "fire safety": ["fire awareness", "fire safety level 1", "fire safety level 2"],
    "infection prevention and control": ["ipc", "infection control", "infection prevention"],
    "information governance": ["ig training", "ig level", "information governance level"],
    "health, safety and welfare": ["health safety", "health & safety", "health and safety"],
    "health safety and welfare": ["health safety", "health & safety", "health and safety"],
    "equality, diversity and human rights": ["equality diversity", "edhr", "diversity and human rights"],
    "safeguarding adults and children level 3": [
        "safeguarding level 3",
        "sg3",
        "adult safeguarding level 3",
    ],
    "safeguarding adults children level 3": [
        "safeguarding level 3",
        "sg3",
        "adult safeguarding level 3",
    ],
}

_MIN_PARTIAL_LEN = 4
_CONFIDENCE = {"exact": 1.0, "alias": 0.8, "partial": 0.5, "none": 0.0}


def normalize(text: Optional[str]) -> str:
    s = (text or "").lower().strip()
    s = re.sub(r"\s*&\s*", " and ", s)
    s = re.sub(r"[^\w\s/-]", " ", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def _confidence_label(score: float) -> str:
    if score >= 0.8:
        return "high"
    if score >= 0.5:
        return "medium"
    return "low"


def portability_from_category(category: Optional[str]) -> str:
    c = (category or "").lower()
    if "local" in c:
        return "local_only"
    if "cstf" in c:
        return "portable"
    if "trust policy" in c:
        return "conditional"
    return "conditional"


def _infer_cstf_hints(topic_norm: str) -> tuple[list[str], list[str]]:
    """When DB/pack hints are missing, link topics to CSTF module codes by display name."""
    codes: list[str] = []
    names: list[str] = []
    if not topic_norm:
        return codes, names
    for code, display in CSTF_MODULES:
        if code == "non_cstf":
            continue
        dn = normalize(display)
        if not dn:
            continue
        if topic_norm == dn or topic_norm in dn or dn in topic_norm:
            codes.append(code)
            if dn not in names:
                names.append(dn)
    return codes, names


def _hints_from_topic(topic: dict) -> dict:
    raw = topic.get("match_hints")
    if not isinstance(raw, dict):
        raw = {}
    topic_name = (topic.get("topic_name") or "").strip()
    topic_norm = normalize(topic_name)
    name_subs = list(raw.get("match_name_substrings") or [])
    if topic_name and topic_name not in name_subs:
        name_subs.insert(0, topic_name)

    module_codes = [str(c).strip().lower() for c in (raw.get("match_module_codes") or []) if str(c).strip()]
    if not module_codes:
        inferred_codes, inferred_names = _infer_cstf_hints(topic_norm)
        module_codes.extend(inferred_codes)
        for dn in inferred_names:
            if dn not in name_subs:
                name_subs.append(dn)

    aliases: list[str] = []
    for key, vals in ALIAS_MAP.items():
        key_norm = normalize(key)
        if topic_norm == key_norm or topic_norm in key_norm or key_norm in topic_norm:
            aliases.extend(vals)
    alias_subs = [normalize(a) for a in aliases if normalize(a)]

    return {
        "match_module_codes": module_codes,
        "match_name_substrings": [normalize(s) for s in name_subs if normalize(s)],
        "alias_name_substrings": alias_subs,
        "partial_module_codes": [str(c).strip().lower() for c in (raw.get("partial_module_codes") or []) if str(c).strip()],
        "partial_name_substrings": [normalize(s) for s in (raw.get("partial_name_substrings") or []) if normalize(s)],
        "partial_hint": (raw.get("partial_hint") or "").strip() or None,
    }


def _substring_hit(needle: str, haystack: str) -> bool:
    if not needle or not haystack:
        return False
    if len(needle) < _MIN_PARTIAL_LEN and needle not in haystack.split():
        return False
    return needle in haystack


def _classify_credential(topic: dict, hints: dict, pl: dict) -> tuple[str, str]:
    """Return (match_type, detail) for one credential payload."""
    code = pl.get("module_code") or ""
    name = normalize(pl.get("module_name") or "")
    topic_norm = normalize(topic.get("topic_name"))

    for mc in hints.get("match_module_codes") or []:
        if code and code == mc:
            return "exact", f"Module code {mc}"

    for sub in hints.get("match_name_substrings") or []:
        if _substring_hit(sub, name):
            if sub == topic_norm or sub == name:
                return "exact", pl.get("module_name_display") or name
            return "exact", sub

    if topic_norm and name and (topic_norm == name or topic_norm in name or name in topic_norm):
        if topic_norm == name:
            return "exact", pl.get("module_name_display") or name
        if len(min(topic_norm, name, key=len)) >= _MIN_PARTIAL_LEN:
            return "exact", pl.get("module_name_display") or name

    for sub in hints.get("alias_name_substrings") or []:
        if _substring_hit(sub, name):
            return "alias", sub

    for mc in hints.get("partial_module_codes") or []:
        if code and code == mc:
            return "partial", f"Partial module code {mc}"

    for sub in hints.get("partial_name_substrings") or []:
        if _substring_hit(sub, name):
            return "partial", sub

    if topic_norm and name and len(min(topic_norm, name, key=len)) >= _MIN_PARTIAL_LEN:
        if topic_norm in name or name in topic_norm:
            return "partial", pl.get("module_name_display") or name

    return "none", ""


def _expiry_bucket(expiry_date: Optional[str], *, warn_days: int = 90) -> str:
    if not expiry_date:
        return "met"
    try:
        exp = date.fromisoformat(str(expiry_date)[:10])
    except ValueError:
        return "met"
    today = date.today()
    if exp < today:
        return "expired"
    if exp <= today + timedelta(days=warn_days):
        return "expiring"
    return "met"


def _build_reason(
    match_type: str,
    detail: str,
    topic_name: str,
    *,
    expiry_bucket: str,
    expiry_date: Optional[str],
    partial_hint: Optional[str],
) -> str:
    if match_type == "none":
        return "No matching training record found"
    if expiry_bucket == "expired":
        exp = (expiry_date or "")[:10]
        return f"Matching record found but expired on {exp}" if exp else "Matching record found but expired"
    if match_type == "exact":
        label = detail or topic_name
        return f"Exact match: {label}"
    if match_type == "alias":
        return f"Matched by alias: {detail} → {topic_name}"
    if partial_hint:
        return f"Partial match found ({detail}); {partial_hint}" if detail else partial_hint
    if detail:
        return f"Partial match found ({detail}); manual review recommended"
    return "Partial match found; manual review recommended"


def _status_label(match_type: str, expiry_bucket: str) -> str:
    if match_type == "none":
        return "No match"
    if expiry_bucket == "expired":
        return "Expired"
    if match_type == "exact":
        return "Met (exact match)"
    if match_type == "alias":
        return "Met (possible match)"
    return "Needs review"


def _legacy_status(match_type: str, expiry_bucket: str) -> str:
    if match_type == "none" or expiry_bucket == "expired":
        return "gap"
    if match_type == "partial":
        return "gap"
    if expiry_bucket == "expiring":
        return "expiring"
    return "met"


def match_topic_to_wallet(
    topic: dict,
    wallet_payloads: list[dict],
    *,
    warn_days: int = 90,
) -> dict[str, Any]:
    """
    Find the best wallet credential for a mandatory topic.

    wallet_payloads: list of dicts from compliance_snapshot._cred_payload (+ raw credential in _raw).
    """
    hints = _hints_from_topic(topic)
    topic_name = (topic.get("topic_name") or "").strip()
    category = topic.get("category")

    best: Optional[tuple[tuple, dict, str, str]] = None
    for pl in wallet_payloads:
        if not pl:
            continue
        match_type, detail = _classify_credential(topic, hints, pl)
        if match_type == "none":
            continue
        rank = {"exact": 3, "alias": 2, "partial": 1}[match_type]
        exp_key = pl.get("expiry_date") or "9999-99-99"
        score = (_CONFIDENCE[match_type], rank, exp_key)
        if best is None or score > best[0]:
            best = (score, pl, match_type, detail)

    if not best:
        return {
            "match_type": "none",
            "confidence_score": 0.0,
            "confidence_label": "low",
            "status": "gap",
            "status_label": "No match",
            "reason": "No matching training record found",
            "portability": portability_from_category(category),
            "credential_id": None,
            "module_name": None,
            "expiry_date": None,
            "expiry_status": None,
            "partial_hint": hints.get("partial_hint"),
            "credential": None,
        }

    pl, match_type, detail = best[1], best[2], best[3]
    expiry_date = pl.get("expiry_date")
    expiry_bucket = _expiry_bucket(expiry_date, warn_days=warn_days)
    conf = _CONFIDENCE[match_type]

    return {
        "match_type": match_type,
        "confidence_score": conf,
        "confidence_label": _confidence_label(conf),
        "status": _legacy_status(match_type, expiry_bucket),
        "status_label": _status_label(match_type, expiry_bucket),
        "reason": _build_reason(
            match_type,
            detail,
            topic_name,
            expiry_bucket=expiry_bucket,
            expiry_date=expiry_date,
            partial_hint=hints.get("partial_hint"),
        ),
        "portability": portability_from_category(category),
        "credential_id": pl.get("credential_id"),
        "module_name": pl.get("module_name_display") or pl.get("module_name"),
        "expiry_date": expiry_date,
        "expiry_status": expiry_bucket,
        "partial_hint": hints.get("partial_hint"),
        "credential": pl.get("_raw"),
    }
