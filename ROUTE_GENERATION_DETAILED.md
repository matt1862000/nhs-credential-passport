# Detailed Route Generation Flow

## High-Level Architecture

### Entry Point: `generateRouteTopologySafe()`
The main entry point that **guarantees** a route is always returned.

```
generateRouteTopologySafe()
  ├─> Step 1: Try POI-first approach (generateLocalRouteWithRetry)
  │     └─> If succeeds → Return route
  │
  └─> Step 2: If POI-first fails → Try topology-safe approach
        ├─> Generate network-constrained base routes (MapKit)
        ├─> Enhance with curated POIs (optional)
        └─> Return best route
```

---

## Stage 1: POI-First Approach (`generateLocalRouteWithRetry`)

### Multi-Stage Retry System

#### **Stage 1: Quick Random Selection**
- **Mode**: Quick (fast, less thorough)
- **Selection**: Random POI selection
- **Search**: Standard radius
- **Goal**: Fast route generation

#### **Stage 2: Systematic Retry** (if Stage 1 fails)
- **Mode**: Systematic (thorough)
- **Selection**: Systematic POI combinations
- **Search**: Expanded radius (2x)
- **Goal**: Find route with more attempts

#### **Stage 3: Duration Reduction** (if Stage 2 fails)
- Reduces target duration by 5 minutes
- Retries with shorter target
- Continues until route found or minimum reached

---

## Stage 2: Core Route Generation (`generateLocalRoute`)

### Phase 1: Configuration & Setup

#### 1. **Tolerance Calculation** (Duration-Based)
- **Quick mode**: 70-130% of target
- **Retry mode**: 40-130% of target
- **Edge cases** (≤10min, ≥55min): 65-130%
- **Hard cap**: 130% maximum (never show routes >130%)

#### 2. **Adaptive Walking Speed**
- **Default**: 80 m/min
- **Adjusts** based on user history (65-90 m/min)
- **Used for**: Distance estimation

#### 3. **Road Factor Multipliers**
- **Estimation multiplier**: 0.65-0.85 (for POI selection, aims shorter)
- **Validation multiplier**: 0.85-0.92 (for route acceptance, realistic)
- **Density-aware** for ≤5 min routes

#### 4. **Search Radius Calculation**
- **Base**: `max(600m, totalDistanceTarget / 2)`
- **Short routes** (≤15min): 1.5x base
- **Medium routes** (16-29min): Standard
- **Long routes** (≥30min): 2x base
- **Expanded search**: 2x base

#### 5. **Route Method Selection** (Duration-Based)
```
1-10 min:  endpointOnly (1-2 waypoints)
11-20 min: endpointOnly (1-3 waypoints)
21-30 min: endpointOnly (2-4 waypoints)
31-45 min: endpointWithEnhancement (2-6 waypoints)
46-60 min: endpointWithEnhancement (3-8 waypoints)
```

---

### Phase 2: POI Fetching

#### 1. **Check Pre-Populated Database**
- First checks `PrePopulatedPOIService`
- If available: uses database POIs (fast, no API calls)
- Tracks `usedDatabase = true`

#### 2. **Free Sources First** (if no database)
- **Apple Maps** (local, fast)
- **OpenStreetMap** (Overpass API)
- **Geograph** (photos/POIs)
- **Goal**: Avoid Google API costs

#### 3. **Google Fallback** (if <15 POIs and no database)
- Only if free sources found <15 POIs
- Fetches Google Places API
- Merges with free sources

#### 4. **POI Filtering Pipeline**
```
All POIs
  ├─> Filter restricted POIs (playcare, nursery, kindergarten, playground)
  ├─> Filter POIs in restricted areas (schools, but NOT hospitals)
  ├─> Validate coordinates (not NaN, not 0,0)
  ├─> Canonical deduplication (by name + coordinate)
  ├─> Pre-filter by duration (distance-based estimation)
  └─> Result: Filtered POI list
```

---

### Phase 3: Route Generation Strategy

Two strategies based on POI density and duration:

#### **Strategy A: Endpoint-First** (10-45 min routes)

##### 1. **Select Endpoint Candidates**
- Calculate ideal distance: `targetDuration * walkingSpeed * estimationMultiplier / 2`
- Score POIs by:
  - **Distance to ideal** (bell curve)
  - **Walkability score**
  - **Recent use penalty**
  - **Source quality** (Google preferred)
  - **Short walk distance bonus**

##### 2. **Try Endpoint Routes**
- For each candidate endpoint:
  - Generate route: `origin → endpoint → origin`
  - Check if within tolerance (minAcceptable to maxAcceptable)
  - If valid: add to `validEndpointRoutes`
  - If too long: store as fallback

##### 3. **Route Selection**
- **Priority 1**: Routes with enhancement potential (can add waypoints)
- **Priority 2**: Any valid route
- **Priority 3**: Best fallback route (within 150% cap)

##### 4. **Route Enhancement** (if selected route can be enhanced)
- Try adding waypoints along the route
- Find POIs within 200m of route polyline
- Add POI if route stays within tolerance
- Max 2 POIs added

#### **Strategy B: Loop Approach** (fallback or 50-60 min routes)

##### 1. **Calculate Waypoint Counts**
- **Ideal**: `(targetDuration / 5) - 1` waypoints
- **Example**: 20min → 3 waypoints (4 segments of 5min each)
- **Range**: `minWaypoints` to `maxWaypoints` (tier-based)

##### 2. **Angular Diversity Check**
- Calculate **Angular Diversity Score** (0-8 sectors)
- If ADS < 3: POIs too clustered, skip multi-waypoint
- If ADS ≥ 3: Proceed with multi-waypoint

##### 3. **Try Waypoint Combinations**
```
For each waypoint count (e.g., 3, 2, 1):
  ├─> Select candidates at ideal segment distance
  ├─> Filter by time (max one-way time check)
  ├─> Apply directional preference (if specified)
  ├─> Shuffle top candidates for variety
  └─> Try combinations:
        ├─> First: Angularly diverse selection
        └─> Subsequent: Weighted random selection
```

##### 4. **Route Evaluation** (`tryRouteAndEvaluate`)
- Generate directions: `origin → waypoint1 → waypoint2 → ... → origin`
- Check duration tolerance
- If valid: add to `validRoutes`
- If too long: try trimming farthest waypoint
- If too short: try extending with on-route POI

---

### Phase 4: Route Extension & Trimming

#### **Extension** (for undershooting routes)
- **Trigger**: Route is 70-95% of target with ≥1min headroom
- **Process**:
  1. Find POIs within 200m of route polyline
  2. Sort by distance to route midpoint
  3. Try adding first POI
  4. If within tolerance: use extended route
  5. If not: use original route

#### **Trimming** (for overshooting routes)
- **Trigger**: Route >130% of target with 2+ waypoints
- **Process**:
  1. Find farthest waypoint from origin
  2. Remove it
  3. Regenerate route
  4. If within tolerance: use trimmed route
  5. If still too long: try again or use original

---

### Phase 5: Route Selection & Finalization

#### 1. **Select Best Route**
- **Priority**: Routes within tolerance (minAcceptable to maxAcceptable)
- **If multiple**: Prefer routes with more waypoints
- **If none**: Use best fallback (within 150% cap)

#### 2. **Final Deduplication**
- Remove duplicate waypoints (same placeId or very close coordinates)
- Regenerate route if waypoints removed
- Ensure no duplicates in final route

#### 3. **Route Summary Logging**
- Logs: duration, waypoints, distance, POIs, database usage

---

## Stage 3: Topology-Safe Fallback (if POI-first fails)

### Network-Constrained Candidate Generation

#### 1. **Generate Base Routes**
- Uses MapKit's topology awareness
- Tries 4 evenly-spaced bearings (N, E, S, W)
- Creates out-and-back routes at target distance
- Returns routes within 70-130% of target

#### 2. **Select Best Base Route**
- Picks route closest to target duration
- Ensures route is topologically valid

#### 3. **Optional POI Enhancement**
- Tries to add 1-2 curated POIs to base route
- Only if route stays within 130% of target
- If enhancement fails: uses base route (still valid)

---

## Stage 4: Guaranteed Fallback (Last Resort)

### Hard Guarantee: `generateOutAndBackFallback`

#### 1. **Try 4 Directions** (N, E, S, W)
- Target distance: `targetDuration * walkingSpeed * 0.45` (half for out-and-back)
- Uses MapKit to generate route
- Accepts if within 50-200% of target

#### 2. **Last Resort: Minimal Route**
- 200m out-and-back route
- Ensures something is always returned

---

## Key Features & Optimizations

### 1. **Pre-Populated Database**
- Checks database first (fast, no API calls)
- Falls back to live APIs if not available
- **100% database usage** in your test results

### 2. **Optimistic Filtering (Option 3C)**
- Filters POIs asynchronously in background
- Caches restricted polygons and filtered POIs
- Reduces blocking API calls

### 3. **Adaptive Parameters**
- **Walking speed** adjusts based on user history
- **Road factor** adapts based on route duration
- **Search radius** adapts based on target duration

### 4. **Route Variety**
- Shuffles top candidates for variety
- Tracks recently used POIs (penalty)
- Angular diversity for multi-waypoint routes

### 5. **Performance Optimizations**
- Pre-fetched POIs skip API calls
- Quick mode returns first valid route
- Caches leg times to avoid repeated API calls
- Rate limiting for MapKit and Google APIs

---

## Route Evaluation Criteria

### Valid Route Requirements
- **Duration**: Within `minAcceptable` to `maxAcceptable` (typically 70-130%)
- **Waypoints**: No duplicates
- **Distance**: Reasonable (not >2x target)
- **Topology**: Must be walkable (validated by directions API)

### Route Selection Priority
1. Routes within tolerance with most waypoints
2. Routes within tolerance with fewer waypoints
3. Best fallback route (within 150% cap)
4. Guaranteed fallback (within 180% cap)

---

## Current Issues (From Test Results)

### 1. **Low Waypoint Count** (avg 1.5)
- Suggests endpoint-first is selecting single-destination routes
- Multi-waypoint logic may be too restrictive

### 2. **Accuracy Issues** (38.6% inaccurate)
- Pre-filter may be too aggressive
- Route extension not triggering enough
- Estimation multipliers may need adjustment

### 3. **Performance Variance**
- **Fastest**: 0.37s (database hit)
- **Slowest**: 33.22s (likely retry stages + API calls)

---

## Data Flow Summary

```
User Request (targetDurationMinutes, location)
    ↓
generateRouteTopologySafe()
    ↓
generateLocalRouteWithRetry()
    ├─> Stage 1: Quick mode
    ├─> Stage 2: Systematic retry (if Stage 1 fails)
    └─> Stage 3: Duration reduction (if Stage 2 fails)
    ↓
generateLocalRoute()
    ├─> Fetch POIs (database → free sources → Google)
    ├─> Filter POIs (restricted, deduplication, pre-filter)
    ├─> Select strategy (endpoint-first vs loop)
    ├─> Generate routes (try combinations)
    ├─> Evaluate routes (extension/trimming)
    └─> Select best route
    ↓
Final Route (GeneratedRoute)
    - places: [PlaceResult]
    - polyline: String
    - distanceMeters: Int
    - durationSeconds: Int
    - legs: [DirectionsLeg]
```

---

## Key Functions Reference

| Function | Purpose |
|----------|---------|
| `generateRouteTopologySafe()` | Main entry point, guarantees route |
| `generateLocalRouteWithRetry()` | Multi-stage retry system |
| `generateLocalRoute()` | Core route generation logic |
| `tryRouteAndEvaluate()` | Evaluate single route, extension/trimming |
| `generateNetworkConstrainedCandidates()` | Topology-safe base routes |
| `enhanceRouteWithCuratedPOIs()` | Add POIs to base route |
| `generateOutAndBackFallback()` | Last resort guaranteed route |
| `preFilterPOIsByDuration()` | Filter POIs by estimated duration |
| `calculatePOIScore()` | Score POI for selection |
| `selectAngularlyDiverseWaypoints()` | Select waypoints for loops |

---

## Configuration Parameters

### Tolerance Ranges
- **Quick mode**: 70-130%
- **Retry mode**: 40-130%
- **Edge cases**: 65-130%
- **Hard cap**: 130% (never exceed)

### Waypoint Tiers
- **10min**: 1-2 waypoints
- **11-20min**: 1-3 waypoints
- **21-30min**: 2-4 waypoints
- **31-45min**: 2-6 waypoints
- **46-60min**: 3-8 waypoints

### Search Radii
- **Base**: `max(600m, totalDistanceTarget / 2)`
- **Short routes**: 1.5x base
- **Long routes**: 2x base
- **Expanded**: 2x base

### Road Factors
- **Estimation**: 0.65-0.85 (aims shorter)
- **Validation**: 0.85-0.92 (realistic)
- **Density-aware**: Adjusts for ≤5min routes

---

## Performance Characteristics

### Fast Path (Database Available)
1. Load POIs from database: ~0.1s
2. Filter and score POIs: ~0.1s
3. Generate route: ~0.2-2s
4. **Total**: ~0.4-2.5s

### Slow Path (No Database)
1. Fetch POIs from APIs: ~2-5s
2. Filter and score POIs: ~0.2s
3. Generate route (multiple attempts): ~5-20s
4. **Total**: ~7-25s

### Retry Path (Multiple Stages)
1. Stage 1 fails: +5-10s
2. Stage 2 (expanded search): +10-15s
3. Stage 3 (duration reduction): +5-10s
4. **Total**: ~20-45s

---

## Recent Changes (v2.0.2)

### Topology-Safe Routing
- Added `generateRouteTopologySafe()` as high-level control
- Network-constrained candidate generation
- POI enhancement (optional, non-blocking)

### Root Cause Fixes
- Disabled aggressive density tightening for curated POIs
- Relaxed pre-filter for curated POIs (35-130%)
- Adaptive road factor (after initial failures)

### Performance Improvements
- Optimistic filtering (Option 3C)
- Database-first approach
- Reduced API calls

---

## Testing & Debugging

### Batch Test Function
- `testRouteGenerationForAllPostcodes()`: Tests all postcodes
- `testRouteGenerationAtIntervals()`: Tests single location
- Captures: routes attempted, valid routes found, all routes, database usage

### Route Capture
- `RouteCapture` class tracks all valid routes
- `RouteGenerationResult` returns selected + all valid routes
- Enables analysis of route generation process

---

## Future Improvements

### Identified Issues
1. **Low waypoint count**: Need to encourage multi-waypoint routes
2. **Accuracy**: 38.6% inaccurate routes need improvement
3. **Performance variance**: Some routes take 30+ seconds

### Potential Solutions
1. **Route multiplier tracking**: Track actual/estimated ratio
2. **Adaptive road factor**: Adjust based on historical data
3. **Conditional topology-safe**: Activate earlier based on routeMultiplier
4. **Better waypoint selection**: Improve angular diversity scoring

---

*Last Updated: 2026-01-23*
*Version: 2.0.2*
