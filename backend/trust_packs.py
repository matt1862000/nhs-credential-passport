"""
Load trust mandatory packs from static/trust/config/*.json and seed DB rows.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

_PACKS_DIR = Path(__file__).resolve().parent.parent / "static" / "trust" / "config"

# ODS code → config filename (without .json)
ODS_TO_PACK_ID: dict[str, str] = {
    "TAH": "sheffield-health-partnership",
    "RHQ": "sheffield",
    "RXE": "rotherham",
}


def pack_path(pack_id: str) -> Path:
    return _PACKS_DIR / f"{pack_id}.json"


def load_trust_pack(pack_id: str) -> Optional[dict[str, Any]]:
    path = pack_path(pack_id)
    if not path.is_file():
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pack_id_for_trust_name(trust_name: str) -> Optional[str]:
    """Match profile/HR trust string to a pack file (exact name or alias)."""
    t = (trust_name or "").strip().lower()
    if not t:
        return None
    seen: set[str] = set()
    for pack_id in sorted(set(ODS_TO_PACK_ID.values())):
        if pack_id in seen:
            continue
        seen.add(pack_id)
        pack = load_trust_pack(pack_id)
        if not pack:
            continue
        names = [pack.get("display_name") or ""]
        names.extend(pack.get("trust_name_aliases") or [])
        for name in names:
            if name and name.strip().lower() == t:
                return pack_id
    return None


def pack_id_for_ods(ods: str) -> Optional[str]:
    return ODS_TO_PACK_ID.get((ods or "").strip().upper())


def mandatory_examples_to_rows(pack: dict[str, Any]) -> list[dict[str, Any]]:
    """Convert pack mandatory_examples to DB insert dicts."""
    shared_esr = (pack.get("esr_resource_url") or "").strip()
    rows: list[dict[str, Any]] = []
    for idx, ex in enumerate(pack.get("mandatory_examples") or []):
        channel = (ex.get("delivery_channel") or "").strip().lower()
        url = (ex.get("resource_url") or "").strip()
        if not url and channel == "esr" and shared_esr:
            url = shared_esr
        hints = {
            "match_module_codes": ex.get("match_module_codes") or [],
            "match_name_substrings": ex.get("match_name_substrings") or [],
        }
        if ex.get("partial_module_codes"):
            hints["partial_module_codes"] = ex.get("partial_module_codes")
        if ex.get("partial_name_substrings"):
            hints["partial_name_substrings"] = ex.get("partial_name_substrings")
        if ex.get("partial_hint"):
            hints["partial_hint"] = ex.get("partial_hint")
        rows.append(
            {
                "topic_name": (ex.get("label") or "").strip(),
                "category": (ex.get("category") or "").strip(),
                "sort_order": idx,
                "delivery_channel": channel or None,
                "resource_url": url or None,
                "match_hints_json": json.dumps(hints) if hints else None,
            }
        )
    return rows


def _title_case_trust_name(name: str) -> str:
    """Turn ODS-style ALL CAPS trust names into readable title case (keep NHS, etc.)."""
    acronyms = {"nhs", "uk", "gp", "ods", "icu", "it"}
    small = {"and", "of", "the", "for", "in", "at"}
    parts = name.lower().split()
    out: list[str] = []
    for i, p in enumerate(parts):
        if p in acronyms:
            out.append(p.upper())
        elif p in small and i > 0:
            out.append(p)
        else:
            out.append(p.capitalize())
    return " ".join(out)


def trust_display_name(trust_name: str) -> str:
    """Human-readable trust label (pack display name or title-cased ODS text)."""
    raw = (trust_name or "").strip()
    if not raw:
        return raw
    pack_id = pack_id_for_trust_name(raw)
    if pack_id:
        pack = load_trust_pack(pack_id)
        if pack and (pack.get("display_name") or "").strip():
            return str(pack["display_name"]).strip()
    if raw == raw.upper() and len(raw) > 3:
        return _title_case_trust_name(raw)
    return raw
