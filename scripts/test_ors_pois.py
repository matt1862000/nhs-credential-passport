#!/usr/bin/env python3
"""
Test OpenRouteService POI endpoint (openpoiservice / HeiGIT).
Uses the same request format as the iOS app: POST /pois with Point + buffer.

  python3 scripts/test_ors_pois.py
  OPEN_ROUTE_SERVICE_API_KEY=your_key python3 scripts/test_ors_pois.py

Loads OPEN_ROUTE_SERVICE_API_KEY from env or Secrets.xcconfig.
Optional: ORS_BASE_URL for proxy (e.g. https://waitwellv3.vercel.app/api/ors) - then key not sent.
"""

import json
import math
import os
import sys
import urllib.request
import urllib.error


def _load_secrets():
    for base in (os.getcwd(), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")):
        path = os.path.join(os.path.normpath(base), "Secrets.xcconfig")
        if os.path.isfile(path):
            try:
                out = {}
                with open(path, "r") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("//"):
                            continue
                        if "=" in line:
                            k, v = line.split("=", 1)
                            out[k.strip()] = v.strip()
                return out
            except OSError:
                pass
    return {}


def main():
    secrets = _load_secrets()
    key = (os.environ.get("OPEN_ROUTE_SERVICE_API_KEY", "") or secrets.get("OPEN_ROUTE_SERVICE_API_KEY", "")).strip()
    base_url = (os.environ.get("ORS_BASE_URL", "") or secrets.get("ORS_BASE_URL", "")).strip()

    use_proxy = bool(base_url)
    if use_proxy:
        url = f"{base_url.rstrip('/')}/pois"
        headers = {"Content-Type": "application/json"}
        print(f"Using proxy: POST {url} (no key in request)")
    else:
        url = "https://api.openrouteservice.org/pois"
        if not key:
            print("FAIL: Set OPEN_ROUTE_SERVICE_API_KEY or ORS_BASE_URL (or add to Secrets.xcconfig)")
            sys.exit(1)
        headers = {"Content-Type": "application/json", "Authorization": key}
        print(f"Using direct: POST {url}")

    # Location: optional postcode (UK, geocoded via postcodes.io) or default
    if len(sys.argv) >= 2:
        postcode = sys.argv[1].strip().replace(" ", "").upper()
        try:
            geo_url = f"https://api.postcodes.io/postcodes/{urllib.parse.quote(postcode)}"
            with urllib.request.urlopen(urllib.request.Request(geo_url), timeout=5) as r:
                geo = json.loads(r.read().decode())
            if geo.get("status") != 200 or "result" not in geo:
                print(f"FAIL: Could not geocode postcode {postcode}")
                sys.exit(1)
            lat = geo["result"]["latitude"]
            lon = geo["result"]["longitude"]
            print(f"Postcode {postcode} -> {lat:.5f}, {lon:.5f}")
        except Exception as e:
            print(f"FAIL: Geocode error for {postcode}: {e}")
            sys.exit(1)
    else:
        lat, lon = 53.6934, -1.5065  # Kirkhamgate default
    radius_m = 1000
    # Match app: bbox (required by public API) + geojson Point + buffer
    meters_per_degree_lat = 111_320.0
    meters_per_degree_lon = 111_320.0 * max(0.01, math.cos(math.radians(lat)))
    delta_lon = radius_m / meters_per_degree_lon
    delta_lat = radius_m / meters_per_degree_lat
    bbox = [[lon - delta_lon, lat - delta_lat], [lon + delta_lon, lat + delta_lat]]
    body = {
        "request": "pois",
        "geometry": {
            "geojson": {"type": "Point", "coordinates": [lon, lat]},
            "bbox": bbox,
            "buffer": radius_m,
        },
        "limit": 200,
    }
    data = json.dumps(body).encode()

    try:
        req = urllib.request.Request(url, data=data, method="POST", headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode() if e.fp else ""
        status = e.code
        print(f"HTTP {status}: {raw[:400]}")
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"URL error: {e.reason}")
        sys.exit(1)

    if status != 200:
        print(f"FAIL status={status} body={raw[:500]}")
        sys.exit(1)

    out = json.loads(raw)
    features = out.get("features") or []
    print(f"OK: {len(features)} POIs returned from ORS\n")
    named_count = 0
    for i, f in enumerate(features):
        geom = f.get("geometry") or {}
        coords = geom.get("coordinates") or [0, 0]
        props = f.get("properties") or {}
        osm_tags = props.get("osm_tags") or {}
        name = props.get("name") or props.get("asciiName") or osm_tags.get("name") or "(no name)"
        if name != "(no name)":
            named_count += 1
        print(f"  {i+1}. {name} @ {coords[1]:.5f}, {coords[0]:.5f}")
    print(f"\nNamed: {named_count}/{len(features)} (using name, asciiName, or osm_tags.name)")
    print("ORS POI fetch test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
