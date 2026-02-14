#!/usr/bin/env python3
"""
Validate and clean prepopulated POI JSON (e.g. prepopulated_pois_WF1.json).
Applies: structure validation, name normalisation, types cleaning, vicinity,
deduplication, geographic validation, Unnamed handling, optional CSV/Excel output.

Usage:
  python3 scripts/clean_pois_json.py prepopulated_pois_WF1.json
  python3 scripts/clean_pois_json.py prepopulated_pois_WF1.json -o cleaned_WF1.json --csv
"""

import argparse
import json
import math
import re
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

# --- Constants ---
REQUIRED_TOP = {"version", "lastUpdated", "postcodeAreas"}
REQUIRED_AREA = {"postcode", "centerLatitude", "centerLongitude", "radiusMeters", "pois"}
REQUIRED_POI = {"placeId", "latitude", "longitude", "types"}
VAGUE_TYPES = {"vacant", "yes", "no", "unknown", "other"}
TYPE_SYNONYMS = {
    "café": "cafe", "cafe": "cafe",
    "barbers": "hairdresser", "barber": "hairdresser",
    "super market": "supermarket", "supermarket": "supermarket",
    "fast_food": "fast_food", "fast food": "fast_food",
    "place_of_worship": "place_of_worship", "place of worship": "place_of_worship",
}
PRIMARY_TYPE_ORDER = ["restaurant", "fast_food", "pub", "bar", "cafe", "nightclub"]
TYPE_TO_LABEL = {
    "beauty": "Beauty Salon", "charity": "Charity Shop", "pharmacy": "Pharmacy",
    "convenience": "Convenience Store", "supermarket": "Supermarket",
    "post_box": "Post Box", "telephone": "Telephone Kiosk",
}
CATEGORY_GROUPS = {
    "Food & Drink": {"restaurant", "fast_food", "cafe", "pub", "bar"},
    "Retail": {"convenience", "supermarket", "bakery", "clothing", "clothes", "charity"},
    "Service": {"hairdresser", "beauty", "pharmacy", "bank"},
    "Community": {"school", "place_of_worship", "library", "community_centre"},
    "Leisure": {"nightclub", "theatre", "cinema"},
    "Infrastructure": {"parking", "post_box", "charging_station", "telephone"},
}
EARTH_RADIUS_M = 6371000
NAME_SIMILARITY_THRESHOLD = 0.85
DUPLICATE_DISTANCE_M = 5.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return EARTH_RADIUS_M * c


def string_similarity(a: str, b: str) -> float:
    if not a or not b:
        return 0.0
    a, b = a.lower().strip(), b.lower().strip()
    if a == b:
        return 1.0
    import difflib
    return difflib.SequenceMatcher(None, a, b).ratio()


def title_case(s: str) -> str:
    """Capitalise first letter of each word; fix 's and & spacing."""
    if not s or not s.strip():
        return s
    s = s.strip()
    words = s.split()
    out = []
    for w in words:
        if not w:
            continue
        w = w[0].upper() + w[1:].lower()
        if w.endswith("'S"):
            w = w[:-2] + "'s"
        elif w.endswith("'s"):
            pass
        out.append(w)
    return " ".join(out)


def normalise_name(raw: str) -> str:
    raw = (raw or "").strip()
    raw = re.sub(r"  +", " ", raw)
    raw = re.sub(r"\s*&\s*", " & ", raw)
    raw = re.sub(r",\s*$", "", raw)
    raw = raw.strip()
    return title_case(raw) if raw else ""


def normalise_vicinity(v: Any) -> str:
    if v is None:
        return "Unnamed location"
    s = (v if isinstance(v, str) else str(v)).strip()
    s = re.sub(r"[^\w\s&'-]", "", s)
    s = re.sub(r"  +", " ", s).strip()
    return title_case(s) if s else "Unnamed location"


def is_valid_coord(lat: Any, lon: Any) -> bool:
    try:
        la, lo = float(lat), float(lon)
        return -90 <= la <= 90 and -180 <= lo <= 180
    except (TypeError, ValueError):
        return False


def validate_structure(data: Dict) -> List[str]:
    errors = []
    if not isinstance(data, dict):
        return ["Root must be a JSON object"]
    for k in REQUIRED_TOP:
        if k not in data:
            errors.append(f"Missing top-level field: {k}")
    if "postcodeAreas" in data and not isinstance(data["postcodeAreas"], list):
        errors.append("postcodeAreas must be an array")
    for i, area in enumerate((data.get("postcodeAreas") or [])):
        if not isinstance(area, dict):
            errors.append(f"postcodeAreas[{i}] must be an object")
            continue
        for k in REQUIRED_AREA:
            if k not in area:
                errors.append(f"postcodeAreas[{i}] missing field: {k}")
        pois = area.get("pois")
        if pois is not None and not isinstance(pois, list):
            errors.append(f"postcodeAreas[{i}].pois must be an array")
    return errors


def validate_and_clean_poi(poi: Dict, center_lat: float, center_lon: float, radius_m: float,
                          strict_radius: bool) -> Tuple[Optional[Dict], Optional[str]]:
    """Returns (cleaned_poi, error_message). If error, cleaned_poi is None."""
    if not isinstance(poi, dict):
        return None, "POI must be an object"
    for k in REQUIRED_POI:
        if k not in poi:
            return None, f"Missing required field: {k}"
    lat, lon = poi.get("latitude"), poi.get("longitude")
    if not is_valid_coord(lat, lon):
        return None, "Invalid latitude/longitude"
    lat, lon = float(lat), float(lon)
    types_val = poi.get("types")
    if not isinstance(types_val, list):
        return None, "types must be an array"
    if strict_radius:
        dist = haversine_m(center_lat, center_lon, lat, lon)
        if dist > radius_m:
            return None, f"POI outside radius ({dist:.0f}m > {radius_m}m)"
    out = dict(poi)
    out["latitude"] = lat
    out["longitude"] = lon
    out["types"] = list(types_val)
    return out, None


def clean_types(types: List[Any]) -> List[str]:
    seen: Set[str] = set()
    result = []
    for t in types:
        s = (t if isinstance(t, str) else str(t)).strip().lower()
        s = TYPE_SYNONYMS.get(s, s)
        s = s.replace(" ", "_")
        if s and s not in seen:
            seen.add(s)
            result.append(s)
    return result


def primary_type(types: List[str]) -> str:
    for pt in PRIMARY_TYPE_ORDER:
        if pt in types:
            return pt
    return types[0] if types else "other"


def category_for_types(types: List[str]) -> str:
    for cat, type_set in CATEGORY_GROUPS.items():
        if type_set & set(types):
            return cat
    return "Other"


def clean_poi_types(poi: Dict) -> Dict:
    poi = dict(poi)
    raw = poi.get("types") or []
    cleaned = clean_types(raw)
    poi["types"] = cleaned
    poi["primaryType"] = primary_type(cleaned)
    poi["category"] = category_for_types(cleaned)
    return poi


def handle_unnamed(poi: Dict) -> Optional[Dict]:
    name = (poi.get("name") or "").strip()
    if name.lower() != "unnamed":
        return poi
    types_list = poi.get("types") or []
    type_str = types_list[0] if types_list else "unknown"
    if type_str in VAGUE_TYPES:
        return None
    place_id = poi.get("placeId") or "unknown"
    label = TYPE_TO_LABEL.get(type_str, type_str.replace("_", " ").title())
    vicinity = normalise_vicinity(poi.get("vicinity"))
    if vicinity and vicinity != "Unnamed location":
        new_name = f"{label} – {vicinity} (est.)"
    else:
        new_name = f"{label} (ID: {place_id})"
    out = dict(poi)
    out["name"] = new_name
    return out


def merge_duplicates(pois: List[Dict]) -> List[Dict]:
    kept: List[Dict] = []
    for p in pois:
        lat, lon = p.get("latitude"), p.get("longitude")
        name = (p.get("name") or "").strip()
        types_set = set(p.get("types") or [])
        vic = (p.get("vicinity") or "").strip()
        merged = False
        for k in kept:
            klat, klon = k.get("latitude"), k.get("longitude")
            dist = haversine_m(lat, lon, klat, klon)
            kname = (k.get("name") or "").strip()
            ktypes = set(k.get("types") or [])
            kvic = (k.get("vicinity") or "").strip()
            if dist < DUPLICATE_DISTANCE_M and name == kname:
                merged = True
                break
            if dist < DUPLICATE_DISTANCE_M and types_set == ktypes and vic == kvic:
                if len(name) > len(kname):
                    k["name"] = name
                merged = True
                break
            if string_similarity(name, kname) >= NAME_SIMILARITY_THRESHOLD and types_set == ktypes:
                all_types = list(types_set | ktypes)
                best_name = kname if len(kname) >= len(name) else name
                best_vic = kvic or vic
                k["types"] = all_types
                k["primaryType"] = primary_type(all_types)
                k["category"] = category_for_types(all_types)
                k["name"] = best_name
                k["vicinity"] = normalise_vicinity(best_vic) if best_vic else k.get("vicinity")
                merged = True
                break
        if not merged:
            kept.append(dict(p))
    return kept


def run_clean(input_path: Path, output_path: Path, strict_radius: bool = True,
              output_csv: bool = False, output_geojson: bool = False) -> None:
    with open(input_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    errors = validate_structure(data)
    if errors:
        for e in errors:
            print(f"Validation error: {e}", file=sys.stderr)
        sys.exit(1)

    cleaned_areas = []
    for area in data["postcodeAreas"]:
        postcode = area.get("postcode", "")
        center_lat = float(area.get("centerLatitude", 0))
        center_lon = float(area.get("centerLongitude", 0))
        radius_m = float(area.get("radiusMeters", 2500))
        pois_in = area.get("pois") or []
        cleaned_pois = []
        dropped = 0
        for poi in pois_in:
            p, err = validate_and_clean_poi(poi, center_lat, center_lon, radius_m, strict_radius)
            if err:
                dropped += 1
                continue
            name = (p.get("name") or "").strip()
            p["name"] = normalise_name(name) if name else p.get("name")
            p["vicinity"] = normalise_vicinity(p.get("vicinity"))
            p = handle_unnamed(p)
            if p is None:
                dropped += 1
                continue
            p = clean_poi_types(p)
            cleaned_pois.append(p)
        cleaned_pois = merge_duplicates(cleaned_pois)
        cleaned_areas.append({
            "postcode": postcode,
            "centerLatitude": center_lat,
            "centerLongitude": center_lon,
            "radiusMeters": int(radius_m),
            "pois": cleaned_pois,
        })
        print(f"Area {postcode}: {len(pois_in)} → {len(cleaned_pois)} POIs (dropped {dropped}, deduped to {len(cleaned_pois)})")

    out_data = {
        "version": data.get("version", 1),
        "lastUpdated": data.get("lastUpdated", ""),
        "postcodeAreas": cleaned_areas,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(out_data, f, indent=2, ensure_ascii=False)
    print(f"Wrote {output_path}")

    if output_csv:
        csv_path = output_path.with_suffix(".csv")
        rows = [["placeId", "name", "latitude", "longitude", "primaryType", "allTypes", "vicinity", "source"]]
        for area in cleaned_areas:
            for p in area["pois"]:
                rows.append([
                    p.get("placeId", ""),
                    p.get("name", ""),
                    p.get("latitude"),
                    p.get("longitude"),
                    p.get("primaryType", ""),
                    "|".join(p.get("types") or []),
                    p.get("vicinity", ""),
                    p.get("source", ""),
                ])
        import csv as csv_module
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            csv_module.writer(f).writerows(rows)
        print(f"Wrote {csv_path}")

    if output_geojson:
        gj_path = output_path.with_suffix(".geojson")
        features = []
        for area in cleaned_areas:
            for p in area["pois"]:
                features.append({
                    "type": "Feature",
                    "geometry": {
                        "type": "Point",
                        "coordinates": [float(p.get("longitude", 0)), float(p.get("latitude", 0))],
                    },
                    "properties": {
                        "placeId": p.get("placeId"),
                        "name": p.get("name"),
                        "primaryType": p.get("primaryType"),
                        "vicinity": p.get("vicinity"),
                        "source": p.get("source"),
                    },
                })
        geojson = {"type": "FeatureCollection", "features": features}
        with open(gj_path, "w", encoding="utf-8") as f:
            json.dump(geojson, f, indent=2, ensure_ascii=False)
        print(f"Wrote {gj_path}")


def main():
    parser = argparse.ArgumentParser(description="Validate and clean prepopulated POI JSON.")
    parser.add_argument("input", type=Path, help="Input JSON file (e.g. prepopulated_pois_WF1.json)")
    parser.add_argument("-o", "--output", type=Path, default=None, help="Output JSON path (default: input with _cleaned suffix)")
    parser.add_argument("--no-radius-check", action="store_true", help="Do not remove POIs outside declared radius")
    parser.add_argument("--csv", action="store_true", help="Also write flattened CSV")
    parser.add_argument("--geojson", action="store_true", help="Also write GeoJSON")
    args = parser.parse_args()
    if not args.input.exists():
        print(f"File not found: {args.input}", file=sys.stderr)
        sys.exit(1)
    out = args.output
    if out is None:
        stem = args.input.stem
        if stem.endswith("_cleaned"):
            out = args.input.parent / (stem + ".json")
        else:
            out = args.input.parent / (stem + "_cleaned.json")
    run_clean(args.input, out, strict_radius=not args.no_radius_check,
              output_csv=args.csv, output_geojson=args.geojson)


if __name__ == "__main__":
    main()
