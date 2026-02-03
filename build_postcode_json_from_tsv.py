#!/usr/bin/env python3
"""
Build app-format prepopulated_pois_<district>.json from generator TSV + existing POI JSON.

Use for mass upload: replace routes in an existing postcode JSON with routes from
pre_generated_routes_<district>.tsv. POIs and center come from the existing JSON.

Usage:
  python3 build_postcode_json_from_tsv.py \\
    --district S12 \\
    --routes-tsv route_csv_generator/pre_generated_routes_S12.tsv \\
    --poi-json prepopulated_pois_S12.json \\
    --output prepopulated_pois_S12.json

Requires: existing prepopulated_pois_<district>.json (from sheet or previous run) for POIs.
"""

import argparse
import csv
import json
from datetime import datetime
from pathlib import Path


def normalize_name(name):
    """Match Apps Script: split on ' (', take first part, lowercase, single spaces."""
    if not name:
        return ""
    s = str(name).split(" (")[0].strip().lower().replace("\t", " ").replace("\n", " ")
    return " ".join(s.split())


def build_poi_by_name_map(pois):
    """First matching POI per normalized name (same as Apps Script poiByNameMap)."""
    by_name = {}
    for p in pois:
        name = (p.get("name") or "").strip()
        key = normalize_name(name)
        if key and key not in by_name:
            by_name[key] = p
    return by_name


def main():
    ap = argparse.ArgumentParser(description="Build app-format JSON from routes TSV + existing POI JSON")
    ap.add_argument("--district", required=True, help="Postcode district, e.g. S12")
    ap.add_argument("--routes-tsv", required=True, help="Path to pre_generated_routes_<district>.tsv")
    ap.add_argument("--poi-json", required=True, help="Path to existing prepopulated_pois_<district>.json (for POIs + center)")
    ap.add_argument("--output", required=True, help="Output path for prepopulated_pois_<district>.json")
    ap.add_argument("--version", type=int, default=1, help="Version number for payload (default 1)")
    args = ap.parse_args()

    district = args.district.strip().upper()
    routes_tsv = Path(args.routes_tsv)
    poi_json_path = Path(args.poi_json)
    out_path = Path(args.output)

    if not poi_json_path.exists():
        raise SystemExit(f"POI JSON not found: {poi_json_path}")
    if not routes_tsv.exists():
        raise SystemExit(f"Routes TSV not found: {routes_tsv}")

    with open(poi_json_path, "r", encoding="utf-8") as f:
        existing = json.load(f)

    area = None
    for a in (existing.get("postcodeAreas") or []):
        pc = (a.get("postcode") or "").strip().upper()
        if pc == district or pc.startswith(district + " "):
            area = a
            break
    if not area:
        raise SystemExit(f"District {district} not found in {poi_json_path}")

    pois = list(area.get("pois") or [])
    poi_by_name = build_poi_by_name_map(pois)
    center_lat = area.get("centerLatitude", 0)
    center_lon = area.get("centerLongitude", 0)
    radius = area.get("radiusMeters", 2500)

    # TSV: Postcode, Duration (min), Route Index, Name, Description, Waypoint Count, Waypoint 1, Waypoint 2, Waypoint 3, Distance (m), Duration (sec), Polyline, ...
    routes_by_duration = {}
    with open(routes_tsv, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            pc = (row.get("Postcode") or "").strip().upper()
            if not pc or not pc.startswith(district):
                continue
            try:
                dur_min = int(float(row.get("Duration (min)", 0) or 0)) or 5
            except (ValueError, TypeError):
                dur_min = 5
            wp1 = (row.get("Waypoint 1") or "").strip()
            wp2 = (row.get("Waypoint 2") or "").strip()
            wp3 = (row.get("Waypoint 3") or "").strip()
            waypoint_names = [x for x in [wp1, wp2, wp3] if x]
            places = []
            for wp in waypoint_names:
                key = normalize_name(wp)
                poi = poi_by_name.get(key) or poi_by_name.get(wp.lower().replace(" ", " "))
                if poi:
                    places.append(poi)
            if not places:
                continue
            try:
                dist_m = float(row.get("Distance (m)", 0) or 0)
            except (ValueError, TypeError):
                dist_m = 0
            try:
                dur_sec = int(float(row.get("Duration (sec)", 0) or 0))
            except (ValueError, TypeError):
                dur_sec = 0
            polyline = (row.get("Polyline") or "").strip()
            if not polyline or polyline.lower() == "click to generate":
                continue
            name_val = (row.get("Name") or "").strip() or None
            desc_val = (row.get("Description") or "").strip() or None

            route_obj = {
                "places": places,
                "polyline": polyline,
                "distanceMeters": int(dist_m),
                "durationSeconds": int(dur_sec),
                "name": name_val,
                "description": desc_val,
                "directions": None,
            }
            if dur_min not in routes_by_duration:
                routes_by_duration[dur_min] = []
            routes_by_duration[dur_min].append(route_obj)

    routes_payload = [
        {"durationMinutes": d, "routes": routes_by_duration[d]}
        for d in sorted(routes_by_duration.keys())
    ]
    new_area = {
        "postcode": district,
        "centerLatitude": center_lat,
        "centerLongitude": center_lon,
        "radiusMeters": radius,
        "pois": pois,
        "routes": routes_payload,
    }
    payload = {
        "version": args.version,
        "lastUpdated": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "postcodeAreas": [new_area],
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)

    total_routes = sum(len(r["routes"]) for r in routes_payload)
    print(f"Wrote {out_path}: {len(pois)} POIs, {total_routes} routes ({len(routes_payload)} duration buckets)")


if __name__ == "__main__":
    main()
