#!/usr/bin/env python3
"""
Query OpenStreetMap (Overpass API) for toilets and benches near a postcode.
Outputs TSV in sheet format: postcode, placeId, name, latitude, longitude, types, vicinity, source, rating

Usage:
  python osm_toilets_benches_s5.py              # S5 7AU, 2.5 km radius
  python osm_toilets_benches_s5.py --radius 3000
"""

import json
import urllib.request
import urllib.parse
import sys

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
S5_7AU_LAT, S5_7AU_LON = 53.4100, -1.4600
DEFAULT_RADIUS_M = 2500


def overpass_query(radius_m, lat, lon):
    """Query for toilets and benches (nodes) within radius."""
    # amenity=toilets, toilet; amenity=bench; leisure=bench (nodes)
    query = f"""
[out:json][timeout:25];
(
  node(around:{radius_m},{lat},{lon})["amenity"~"toilet"];
  node(around:{radius_m},{lat},{lon})["amenity"="bench"];
  node(around:{radius_m},{lat},{lon})["leisure"="bench"];
);
out body;
>;
out skel qt;
"""
    return query


def run_overpass(query):
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    req = urllib.request.Request(OVERPASS_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def element_to_row(elem, postcode, typ):
    """Convert Overpass node to sheet row: postcode, placeId, name, lat, lon, types, vicinity, source, rating."""
    tags = elem.get("tags") or {}
    lat = elem.get("lat")
    lon = elem.get("lon")
    if lat is None or lon is None:
        return None
    osm_id = elem.get("id", 0)
    place_id = f"osm_{typ}_{osm_id}"
    name = (tags.get("name") or "").strip() or (f"OSM {typ} ({osm_id})")
    # vicinity: address or description
    vicinity = (tags.get("addr:street") or tags.get("addr:full") or "").strip() or ""
    rating = ""
    return [postcode, place_id, name, lat, lon, typ, vicinity, "osm", rating]


def main():
    radius = DEFAULT_RADIUS_M
    postcode = "S5 7AU"
    lat, lon = S5_7AU_LAT, S5_7AU_LON

    print(f"Querying OSM (Overpass) for toilets and benches within {radius}m of {postcode} ({lat}, {lon})...", file=sys.stderr)
    query = overpass_query(radius, lat, lon)
    data = run_overpass(query)

    rows = []
    seen = set()
    for elem in data.get("elements", []):
        if elem.get("type") != "node":
            continue
        tags = elem.get("tags") or {}
        # Classify type
        typ = None
        if tags.get("amenity") in ("toilets", "toilet", "toilets;shower"):
            typ = "public_toilet"
        elif tags.get("amenity") == "bench" or tags.get("leisure") == "bench":
            typ = "bench"
        if not typ:
            continue
        key = (elem.get("lat"), elem.get("lon"), typ)
        if key in seen:
            continue
        seen.add(key)
        row = element_to_row(elem, postcode, typ)
        if row:
            rows.append(row)

    # Sort: toilets first, then benches; then by distance (optional: by lat)
    def sort_key(r):
        return (0 if "toilet" in r[5] else 1, r[3], r[4])
    rows.sort(key=sort_key)

    print(f"Found {len(rows)} OSM features ({sum(1 for r in rows if 'toilet' in r[5])} toilets, {sum(1 for r in rows if r[5]=='bench')} benches).", file=sys.stderr)

    # TSV output
    header = ["postcode", "placeId", "name", "latitude", "longitude", "types", "vicinity", "source", "rating"]
    print("\t".join(header))
    for row in rows:
        print("\t".join(str(x) for x in row))


if __name__ == "__main__":
    main()
