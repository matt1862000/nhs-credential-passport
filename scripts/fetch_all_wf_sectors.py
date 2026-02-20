#!/usr/bin/env python3
"""
Fetch POIs (OSM + Geograph) for ALL Wakefield postcode sectors.
Discovers sectors by geocoding, then runs POI fetch per sector.

Usage:
  python3 scripts/fetch_all_wf_sectors.py
"""

import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# --- Config ---
WF_DISTRICTS = list(range(1, 18))  # WF1 through WF17
SECTORS_TO_TRY = list(range(0, 10))  # 0-9 for each district
RADIUS_METERS = 2500
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
# Set GEOGRAPH_API_KEY env var or leave empty to skip Geograph (get key from https://www.geograph.org.uk/help/api)
GEOGRAPH_API_KEY = os.environ.get("GEOGRAPH_API_KEY", "")
GEOGRAPH_BASE_URL = "https://api.geograph.org.uk/syndicator.php"
OSM_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
]
OUTPUT_DIR = Path(__file__).resolve().parent.parent  # project root

# --- Geocode ---
def geocode_sector(district: int, sector: int) -> tuple:
    """Geocode e.g. 'WF1 1AA' → (lat, lon) or None."""
    postcode = f"WF{district} {sector}AA"
    params = urllib.parse.urlencode({
        "q": postcode + ", UK",
        "format": "json",
        "limit": 1,
        "countrycodes": "gb",
    })
    url = f"{NOMINATIM_URL}?{params}"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "WalkingWR-POI-Fetch/1.0")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
        if data:
            lat = float(data[0]["lat"])
            lon = float(data[0]["lon"])
            return (lat, lon)
    except Exception:
        pass
    return None


# --- OSM fetch ---
def fetch_osm_pois(lat: float, lon: float, radius: int) -> list:
    query = f"""
    [out:json][timeout:30];
    (
      node["amenity"](around:{radius},{lat},{lon});
      node["shop"](around:{radius},{lat},{lon});
      node["tourism"](around:{radius},{lat},{lon});
      node["historic"](around:{radius},{lat},{lon});
      node["leisure"](around:{radius},{lat},{lon});
      way["amenity"](around:{radius},{lat},{lon});
      way["shop"](around:{radius},{lat},{lon});
      way["tourism"](around:{radius},{lat},{lon});
      way["historic"](around:{radius},{lat},{lon});
      way["leisure"](around:{radius},{lat},{lon});
    );
    out center;
    """
    for mirror in OSM_MIRRORS:
        try:
            data_bytes = urllib.parse.urlencode({"data": query}).encode("utf-8")
            req = urllib.request.Request(mirror, data=data_bytes, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.load(resp)
            pois = []
            for elem in result.get("elements", []):
                if elem.get("type") == "node":
                    elat, elon = elem.get("lat"), elem.get("lon")
                elif elem.get("type") == "way" and "center" in elem:
                    elat, elon = elem["center"].get("lat"), elem["center"].get("lon")
                else:
                    continue
                if elat is None or elon is None:
                    continue
                tags = elem.get("tags", {})
                name = tags.get("name") or tags.get("addr:housename") or "Unnamed"
                types = []
                for key in ["amenity", "shop", "tourism", "historic", "leisure"]:
                    if key in tags:
                        types.append(tags[key])
                vicinity = tags.get("addr:street") or tags.get("addr:city") or None
                pois.append({
                    "placeId": f"osm_{elem.get('id')}",
                    "name": name,
                    "latitude": elat,
                    "longitude": elon,
                    "types": types,
                    "vicinity": vicinity,
                    "source": "osm",
                    "rating": None,
                })
            return pois
        except Exception as e:
            continue
    return []


# --- Geograph fetch ---
def fetch_geograph_pois(lat: float, lon: float, radius: int) -> list:
    if not GEOGRAPH_API_KEY:
        return []
    try:
        params = urllib.parse.urlencode({
            "key": GEOGRAPH_API_KEY,
            "location": f"{lat},{lon}",
            "distance": radius / 1000.0,
            "perpage": 100,
            "format": "JSON",
            "ll": 1,
            "thumb": 1,
            "desc": 1,
        })
        url = f"{GEOGRAPH_BASE_URL}?{params}"
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "WalkingWR-POI-Fetch/1.0")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        items = data.get("items", [])
        pois = []
        for item in items:
            elat = float(item.get("lat", 0))
            elon = float(item.get("long", 0))
            if elat == 0 and elon == 0:
                continue
            name = item.get("title", "Unnamed")
            if " : " in name:
                name = name.split(" : ", 1)[1]
            pois.append({
                "placeId": f"geograph_{item.get('guid', '')}",
                "name": name,
                "latitude": elat,
                "longitude": elon,
                "types": ["geograph"],
                "vicinity": None,
                "source": "geograph",
                "rating": None,
            })
        return pois
    except Exception:
        return []


# --- Deduplicate ---
def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


def deduplicate(pois, lat, lon):
    seen = set()
    kept = []
    for p in pois:
        key = (p["name"].lower().strip(), round(p["latitude"], 4), round(p["longitude"], 4))
        if key in seen:
            continue
        dup = False
        for e in kept:
            if e["name"].lower().strip() == p["name"].lower().strip():
                if haversine_m(p["latitude"], p["longitude"], e["latitude"], e["longitude"]) < 200:
                    dup = True
                    break
        if not dup:
            seen.add(key)
            kept.append(p)
    return kept


def filter_restricted(pois):
    BAD = ["playcare", "daycare", "preschool", "nursery", "kindergarten",
           "childcare", "playground", "playarea", "playgroup", "creche"]
    BAD_TYPES = {"kindergarten", "nursery", "playground", "preschool", "daycare", "childcare"}
    out = []
    for p in pois:
        n = p.get("name", "").lower().replace("'", "").replace(" ", "")
        if any(b in n for b in BAD):
            continue
        if BAD_TYPES & {t.lower() for t in (p.get("types") or [])}:
            continue
        out.append(p)
    return out


def filter_unnamed(pois):
    return [p for p in pois if (p.get("name") or "").strip().lower() not in ("", "unnamed")]


# --- Main ---
def main():
    print("=" * 70)
    print("  WAKEFIELD POSTCODE SECTOR POI FETCH")
    print("  Districts: WF1 – WF17 | Sectors: 0–9 each")
    print("=" * 70)
    print()
    sys.stdout.flush()

    # Phase 1: Discover valid sectors
    print("PHASE 1: Discovering valid sectors via geocoding...")
    print("-" * 50)
    sys.stdout.flush()
    valid_sectors = []
    for d in WF_DISTRICTS:
        found_for_district = []
        for s in SECTORS_TO_TRY:
            result = geocode_sector(d, s)
            time.sleep(1.1)  # Nominatim: max 1 req/sec
            if result:
                lat, lon = result
                label = f"WF{d} {s}"
                found_for_district.append((label, lat, lon))
                print(f"  ✅ {label:8s} → ({lat:.4f}, {lon:.4f})")
            else:
                print(f"  ⬜ WF{d} {s}  → not found")
            sys.stdout.flush()
        valid_sectors.extend(found_for_district)
        print(f"  WF{d}: {len(found_for_district)} sector(s)\n")
        sys.stdout.flush()

    print(f"\n{'=' * 50}")
    print(f"  Found {len(valid_sectors)} valid sectors across WF1–WF17")
    print(f"{'=' * 50}\n")
    sys.stdout.flush()

    # Phase 2: Fetch POIs per sector
    print("PHASE 2: Fetching POIs (OSM + Geograph) per sector...")
    print("-" * 50)
    sys.stdout.flush()

    all_results = []
    total = len(valid_sectors)
    grand_total_pois = 0

    for i, (label, lat, lon) in enumerate(valid_sectors, 1):
        t0 = time.time()
        print(f"\n[{i}/{total}] {label} ({lat:.4f}, {lon:.4f})")
        sys.stdout.flush()

        # OSM
        osm = fetch_osm_pois(lat, lon, RADIUS_METERS)
        print(f"    OSM: {len(osm)} POIs", end="")
        sys.stdout.flush()
        time.sleep(1)

        # Geograph
        geo = fetch_geograph_pois(lat, lon, RADIUS_METERS)
        print(f"  |  Geograph: {len(geo)} POIs", end="")
        sys.stdout.flush()
        time.sleep(1)

        # Process
        combined = osm + geo
        deduped = deduplicate(combined, lat, lon)
        filtered = filter_restricted(deduped)
        filtered = filter_unnamed(filtered)

        elapsed = time.time() - t0
        print(f"  |  Final: {len(filtered)} POIs  ({elapsed:.1f}s)")
        sys.stdout.flush()

        grand_total_pois += len(filtered)

        # Write per-sector JSON
        safe_label = label.replace(" ", "_")
        out_file = OUTPUT_DIR / f"prepopulated_pois_{safe_label}.json"
        db = {
            "version": 1,
            "lastUpdated": datetime.utcnow().isoformat() + "Z",
            "postcodeAreas": [{
                "postcode": label,
                "centerLatitude": lat,
                "centerLongitude": lon,
                "radiusMeters": RADIUS_METERS,
                "pois": filtered,
                "routes": [],
            }],
        }
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(db, f, indent=2, ensure_ascii=False)

        all_results.append((label, len(filtered), str(out_file.name)))

        # Progress bar
        pct = int(i / total * 100)
        bar = "█" * (pct // 2) + "░" * (50 - pct // 2)
        print(f"    [{bar}] {pct}%  ({i}/{total})")
        sys.stdout.flush()

    # Summary
    print(f"\n{'=' * 70}")
    print(f"  COMPLETE: {total} sectors processed, {grand_total_pois} total POIs")
    print(f"{'=' * 70}")
    print(f"\n{'Label':<10} {'POIs':>6}  File")
    print(f"{'-'*10} {'-'*6}  {'-'*40}")
    for label, count, fname in all_results:
        print(f"{label:<10} {count:>6}  {fname}")
    print(f"\n{'TOTAL':<10} {grand_total_pois:>6}")
    print(f"\nAll files in: {OUTPUT_DIR}")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
