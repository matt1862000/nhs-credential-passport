#!/usr/bin/env python3
"""
Pre-generate walking loop routes and export to TSV.

Uses OSRM walking API only. No haversine fallback — routes are skipped if all mirrors fail.
Tries each mirror with retries.

Max 3 waypoints per route. Waypoint count by duration: 10 min → 2, 15 min → 2, 20+ min → 3 (TSV “Waypoint Count” = intermediate waypoints only).

Output (tab-separated): Postcode, Duration (min), Route Index, Name, Description,
Waypoint Count, Waypoint 1, Waypoint 2, Waypoint 3, Distance (m), Duration (sec),
Polyline, Generate Polyline.
Waypoints are formatted as "Name (Postcode)". Route Index is always 1.
Generate Polyline is empty (reserved for sheet button/regenerate).
"""

import csv
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

# One run at a time: lock file in script dir
_LOCK_FILE = Path(__file__).resolve().parent / ".route_generate.lock"


def _release_lock():
    try:
        _LOCK_FILE.unlink(missing_ok=True)
    except Exception:
        pass


def _acquire_lock():
    """Return True if we got the lock, False if another run is active."""
    if _LOCK_FILE.exists():
        try:
            line = _LOCK_FILE.read_text().strip().split()
            pid = int(line[0]) if line else None
        except Exception:
            pid = None
        if pid is not None:
            try:
                os.kill(pid, 0)  # check if process exists (Unix)
                return False  # other process still running
            except (ProcessLookupError, PermissionError, OSError):
                pass  # stale
        _LOCK_FILE.unlink(missing_ok=True)
    try:
        _LOCK_FILE.write_text(f"{os.getpid()}\n")
    except Exception:
        return False
    return True

# OSRM walking mirrors — tried in order until one returns a route
# Add more public OSRM bases here if needed (same path: /route/v1/{profile}/...)
OSRM_MIRRORS = [
    "http://router.project-osrm.org/route/v1/walking",
    "http://router.project-osrm.org/route/v1/foot",  # standard OSRM profile name
    "https://router.project-osrm.org/route/v1/walking",
    "https://router.project-osrm.org/route/v1/foot",
]
OSRM_DELAY_SEC = 1.0  # Delay between requests (higher = fewer rate-limit skips)
OSRM_RETRIES = 2     # Retries per mirror before trying next

# ==========================
# HELPER FUNCTIONS
# ==========================


def haversine(lat1, lon1, lat2, lon2):
    """
    Great-circle distance between two points in meters (Haversine).
    """
    R = 6371000  # Earth radius in meters
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)

    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c


MIN_WAYPOINT_DISTANCE_M = 100
MAX_WAYPOINTS = 3  # Only allow up to 3 intermediate waypoints per route
# For 10 min, require at least one waypoint this far (m) so loop has a chance to be ~10 min
MIN_LOOP_EXTENT_FOR_10_MIN_M = 350
# Walking speed for duration sanity: OSRM can return unrealistically fast times
WALKING_SPEED_M_PER_MIN = 80  # same as haversine fallback
MAX_PLAUSIBLE_WALKING_SPEED_M_PER_SEC = 2.0  # ~7.2 km/h; above this we recompute duration from distance
# Standard duration buckets for output (match Apps Script ROUTE_DURATIONS)
DURATION_BUCKETS = [5, 10, 15, 20, 30, 45, 60]
# Max routes to keep per (postcode, duration bucket). 0 = no cap (emit all); app filters to best 10 per bucket using user location.
MAX_ROUTES_PER_BUCKET = 0

# Gemini API for route name/description (optional)
GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
GEMINI_MODEL = "gemini-2.0-flash"  # Use gemini-1.5-flash if your key doesn't have 2.0
GEMINI_DELAY_SEC = 1.0  # Delay between calls to reduce rate-limit risk


def get_max_waypoints(duration_min):
    """
    Waypoints from duration: 10 min = 2, 15 min = 2, 20+ min = 3; capped at MAX_WAYPOINTS (3).
    10 min uses 2 waypoints so loops can reach ~10 min (avoid 1–2 min “10 min” routes).
    """
    if duration_min <= 10:
        return min(MAX_WAYPOINTS, 2)
    return min(MAX_WAYPOINTS, max(0, (duration_min - 5) // 5))


def nearest_duration_bucket(actual_min):
    """Return the standard bucket (from DURATION_BUCKETS) nearest to actual_min. Used so Duration (min) matches the route's real length."""
    if actual_min <= 0:
        return DURATION_BUCKETS[0]
    best = DURATION_BUCKETS[0]
    best_diff = abs(actual_min - best)
    for b in DURATION_BUCKETS:
        d = abs(actual_min - b)
        if d < best_diff:
            best_diff = d
            best = b
    return best


def score_route(r):
    """
    Score for "best" route selection (lower = better). Aligned with ROUTE_GENERATION_ALGORITHM.md Phase 6.
    - Prefer duration 90-110% of target; penalize over/under.
    - Prefer more waypoints.
    - Tiebreak: closer to target duration.
    """
    target_min = r["duration_min"]
    actual_min = r["duration_sec"] // 60
    if target_min <= 0:
        accuracy = 1.0
    else:
        accuracy = actual_min / target_min
    wp_count = r.get("output_waypoint_count", r.get("waypoint_count", 0))

    # Duration penalty: prefer 90-110%
    overrun = max(0, accuracy - 1.10) * 30
    underrun = max(0, 0.90 - accuracy) * 20
    duration_penalty = overrun + underrun

    # Waypoint bonus (more = better): subtract so lower score wins
    waypoint_bonus = -0.10 * wp_count

    # Sub-target bonus: slight preference for 90-100%
    sub_target_bonus = -0.05 if 0.90 <= accuracy <= 1.00 else 0.0

    primary = duration_penalty + waypoint_bonus + sub_target_bonus
    # Tiebreakers: more waypoints, then closer to target
    return (primary, -wp_count, abs(actual_min - target_min))


def keep_top_per_bucket(routes, max_per_bucket):
    """
    Group by (postcode, duration_bucket), score, keep top max_per_bucket per group.
    Returns flattened list of routes in stable order (by bucket then by score).
    """
    groups = defaultdict(list)
    for r in routes:
        actual_min = r["duration_sec"] // 60
        bucket = nearest_duration_bucket(actual_min)
        key = (r["anchor_postcode"], bucket)
        groups[key].append(r)

    out = []
    for key in sorted(groups.keys()):
        group = groups[key]
        if max_per_bucket > 0 and len(group) > max_per_bucket:
            group = sorted(group, key=score_route)[:max_per_bucket]
        out.extend(group)
    return out


def call_gemini_route_content(route, api_key):
    """
    Call Gemini API to generate a short route name and description.
    Matches the app's GeminiService prompt style. Returns (name, description) or (None, None) on failure.
    """
    waypoints = [
        route.get("waypoint_1", ""),
        route.get("waypoint_2", ""),
        route.get("waypoint_3", ""),
    ]
    waypoints = [w for w in waypoints if w]
    waypoint_descriptions = "; ".join(waypoints)
    duration_min = route.get("duration_sec", 0) // 60
    distance_m = route.get("distance_m", 0)
    # Difficulty: same as app (duration-based)
    if duration_min <= 10:
        difficulty = "easy, gentle"
    elif duration_min <= 20:
        difficulty = "moderate"
    else:
        difficulty = "challenging, brisk"

    prompt = f"""Create a fun, creative name AND a warm description for a walking route that a patient can take while waiting for their medical appointment.

WAYPOINTS YOU'LL PASS:
{waypoint_descriptions}

ROUTE CONTEXT:
- Total walk time: {duration_min} minutes
- Distance: approximately {distance_m} meters
- Walking pace: {difficulty}
- Number of discovery spots: {len(waypoints)}

RESPOND IN EXACTLY THIS FORMAT (two lines only):
NAME: [Your creative route name here]
DESCRIPTION: [Your 2-sentence description here]

NAME GUIDELINES:
- Make it fun, memorable, and specific to THIS route
- MAXIMUM 20 CHARACTERS (this is critical - will be truncated otherwise)
- 2-4 words maximum
- Can be playful, alliterative, or reference a key landmark
- Examples: "Pub & Spire Stroll", "Bakery Loop", "Garden Gateway", "High Street Wander", "Cosy Circuit"
- Don't use generic names like "Local Discovery" or "Neighbourhood Walk"
- Don't start with "The" to save characters

DESCRIPTION GUIDELINES:
- YOU MUST mention at least 2 specific place names from the waypoints list
- Describe something CONCRETE about each place (e.g. "grab a coffee at Costa", "see the historic church spire")
- NO generic phrases like "enjoy fresh air", "take a breath", "clear your mind"
- Be SPECIFIC: what will they actually SEE, SMELL, HEAR at these places?
- Keep it under 40 words
- Don't mention exact times or distances

Remember: Respond ONLY with the two lines starting with NAME: and DESCRIPTION:"""

    url = f"{GEMINI_BASE}/{GEMINI_MODEL}:generateContent?key={api_key}"
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
    }
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, OSError) as e:
        import sys
        print(f"Gemini request error: {e}", file=sys.stderr)
        return (None, None)

    try:
        cands = data.get("candidates") or []
        if not cands:
            block = (data.get("promptFeedback") or {}).get("blockReason") or "no candidates"
            import sys
            print(f"Gemini no candidates: {block}", file=sys.stderr)
            return (None, None)
        parts = (cands[0].get("content", {}) or {}).get("parts") or []
        text = (parts[0] if parts else {}).get("text", "") or ""
    except (IndexError, KeyError, TypeError):
        return (None, None)

    text = (text or "").strip()
    name, description = None, None
    for line in text.split("\n"):
        line = line.strip()
        # Allow "NAME:" or "**NAME:**" or "### NAME:" etc.
        u = line.upper()
        if "NAME:" in u:
            idx = u.index("NAME:") + 5
            name = line[idx:].split("\n")[0].strip().strip("*#")
        elif "DESCRIPTION:" in u:
            idx = u.index("DESCRIPTION:") + 12
            description = line[idx:].split("\n")[0].strip().strip("*#")

    if name and len(name) > 22:
        original = name
        words = name.split()
        name = ""
        for w in words:
            if not name:
                name = w
            elif len(name) + 1 + len(w) <= 22:
                name += " " + w
            else:
                break
        name = name or original[:22]
    if (name is None or description is None) and text:
        import sys
        print(f"Gemini parse failed, raw (first 400 chars): {repr(text[:400])}", file=sys.stderr)
    return (name or None, description or None)


def fetch_route_osrm(coords):
    """
    Fetch walking route from OSRM. coords = [(lat, lon), ...].
    Tries every mirror in OSRM_MIRRORS (with retries) until one returns a valid route.
    Returns {"distance_m": int, "duration_sec": int, "polyline": str} or None if all fail.
    OSRM expects lon,lat in URL.
    """
    if len(coords) < 2:
        return None
    pts = ";".join(f"{lon},{lat}" for lat, lon in coords)
    for base in OSRM_MIRRORS:
        url = f"{base}/{pts}?overview=full&geometries=polyline"
        req = urllib.request.Request(url, headers={"User-Agent": "WalkingWR-RouteGenerator/1"})
        for attempt in range(OSRM_RETRIES + 1):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read().decode())
            except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, OSError):
                if attempt < OSRM_RETRIES:
                    time.sleep(2)  # Backoff before retry
                continue
            if data.get("code") != "Ok" or not data.get("routes"):
                if attempt < OSRM_RETRIES:
                    time.sleep(2)
                continue
            r = data["routes"][0]
            return {
                "distance_m": int(r.get("distance", 0)),
                "duration_sec": int(r.get("duration", 0)),
                "polyline": r.get("geometry", ""),
            }
    return None


def generate_loop(anchor, pois, target_duration_min, use_osrm=True):
    """
    Build a loop route: anchor -> nearest N POIs -> anchor.
    N is at most MAX_WAYPOINTS (3). Waypoints must be >= MIN_WAYPOINT_DISTANCE_M apart.
    If use_osrm: OSRM walking only — tries all mirrors; returns None if all fail (no haversine).
    If not use_osrm: haversine + 80 m/min only (for --no-osrm).
    """
    max_waypoints = min(MAX_WAYPOINTS, get_max_waypoints(target_duration_min))
    candidates = [p for p in pois if p["placeId"] != anchor["placeId"]]
    ax, ay = anchor["latitude"], anchor["longitude"]

    # Sort by distance from anchor; then greedily add only if >= 100m from anchor and all selected
    def d_anchor(p):
        return haversine(ax, ay, p["latitude"], p["longitude"])
    candidates.sort(key=d_anchor)
    selected = []
    for p in candidates:
        if len(selected) >= max_waypoints:
            break
        if d_anchor(p) < MIN_WAYPOINT_DISTANCE_M:
            continue
        ok = True
        for s in selected:
            if haversine(s["latitude"], s["longitude"], p["latitude"], p["longitude"]) < MIN_WAYPOINT_DISTANCE_M:
                ok = False
                break
        if ok:
            selected.append(p)

    # For 10 min with 2 waypoints, prefer a longer loop: ensure at least one waypoint is >= MIN_LOOP_EXTENT_FOR_10_MIN_M from anchor
    if target_duration_min == 10 and max_waypoints == 2 and len(selected) == 2:
        if d_anchor(selected[0]) < MIN_LOOP_EXTENT_FOR_10_MIN_M and d_anchor(selected[1]) < MIN_LOOP_EXTENT_FOR_10_MIN_M:
            sel_ids = {s["placeId"] for s in selected}
            far = [c for c in candidates if c["placeId"] not in sel_ids and d_anchor(c) >= MIN_LOOP_EXTENT_FOR_10_MIN_M
                   and haversine(selected[0]["latitude"], selected[0]["longitude"], c["latitude"], c["longitude"]) >= MIN_WAYPOINT_DISTANCE_M]
            if far:
                # Prefer the one nearest to first waypoint among those >= 350m, to keep loop compact but long enough
                selected[1] = min(far, key=lambda c: haversine(selected[0]["latitude"], selected[0]["longitude"], c["latitude"], c["longitude"]))

    route = [anchor] + selected + [anchor]
    waypoints_str = " → ".join(p["name"] for p in route)  # include anchor as start/end

    if use_osrm:
        if len(route) < 2:
            return None
        coords = [(p["latitude"], p["longitude"]) for p in route]
        osrm = fetch_route_osrm(coords)
        if osrm is None:
            return None  # Always use OSRM only — no haversine fallback
        total_distance = osrm["distance_m"]
        duration_sec = osrm["duration_sec"]
        polyline = osrm.get("polyline", "")
        timing_source = "OSRM"
        # Sanity: OSRM walking can return unrealistically fast durations (e.g. 6 m/s).
        # If implied speed > 2 m/s, recompute duration from distance at WALKING_SPEED_M_PER_MIN.
        if total_distance > 0 and duration_sec > 0:
            implied_speed = total_distance / duration_sec
            if implied_speed > MAX_PLAUSIBLE_WALKING_SPEED_M_PER_SEC:
                duration_sec = int(round(total_distance / (WALKING_SPEED_M_PER_MIN / 60)))
    else:
        total_distance = 0
        for i in range(len(route) - 1):
            total_distance += haversine(
                route[i]["latitude"], route[i]["longitude"],
                route[i + 1]["latitude"], route[i + 1]["longitude"]
            )
        duration_sec = int(total_distance / 80 * 60)  # 80 m/min walking
        polyline = ""
        timing_source = "Haversine"

    duration_formatted = f"{duration_sec // 60}min"

    # Waypoints for output: the N intermediate waypoints (selected[0..N-1]) fill Waypoint 1..3.
    # Waypoint Count = len(selected) so 10/15 min → 2, 20+ min → 3. Anchor is start/end, not in these columns.
    # Format: "Name (Postcode)"
    postcode = anchor["postcode"]
    def fmt(p):
        return f"{p['name']} ({postcode})"

    waypoint_1 = fmt(selected[0]) if len(selected) >= 1 else ""
    waypoint_2 = fmt(selected[1]) if len(selected) >= 2 else ""
    waypoint_3 = fmt(selected[2]) if len(selected) >= 3 else ""
    output_waypoint_count = len(selected)

    return {
        "anchor_postcode": anchor["postcode"],
        "duration_min": target_duration_min,
        "waypoints": waypoints_str,
        "waypoint_count": len(selected),
        "distance_m": int(total_distance),
        "duration_sec": duration_sec,
        "duration_formatted": duration_formatted,
        "polyline": polyline,
        "timing_source": timing_source,
        "output_waypoint_count": output_waypoint_count,
        "waypoint_1": waypoint_1,
        "waypoint_2": waypoint_2,
        "waypoint_3": waypoint_3,
    }


# ==========================
# DEFAULT POI LIST (S5 sample)
# ==========================

DEFAULT_POIS = [
    {"postcode": "S5", "placeId": "osm_1242591244", "name": "2nd Time Around", "latitude": 53.4187584, "longitude": -1.4467826, "types": "clothes", "vicinity": "Bellhouse Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1242585576", "name": "7 Hills Blinds", "latitude": 53.4188323, "longitude": -1.4475842, "types": "window_blind", "vicinity": "Sicey Avenue", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1058162420", "name": "A1 Immigration Services", "latitude": 53.408998, "longitude": -1.4475843, "types": "social_facility", "vicinity": "Page Hall Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1222627283", "name": "Abbeymoor Veterinary Centres", "latitude": 53.4210664, "longitude": -1.4922881, "types": "veterinary", "vicinity": "Halifax Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1222627290", "name": "Ace Domestics", "latitude": 53.4213262, "longitude": -1.492073, "types": "appliance", "vicinity": "Halifax Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1058162417", "name": "A.D Hairdressing", "latitude": 53.4088015, "longitude": -1.4478735, "types": "hairdresser", "vicinity": "Page Hall Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_8378842015", "name": "Air Raid Night", "latitude": 53.4168026, "longitude": -1.4291303, "types": "artwork", "vicinity": "", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_127886464", "name": "Al Mahdi Centre", "latitude": 53.4131854, "longitude": -1.4444472, "types": "community_centre", "vicinity": "", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_9806979754", "name": "Albatross", "latitude": 53.4190294, "longitude": -1.4476859, "types": "fast_food", "vicinity": "Sicey Avenue", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1242591246", "name": "Alex Barbers", "latitude": 53.4188158, "longitude": -1.4466725, "types": "hairdresser", "vicinity": "Bellhouse Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1242333268", "name": "Allied Pharmacy - Firth Park Road", "latitude": 53.4179818, "longitude": -1.446763, "types": "pharmacy", "vicinity": "Firth Park Road", "source": "osm"},
    {"postcode": "S5", "placeId": "osm_1189425313", "name": "Ameen", "latitude": 53.4065513, "longitude": -1.4349821, "types": "fast_food", "vicinity": "Upwell Street", "source": "osm"},
]


# ==========================
# MAIN: GENERATE & WRITE CSV
# ==========================

# Tab-separated output. Matches build_postcode_json_from_tsv / database expectations:
# Postcode, Duration (min), Route Index, Name, Description, Waypoint Count,
# Waypoint 1, Waypoint 2, Waypoint 3, Distance (m), Duration (sec), Polyline,
# Actual Duration (min), Timing source.
OUTPUT_HEADERS_TSV = [
    "Postcode",
    "Duration (min)",
    "Route Index",
    "Name",
    "Description",
    "Waypoint Count",
    "Waypoint 1",
    "Waypoint 2",
    "Waypoint 3",
    "Distance (m)",
    "Duration (sec)",
    "Polyline",
    "Actual Duration (min)",
    "Timing source",
]


def _write_routes_tsv(routes, out_path):
    """Write route list to TSV (same format as main output). Used for normal finish and on Ctrl+C."""
    path = Path(out_path)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_HEADERS_TSV, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for r in routes:
            actual_min = r["duration_sec"] // 60
            duration_bucket = nearest_duration_bucket(actual_min)
            row = {
                "Postcode": r["anchor_postcode"],
                "Duration (min)": duration_bucket,
                "Route Index": 1,
                "Name": r.get("name", ""),
                "Description": r.get("description", ""),
                "Waypoint Count": r["output_waypoint_count"],
                "Waypoint 1": r["waypoint_1"],
                "Waypoint 2": r["waypoint_2"],
                "Waypoint 3": r["waypoint_3"],
                "Distance (m)": r.get("distance_m", 0),
                "Duration (sec)": r.get("duration_sec", 0),
                "Polyline": r.get("polyline", ""),
                "Actual Duration (min)": actual_min,
                "Timing source": "OSRM",
            }
            writer.writerow(row)


def load_pois_from_tsv(path):
    """Load POIs from a tab-separated file with columns: postcode, placeId, name, latitude, longitude, types, vicinity, source."""
    pois = []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            pois.append({
                "postcode": row["postcode"].strip(),
                "placeId": row["placeId"].strip(),
                "name": row["name"].strip(),
                "latitude": float(row["latitude"]),
                "longitude": float(row["longitude"]),
                "types": row.get("types", "").strip(),
                "vicinity": row.get("vicinity", "").strip(),
                "source": row.get("source", "").strip(),
            })
    return pois


def _pois_from_json_data(data):
    """Extract flat POI list from prepopulated JSON structure (postcodeAreas[].pois)."""
    pois = []
    for area in data.get("postcodeAreas", []):
        postcode = area.get("postcode", "")
        for p in area.get("pois", []):
            t = p.get("types")
            types_str = ",".join(t) if isinstance(t, list) else (str(t) if t is not None else "")
            pois.append({
                "postcode": postcode,
                "placeId": str(p.get("placeId", "")),
                "name": str(p.get("name") or "Unnamed").strip(),
                "latitude": float(p["latitude"]),
                "longitude": float(p["longitude"]),
                "types": types_str,
                "vicinity": str(p.get("vicinity") or "").strip(),
                "source": str(p.get("source") or "").strip(),
            })
    return pois


def load_pois_from_json(path_or_url):
    """
    Load POIs from prepopulated JSON (postcodeAreas[].postcode, pois[]).
    path_or_url: local path or https:// URL (e.g. Firebase Storage download URL for prepopulated_pois.json).
    Use the Firebase/Google Sheets export URL to get only the curated ~5k POIs the app uses.
    """
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        req = urllib.request.Request(path_or_url, headers={"User-Agent": "WalkingWR-route-generator/1.0"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    else:
        with open(path_or_url, "r", encoding="utf-8") as f:
            data = json.load(f)
    return _pois_from_json_data(data)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate walking-loop routes CSV (no routing API).")
    parser.add_argument(
        "-i", "--input",
        action="append",
        default=None,
        metavar="FILE",
        help="POI input(s): .json file, .tsv file, or https:// URL (e.g. Firebase Storage download URL for prepopulated_pois.json). Use the Firebase/Sheets URL to get only the curated POIs the app uses (~5k). May be repeated. Default: built-in 12-POI sample.",
    )
    parser.add_argument(
        "-o", "--output",
        default="pre_generated_routes.csv",
        help="Output CSV path (default: pre_generated_routes.csv)",
    )
    parser.add_argument(
        "--durations",
        default="10,15,20,25,30,35,40,45,50,55,60",
        help="Comma-separated duration minutes (default: 10,15,...,60; 5 min excluded)",
    )
    parser.add_argument(
        "--no-osrm",
        action="store_true",
        help="Skip OSRM; use haversine + 80 m/min only (faster, no real polylines)",
    )
    parser.add_argument(
        "--progress-file",
        default=None,
        metavar="FILE",
        help="Write live progress to this file (open in another window to watch). Omit to only print to stdout.",
    )
    parser.add_argument(
        "--no-progress-file",
        action="store_true",
        help="Do not write progress to any file; only print to stdout (same as omitting --progress-file).",
    )
    parser.add_argument(
        "--filter-by-actual",
        action="store_true",
        help="Only output rows where Actual Duration is within 80%%–120%% of target (e.g. 10 min → 8–12 min). Drops short “10 min” routes that are actually 1–2 min.",
    )
    parser.add_argument(
        "--max-per-bucket",
        type=int,
        default=MAX_ROUTES_PER_BUCKET,
        metavar="N",
        help="Keep at most N best routes per (postcode, duration bucket). Default %(default)s (no cap). App filters to best 10 using user location.",
    )
    parser.add_argument(
        "--gemini-key",
        type=str,
        default=None,
        metavar="KEY",
        help="Google Gemini API key for generating route Name/Description. Also uses env GEMINI_API_KEY or GOOGLE_API_KEY if unset.",
    )
    args = parser.parse_args()

    # Only one route generation at a time (no parallel runs)
    if not _acquire_lock():
        print("Another route generation is already running. Only one run at a time.", file=sys.stderr)
        sys.exit(1)
    try:
        _run_main(args)
    finally:
        _release_lock()


def _run_main(args):
    """Inner main after lock is acquired."""
    use_osrm = not args.no_osrm
    if use_osrm:
        print("Using OSRM walking only — no haversine fallback; tries all mirrors until one succeeds.")
    else:
        print("Using haversine + 80 m/min only (--no-osrm).")

    inputs = [p for p in (args.input or []) if p]
    if inputs:
        poi_list = []
        for path in inputs:
            is_url = path.startswith("http://") or path.startswith("https://")
            if not is_url and not Path(path).exists():
                print(f"Input file not found: {path}, skipping.")
                continue
            if is_url or (Path(path).suffix.lower() == ".json" if not is_url else True):
                # JSON: local file or URL (e.g. Firebase Storage prepopulated_pois.json)
                loaded = load_pois_from_json(path)
            else:
                loaded = load_pois_from_tsv(path)
            poi_list.extend(loaded)
            label = path if len(path) < 60 else path[:57] + "..."
            print(f"Loaded {len(loaded)} POIs from {label}")
        if not poi_list:
            print("No POIs loaded; using built-in S5 sample.")
            poi_list = DEFAULT_POIS
        else:
            print(f"Total: {len(poi_list)} POIs")
    else:
        poi_list = DEFAULT_POIS
        print(f"Using built-in S5 sample ({len(poi_list)} POIs)")

    durations = [int(x.strip()) for x in args.durations.split(",") if x.strip()]

    all_routes = []
    route_index = 1
    total = len(durations) * len(poi_list)
    skipped = 0
    progress_file = None if getattr(args, "no_progress_file", False) else args.progress_file
    start_time = time.time()

    def write_progress(msg):
        print(msg, flush=True)
        if progress_file:
            with open(Path(progress_file), "w", encoding="utf-8") as pf:
                pf.write(msg + "\n")

    area = poi_list[0].get("postcode", "") if poi_list else ""
    write_progress(f"Starting: {total} candidate routes | area {area or '?'} (OSRM={'on' if use_osrm else 'off'})")

    out_path = Path(args.output)
    try:
        for idx, (duration_min, anchor) in enumerate(
            (d, a) for d in durations for a in poi_list
        ):
            elapsed = int(time.time() - start_time)
            done = idx + 1
            pc = anchor.get("postcode", "?")
            write_progress(f"[{elapsed}s] {done}/{total} | {pc} {duration_min}min | routes: {len(all_routes)} | skipped: {skipped}")
            r = generate_loop(anchor, poi_list, duration_min, use_osrm=use_osrm)
            if r is None:
                skipped += 1
                if use_osrm:
                    time.sleep(OSRM_DELAY_SEC)
                continue
            all_routes.append(r)
            route_index += 1
            if use_osrm:
                time.sleep(OSRM_DELAY_SEC)
    except KeyboardInterrupt:
        write_progress(f"Stopped. Writing {len(all_routes)} routes so far to {out_path}...")
        _write_routes_tsv(all_routes, out_path)
        write_progress(f"Wrote {len(all_routes)} routes to {out_path} (partial run).")
        print(f"\nWrote {len(all_routes)} routes to {out_path} (partial run).", flush=True)
        raise SystemExit(130)

    write_progress(f"Done. Routes: {len(all_routes)}, skipped: {skipped}, elapsed: {int(time.time() - start_time)}s")

    filter_by_actual = getattr(args, "filter_by_actual", False)
    if filter_by_actual:
        low, high = 0.8, 1.2
        kept = [r for r in all_routes if low * r["duration_min"] <= (r["duration_sec"] // 60) <= high * r["duration_min"]]
        dropped = len(all_routes) - len(kept)
        if dropped:
            print(f"Filter by actual: kept {len(kept)}, dropped {dropped} (actual outside {low:.0%}–{high:.0%} of target)")
        all_routes = kept

    max_per_bucket = getattr(args, "max_per_bucket", MAX_ROUTES_PER_BUCKET)
    if max_per_bucket > 0:
        before = len(all_routes)
        all_routes = keep_top_per_bucket(all_routes, max_per_bucket)
        dropped_bucket = before - len(all_routes)
        if dropped_bucket:
            print(f"Best-per-bucket (max {max_per_bucket}): kept {len(all_routes)}, dropped {dropped_bucket}")

    gemini_key = getattr(args, "gemini_key", None) or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if gemini_key and all_routes:
        print(f"Generating Name/Description with Gemini for {len(all_routes)} routes...")
        for i, r in enumerate(all_routes):
            name, desc = call_gemini_route_content(r, gemini_key)
            r["name"] = name or ""
            r["description"] = desc or ""
            if (i + 1) % 5 == 0 or i == len(all_routes) - 1:
                print(f"  Gemini: {i + 1}/{len(all_routes)}")
            time.sleep(GEMINI_DELAY_SEC)
        print("Gemini done.")

    _write_routes_tsv(all_routes, out_path)

    if use_osrm:
        print(f"Wrote {len(all_routes)} rows to {out_path} (TSV, OSRM only); skipped {skipped} (OSRM failed).")
    else:
        print(f"Wrote {len(all_routes)} rows to {out_path} (TSV)")
    print(f"Headers: {'	'.join(OUTPUT_HEADERS_TSV)}")


if __name__ == "__main__":
    main()
