# 🗺️ Route Generation Algorithm Summary (v2.0.12)

*Complete overview of the WalkingWR route generation pipeline*

---

## **High-Level Flow**

```
1. POI Fetching & Filtering
   ↓
2. Angular Diversity Score (ADS) Calculation
   ↓
3. Radius Expansion (if low diversity)
   ↓
4. Waypoint Count Selection
   ↓
5. Outer Loop: Route Generation Attempts
   ├─ Candidate Selection
   ├─ Route Generation (MapKit/OSRM)
   ├─ Extension for Undershoots
   └─ Repair for Overshoots
   ↓
6. Route Selection (k-best Pareto set)
   ↓
7. Finalization
   ├─ Deduplication
   ├─ Nudge Clustered Waypoints
   ├─ Micro-Spur Insertion (up to 3 passes)
   ├─ Per-Leg Cap Trimming
   └─ Micro-Extend After Trim
   ↓
8. Return Final Route
```

---

## **Phase 1: POI Fetching & Filtering**

### **Sources (in priority order):**
1. **Pre-populated database** (OSM/Geograph, ToS-safe)
2. **Apple Maps** (free, unlimited)
3. **OSM Overpass API** (free, multiple mirrors)
4. **Geograph API** (historic/industrial photos)
5. **Google Places** (fallback, quota-limited)

### **Filtering Pipeline:**
- **Distance pre-filter**: Exclude POIs too close/far based on target duration
- **Type exclusion**: Remove infrastructure noise (post_box, bench, parking, etc.)
- **Restricted POI filtering**: Exclude playcare, nursery, playground
- **Deduplication**: Remove duplicates by place ID and coordinate
- **Geograph quality scoring**: Keep only historic/industrial items (score ≥ 1.0)

### **Output:**
- Filtered POI list with source tracking
- Angular Diversity Score (ADS) calculated once after filtering

---

## **Phase 2: Angular Diversity Score (ADS)**

### **Purpose:**
Measures geographic spread of POIs around origin to determine if multi-waypoint routes are feasible.

### **Calculation:**
- Divides 360° around origin into 8 sectors (45° each)
- Counts POIs per sector
- Score = number of sectors with ≥1 POI (range: 1-8)

### **Usage:**
- **ADS < 3**: Triggers radius expansion
- **ADS = 2**: Enforces ≥60° angular spacing between waypoints
- **ADS ≥ 3**: Allows multi-waypoint routes

---

## **Phase 3: Radius Expansion (Conditional)**

### **Trigger:**
- ADS ≤ 2 AND search radius not overridden AND elapsed time < 50% of hard-wall

### **Process:**
- Expands search radius by 25-40% (based on ADS)
- Fetches additional POIs from free sources (skip Google)
- Recalculates ADS with expanded set
- Timeout: 4 seconds max

### **Budget Guard:**
- Checks global hard-stop before expansion
- Skips if budget exhausted

---

## **Phase 4: Waypoint Count Selection**

### **Ideal Calculation:**
```
idealWaypoints = max(1, (targetDurationMinutes / 5) - 1)
```
- Assumes ~5 min walking segments between waypoints
- Example: 20 min → 3 waypoints (4 segments of 5 min each)

### **Waypoint Ranges:**
- **Standard**: `minWaypoints` to `idealWaypoints + 1`
- **Extended fallback**: Up to `(targetDurationMinutes / 4) - 1` if routes too short

### **Minimum Waypoints by Duration:**
- **≤15 min**: 2 waypoints
- **16-34 min**: 3 waypoints
- **35+ min**: 4 waypoints

### **Ordering Strategy:**
- **Quick mode**: Ascending (fewest first) for fast matching
- **Retry modes**: Descending (most first) to maximize POIs

---

## **Phase 5: Outer Loop - Route Generation**

### **Attempt Caps (Duration-Based):**
- **10-20 min**: 30 attempts
- **21-34 min**: 40 attempts
- **35-60 min**: 10 attempts (SPRINT-7: tightened from 25)

### **Time Budgets:**
- **Soft stop**: 12.0s (early exit if k-best filled)
- **Hard stop**: 17.8s (absolute cutoff, 200ms guard band)

### **Global Hard-Stop Guards:**
Applied at:
- Loop entry
- Expansion iterations
- Engine call sites
- Repair/extend passes
- Finalization steps

### **For Each Waypoint Count:**

#### **5.1 Candidate Selection**
- Filters POIs by distance range (ideal ± tolerance)
- Excludes restricted types
- Sorts by walkability score, distance, recent use penalty

#### **5.2 Route Generation**
- Calls MapKit Directions API (free, unlimited)
- Falls back to OSRM if MapKit rate-limited
- Wraps with timeout (soft/hard caps per call)
- Returns polyline, legs, distance, duration

#### **5.3 Extension for Undershoots (v2.0.11)**
**Trigger:**
- Route is 20-98% of target (15% for 40+ min targets)
- At least 90 seconds headroom
- Available POIs exist

**Process:**
- **Severe undershoot (<50%)**: Search 500m from route polyline
- **Mild undershoot (50-98%)**: Search 200m from route polyline
- **Multi-pass extension**: Up to 3 passes if route <70% of target
- Each pass adds one POI near route midpoint
- Stops when route reaches tolerance or MapKit waypoint limit (8)

**Budget Guard:**
- Checks time remaining before each pass
- Skips if <1.2s remaining

#### **5.4 Repair for Overshoots**
**Trigger:**
- Route >120% of target

**Process:**
- **Micro-trim**: Remove farthest waypoint, regenerate
- **Micro-extend**: If trimmed route <90%, add POIs back (up to 2 passes)
- **Per-leg cap**: Trim legs exceeding 50% of target duration

---

## **Phase 6: Route Selection (k-best Pareto Set)**

### **Valid Route Criteria:**
- Duration: 50-180% of target (80-130% preferred)
- Waypoints: ≥ minimum for duration tier
- No hard cap violations

### **Scoring Formula (v2.0.12):**
```swift
score = overrunPenalty 
      - subTargetBonus 
      - waypointBonus 
      + (backtrackScore * 0.5)
      + underWPPenalty  // If below minWaypoints
```

**Components:**
- **overrunPenalty**: 
  - Routes >110%: `(accuracy - 1.10) * 30`
  - Routes >1.10 with <minWP: `× 3.0 multiplier`
  - Right-edge penalty: `+0.5` if accuracy > 1.10
- **subTargetBonus**: `+0.05` if accuracy 0.90-1.00
- **waypointBonus**: `count * 0.10` (or `0.12` if within ±10% of target)
- **underWPPenalty**: `+1.0` if below minWaypoints
- **backtrackScore**: Measures route loopiness (0-1 scale)

### **Selection Priority:**
1. Lower composite score
2. More waypoints (tiebreaker)
3. Closer to target (tiebreaker)
4. Shorter if equidistant (prefer sub-100%)

### **k-best Filtering:**
- Keeps top k routes by score
- Early exit if k filled and soft-stop reached

---

## **Phase 7: Finalization**

### **7.1 Deduplication**
- Removes duplicate POIs by place ID and coordinate
- Category-aware duplicate check (same category + <50m apart)

### **7.2 Nudge Clustered Waypoints**
**Trigger:**
- Route below minWaypoints after deduplication

**Process:**
- Moves clustered waypoints 15-25m along network
- Preserves waypoint count
- Regenerates polyline after nudge

### **7.3 Micro-Spur Insertion (v2.0.12)**
**Trigger:**
- Still below minWaypoints after nudge
- Available POIs within 800m of origin

**Process:**
- **Up to 3 passes** (was 2 in v2.0.11)
- Each pass adds 1-2 POIs near route midpoint
- **Time guard**: Skip if <1.2s remaining
- Regenerates polyline after each pass

### **7.4 Per-Leg Cap Trimming**
**Trigger:**
- Any leg exceeds 50% of target duration

**Process:**
- Removes farthest waypoint causing over-cap leg
- Regenerates route
- **Micro-extend after trim**: If route falls below 95%, add POI back (up to 2 passes)

### **7.5 Final Guards**
- **Micro-trim**: If route >130%, remove farthest waypoint
- **Hard cap**: Reject if >180%
- **NEAR_MISS**: Return nil if still >130% OR <minWP after all fixes

---

## **Phase 8: Fallbacks**

### **Topology-Safe Fallback:**
- Uses nearest-neighbor algorithm
- Guaranteed to return a route
- May exceed tolerance

### **Out-and-Back Fallback:**
- Single waypoint at ideal distance
- Guaranteed success
- Accepts extended cap (up to 180%)

### **Template Fallback:**
- Pre-computed routes for fragile durations (10, 25, 45 min)
- Triggered if candidates < 3

---

## **Key Configuration Parameters (v2.0.12)**

### **Time Budgets:**
- Soft stop: **12.0s**
- Hard stop: **17.8s** (200ms guard band)

### **Selection Scoring:**
- Overshoot penalty multiplier: **3.0**
- Sub-target bonus: **0.05**
- Waypoint score bonus: **0.10** (0.12 for close fits)
- Under-WP penalty: **1.0**
- Right-edge penalty: **0.5** (for accuracy > 1.10)

### **Finalization:**
- Max spur passes: **3**
- Min time for spur: **1.2s**
- Max extension passes: **3** (for severe undershoots)
- Extension search radius: **500m** (severe) / **200m** (mild)

### **Speed Model (Density-Aware):**
- Dense (<150m avg leg): **3.88 km/h**
- Urban (150-350m): **4.25 km/h**
- Suburban (>350m): **5.00 km/h**

---

## **Telemetry & Logging**

### **Tracked Metrics:**
- `elapsed_ms`: Total generation time
- `engine_calls`: MapKit/OSRM call counts
- `expansions`: Radius expansion count
- `repair_passes`: Overshoot repair attempts
- `nudges`: Waypoint nudge count
- `micro_spurs`: Micro-spur insertion count
- `wp_before_finalization`: Waypoint count before finalization
- `wp_after_finalization`: Waypoint count after finalization
- `stop_reason`: Why generation stopped (NORMAL, SOFT-STOP, HARD-STOP)
- `stage_exited`: Which stage triggered hard-stop
- `per_leg_over_cap`: Boolean flag if any leg exceeded 50% cap

### **Log Format:**
```
📊 [TELEMETRY] route_id={duration}min duration_bucket={duration}min elapsed_ms={ms}
   engine_calls={mapkit:X, osrm:Y, skipped:Z}
   expansions={N} repair_passes={M} nudges={K} micro_spurs={L}
   wp_before_finalization={A} wp_after_finalization={B}
   stop_reason={reason} stage_exited={stage} per_leg_over_cap={bool}
```

---

## **Performance Optimizations**

### **Early Exit:**
- If k-best filled and soft-stop reached → exit early
- If first valid route found → short-circuit after 1s grace period

### **Progressive Widening:**
- Start with tight search radius
- Expand only if no valid candidates found
- Cap expansion at 50% of hard-wall budget

### **Duration-Specific Caps:**
- Tighter attempt limits for 35-60 min routes (10 attempts)
- Prevents search explosion on long durations

### **Budget-Aware Operations:**
- Time-remaining checks before expensive operations
- Skip micro-spur/extend if <1.2s remaining
- Short-circuit engine calls near hard-stop

---

## **Quality Guarantees**

### **Minimum Waypoints:**
- Enforced at finalization
- Nudge → micro-spur → repair sequence
- Routes below minimum demoted in scoring (not hard-rejected)

### **Accuracy Targets:**
- **Tight accuracy (90-110%)**: Target ≥28%
- **Overshoot penalty**: Strongly penalizes >110%
- **Sub-target bonus**: Slightly prefers <100% over >100%

### **Latency Targets:**
- **p95**: ≤12s
- **p99**: ≤18s
- **Zero outliers**: No `elapsed_ms > 17800`

---

## **Recent Improvements (Sprint-7)**

### **v2.0.11: Multi-Pass Extension**
- Lowered extension trigger from 35% to 20% (15% for 40+ min)
- Adaptive search radius (500m for severe undershoots)
- Multi-pass extension (up to 3 passes for routes <70% of target)

### **v2.0.12: Config Tweaks**
- Increased overshoot penalty (2.5 → 3.0)
- Increased sub-target bonus (0.01 → 0.05)
- Increased waypoint bonus (0.08 → 0.10)
- Added under-WP penalty (+1.0)
- Increased spur passes (2 → 3)
- Tightened spur time guard (0.5s → 1.2s)

---

*Last updated: v2.0.12 (January 2026)*
