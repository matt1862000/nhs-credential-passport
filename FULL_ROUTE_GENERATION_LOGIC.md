# Full Route Generation Logic (Main Branch)

## Overview

The route generation system uses a multi-stage retry mechanism with two primary approaches:
1. **Endpoint-First Approach**: Finds a single POI at half the target distance, routes there and back
2. **Loop Approach**: Creates circular routes with multiple waypoints

## Entry Point: `generateLocalRouteWithRetry()`

**Location**: `WalkingWR/Services/GoogleMapsService.swift:5247`

### Stages

1. **Stage 1: Random Selection** (Quick Mode)
   - Calls `generateLocalRoute()` with `useSystematicSelection: false`
   - Fastest path, returns immediately if successful

2. **Stage 2: Systematic Selection + Expanded Search**
   - Calls `generateLocalRoute()` with `useSystematicSelection: true, expandedSearch: true`
   - Uses larger search radius (2x) to find more POIs

3. **Stage 3: Shorter Durations Fallback**
   - Reduces target duration by 5 minutes at a time (down to 5 min minimum)
   - Tries systematic selection with expanded search at each reduced duration

## Main Function: `generateLocalRoute()`

**Location**: `WalkingWR/Services/GoogleMapsService.swift:5761`

### Parameters
- `from location`: User's starting location
- `targetDurationMinutes`: Desired route duration
- `difficulty`: Optional route difficulty filter
- `excludePlaceIds`: POIs to exclude (for variety)
- `prefetchedPOIs`: Pre-fetched POIs (for speed)
- `useSystematicSelection`: Use systematic vs random selection
- `expandedSearch`: Use 2x search radius
- `preferredDirection`: Optional directional preference
- `useEndpointFirst`: Use single endpoint approach (better for Route 1)
- `preferMultiWaypoint`: Force 2+ waypoints for variety (routes 2-4)

### Key Steps

#### 1. Tolerance Calculation
- **Quick Mode**: 70-130% of target (65-130% for edge cases)
- **Systematic Mode**: 50-130% of target
- **Expanded Search**: 40-130% of target
- **Hard Cap**: Never exceeds 130% (routes >130% are rejected)

#### 2. Adaptive Walking Speed
- Default: 80m/min
- Adjusts to 65-90m/min based on user's completed walks
- Stored in `adaptiveWalkingSpeed` property

#### 3. Distance Multipliers (Dual-Multiplier System)
- **Estimation Multiplier**: Aggressive - used for POI selection (aims shorter)
- **Validation Multiplier**: Realistic - used for accepting routes

**By Duration**:
- ≤5 min: Density-aware (0.55-0.75 estimation, 0.85 validation)
- ≤10 min: 0.65 estimation, 0.85 validation
- ≤15 min: 0.70 estimation, 0.85 validation
- ≤20 min: 0.75 estimation, 0.88 validation
- ≤35 min: 0.82 estimation, 0.90 validation
- >35 min: 0.85 estimation, 0.92 validation

#### 4. Search Radius Calculation
- Base: `max(600, totalDistanceTarget / 2)`
- Expanded: `baseRadius * 2`
- 30+ min: `max(1500, baseRadius * 2)`
- 20-29 min: `max(1200, baseRadius * 2)`
- ≤15 min: `max(800, baseRadius * 3 / 2)`

#### 5. POI Fetching
- Uses `prefetchedPOIs` if available (faster!)
- Otherwise calls `findNearbyPlaces()` with calculated search radius
- Filters out restricted POIs (schools, hospitals without road access)
- Excludes previously shown POIs (`excludePlaceIds`)

#### 6. POI Pre-Filtering
- **Duration Pre-Filter**: Removes POIs that would create routes WAY outside target
- **POI Cap**: Density-adaptive cap
  - >300 POIs: Cap to 50
  - >200 POIs: Cap to 75
  - Otherwise: Cap to 150
- **Spatial Thinning**: Ensures geographic diversity (150m grid)
- **Source Quality Scoring**: Prefers Google POIs when plentiful

#### 7. Viability Gate (Short Routes)
- For 5-7 min routes: Nearest POI must be ≤300m
- If not viable, sets `shortRouteNotViable = true` flag

#### 8. Route Method Selection

**By Duration**:
- 1-10 min: `endpointOnly` (1-2 waypoints)
- 11-20 min: `endpointOnly` (1-3 waypoints)
- 21-30 min: `endpointOnly` (2-4 waypoints)
- 31-45 min: `endpointWithEnhancement` (2-6 waypoints)
- 46+ min: `endpointWithEnhancement` (3-8 waypoints)

## Endpoint-First Approach

**Location**: `WalkingWR/Services/GoogleMapsService.swift:6182`

### Process

1. **Calculate Ideal Endpoint Distance**
   - Half of target duration (rounded up for short routes)
   - Example: 20 min → 10 min one-way → ~800m at 80m/min

2. **Adaptive Range**
   - ≤10 min: 0.1x to 3.0x ideal distance
   - ≤15 min: 0.2x to 2.5x ideal distance
   - ≤25 min: 0.3x to 2.0x ideal distance
   - >25 min: 0.4x to 1.8x ideal distance

3. **Candidate Scoring**
   - Distance fit: `abs(distance - ideal)`
   - Corridor penalty: Penalizes if 2×distance exceeds target
   - Short walk bonus: Distance bonus for short walks (density-aware)

4. **Closest-First vs Score-Based**
   - Short routes (≤10 min): Closest-first with shuffle for variety
   - Longer routes: Score-based sorting

5. **Shuffle Top Candidates**
   - Shuffles top 8 candidates for variety when generating multiple routes

6. **Time Pre-Filter**
   - Checks cached one-way time
   - Skips POIs with estimated one-way > `halfDuration + buffer`

7. **Batch vs Sequential Mode**
   - **Batch Mode**: For short routes (≤20 min) with <35 rate limit count
     - Processes up to 6 candidates in parallel (3 concurrent)
     - Faster for tight tolerances
   - **Sequential Mode**: For longer routes or high rate limit
     - Tries candidates one by one

8. **Route Evaluation**
   - Valid if within tolerance (minAcceptable to maxAcceptable)
   - Checks enhancement potential (time headroom ≥2 min + POIs nearby)
   - Stores valid routes and best fallback

9. **Shorter Endpoint Strategy** (for variety)
   - Tries 75% of target duration endpoint
   - If 50-80% of target, enhances with waypoints
   - Adds as alternative route

10. **Return Logic**
    - Prefers enhanceable routes
    - Falls back to valid routes
    - Falls back to best fallback (if within 130% cap)

## Loop Approach

**Location**: `WalkingWR/Services/GoogleMapsService.swift:6598`

### Process

1. **Angular Diversity Score (ADS)**
   - Calculates POI distribution across 8 sectors
   - Requires ADS ≥3 for multi-waypoint mode
   - If ADS <3, POIs too clustered - skip multi-waypoint

2. **Waypoint Count Calculation**
   - Ideal: `max(1, (targetDurationMinutes / 5) - 1)`
   - Waypoints spaced ~5 mins apart
   - Extended fallback: `max(1, (targetDurationMinutes / 4) - 1)`

3. **Waypoint Range by Tier**
   - 1-10 min: 1-2 waypoints
   - 11-20 min: 1-3 waypoints
   - 21-30 min: 2-4 waypoints
   - 31-45 min: 2-6 waypoints
   - 46+ min: 3-8 waypoints

4. **Multi-Waypoint Preference**
   - For routes 2-4 (variety): Forces min 2 waypoints if ADS ≥3
   - Only applies to 20+ min routes

5. **Waypoint Count Order**
   - **Quick Mode**: Ascending (fewest first) for fast matching
   - **Retry Mode**: Descending (most first) to maximize POIs

6. **Candidate Selection**
   - `selectCandidateWaypoints()`: Filters by distance, difficulty, walkability
   - Time-based pre-filter: Removes candidates with one-way > `(target/2) + 1` min
   - Directional preference: Filters to preferred quadrant if specified
   - Shuffle top 12 candidates for variety

7. **Combination Attempts**
   - **First Attempt**: Angularly diverse waypoints (better loops)
   - **Subsequent**: Weighted randomization (prefers better candidates but allows variety)
   - Tracks tried combinations to avoid duplicates

8. **Route Evaluation** (`tryRouteAndEvaluate()`)
   - Gets walking directions via MapKit
   - Calculates total duration and distance
   - Valid if within tolerance
   - Tracks best fallback (closest to target)

9. **Early Break Logic**
   - If route >120% of target, stop trying more combinations with same waypoint count
   - Try fewer waypoints instead

10. **Route Selection**
    - Sorts valid routes by:
      1. Overrun penalty (routes >115% get penalized)
      2. Most waypoints
      3. Least backtracking (more loop-like)
      4. Closest to target time

11. **Post-Processing**
    - Removes waypoints too close together (<250m)
    - Regenerates polyline after removal
    - Route extension: If 70-95% of target, tries adding on-route POI

12. **Fallback Routes**
    - Returns best fallback if within 130% cap
    - Creates guaranteed fallback (simple out-and-back) if all else fails

## Helper Functions

### `selectCandidateWaypoints()`
- Filters POIs by ideal distance, difficulty, walkability
- Returns sorted candidates

### `selectAngularlyDiverseWaypoints()`
- Selects waypoints spread across different angles from origin
- Creates better circular routes

### `tryRouteAndEvaluate()`
- Gets walking directions for waypoint combination
- Evaluates if route is valid
- Updates valid routes and best fallback

### `enhanceRouteWithWaypoints()`
- Adds waypoints to existing route
- Finds POIs near route path
- Inserts waypoints without breaking route

### `tryExtendRoute()`
- Extends route that's 70-95% of target
- Finds POIs near route path
- Adds waypoint if it improves route

### `removeCloseWaypoints()`
- Removes waypoints <250m apart
- Regenerates polyline after removal

### `createGuaranteedFallbackRoute()`
- Creates simple out-and-back route
- Finds POI closest to half target distance
- Accepts if 40-130% of target

## Route Refresh Logic

**Location**: `WalkingWR/Services/GoogleMapsService.swift` (separate functions)

### Primary: `refreshRouteWithGoogleThenMapKit()`
1. Checks Google Directions quota (100 calls/day)
2. Local waypoint optimization (Nearest Neighbor)
3. Calls Google Directions API
4. Prefers step polylines (more detailed)
5. Falls back to MapKit if Google fails

### Fallback: `refreshRouteWithMapKit()`
1. Gets directions for each leg
2. Checks for suspicious routes (distance/straight-line < 1.10)
3. Builds combined polyline
4. Generates walking directions

### Fallback: `getOSRMWalkingDirections()`
- Used when MapKit rate-limited or suspicious route detected
- Free Open Source Routing Machine API

## Key Features

1. **Adaptive Timing**: More flexible for short routes in dense areas
2. **Density-Aware**: Adjusts behavior based on POI density
3. **Variety**: Shuffles candidates, excludes used POIs
4. **Rate Limit Aware**: Tracks MapKit requests (50/min limit)
5. **Caching**: Caches leg times to avoid redundant API calls
6. **Hard Cap**: Never returns routes >130% of target
7. **Guaranteed Fallback**: Always returns a route (or throws error)

## Error Handling

- `GoogleMapsError.rateLimited`: Waits for cooldown, returns best route found
- `GoogleMapsError.noRouteFound`: After all stages fail
- `GoogleMapsError.noPlacesFound`: If no POIs available

## Performance Optimizations

1. **Pre-fetched POIs**: Skips API call if POIs already fetched
2. **Batch Processing**: Parallel endpoint evaluation for short routes
3. **Time Pre-filtering**: Skips POIs with cached times that are too long
4. **Early Breaks**: Stops trying combinations if route too long
5. **Quick Mode**: Returns first valid route (75-120% of target)
