#!/usr/bin/env python3
"""
POI Name & Quality Cleaner v2
Cleans prepopulated POI JSON files (v2 sector-indexed format).

Fixes applied:
  1. Strip "(ID: osm_xxx)" suffix from all names
  2. Remove boring infrastructure POIs (post boxes, parking, bins, etc.)
  3. Fix brand capitalisation (KFC, WHSmith, McDonald's, EE, etc.)
  4. Remove generic low-value type-only names (Pitch, Bench, Track)
  5. Deduplicate chain stores (max 2 per sector)
  6. Strip "(est.)" suffix from Geograph names

Usage:
  python3 scripts/clean_pois_v2.py prepopulated_pois_WF2.json
  python3 scripts/clean_pois_v2.py prepopulated_pois_WF2.json -o prepopulated_pois_WF2_cleaned.json
"""

import argparse
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ═══════════════════════════════════════════════════════════════════════
# FIX 1: Strip (ID: osm_xxx) pattern
# ═══════════════════════════════════════════════════════════════════════
ID_SUFFIX_RE = re.compile(r"\s*\(ID:\s*osm_\d+\)\s*$")

def strip_osm_id(name: str) -> str:
    """Remove '(ID: osm_12345)' suffix from POI names."""
    return ID_SUFFIX_RE.sub("", name).strip()


# ═══════════════════════════════════════════════════════════════════════
# FIX 2: Remove boring/infrastructure POIs
# ═══════════════════════════════════════════════════════════════════════
BORING_NAME_PREFIXES = {
    "post box", "parking space", "parking entrance",
    "bicycle parking", "motorcycle parking", "waste bin", "grit bin",
    "trolley bay", "compressed air", "vacuum cleaner", "storage rental",
    "boat storage",
}

# Names that are EXACTLY these (after stripping IDs) get removed
# These are generic type labels with no real distinguishing name
GENERIC_EXACT_NAMES = {
    "telephone kiosk", "telephone exchange", "toilets", "grave yard",
    "parcel locker", "charging station", "taxi", "atm", "photo booth",
    "car wash", "car", "vending machine", "outdoor seating",
    "recycling point", "park", "garden", "evbox",
}

BORING_TYPES = {
    "post_box", "parking", "parking_space", "parking_entrance",
    "bicycle_parking", "motorcycle_parking", "waste_basket",
    "grit_bin", "recycling", "trolley_bay", "compressed_air",
    "vacuum_cleaner", "storage_rental", "boat_storage",
}

def is_boring_poi(poi: Dict) -> bool:
    """Check if POI is boring infrastructure not worth walking to."""
    name_lower = (poi.get("name") or "").strip().lower()
    # Check name prefix
    for prefix in BORING_NAME_PREFIXES:
        if name_lower.startswith(prefix):
            return True
    # Check exact generic names (after ID stripping, the name is just the type label)
    clean_name = strip_osm_id(strip_est_suffix(name_lower))
    if clean_name in GENERIC_EXACT_NAMES:
        return True
    # Check types
    types = set(t.lower() for t in (poi.get("types") or []))
    if types & BORING_TYPES and not _has_real_name(poi):
        return True
    return False

def _has_real_name(poi: Dict) -> bool:
    """Check if a POI has a real distinctive name (not just a type label)."""
    name = strip_osm_id((poi.get("name") or "").strip())
    name_lower = name.lower()
    # If name is just a type label, it's not a real name
    generic_labels = {
        "post box", "car park", "parking space", "parking entrance",
        "bicycle parking", "motorcycle parking", "waste bin", "grit bin",
        "trolley bay", "compressed air", "vacuum cleaner", "storage rental",
        "recycling point", "bench", "pitch", "track", "shelter",
        "information", "parking", "garden", "park", "atm",
        "telephone kiosk", "telephone exchange", "vending machine",
        "parcel locker", "outdoor seating", "charging station",
        "taxi", "slipway", "grave yard", "fitness station",
        "bicycle repair station", "mounting block", "wreck",
        "photo booth", "car wash", "car", "fountain",
    }
    return name_lower not in generic_labels


# ═══════════════════════════════════════════════════════════════════════
# FIX 3: Brand capitalisation lookup
# ═══════════════════════════════════════════════════════════════════════
BRAND_CORRECTIONS = {
    "whsmith": "WHSmith",
    "mcdonald's": "McDonald's",
    "mcdonalds": "McDonald's",
    "kfc": "KFC",
    "ee": "EE",
    "o2": "O2",
    "bp": "BP",
    "hsbc": "HSBC",
    "rbs": "RBS",
    "bt": "BT",
    "dhl": "DHL",
    "asda": "ASDA",
    "b & q": "B&Q",
    "b&q": "B&Q",
    "b and q": "B&Q",
    "j & s": "J&S",
    "f & f": "F&F",
    "atm": "ATM",
    "bbq": "BBQ",
    "big dukes bbq": "Big Dukes BBQ",
    "jd sports": "JD Sports",
    "jd": "JD Sports",
    "tkmaxx": "TK Maxx",
    "tk maxx": "TK Maxx",
    "wilko": "Wilko",
    "nhs": "NHS",
    "ymca": "YMCA",
    "ywca": "YWCA",
    "rspca": "RSPCA",
    "pdsa": "PDSA",
    "rac": "RAC",
    "aa": "AA",
    "vets4pets": "Vets4Pets",
    "pets at home": "Pets at Home",
    "evbox": "EVBox",
    "inpost": "InPost",
    "natwest": "NatWest",
    "poundland": "Poundland",
    "superdrug": "Superdrug",
    "specsavers": "Specsavers",
    "domino's": "Domino's",
    "starbucks": "Starbucks",
}

# Words that should always be capitalised a certain way, even mid-name
WORD_CORRECTIONS = {
    "bbq": "BBQ",
    "atm": "ATM",
    "mcdonald's": "McDonald's",
    "mcdonalds": "McDonald's",
    "mcdonald": "McDonald",  # surname (no apostrophe)
}

def fix_brand_capitalisation(name: str) -> str:
    """Fix known brand capitalisations."""
    lookup = name.lower().strip()
    if lookup in BRAND_CORRECTIONS:
        return BRAND_CORRECTIONS[lookup]
    # Also check for partial matches at the start (e.g. "Mcdonald's Wakefield")
    for key, corrected in BRAND_CORRECTIONS.items():
        if lookup.startswith(key + " ") or lookup.startswith(key + " –"):
            return corrected + name[len(key):]

    # Fix known words anywhere in the name (e.g. "Raja's Desi Grill & Bbq" → "BBQ")
    result = name
    for bad_word, good_word in WORD_CORRECTIONS.items():
        # Case-insensitive word boundary replacement
        pattern = re.compile(r'\b' + re.escape(bad_word) + r'\b', re.IGNORECASE)
        # Only replace if the current form isn't already correct
        def replacer(m):
            if m.group(0) == good_word:
                return good_word
            return good_word
        result = pattern.sub(replacer, result)
    return result


# ═══════════════════════════════════════════════════════════════════════
# FIX 4: Remove generic low-value type-only names
# ═══════════════════════════════════════════════════════════════════════
GENERIC_REMOVE_TYPES = {
    # These are just type labels with no name — not useful as waypoints
    "pitch", "bench", "track", "shelter", "information",
    "outdoor_seating", "fitness_station", "bicycle_repair_station",
    "grit_bin", "waste_basket", "vending_machine",
    "mounting_block", "wreck", "slipway",
}

def is_generic_removable(poi: Dict) -> bool:
    """Remove POIs that are just a generic type with no real name."""
    name = strip_osm_id((poi.get("name") or "").strip())
    if not name:
        return True
    name_lower = name.lower()
    types = [t.lower() for t in (poi.get("types") or [])]
    # If the name is just the type label (e.g. "Pitch" with type "pitch")
    for t in types:
        label = t.replace("_", " ")
        if name_lower == label:
            if t in GENERIC_REMOVE_TYPES:
                return True
    return False


# ═══════════════════════════════════════════════════════════════════════
# FIX 5: Deduplicate chain stores (max 2 per sector)
# ═══════════════════════════════════════════════════════════════════════
MAX_SAME_NAME_PER_SECTOR = 2

def deduplicate_chains(pois: List[Dict], sector_center_lat: float,
                       sector_center_lon: float) -> List[Dict]:
    """Keep max N of each identical name per sector, preferring closest."""
    name_counts: Dict[str, List[Tuple[float, Dict]]] = {}
    for poi in pois:
        name = (poi.get("name") or "").strip()
        name_key = name.lower()
        dist = haversine_m(sector_center_lat, sector_center_lon,
                           poi.get("latitude", 0), poi.get("longitude", 0))
        if name_key not in name_counts:
            name_counts[name_key] = []
        name_counts[name_key].append((dist, poi))

    result = []
    deduped_count = 0
    for name_key, entries in name_counts.items():
        if len(entries) <= MAX_SAME_NAME_PER_SECTOR:
            result.extend(poi for _, poi in entries)
        else:
            # Sort by distance, keep closest N
            entries.sort(key=lambda x: x[0])
            kept = entries[:MAX_SAME_NAME_PER_SECTOR]
            result.extend(poi for _, poi in kept)
            deduped_count += len(entries) - MAX_SAME_NAME_PER_SECTOR

    if deduped_count > 0:
        print(f"    📋 Chain dedup: removed {deduped_count} duplicate chain entries")
    return result


# ═══════════════════════════════════════════════════════════════════════
# FIX 6: Strip "(est.)" suffix
# ═══════════════════════════════════════════════════════════════════════
EST_SUFFIX_RE = re.compile(r"\s*\(est\.\)\s*$")

def strip_est_suffix(name: str) -> str:
    """Remove '(est.)' suffix from Geograph-sourced names."""
    return EST_SUFFIX_RE.sub("", name).strip()


# ═══════════════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════════════
EARTH_RADIUS_M = 6371000

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return EARTH_RADIUS_M * c


def title_case_smart(s: str) -> str:
    """Title case but preserve existing capitalisation for known brands."""
    if not s or not s.strip():
        return s
    # First check brand corrections
    corrected = fix_brand_capitalisation(s)
    if corrected != s:
        return corrected
    return s


# ═══════════════════════════════════════════════════════════════════════
# Master clean function for a single POI
# ═══════════════════════════════════════════════════════════════════════
def clean_poi(poi: Dict) -> Optional[Dict]:
    """
    Apply all cleaning rules to a single POI.
    Returns None if POI should be removed.
    """
    out = dict(poi)
    name = (out.get("name") or "").strip()

    # FIX 1: Strip (ID: osm_xxx)
    name = strip_osm_id(name)

    # FIX 6: Strip (est.)
    name = strip_est_suffix(name)

    out["name"] = name

    # FIX 2: Remove boring infrastructure
    if is_boring_poi(out):
        return None

    # FIX 4: Remove generic low-value type-only names
    if is_generic_removable(out):
        return None

    # FIX 3: Fix brand capitalisation
    out["name"] = fix_brand_capitalisation(out["name"])

    # Final: skip empty names
    if not out["name"].strip():
        return None

    return out


# ═══════════════════════════════════════════════════════════════════════
# Process a sector's POIs
# ═══════════════════════════════════════════════════════════════════════
def clean_sector(sector: Dict) -> Dict:
    """Clean all POIs in a sector."""
    pois_in = sector.get("pois", [])
    center_lat = sector.get("centerLatitude", 0)
    center_lon = sector.get("centerLongitude", 0)
    sector_name = sector.get("sector", "?")

    # Apply per-POI cleaning
    cleaned = []
    removed_boring = 0
    removed_generic = 0
    removed_empty = 0
    fixed_brand = 0
    stripped_id = 0
    stripped_est = 0

    for poi in pois_in:
        original_name = (poi.get("name") or "").strip()

        # Track what we strip
        if ID_SUFFIX_RE.search(original_name):
            stripped_id += 1
        if EST_SUFFIX_RE.search(original_name):
            stripped_est += 1

        result = clean_poi(poi)
        if result is None:
            if is_boring_poi({"name": strip_osm_id(strip_est_suffix(original_name)),
                              "types": poi.get("types", [])}):
                removed_boring += 1
            elif is_generic_removable({"name": strip_osm_id(strip_est_suffix(original_name)),
                                        "types": poi.get("types", [])}):
                removed_generic += 1
            else:
                removed_empty += 1
            continue

        if result["name"] != original_name and result["name"].lower() != original_name.lower():
            fixed_brand += 1

        cleaned.append(result)

    # FIX 5: Deduplicate chains within sector
    before_dedup = len(cleaned)
    cleaned = deduplicate_chains(cleaned, center_lat, center_lon)
    chain_deduped = before_dedup - len(cleaned)

    print(f"  Sector {sector_name}: {len(pois_in)} → {len(cleaned)} POIs")
    print(f"    stripped_ids={stripped_id} stripped_est={stripped_est} "
          f"removed_boring={removed_boring} removed_generic={removed_generic} "
          f"removed_empty={removed_empty} brand_fixes={fixed_brand} "
          f"chain_deduped={chain_deduped}")

    out = dict(sector)
    out["pois"] = cleaned
    return out


# ═══════════════════════════════════════════════════════════════════════
# Main processing
# ═══════════════════════════════════════════════════════════════════════
def process_file(input_path: Path, output_path: Path) -> None:
    with open(input_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    total_before = 0
    total_after = 0

    # Handle v2 sector-indexed format
    for area in data.get("postcodeAreas", []):
        postcode = area.get("postcode", "?")
        sectors = area.get("sectors", [])

        if sectors:
            # v2 format: sectors array
            print(f"\n📦 Processing {postcode} ({len(sectors)} sectors):")
            cleaned_sectors = []
            for sector in sectors:
                sector_before = len(sector.get("pois", []))
                total_before += sector_before
                cleaned_sector = clean_sector(sector)
                total_after += len(cleaned_sector["pois"])
                cleaned_sectors.append(cleaned_sector)
            area["sectors"] = cleaned_sectors

            # Also update flat pois list if present (for backward compat)
            all_flat = []
            for s in cleaned_sectors:
                all_flat.extend(s.get("pois", []))
            area["pois"] = all_flat
        else:
            # v1 format: flat pois array
            pois_in = area.get("pois", [])
            total_before += len(pois_in)
            print(f"\n📦 Processing {postcode} ({len(pois_in)} POIs, v1 flat format):")

            cleaned = []
            for poi in pois_in:
                result = clean_poi(poi)
                if result is not None:
                    cleaned.append(result)

            # Deduplicate chains
            center_lat = area.get("centerLatitude", 0)
            center_lon = area.get("centerLongitude", 0)
            cleaned = deduplicate_chains(cleaned, center_lat, center_lon)

            total_after += len(cleaned)
            area["pois"] = cleaned
            print(f"  {len(pois_in)} → {len(cleaned)} POIs")

    print(f"\n{'═' * 60}")
    print(f"TOTAL: {total_before} → {total_after} POIs "
          f"(removed {total_before - total_after}, "
          f"{(total_before - total_after) * 100 // max(total_before, 1)}%)")
    print(f"{'═' * 60}")

    # Write output
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"\n✅ Wrote {output_path}")
    print(f"   File size: {output_path.stat().st_size / 1024:.1f} KB")


def main():
    parser = argparse.ArgumentParser(description="Clean POI names and remove junk POIs (v2).")
    parser.add_argument("input", type=Path, help="Input JSON file")
    parser.add_argument("-o", "--output", type=Path, default=None,
                        help="Output path (default: overwrites input)")
    args = parser.parse_args()

    if not args.input.exists():
        print(f"File not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    output = args.output or args.input
    process_file(args.input, output)


if __name__ == "__main__":
    main()
