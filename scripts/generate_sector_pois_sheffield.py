#!/usr/bin/env python3
"""
Generate sector-indexed POI files for Sheffield (S postcodes).
Adapted from generate_sector_pois.py (Wakefield).

Sheffield postcodes: S1-S45 (with gaps).
Output: prepopulated_pois_S1.json, prepopulated_pois_S2.json, etc.

Usage:
  python3 scripts/generate_sector_pois_sheffield.py                    # All S districts
  python3 scripts/generate_sector_pois_sheffield.py --district S1      # Single district
"""

import argparse
import json
import math
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# --- Config ---
# Sheffield postcodes: S1-S14, S17-S18, S20-S21, S25-S26, S30-S36, S40-S45, S60-S66, S70-S75, S80-S81
# We'll try S1-S81 and let geocoding filter out invalid ones
ALL_S_DISTRICTS = [f"S{i}" for i in range(1, 82)]
SECTORS_TO_TRY = list(range(0, 10))
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

TYPE_SYNONYMS = {
    "café": "cafe", "barbers": "hairdresser", "barber": "hairdresser",
    "super market": "supermarket",
}

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

def geocode_sector(district: str, sector_digit: int) -> tuple:
    """Geocode e.g. 'S1 1AA' → (lat, lon) or None. Validates result is in South Yorkshire."""
    postcode = f"{district} {sector_digit}AA"
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
            # Validate: must be in roughly the Sheffield/South Yorkshire area
            # Sheffield area: lat ~53.1–53.6, lon ~-1.8 to -0.9
            if 53.1 <= lat <= 53.7 and -1.9 <= lon <= -0.8:
                return (lat, lon)
            else:
                return None  # Wrong location
    except Exception:
        pass
    return None


def discover_sectors(district: str) -> list:
    """Returns list of (sector_label, lat, lon) for valid sectors in the district."""
    sectors = []
    for s in SECTORS_TO_TRY:
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
        return None
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
        try:
            lat, lon = float(p["latitude"]), float(p["longitude"])
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                continue
        except (TypeError, ValueError):
            continue
        out.append(p)
    return deduplicate(out)


def fetch_and_clean_sector(label, lat, lon, radius):
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
    print(f"\n{'='*60}")
    print(f"  DISTRICT: {district}")
    print(f"{'='*60}")
    sys.stdout.flush()

    print(f"\n  Discovering sectors...")
    sectors = discover_sectors(district)
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
    parser = argparse.ArgumentParser(description="Generate sector-indexed POI files for Sheffield (S postcodes).")
    parser.add_argument("--district", type=str, default=None,
                        help="Process only this district (e.g. S1). Default: all S1–S81.")
    args = parser.parse_args()

    districts = [args.district.upper()] if args.district else ALL_S_DISTRICTS

    print("=" * 60)
    print("  SHEFFIELD SECTOR-INDEXED POI GENERATOR")
    print(f"  Districts: {districts[0]}–{districts[-1]} ({len(districts)} to try)")
    print(f"  Sectors per district: 0–9 (valid ones kept)")
    print(f"  Radius: {RADIUS_METERS}m per sector")
    print(f"  Sources: OSM (Overpass) + Geograph")
    print("=" * 60)
    sys.stdout.flush()

    generated = []
    for district in districts:
        result = process_district(district)
        if result is None:
            continue

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
        print(f"\n  📄 Wrote {out_file.name} ({size_kb:.0f} KB, {len(result['sectors'])} sectors, {total_pois} POIs)")
        generated.append(district)
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
