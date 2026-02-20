#!/usr/bin/env python3
"""
Route Generation Test Harness — Results Analyzer (Detailed)
Usage: python3 analyze_routes.py diagnostic_routes.json

Parses the JSON output from the 12-phase diagnostic and displays
detailed tables with full waypoint info, per-bucket metrics,
feature test results, and an overall health grade.
"""

import json
import sys
import os
from collections import defaultdict

# ─── ANSI colors ──────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BLUE   = "\033[94m"
MAGENTA = "\033[95m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RESET  = "\033[0m"

def pass_fail(ok):
    return f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"

def grade_color(grade):
    colors = {"A": GREEN, "B": GREEN, "C": YELLOW, "D": RED, "F": RED}
    return f"{BOLD}{colors.get(grade, RESET)}{grade}{RESET}"

def fmt_ms(val):
    if val is None or val == 0: return "—"
    if val >= 60000:
        return f"{val/60000:.1f}min"
    if val >= 1000:
        return f"{val/1000:.1f}s"
    return f"{val}ms"


def load_data(path):
    with open(path, "r") as f:
        return json.load(f)


def print_header(title):
    width = 90
    print(f"\n{BOLD}{CYAN}{'═' * width}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'═' * width}{RESET}")


def print_section(title):
    print(f"\n{BOLD}{'─' * 90}{RESET}")
    print(f"{BOLD}  {title}{RESET}")
    print(f"{BOLD}{'─' * 90}{RESET}")


def print_subsection(title):
    print(f"\n  {BOLD}{BLUE}{title}{RESET}")


def analyze(data):
    phases = data.get("phases", {})
    
    # ─── Overview ──────────────────────────────────────────────────────
    print_header("Route Generation Test Results — Detailed Report")
    print(f"  Timestamp:     {data.get('timestamp', '?')}")
    loc = data.get("location", {})
    print(f"  Location:      ({loc.get('lat', '?')}, {loc.get('lng', '?')}) — WF2 Kirkhamgate")
    print(f"  Total routes:  {BOLD}{data.get('totalRoutes', '?')}{RESET}")
    print(f"  In-band:       {BOLD}{data.get('totalInBand', '?')}{RESET}")
    print(f"  Total time:    {BOLD}{data.get('totalTimeSeconds', '?')}s{RESET}")
    
    # ═══════════════════════════════════════════════════════════════════
    # TABLE 1: Per Bucket Summary
    # ═══════════════════════════════════════════════════════════════════
    print_section("1. Per Bucket Summary")
    gen = phases.get("initialGeneration", {}).get("buckets", {})
    
    header = f"  {'Bucket':>6} {'Prepop':>6} {'Live':>5} {'Total':>5} {'Time':>8} {'In-Band':>7} {'Best Dev':>9} {'Worst Dev':>9} {'Avg m/min':>9}"
    print(f"{DIM}{header}{RESET}")
    print(f"  {DIM}{'─' * 80}{RESET}")
    
    total_routes = 0
    total_inband = 0
    bucket_times = []
    
    for bucket in sorted(gen.keys(), key=int):
        info = gen[bucket]
        routes = info.get("routes", [])
        prepop = info.get("prepopRoutes", 0)
        live = info.get("liveRoutes", 0)
        total = len(routes)
        time_ms = info.get("timeMs", 0)
        bucket_times.append(time_ms)
        
        inband_count = sum(1 for r in routes if r.get("inBand", False))
        deviations = [r.get("deviationPercent", 0) for r in routes]
        speeds = [r.get("impliedSpeedMpm", 0) for r in routes if r.get("impliedSpeedMpm", 0) > 0]
        
        best_dev = f"{min(deviations):.0f}%" if deviations else "—"
        worst_dev = f"{max(deviations):.0f}%" if deviations else "—"
        avg_speed = f"{sum(speeds)/len(speeds):.0f}" if speeds else "—"
        
        inband_str = f"{inband_count}/{total}"
        if inband_count == total and total > 0:
            inband_str = f"{GREEN}{inband_str}{RESET}"
        elif inband_count == 0 and total > 0:
            inband_str = f"{RED}{inband_str}{RESET}"
        else:
            inband_str = f"{YELLOW}{inband_str}{RESET}"
        
        total_routes += total
        total_inband += inband_count
        
        print(f"  {bucket:>4}m {prepop:>6} {live:>5} {total:>5} {fmt_ms(time_ms):>8} {inband_str:>16} {best_dev:>9} {worst_dev:>9} {avg_speed:>9}")
    
    print(f"  {DIM}{'─' * 80}{RESET}")
    avg_time = sum(bucket_times) / len(bucket_times) if bucket_times else 0
    print(f"  {'TOTAL':>6} {'':>6} {'':>5} {BOLD}{total_routes:>5}{RESET} {fmt_ms(int(avg_time)):>8}{'avg':>0} {BOLD}{total_inband:>7}{RESET}")
    
    # ═══════════════════════════════════════════════════════════════════
    # TABLE 2: Detailed Route Breakdown (per bucket)
    # ═══════════════════════════════════════════════════════════════════
    print_section("2. Detailed Route Breakdown (per bucket)")
    
    for bucket in sorted(gen.keys(), key=int):
        info = gen[bucket]
        routes = info.get("routes", [])
        if not routes:
            continue
        
        inband_count = sum(1 for r in routes if r.get("inBand", False))
        print_subsection(f"{bucket}-minute bucket — {len(routes)} routes, {inband_count} in-band, {fmt_ms(info.get('timeMs', 0))}")
        
        for idx, r in enumerate(routes):
            name = r.get("name", "?")
            src = r.get("source", "?")
            dur = r.get("durationMinutes", 0)
            dist = r.get("distanceMeters", 0)
            dev = r.get("deviationPercent", 0)
            speed = r.get("impliedSpeedMpm", 0)
            travel_m = r.get("travelToStartMeters", 0)
            travel_min = r.get("travelToStartMinutes", 0)
            ib = r.get("inBand", False)
            gen_time = r.get("generationTimeMs", 0)
            wps = r.get("waypoints", [])
            is_dz = r.get("isDeadZoneFallback", False)
            
            ib_str = f"{GREEN}YES{RESET}" if ib else f"{RED}NO{RESET}"
            src_str = f"{MAGENTA}{src}{RESET}" if src == "prepop" else f"{CYAN}{src}{RESET}"
            dz_str = f" {YELLOW}[DEAD ZONE]{RESET}" if is_dz else ""
            
            print(f"    {BOLD}Route {idx + 1}: {name}{RESET}{dz_str}")
            print(f"      Source:       {src_str}")
            print(f"      Duration:     {dur}m (target {bucket}m, deviation {dev:.0f}%)")
            print(f"      Distance:     {dist}m ({dist/1000:.1f}km)")
            print(f"      Speed:        {speed:.0f} m/min")
            print(f"      In-Band:      {ib_str}")
            print(f"      Gen Time:     {fmt_ms(gen_time)}")
            print(f"      Travel Start: {travel_m:.0f}m ({travel_min:.1f} min, {travel_min / int(bucket) * 100 if int(bucket) > 0 else 0:.0f}% of target)")
            print(f"      Waypoints:    {len(wps)}")
            
            poly_len = r.get("polylineLength", 0)
            dir_count = r.get("directionsCount", 0)
            qr_count = r.get("qrMarkerCount", 0)
            print(f"      Polyline:     {poly_len} chars")
            print(f"      Directions:   {dir_count} steps")
            print(f"      QR Markers:   {qr_count}")
            print(f"      Waypoints ({len(wps)}):")
            
            for wi, wp in enumerate(wps):
                wp_name = wp.get("name", "?")
                wp_lat = wp.get("lat", 0)
                wp_lng = wp.get("lng", 0)
                wp_types = wp.get("types", [])
                wp_pid = wp.get("placeId", "?")
                wp_dist = wp.get("distanceFromOriginMeters", 0)
                types_str = f" {DIM}[{', '.join(wp_types)}]{RESET}" if wp_types else ""
                pid_short = wp_pid[:20] + "..." if len(wp_pid) > 23 else wp_pid
                print(f"        {wi + 1}. {BOLD}{wp_name}{RESET}")
                print(f"           ({wp_lat:.5f}, {wp_lng:.5f})  {wp_dist:.0f}m from origin  {DIM}id:{pid_short}{RESET}{types_str}")
            print()
    
    # ═══════════════════════════════════════════════════════════════════
    # TABLE 3: Feature Tests — Detailed
    # ═══════════════════════════════════════════════════════════════════
    print_section("3. Feature Tests — Detailed")
    
    tests_passed = 0
    tests_total = 0
    
    # +1 Generation
    print_subsection("+1 Generation (mimics +1 button with 10s timeout)")
    plus_one = phases.get("plusOneGeneration", {}).get("results", [])
    for r in plus_one:
        ok = r.get("success", False) and r.get("inBand", False) and not r.get("timedOut", True)
        tests_total += 1
        if ok: tests_passed += 1
        bucket = r.get("bucket", "?")
        print(f"    {bucket}m bucket:  {pass_fail(ok)}")
        print(f"      Success:    {r.get('success')}")
        print(f"      In-Band:    {r.get('inBand')}")
        print(f"      Time:       {fmt_ms(r.get('timeMs', 0))}")
        print(f"      Timed Out:  {r.get('timedOut')}")
        if r.get("success"):
            dur = r.get("durationMinutes", "?")
            dist = r.get("distanceMeters", "?")
            dev = r.get("deviationPercent", "?")
            speed = r.get("impliedSpeedMpm", "?")
            wp_count = r.get("waypointCount", 0)
            travel = r.get("travelToStartMeters", "?")
            print(f"      Duration:   {dur}m (deviation {dev}%)")
            print(f"      Distance:   {dist}m")
            print(f"      Speed:      {speed} m/min")
            print(f"      WPs:        {wp_count}")
            print(f"      Travel:     {travel}m to start")
            wps = r.get("waypoints", [])
            for wi, wp in enumerate(wps):
                wp_name = wp.get("name", "?")
                wp_dist = wp.get("distanceFromOriginMeters", 0)
                print(f"        {wi + 1}. {wp_name} ({wp_dist:.0f}m from origin)")
        print()
    
    # Cross-bucket
    print_subsection("Cross-Bucket Cache")
    cb = phases.get("crossBucketCache", {})
    note = cb.get("note", "")
    if note:
        print(f"    Result:          {YELLOW}SKIP{RESET}")
        print(f"    Note:            {note}")
    else:
        cb_ok = cb.get("stored", False) and cb.get("retrieved", False)
        tests_total += 1
        if cb_ok: tests_passed += 1
        print(f"    Result:          {pass_fail(cb_ok)}")
        print(f"    Route Duration:  {cb.get('routeDuration', '?')}m")
        print(f"    Requested Bucket:{cb.get('requestedBucket', '?')}m")
        print(f"    Stored Bucket:   {cb.get('storedBucket', '?')}m")
        print(f"    Stored:          {cb.get('stored')}")
        print(f"    Retrieved:       {cb.get('retrieved')}")
        print(f"    Retrieved Count: {cb.get('retrievedCount', '?')}")
    print()
    
    # Google Refresh
    print_subsection("Google Refresh (refreshRouteWithGoogleOnly)")
    gr = phases.get("googleRefresh", {})
    gr_ok = gr.get("success", False)
    tests_total += 1
    if gr_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(gr_ok)}")
    print(f"    API Key:    {gr.get('hasAPIKey', '?')}")
    print(f"    Time:       {fmt_ms(gr.get('elapsedMs', 0))}")
    if gr_ok:
        pre = gr.get("pre", {})
        post = gr.get("post", {})
        print(f"    {'':>12} {'BEFORE':>10} {'AFTER':>10} {'CHANGED':>10}")
        print(f"    {'Duration':>12} {str(pre.get('duration','?'))+'m':>10} {str(post.get('duration','?'))+'m':>10} {'YES' if gr.get('durationChanged') else 'no':>10}")
        print(f"    {'Distance':>12} {str(pre.get('distance','?'))+'m':>10} {str(post.get('distance','?'))+'m':>10} {'—':>10}")
        print(f"    {'Polyline':>12} {str(pre.get('polylineLen','?'))+' ch':>10} {str(post.get('polylineLen','?'))+' ch':>10} {'YES' if gr.get('polylineChanged') else 'no':>10}")
        print(f"    {'Directions':>12} {str(pre.get('directionsCount','?')):>10} {str(post.get('directionsCount','?')):>10} {'YES' if gr.get('directionsPopulated') else 'no':>10}")
    else:
        print(f"    Error:      {gr.get('error', 'unknown')}")
    print()
    
    # Cancel-Save
    print_subsection("Cancel-Save (session cache persistence)")
    cs = phases.get("cancelSave", {})
    cs_ok = cs.get("match", False)
    tests_total += 1
    if cs_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(cs_ok)}")
    print(f"    Stored:     {cs.get('stored', 0)} routes")
    print(f"    Retrieved:  {cs.get('retrieved', 0)} routes")
    print(f"    Match:      {cs.get('match')}")
    print()
    
    # Deduplication
    print_subsection("Route Deduplication (Jaccard similarity)")
    dedup = phases.get("deduplication", {}).get("buckets", {})
    total_dupes = sum(b.get("duplicatePairs", 0) for b in dedup.values())
    dedup_ok = total_dupes == 0
    tests_total += 1
    if dedup_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(dedup_ok)}")
    print(f"    {'Bucket':>8} {'Routes':>7} {'Unique Sigs':>11} {'Avg Jaccard':>12} {'Dupe Pairs':>11}")
    print(f"    {DIM}{'─' * 55}{RESET}")
    for bucket in sorted(dedup.keys(), key=int):
        b = dedup[bucket]
        jaccard_str = f"{b.get('avgJaccard', 0):.2f}"
        dupes = b.get("duplicatePairs", 0)
        dupe_str = f"{RED}{dupes}{RESET}" if dupes > 0 else f"{GREEN}{dupes}{RESET}"
        print(f"    {bucket:>6}m {b.get('routeCount', 0):>7} {b.get('uniqueSignatures', 0):>11} {jaccard_str:>12} {dupe_str:>20}")
    print()
    
    # Permutation
    print_subsection("Route Permutation (reversing waypoint order)")
    perm = phases.get("permutation", {})
    perm_ok = perm.get("permutable", 0) > 0
    tests_total += 1
    if perm_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(perm_ok)}")
    print(f"    Tested:     {perm.get('tested', 0)} routes")
    print(f"    Permutable: {perm.get('permutable', 0)} (waypoint order reversible)")
    print(f"    Unique:     {perm.get('uniqueSignatures', 0)} (would create new distinct routes)")
    print()
    
    # ═══════════════════════════════════════════════════════════════════
    # TABLE 4: POI Quality & Diversity — Detailed
    # ═══════════════════════════════════════════════════════════════════
    print_section("4. POI Quality & Diversity")
    pq = phases.get("poiQuality", {})
    junk_count = pq.get("junkNamesFound", 0)
    junk_ok = junk_count == 0
    tests_total += 1
    if junk_ok: tests_passed += 1
    
    print(f"  Total POIs:       {BOLD}{pq.get('totalPOIs', 0)}{RESET}")
    print(f"  Junk Name Filter: {pass_fail(junk_ok)} ({junk_count} leaked through)")
    if junk_count > 0:
        print(f"  Junk names found:")
        for name in pq.get("junkNames", []):
            print(f"    {RED}* \"{name}\"{RESET}")
    
    print_subsection("POI Type Distribution")
    type_dist = pq.get("typeDistribution", {})
    if type_dist:
        sorted_types = sorted(type_dist.items(), key=lambda x: -x[1])
        max_count = max(v for _, v in sorted_types) if sorted_types else 1
        for t, c in sorted_types:
            bar_len = int(c / max_count * 30)
            bar = "█" * bar_len
            print(f"    {t:>25} {c:>3}  {CYAN}{bar}{RESET}")
    
    print_subsection("Type Diversity per Bucket")
    diversity = pq.get("diversityPerBucket", {})
    if diversity:
        for b in sorted(diversity.keys(), key=int):
            v = diversity[b]
            bar = "█" * v
            color = GREEN if v >= 3 else (YELLOW if v >= 1 else RED)
            print(f"    {b:>4}m: {v:>2} types  {color}{bar}{RESET}")
    print()

    # ═══════════════════════════════════════════════════════════════════
    # TABLE 5: Dead Zone, Travel, Distance, API
    # ═══════════════════════════════════════════════════════════════════
    print_section("5. Other Quality Metrics")
    
    # Dead Zone
    print_subsection("Dead Zone Fallback")
    dz = phases.get("deadZoneFallback", {})
    if dz.get("naturalDeadZone", False):
        print(f"    Status:          {YELLOW}DEAD ZONE DETECTED{RESET}")
        print(f"    Bucket:          {dz.get('bucket', '?')}m")
        print(f"    Total Routes:    {dz.get('totalRoutes', '?')}")
        print(f"    In-Band Routes:  0")
        print(f"    70-80% Fallback: {dz.get('deadZoneFallbackRoutes', 0)} routes")
        print(f"    Closest:         {dz.get('closestDuration', '?')}m ({dz.get('closestPercent', '?')}% of target)")
    else:
        print(f"    Status:          {GREEN}No dead zones{RESET} — all buckets have in-band routes")
    print()
    
    # Travel-to-Start — detailed
    print_subsection("Travel-to-Start (distance to first waypoint)")
    tts = phases.get("travelToStart", {})
    tts_ok = tts.get("flaggedRoutes", 0) == 0
    tests_total += 1
    if tts_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(tts_ok)}")
    print(f"    Average:    {tts.get('avgPercent', 0):.1f}% of target duration")
    print(f"    Maximum:    {tts.get('maxPercent', 0):.1f}% of target duration")
    print(f"    Flagged:    {tts.get('flaggedRoutes', 0)} routes (>25% of target)")
    print(f"    Total:      {tts.get('totalRoutes', 0)} routes tested")
    
    # Show worst offenders from route data
    worst_travel = []
    for bucket in sorted(gen.keys(), key=int):
        info = gen[bucket]
        for r in info.get("routes", []):
            travel_min = r.get("travelToStartMinutes", 0)
            bk = int(bucket)
            pct = (travel_min / bk * 100) if bk > 0 else 0
            if pct > 25:
                worst_travel.append((bk, r.get("name", "?"), travel_min, r.get("travelToStartMeters", 0), pct))
    
    if worst_travel:
        worst_travel.sort(key=lambda x: -x[4])
        print(f"\n    {YELLOW}Flagged routes (travel > 25% of target):{RESET}")
        print(f"    {'Bucket':>6} {'Route':>30} {'Travel':>8} {'Dist':>7} {'% of Target':>11}")
        print(f"    {DIM}{'─' * 68}{RESET}")
        for bk, name, t_min, t_m, pct in worst_travel[:10]:
            print(f"    {bk:>4}m {name[:30]:>30} {t_min:>6.1f}m {t_m:>6.0f}m {RED}{pct:>9.0f}%{RESET}")
    print()
    
    # Distance Consistency
    print_subsection("Distance vs Duration Consistency (walking speed)")
    dc = phases.get("distanceConsistency", {})
    dc_ok = dc.get("flaggedTooSlow", 0) == 0 and dc.get("flaggedTooFast", 0) == 0
    tests_total += 1
    if dc_ok: tests_passed += 1
    print(f"    Result:     {pass_fail(dc_ok)}")
    print(f"    Avg Speed:  {dc.get('avgSpeedMpm', 0):.0f} m/min (expected 60-100)")
    print(f"    Too Slow:   {dc.get('flaggedTooSlow', 0)} routes (<50 m/min)")
    print(f"    Too Fast:   {dc.get('flaggedTooFast', 0)} routes (>120 m/min)")
    print(f"    Total:      {dc.get('totalRoutes', 0)} routes tested")
    print()
    
    # API Health
    print_subsection("API Health")
    api = phases.get("apiHealth", {})
    google = api.get("google", {})
    osrm = api.get("osrm", {})
    places = api.get("places", {})
    print(f"    Google API Key:  {'✅ Present' if api.get('hasGoogleAPIKey', False) else '❌ Missing'}")
    print(f"    {'API':>15} {'Calls':>7} {'Failures':>9} {'Success':>9}")
    print(f"    {DIM}{'─' * 45}{RESET}")
    g_rate = f"{google.get('successRate', 0)*100:.0f}%"
    print(f"    {'Google':>15} {google.get('calls', 0):>7} {google.get('failures', 0):>9} {g_rate:>9}")
    print(f"    {'OSRM':>15} {osrm.get('calls', 0):>7} {osrm.get('timeouts', 0):>9} {'—':>9}")
    print(f"    {'Places':>15} {places.get('calls', 0):>7} {places.get('failures', 0):>9} {'—':>9}")
    print()
    
    # ═══════════════════════════════════════════════════════════════════
    # UNIQUE WAYPOINT CATALOG
    # ═══════════════════════════════════════════════════════════════════
    print_section("6. Unique Waypoint Catalog")
    all_waypoints = {}  # name -> {lat, lng, types, buckets, count, placeId, distFromOrigin}
    for bucket in sorted(gen.keys(), key=int):
        info = gen[bucket]
        for r in info.get("routes", []):
            for wp in r.get("waypoints", []):
                name = wp.get("name", "?")
                if name not in all_waypoints:
                    all_waypoints[name] = {
                        "lat": wp.get("lat", 0),
                        "lng": wp.get("lng", 0),
                        "types": set(wp.get("types", [])),
                        "buckets": set(),
                        "count": 0,
                        "placeId": wp.get("placeId", "?"),
                        "distFromOrigin": wp.get("distanceFromOriginMeters", 0)
                    }
                all_waypoints[name]["buckets"].add(int(bucket))
                all_waypoints[name]["count"] += 1
                all_waypoints[name]["types"].update(wp.get("types", []))
    
    sorted_wps = sorted(all_waypoints.items(), key=lambda x: -x[1]["count"])
    print(f"  {BOLD}{len(sorted_wps)} unique waypoints{RESET} across all routes\n")
    print(f"  {'#':>3} {'Waypoint Name':>35} {'Used':>5} {'Dist(m)':>8} {'Buckets':>20} {'Types':>30} {'Coordinates':>25}")
    print(f"  {DIM}{'─' * 135}{RESET}")
    for i, (name, info) in enumerate(sorted_wps):
        buckets_str = ",".join(f"{b}m" for b in sorted(info["buckets"]))
        types_str = ", ".join(sorted(info["types"]))[:30] if info["types"] else "—"
        coord_str = f"({info['lat']:.5f}, {info['lng']:.5f})"
        dist_str = f"{info['distFromOrigin']:.0f}"
        count_color = GREEN if info["count"] >= 3 else (YELLOW if info["count"] >= 2 else "")
        print(f"  {i+1:>3} {name[:35]:>35} {count_color}{info['count']:>5}{RESET} {dist_str:>8} {buckets_str:>20} {types_str:>30} {DIM}{coord_str:>25}{RESET}")
    
    # Also print placeIds grouped by waypoint name
    print_subsection("Place IDs for each waypoint")
    for i, (name, info) in enumerate(sorted_wps):
        pid = info.get("placeId", "?")
        print(f"    {name[:40]:>40}  {DIM}{pid}{RESET}")
    print()
    
    # ═══════════════════════════════════════════════════════════════════
    # OVERALL GRADE
    # ═══════════════════════════════════════════════════════════════════
    print_section("7. Overall Summary & Grade")
    
    inband_pct = (total_inband / total_routes * 100) if total_routes > 0 else 0
    test_pct = (tests_passed / tests_total * 100) if tests_total > 0 else 0
    
    poi_score = 100 if junk_count == 0 else max(0, 100 - junk_count * 10)
    overall_score = inband_pct * 0.5 + test_pct * 0.3 + poi_score * 0.2
    
    if overall_score >= 90: grade = "A"
    elif overall_score >= 75: grade = "B"
    elif overall_score >= 60: grade = "C"
    elif overall_score >= 40: grade = "D"
    else: grade = "F"
    
    print(f"  Routes Generated:  {BOLD}{total_routes}{RESET}")
    print(f"  Routes In-Band:    {BOLD}{total_inband}{RESET} ({inband_pct:.0f}%)")
    print(f"  Feature Tests:     {BOLD}{tests_passed}/{tests_total}{RESET} passed ({test_pct:.0f}%)")
    print(f"  Total Time:        {BOLD}{data.get('totalTimeSeconds', '?')}s{RESET}")
    print(f"  POI Quality:       {BOLD}{poi_score}/100{RESET}")
    print(f"  Unique Waypoints:  {BOLD}{len(sorted_wps)}{RESET}")
    print()
    print(f"  Scoring: 50% in-band rate + 30% test pass rate + 20% POI quality = {overall_score:.0f}/100")
    print(f"  {BOLD}Overall Grade:  {grade_color(grade)}{RESET}")
    print()


def main():
    if len(sys.argv) < 2:
        default_path = os.path.join(os.path.dirname(__file__), "diagnostic_routes.json")
        if os.path.exists(default_path):
            path = default_path
        else:
            print(f"Usage: {sys.argv[0]} <diagnostic_routes.json>")
            sys.exit(1)
    else:
        path = sys.argv[1]
    
    if not os.path.exists(path):
        print(f"Error: File not found: {path}")
        sys.exit(1)
    
    data = load_data(path)
    analyze(data)


if __name__ == "__main__":
    main()
