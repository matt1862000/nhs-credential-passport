#!/usr/bin/env python3
"""
Generate sector-indexed POI files for WalkingWR.
One JSON per district (e.g. prepopulated_pois_WF1.json), with sectors inside.

Output format (version 2):
{
  "version": 2,
  "lastUpdated": "...",
  "postcodeAreas": [{
    "postcode": "WF1",
    "radiusMeters": 2500,
    "sectors": [
      { "sector": "WF1 1", "centerLatitude": ..., "centerLongitude": ..., "pois": [...] },
      { "sector": "WF1 2", ... }
    ]
  }]
}

Uses canonical WF districts (WF1–WF17, WF90) and fetches sector list per district from https://www.streetlist.co.uk/wf/wfX .
Usage:
  python3 scripts/generate_sector_pois.py                     # All WF districts
  python3 scripts/generate_sector_pois.py --district WF1      # Single district
  python3 scripts/generate_sector_pois.py --district WF1 --no-clean  # Skip cleaning
"""

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import List, Optional

# --- Config ---
# Canonical WF districts from https://www.streetlist.co.uk/wf/ (Wakefield area: WF1–WF17, WF90)
KNOWN_WF_DISTRICTS = [f"WF{i}" for i in range(1, 18)] + ["WF90"]
ALL_WF_DISTRICTS = KNOWN_WF_DISTRICTS
SECTORS_TO_TRY = list(range(0, 10))
KNOWN_SECTORS_BY_DISTRICT = {}  # Optional override; else fetched from streetlist per district
STREETLIST_BASE_URL = "https://www.streetlist.co.uk/wf/"
RADIUS_METERS = 2500
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
GEOGRAPH_API_KEY = "df200a5f61"
GEOGRAPH_BASE_URL = "https://api.geograph.org.uk/syndicator.php"
OSM_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
]
OUTPUT_DIR = Path(__file__).resolve().parent.parent  # project root

# Restricted POI patterns
RESTRICTED_NAME_PATTERNS = [
    "playcare", "daycare", "preschool", "nursery", "kindergarten",
    "childcare", "playground", "playarea", "playgroup", "creche",
]
RESTRICTED_TYPES = {
    "kindergarten", "nursery", "playground", "preschool", "daycare", "childcare",
}
VAGUE_TYPES = {"vacant", "yes", "no", "unknown", "other"}

# Type synonyms for normalisation
TYPE_SYNONYMS = {
    "café": "cafe", "barbers": "hairdresser", "barber": "hairdresser",
    "super market": "supermarket",
}

# Human-readable labels for unnamed POIs
TYPE_LABELS = {
    "beauty": "Beauty Salon", "charity": "Charity Shop", "pharmacy": "Pharmacy",
    "convenience": "Convenience Store", "supermarket": "Supermarket",
    "post_box": "Post Box", "telephone": "Telephone Kiosk",
    "parking": "Car Park", "bicycle_parking": "Bicycle Parking",
    "recycling": "Recycling Point", "grit_bin": "Grit Bin",
    "bench": "Bench", "waste_basket": "Waste Bin",
}


def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


# ============================================================
# Phase 1: Discover sectors via geocoding
# ============================================================

INWARD_SUFFIXES = ["AA", "AB", "FG", "EH", "BL", "AD", "PQ"]


def fetch_sectors_from_streetlist(district: str) -> Optional[List[int]]:
    """Fetch geographic sector list from https://www.streetlist.co.uk/wf/wfX (e.g. /wf/wf1).
    Parses Postcode Sectors and excludes any sector marked 'non-geographic'. Returns sorted list of sector digits, or None on failure."""
    url = f"{STREETLIST_BASE_URL}{district.lower()}"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "WalkingWR-POI-Fetch/1.0")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  ⚠️  Could not fetch {url}: {e}")
        return None
    escaped = re.escape(district)
    sector_matches = set()
    for m in re.finditer(rf"\b{escaped}\s+(\d)\b", html, re.IGNORECASE):
        d = int(m.group(1))
        if 0 <= d <= 9:
            sector_matches.add(d)
    non_geo = set()
    for m in re.finditer(rf"\b{escaped}\s+(\d)\s+is\s+non-geographic", html, re.IGNORECASE):
        non_geo.add(int(m.group(1)))
    sector_matches -= non_geo
    if not sector_matches:
        return None
    return sorted(sector_matches)


def geocode_sector(district: str, sector_digit: int) -> tuple:
    """Geocode e.g. 'WF1 1FG' → (lat, lon) or None. Tries multiple inward suffixes. Validates result is in West Yorkshire."""
    for suffix in INWARD_SUFFIXES:
        postcode = f"{district} {sector_digit}{suffix}"
        params = urllib.parse.urlencode({
            "q": postcode,
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
                if 53.3 <= lat <= 53.9 and -1.8 <= lon <= -1.1:
                    return (lat, lon)
        except Exception:
            pass
        time.sleep(1.1)  # Nominatim: max 1 req/sec per request
    return None


def discover_sectors(district: str, sector_digits: Optional[List[int]] = None) -> list:
    """Returns list of (sector_label, lat, lon) for valid sectors. sector_digits: if provided use it; else KNOWN_SECTORS_BY_DISTRICT or 0–9."""
    if sector_digits is None:
        sector_digits = KNOWN_SECTORS_BY_DISTRICT.get(district, SECTORS_TO_TRY)
    sectors = []
    for s in sector_digits:
        result = geocode_sector(district, s)
        time.sleep(1.1)  # Nominatim: max 1 req/sec
        label = f"{district} {s}"
        if result:
            lat, lon = result
            sectors.append((label, lat, lon))
            print(f"  ✅ {label:8s} → ({lat:.4f}, {lon:.4f})")
        else:
            print(f"  ⬜ {label:8s} → not found / invalid")
        sys.stdout.flush()
    return sectors


# ============================================================
# Phase 2: Fetch POIs per sector
# ============================================================

def fetch_osm_pois(lat, lon, radius):
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
        except Exception:
            continue
    return []


def fetch_geograph_pois(lat, lon, radius):
    if not GEOGRAPH_API_KEY:
        return []
    try:
        params = urllib.parse.urlencode({
            "key": GEOGRAPH_API_KEY,
            "location": f"{lat},{lon}",
            "distance": radius / 1000.0,
            "perpage": 100,
            "format": "JSON",
            "ll": 1, "thumb": 1, "desc": 1,
        })
        url = f"{GEOGRAPH_BASE_URL}?{params}"
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "WalkingWR-POI-Fetch/1.0")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        pois = []
        for item in data.get("items", []):
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


# ============================================================
# Phase 3: Clean / dedupe / normalise
# ============================================================

def normalise_name(raw):
    s = (raw or "").strip()
    s = re.sub(r"  +", " ", s)
    s = re.sub(r"\s*&\s*", " & ", s)
    s = re.sub(r",\s*$", "", s).strip()
    if not s:
        return ""
    words = s.split()
    out = []
    for w in words:
        if not w:
            continue
        w = w[0].upper() + w[1:].lower() if len(w) > 1 else w.upper()
        if w.endswith("'S"):
            w = w[:-2] + "'s"
        out.append(w)
    return " ".join(out)


def normalise_vicinity(v):
    if not v or not str(v).strip():
        return None
    s = str(v).strip()
    s = re.sub(r"[^\w\s&'-]", "", s)
    s = re.sub(r"  +", " ", s).strip()
    if not s:
        return None
    words = s.split()
    return " ".join(w[0].upper() + w[1:].lower() if len(w) > 1 else w.upper() for w in words if w)


def clean_types(types):
    seen = set()
    result = []
    for t in types:
        s = str(t).strip().lower().replace(" ", "_")
        s = TYPE_SYNONYMS.get(s, s)
        if s and s not in seen:
            seen.add(s)
            result.append(s)
    return result


def is_restricted(poi):
    n = (poi.get("name") or "").lower().replace("'", "").replace("\u2019", "").replace(" ", "")
    if any(p in n for p in RESTRICTED_NAME_PATTERNS):
        return True
    if RESTRICTED_TYPES & {t.lower() for t in (poi.get("types") or [])}:
        return True
    return False


def handle_unnamed(poi):
    name = (poi.get("name") or "").strip()
    if name.lower() != "unnamed":
        return poi
    types = poi.get("types") or []
    t = types[0] if types else "unknown"
    if t in VAGUE_TYPES:
        return None  # Remove vague unnamed
    label = TYPE_LABELS.get(t, t.replace("_", " ").title())
    vic = normalise_vicinity(poi.get("vicinity"))
    if vic:
        poi = dict(poi, name=f"{label} \u2013 {vic} (est.)")
    else:
        poi = dict(poi, name=f"{label} (ID: {poi.get('placeId', '?')})")
    return poi


def deduplicate(pois):
    kept = []
    for p in pois:
        lat, lon = p["latitude"], p["longitude"]
        name = (p.get("name") or "").strip().lower()
        dup = False
        for k in kept:
            klat, klon = k["latitude"], k["longitude"]
            dist = haversine_m(lat, lon, klat, klon)
            kname = (k.get("name") or "").strip().lower()
            if dist < 5 and name == kname:
                dup = True
                break
            if dist < 200 and name == kname:
                dup = True
                break
        if not dup:
            kept.append(p)
    return kept


def clean_pois(pois):
    """Full cleaning pipeline: normalise, filter, dedupe."""
    out = []
    for p in pois:
        if is_restricted(p):
            continue
        p = dict(p)
        p["name"] = normalise_name(p.get("name"))
        p["vicinity"] = normalise_vicinity(p.get("vicinity"))
        p["types"] = clean_types(p.get("types") or [])
        p = handle_unnamed(p)
        if p is None:
            continue
        if not p.get("name") or not p["name"].strip():
            continue
        # Validate coords
        try:
            lat, lon = float(p["latitude"]), float(p["longitude"])
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                continue
        except (TypeError, ValueError):
            continue
        out.append(p)
    return deduplicate(out)


def fetch_and_clean_sector(label, lat, lon, radius):
    """Fetch OSM + Geograph POIs, clean, return list."""
    osm = fetch_osm_pois(lat, lon, radius)
    time.sleep(1)
    geo = fetch_geograph_pois(lat, lon, radius)
    time.sleep(1)
    combined = osm + geo
    cleaned = clean_pois(combined)
    return cleaned, len(osm), len(geo)


# ============================================================
# Main
# ============================================================

def process_district(district: str) -> dict:
    """Process all sectors for a district, return sector-indexed data."""
    print(f"\n{'='*60}")
    print(f"  DISTRICT: {district}")
    print(f"{'='*60}")
    sys.stdout.flush()

    # Get sector list: override from KNOWN_SECTORS_BY_DISTRICT, else fetch from streetlist.co.uk/wf/wfX.
    if district in KNOWN_SECTORS_BY_DISTRICT:
        sector_digits = KNOWN_SECTORS_BY_DISTRICT[district]
        print(f"\n  Discovering sectors {district} {sector_digits} (from config)...")
    else:
        print(f"\n  Fetching sector list from https://www.streetlist.co.uk/wf/{district.lower()} ...")
        sector_digits = fetch_sectors_from_streetlist(district)
        if sector_digits is not None:
            print(f"  → Geographic sectors: {sector_digits}")
        else:
            sector_digits = SECTORS_TO_TRY
            print(f"  → Using 0–9 (fetch failed or no sectors parsed)")
        time.sleep(1.0)  # be nice to streetlist
    sectors = discover_sectors(district, sector_digits)
    if not sectors:
        print(f"  ⚠️  No valid sectors found for {district}")
        return None

    print(f"\n  Found {len(sectors)} sectors for {district}")
    print(f"  Fetching POIs per sector...\n")
    sys.stdout.flush()

    sector_data = []
    total_pois = 0

    for i, (label, lat, lon) in enumerate(sectors, 1):
        t0 = time.time()
        pois, osm_count, geo_count = fetch_and_clean_sector(label, lat, lon, RADIUS_METERS)
        elapsed = time.time() - t0
        total_pois += len(pois)

        sector_data.append({
            "sector": label,
            "centerLatitude": lat,
            "centerLongitude": lon,
            "pois": pois,
        })

        pct = int(i / len(sectors) * 100)
        bar = "\u2588" * (pct // 2) + "\u2591" * (50 - pct // 2)
        print(f"  [{i}/{len(sectors)}] {label:8s} | OSM:{osm_count:>4} Geo:{geo_count:>3} → {len(pois):>4} POIs | {elapsed:.1f}s")
        print(f"  [{bar}] {pct}%")
        sys.stdout.flush()

    # Compute district-level centre (average of sector centres)
    if sector_data:
        avg_lat = sum(s["centerLatitude"] for s in sector_data) / len(sector_data)
        avg_lon = sum(s["centerLongitude"] for s in sector_data) / len(sector_data)
    else:
        avg_lat, avg_lon = 0, 0

    print(f"\n  ✅ {district}: {len(sector_data)} sectors, {total_pois} total POIs")
    sys.stdout.flush()

    return {
        "postcode": district,
        "centerLatitude": round(avg_lat, 6),
        "centerLongitude": round(avg_lon, 6),
        "radiusMeters": RADIUS_METERS,
        "sectors": sector_data,
    }


def main():
    parser = argparse.ArgumentParser(description="Generate sector-indexed POI files for WalkingWR.")
    parser.add_argument("--district", type=str, default=None,
                        help="Process only this district (e.g. WF1). Default: all WF1–WF17, WF90 (streetlist.co.uk).")
    args = parser.parse_args()

    districts = [args.district.upper()] if args.district else KNOWN_WF_DISTRICTS

    print("=" * 60)
    print("  WAKEFIELD (WF) SECTOR-INDEXED POI GENERATOR")
    print(f"  Districts: {len(districts)} (streetlist.co.uk/wf/)")
    print(f"  Sectors: from streetlist per district (or 0–9 fallback)")
    print(f"  Radius: {RADIUS_METERS}m per sector")
    print(f"  Sources: OSM (Overpass) + Geograph")
    print("=" * 60)
    sys.stdout.flush()

    generated = []
    total = len(districts)
    for idx, district in enumerate(districts, 1):
        ts = datetime.utcnow().strftime("%H:%M:%S")
        print(f"\n  --- [{ts}] {district} ({idx}/{total}) | Generated so far: {len(generated)} ---")
        sys.stdout.flush()
        result = process_district(district)
        if result is None:
            print(f"  → {district} skipped (no valid sectors)")
            sys.stdout.flush()
            continue

        # Write one file per district
        out_file = OUTPUT_DIR / f"prepopulated_pois_{district}.json"
        db = {
            "version": 2,
            "lastUpdated": datetime.utcnow().isoformat() + "Z",
            "postcodeAreas": [result],
        }
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(db, f, indent=2, ensure_ascii=False)

        size_kb = out_file.stat().st_size / 1024
        total_pois = sum(len(s["pois"]) for s in result["sectors"])
        print(f"  📄 Wrote {out_file.name} ({size_kb:.0f} KB, {len(result['sectors'])} sectors, {total_pois} POIs)")
        generated.append(district)
        print(f"  → {district} done. Total generated: {len(generated)}")
        sys.stdout.flush()

    # Final summary
    print(f"\n{'='*60}")
    print(f"  ALL DONE — {len(generated)} districts generated")
    print(f"{'='*60}")
    for district in generated:
        f = OUTPUT_DIR / f"prepopulated_pois_{district}.json"
        if f.exists():
            size = f.stat().st_size / 1024
            print(f"  {f.name:>35s}  {size:>6.0f} KB")
    print()
    sys.stdout.flush()


if __name__ == "__main__":
    main()
