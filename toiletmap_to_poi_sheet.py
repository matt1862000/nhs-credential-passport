#!/usr/bin/env python3
"""
Fetch Great British Public Toilet Map dataset and output POIs in Google Sheet format.

Sheet columns: postcode, placeId, name, latitude, longitude, types, vicinity, source, rating

Usage:
  python toiletmap_to_poi_sheet.py                    # WF2 (Wakefield) only, CSV to stdout
  python toiletmap_to_poi_sheet.py --area "Leeds"     # Filter by area name
  python toiletmap_to_poi_sheet.py --postcode "S1"    # Filter by postcode (uses center + radius)
  python toiletmap_to_poi_sheet.py --all              # All active toilets (large)

Dataset: https://www.toiletmap.org.uk/dataset (CC BY 4.0)
"""

import json
import sys
import urllib.request
import math
import argparse
import csv

# Toilet Map dataset URL (updated periodically - check https://www.toiletmap.org.uk/dataset)
TOILETMAP_JSON_URL = "https://p02w6qqjlqmja4sk.public.blob.vercel-storage.com/exports/toilets-2026-01-29T00%3A00%3A06.393Z-rSFJleW9ykDrmNTXxBmvHK6EK9AL0S.json?download=1"

# Northern General Hospital / Longley Centre (Sheffield S5)
NORTHERN_GENERAL_LAT, NORTHERN_GENERAL_LON = 53.4108891, -1.4603237

# Postcode area centers and radius (m) - match your GOOGLE_APPS_SCRIPT / app
POSTCODE_CENTERS = {
    "WF2 0GU": (53.7029, -1.5496, 2500),
    "WF2": (53.7029, -1.5496, 2500),
    "S1": (53.3800, -1.4700, 2500),
    "S2": (53.3750, -1.4600, 2500),
    "S5": (53.4100, -1.4600, 2500),
    "S5 7AU": (53.4100, -1.4600, 2500),  # Sheffield S5
    # Add more as needed
}


def haversine_m(lat1, lon1, lat2, lon2):
    """Distance in metres between two WGS84 points."""
    R = 6371000
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c


def toilet_to_row(toilet, postcode, source_label="toiletmap"):
    """Map one Toilet Map record to sheet row: postcode, placeId, name, latitude, longitude, types, vicinity, source, rating."""
    coords = toilet.get("location") or {}
    coords_list = coords.get("coordinates") or [0, 0]
    lng, lat = coords_list[0], coords_list[1]
    name = (toilet.get("name") or "").strip() or "Public toilet"
    area_name = (toilet.get("areas") or {}).get("name") or ""
    place_id = (toilet.get("id") or "").strip()
    if place_id and not place_id.startswith("toiletmap_"):
        place_id = "toiletmap_" + place_id
    types_list = ["public_toilet"]
    if toilet.get("accessible"):
        types_list.append("accessible")
    if toilet.get("baby_change"):
        types_list.append("baby_change")
    types_str = ", ".join(types_list)
    vicinity = area_name
    rating = ""  # Toilet Map has no rating
    return [postcode, place_id, name, lat, lng, types_str, vicinity, source_label, rating]


def filter_by_area(toilets, area_name):
    """Filter to toilets in this area (areas.name). Case-sensitive match."""
    out = []
    for t in toilets:
        if not t.get("active"):
            continue
        name = (t.get("areas") or {}).get("name")
        if name == area_name:
            out.append(t)
    return out


def filter_by_postcode(toilets, postcode_key):
    """Filter to toilets within radius of postcode center."""
    if postcode_key not in POSTCODE_CENTERS:
        print("Unknown postcode. Known:", list(POSTCODE_CENTERS.keys()), file=sys.stderr)
        return []
    lat_c, lon_c, radius_m = POSTCODE_CENTERS[postcode_key]
    out = []
    for t in toilets:
        if not t.get("active"):
            continue
        coords = (t.get("location") or {}).get("coordinates") or [0, 0]
        lng, lat = coords[0], coords[1]
        if haversine_m(lat_c, lon_c, lat, lng) <= radius_m:
            out.append(t)
    return out


def main():
    ap = argparse.ArgumentParser(description="Toilet Map → POI sheet rows")
    ap.add_argument("--area", default=None, help='Filter by area name (e.g. "Wakefield")')
    ap.add_argument("--postcode", default="WF2 0GU", help="Postcode for center+radius filter (default WF2 0GU)")
    ap.add_argument("--all", action="store_true", help="Output all active toilets (no filter)")
    ap.add_argument("--url", default=TOILETMAP_JSON_URL, help="Override dataset JSON URL")
    ap.add_argument("--file", default=None, help="Use local JSON file instead of downloading")
    ap.add_argument("--csv", action="store_true", help="Output CSV (default is TSV for sheet paste)")
    args = ap.parse_args()

    if args.file:
        print(f"Loading from {args.file}...", file=sys.stderr)
        with open(args.file, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        print("Downloading Toilet Map dataset (may take a moment)...", file=sys.stderr)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(args.url, timeout=120) as resp:
                    raw = resp.read()
                data = json.loads(raw)
                break
            except Exception as e:
                if attempt < 2:
                    print(f"Retry {attempt + 2}/3: {e}", file=sys.stderr)
                else:
                    raise
    print(f"Loaded {len(data)} toilets.", file=sys.stderr)

    if args.all:
        toilets = [t for t in data if t.get("active")]
        postcode_for_row = "UK"  # or leave as single value
    elif args.area:
        toilets = filter_by_area(data, args.area)
        postcode_for_row = args.postcode  # use default or area as label
    else:
        toilets = filter_by_postcode(data, args.postcode)
        postcode_for_row = args.postcode

    print(f"Filtered to {len(toilets)} toilets.", file=sys.stderr)

    if not toilets:
        print("No toilets match. Try --area Wakefield or --postcode WF2 0GU", file=sys.stderr)
        sys.exit(1)

    delimiter = "," if args.csv else "\t"
    writer = csv.writer(sys.stdout, delimiter=delimiter, quoting=csv.QUOTE_MINIMAL)
    writer.writerow(["postcode", "placeId", "name", "latitude", "longitude", "types", "vicinity", "source", "rating"])
    for t in toilets:
        row = toilet_to_row(t, postcode_for_row)
        writer.writerow(row)

    print(f"Wrote {len(toilets)} rows.", file=sys.stderr)


if __name__ == "__main__":
    main()
