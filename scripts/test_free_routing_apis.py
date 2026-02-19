#!/usr/bin/env python3
"""
Test OSRM, OpenRouteService (Directions, Isochrones V2, Matrix V2), and GraphHopper
routing APIs with the same request format the iOS app uses. Run from repo root.

  # OSRM only (no keys needed):
  python3 scripts/test_free_routing_apis.py

  # With ORS and GraphHopper: set env vars, or run from repo root to use Secrets.xcconfig
  OPEN_ROUTE_SERVICE_API_KEY=your_key GRAPHHOPPER_API_KEY=your_key python3 scripts/test_free_routing_apis.py
  python3 scripts/test_free_routing_apis.py   # uses Secrets.xcconfig if present

  # Optional: custom coordinates (lat,lon lat,lon lat,lon for origin waypoint destination)
  python3 scripts/test_free_routing_apis.py 53.6934 -1.5065 53.701 -1.498 53.6934 -1.5065
"""

import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse


def _load_secrets_xcconfig():
    """Load OPEN_ROUTE_SERVICE_API_KEY and GRAPHHOPPER_API_KEY from Secrets.xcconfig if present."""
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


# Default: round-trip route (Kirkhamgate area). Override with CLI args: origin_lat origin_lon wp_lat wp_lon dest_lat dest_lon
def _coords():
    if len(sys.argv) >= 7:
        return (
            (float(sys.argv[1]), float(sys.argv[2])),
            (float(sys.argv[3]), float(sys.argv[4])),
            (float(sys.argv[5]), float(sys.argv[6])),
        )
    return (53.6934, -1.5065), (53.7010, -1.4980), (53.6934, -1.5065)


ORIGIN, WAYPOINT, DESTINATION = _coords()


def request(url, method="GET", data=None, headers=None, timeout=10):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode(), resp.status


def test_osrm():
    """OSRM: GET .../route/v1/foot/lon,lat;lon,lat?overview=full&geometries=polyline"""
    print("Testing OSRM (router.project-osrm.org)...")
    coords = [
        f"{ORIGIN[1]},{ORIGIN[0]}",
        f"{WAYPOINT[1]},{WAYPOINT[0]}",
        f"{DESTINATION[1]},{DESTINATION[0]}",
    ]
    path = ";".join(coords)
    url = f"https://router.project-osrm.org/route/v1/foot/{path}?overview=full&geometries=polyline"
    try:
        body, status = request(url, timeout=5)
        if status != 200:
            print(f"  FAIL status={status} body={body[:200]}")
            return False
        data = json.loads(body)
        if data.get("code") != "Ok":
            print(f"  FAIL code={data.get('code')} message={data.get('message', '')}")
            return False
        routes = data.get("routes") or []
        if not routes:
            print("  FAIL no routes")
            return False
        r = routes[0]
        dist = r.get("distance", 0)
        dur = r.get("duration", 0)
        print(f"  OK distance={int(dist)}m duration={int(dur)}s ({int(dur/60)}min)")
        return True
    except urllib.error.HTTPError as e:
        print(f"  FAIL HTTP {e.code} {e.reason}")
        return False
    except urllib.error.URLError as e:
        print(f"  FAIL URL error: {e.reason}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def test_openrouteservice():
    """OpenRouteService: POST .../v2/directions/foot-walking with JSON coordinates [lon,lat]"""
    print("Testing OpenRouteService (api.openrouteservice.org)...")
    key = (os.environ.get("OPEN_ROUTE_SERVICE_API_KEY", "").strip() or _load_secrets_xcconfig().get("OPEN_ROUTE_SERVICE_API_KEY", "")).strip()
    if not key:
        print("  SKIP (set OPEN_ROUTE_SERVICE_API_KEY to test)")
        return None
    coords = [
        [ORIGIN[1], ORIGIN[0]],
        [WAYPOINT[1], WAYPOINT[0]],
        [DESTINATION[1], DESTINATION[0]],
    ]
    url = "https://api.openrouteservice.org/v2/directions/foot-walking"
    payload = json.dumps({"coordinates": coords}).encode()
    headers = {
        "Authorization": key,
        "Content-Type": "application/json",
    }
    try:
        body, status = request(url, method="POST", data=payload, headers=headers, timeout=10)
        if status != 200:
            print(f"  FAIL status={status} body={body[:300]}")
            return False
        data = json.loads(body)
        routes = data.get("routes") or []
        if not routes:
            print("  FAIL no routes")
            return False
        summary = routes[0].get("summary") or {}
        dist = summary.get("distance", 0)
        dur = summary.get("duration", 0)
        print(f"  OK distance={int(dist)}m duration={int(dur)}s ({int(dur/60)}min)")
        return True
    except urllib.error.HTTPError as e:
        print(f"  FAIL HTTP {e.code} {e.reason} {e.read().decode()[:200]}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def test_ors_isochrones():
    """OpenRouteService Isochrones V2: POST .../v2/isochrones/foot-walking with locations and range (seconds)."""
    print("Testing OpenRouteService Isochrones V2 (api.openrouteservice.org)...")
    key = (os.environ.get("OPEN_ROUTE_SERVICE_API_KEY", "").strip() or _load_secrets_xcconfig().get("OPEN_ROUTE_SERVICE_API_KEY", "")).strip()
    if not key:
        print("  SKIP (set OPEN_ROUTE_SERVICE_API_KEY to test)")
        return None
    # Single location [lon, lat]; multi-band in one call: 10, 20, 30 min
    locations = [[ORIGIN[1], ORIGIN[0]]]
    payload = json.dumps({"locations": locations, "range": [600, 1200, 1800]}).encode()
    url = "https://api.openrouteservice.org/v2/isochrones/foot-walking"
    headers = {
        "Authorization": key,
        "Content-Type": "application/json",
    }
    try:
        body, status = request(url, method="POST", data=payload, headers=headers, timeout=15)
        if status != 200:
            print(f"  FAIL status={status} body={body[:300]}")
            return False
        data = json.loads(body)
        features = data.get("features")
        if not features or not isinstance(features, list):
            print("  FAIL no features or invalid response")
            return False
        for f in features:
            if not f.get("geometry") or not f.get("properties"):
                print("  FAIL feature missing geometry or properties")
                return False
        print(f"  OK {len(features)} isochrone band(s) (10/20/30 min)")
        return True
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()[:200] if e.fp else ""
        print(f"  FAIL HTTP {e.code} {e.reason} {err_body}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def test_ors_matrix():
    """OpenRouteService Matrix V2: POST .../v2/matrix/foot-walking with locations; returns durations matrix."""
    print("Testing OpenRouteService Matrix V2 (api.openrouteservice.org)...")
    key = (os.environ.get("OPEN_ROUTE_SERVICE_API_KEY", "").strip() or _load_secrets_xcconfig().get("OPEN_ROUTE_SERVICE_API_KEY", "")).strip()
    if not key:
        print("  SKIP (set OPEN_ROUTE_SERVICE_API_KEY to test)")
        return None
    locations = [
        [ORIGIN[1], ORIGIN[0]],
        [WAYPOINT[1], WAYPOINT[0]],
        [DESTINATION[1], DESTINATION[0]],
    ]
    payload = json.dumps({"locations": locations, "metrics": ["duration"]}).encode()
    url = "https://api.openrouteservice.org/v2/matrix/foot-walking"
    headers = {
        "Authorization": key,
        "Content-Type": "application/json",
    }
    try:
        body, status = request(url, method="POST", data=payload, headers=headers, timeout=15)
        if status != 200:
            print(f"  FAIL status={status} body={body[:300]}")
            return False
        data = json.loads(body)
        durations = data.get("durations")
        if not durations or not isinstance(durations, list):
            print("  FAIL no durations or invalid response")
            return False
        if len(durations) != 3 or len(durations[0]) != 3:
            print(f"  FAIL expected 3x3 matrix, got {len(durations)}x{len(durations[0]) if durations else 0}")
            return False
        if durations[0][0] != 0:
            print(f"  FAIL origin-to-origin should be 0, got {durations[0][0]}")
            return False
        for i in range(3):
            for j in range(3):
                v = durations[i][j]
                if not isinstance(v, (int, float)) or v < 0:
                    print(f"  FAIL durations[{i}][{j}] should be non-negative, got {v}")
                    return False
        # At least one off-diagonal should be positive (different points)
        off_diag = [durations[i][j] for i in range(3) for j in range(3) if i != j]
        if not any(v > 0 for v in off_diag):
            print("  FAIL at least one off-diagonal duration should be positive")
            return False
        # Plausible walking: e.g. 100s–3600s between points in test area
        max_s = max(durations[i][j] for i in range(3) for j in range(3))
        if max_s > 7200:
            print(f"  WARN max duration {int(max_s)}s (>2h) may be unexpected")
        print(f"  OK 3x3 duration matrix (origin->origin=0, others positive)")
        return True
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()[:200] if e.fp else ""
        print(f"  FAIL HTTP {e.code} {e.reason} {err_body}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def test_ors_snap_v2():
    """OpenRouteService Snap V2: POST .../v2/snap/foot-walking with locations and radius (HeiGIT). Same as app's ORS Snap V2 retry."""
    print("Testing OpenRouteService Snap V2 (api.openrouteservice.org or ORS_BASE_URL)...")
    secrets = _load_secrets_xcconfig()
    key = (os.environ.get("OPEN_ROUTE_SERVICE_API_KEY", "").strip() or secrets.get("OPEN_ROUTE_SERVICE_API_KEY", "")).strip()
    base_url = (os.environ.get("ORS_BASE_URL", "").strip() or secrets.get("ORS_BASE_URL", "")).strip()
    if base_url and ("$(" in base_url or not base_url.startswith("https://")):
        base_url = ""
    if not base_url and not key:
        print("  SKIP (set OPEN_ROUTE_SERVICE_API_KEY or ORS_BASE_URL to test)")
        return None
    url = (base_url.rstrip("/") if base_url else "https://api.openrouteservice.org") + "/v2/snap/foot-walking"
    locations = [
        [ORIGIN[1], ORIGIN[0]],
        [WAYPOINT[1], WAYPOINT[0]],
        [DESTINATION[1], DESTINATION[0]],
    ]
    payload = json.dumps({"locations": locations, "radius": 100}).encode()
    headers = {"Content-Type": "application/json"}
    if not base_url:
        headers["Authorization"] = key
    try:
        body, status = request(url, method="POST", data=payload, headers=headers, timeout=10)
        if status != 200:
            print(f"  FAIL status={status} body={body[:300]}")
            return False
        data = json.loads(body)
        result_locations = data.get("locations")
        if not result_locations or len(result_locations) != len(locations):
            print(f"  FAIL expected {len(locations)} locations, got {len(result_locations or [])}")
            return False
        for i, loc in enumerate(result_locations):
            if not isinstance(loc, dict) or "location" not in loc:
                print(f"  FAIL locations[{i}] missing 'location'")
                return False
            coords = loc["location"]
            if not isinstance(coords, list) or len(coords) < 2:
                print(f"  FAIL locations[{i}].location invalid")
                return False
        print(f"  OK Snap V2 returned {len(result_locations)} snapped points (HeiGIT)")
        return True
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()[:200] if e.fp else ""
        print(f"  FAIL HTTP {e.code} {e.reason} {err_body}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def test_graphhopper():
    """GraphHopper: GET .../api/1/route?key=...&profile=foot&points_encoded=false&point=lat,lon&point=..."""
    print("Testing GraphHopper (graphhopper.com)...")
    key = (os.environ.get("GRAPHHOPPER_API_KEY", "").strip() or _load_secrets_xcconfig().get("GRAPHHOPPER_API_KEY", "")).strip()
    if not key:
        print("  SKIP (set GRAPHHOPPER_API_KEY to test)")
        return None
    points = [
        f"{ORIGIN[0]},{ORIGIN[1]}",
        f"{WAYPOINT[0]},{WAYPOINT[1]}",
        f"{DESTINATION[0]},{DESTINATION[1]}",
    ]
    params = {
        "key": key,
        "profile": "foot",
        "points_encoded": "false",
    }
    url = "https://graphhopper.com/api/1/route?" + urllib.parse.urlencode(params)
    for p in points:
        url += "&point=" + urllib.parse.quote(p)
    try:
        body, status = request(url, timeout=10)
        if status != 200:
            print(f"  FAIL status={status} body={body[:300]}")
            return False
        data = json.loads(body)
        paths = data.get("paths") or []
        if not paths:
            print("  FAIL no paths", data.get("message", ""))
            return False
        p = paths[0]
        dist = p.get("distance", 0)
        time_ms = p.get("time", 0)
        print(f"  OK distance={int(dist)}m duration={int(time_ms/1000)}s ({int(time_ms/60000)}min)")
        return True
    except urllib.error.HTTPError as e:
        print(f"  FAIL HTTP {e.code} {e.reason} {e.read().decode()[:200]}")
        return False
    except Exception as e:
        print(f"  FAIL {type(e).__name__}: {e}")
        return False


def main():
    print("Free routing API test (same request shape as WalkingWR app)")
    print("Route: round trip with 1 waypoint", ORIGIN, "->", WAYPOINT, "->", DESTINATION)
    print()
    results = {}
    results["OSRM"] = test_osrm()
    print()
    results["OpenRouteService"] = test_openrouteservice()
    print()
    results["ORS Isochrones V2"] = test_ors_isochrones()
    print()
    results["ORS Matrix V2"] = test_ors_matrix()
    print()
    results["ORS Snap V2"] = test_ors_snap_v2()
    print()
    results["GraphHopper"] = test_graphhopper()
    print()
    print("Summary:")
    for name, ok in results.items():
        if ok is None:
            print(f"  {name}: skipped (no key)")
        elif ok:
            print(f"  {name}: OK")
        else:
            print(f"  {name}: FAIL")
    failures = [k for k, v in results.items() if v is False]
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
