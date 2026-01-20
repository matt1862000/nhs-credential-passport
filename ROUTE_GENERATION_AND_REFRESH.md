# Route Generation & Refresh Flow

## Overview

The app uses a **multi-tier fallback system** for route generation and refresh:
1. **Initial Generation**: MapKit (free) → Google Directions (paid, if needed)
2. **Route Refresh**: Google Directions (paid) → MapKit (free) → OSRM (free, if MapKit rate-limited)

---

## 1. Initial Route Generation

### Flow: `generateLocalRouteWithRetry()` → `generateLocalRoute()`

**Primary Method**: `generateLocalRoute()` in `GoogleMapsService.swift`

#### Step 1: POI Selection
- Fetches nearby POIs from:
  - **OpenStreetMap (OSM)** - Primary source (free, open data)
  - **Apple Maps** - Secondary source (free, rate-limited to 50/min)
  - **Google Places API** - Tertiary source (paid, currently disabled in your project)
- Filters POIs by:
  - Distance (within target duration range)
  - Restricted areas (schools, private property without road access)
  - Walkability score

#### Step 2: Route Calculation
Uses **MapKit (Apple Maps)** for initial route calculation:
- **FREE** - No API costs
- Rate limit: 50 requests per 60 seconds
- Calculates walking directions between waypoints
- Generates polyline (route path)

#### Step 3: Waypoint Optimization
- **Local optimization** (Nearest Neighbor algorithm) before sending to APIs
- Reorders waypoints to minimize total distance
- **Why?** Google's `optimize:true` parameter requires Premium SKU ($40/month)
- We stay in **Essentials SKU** ($0.20 per 1000 requests) by optimizing locally

#### Step 4: Fallback to Google (if needed)
- Only if MapKit route is outside tolerance (too short/long)
- Uses `getGoogleDirectionsRoute()`:
  - Calls Google Directions API (Legacy REST)
  - **Cost**: ~$0.20 per 1000 requests (Essentials SKU)
  - Returns optimized route with detailed polyline

---

## 2. Route Refresh (When User Taps "Let's Go")

### Flow: `refreshRouteWithGoogleThenMapKit()` → `refreshRouteWithMapKit()`

**Purpose**: Get fresh, accurate directions from user's current location before navigation starts.

### Primary Path: Google Directions API

**Function**: `refreshRouteWithGoogleThenMapKit()` in `GoogleMapsService.swift`

#### Step 1: Check Quota
- Checks if Google Directions quota available (`canUseGoogleDirectionsRefresh`)
- Daily limit: 100 calls (configurable)

#### Step 2: Local Waypoint Optimization
- Uses `performLocalOptimization()` (Nearest Neighbor algorithm)
- Reorders waypoints to minimize distance
- **Format**: `%.6f,%.6f` (6 decimal places for precision)
- **No `optimize:true` parameter** - stays in Essentials SKU

#### Step 3: Google Directions API Call
```
URL: https://maps.googleapis.com/maps/api/directions/json?
  origin={lat},{lng}
  destination={lat},{lng}  (same as origin - loop route)
  waypoints={lat1},{lng1}|{lat2},{lng2}|...
  mode=walking
  key={API_KEY}
```

**Response includes**:
- Overview polyline (route path)
- Step-by-step polylines (more detailed, preferred)
- Turn-by-turn directions
- Distance and duration per leg

#### Step 4: Polyline Selection
- **Preferred**: Step polylines (more points = follows roads better)
- **Fallback**: Overview polyline (fewer points, less precise)
- Checks point density: <20 points/km = low quality warning

### Fallback Path: MapKit

**Function**: `refreshRouteWithMapKit()` in `GoogleMapsService.swift`

**Triggers**:
- Google quota reached
- Google API error (403, network failure, etc.)
- Google returns no routes

#### Process:
1. **Get directions** for each leg (origin → waypoint1 → waypoint2 → ... → origin)
2. **Check for suspicious routes**:
   - If route distance / straight-line distance < 1.10 → suspicious (likely shortcut through fields)
   - **Fix**: Try OSRM first (free), then Google if needed
3. **Build combined polyline** from all legs
4. **Generate walking directions** from MapKit response

### Fallback Path: OSRM (Open Source Routing Machine)

**Triggers**:
- MapKit rate limit approaching (45+ requests in 60s)
- Suspicious MapKit route detected

**Function**: `getOSRMWalkingDirections()` in `GoogleMapsService.swift`

- **FREE** - Open source, no API costs
- Uses OpenStreetMap data
- **Calibration**: OSRM often overestimates walking time
  - Calibration factor calculated from MapKit comparisons
  - Applied to OSRM durations for accuracy

---

## 3. Waypoint Optimization Algorithms

### Local Optimization (Nearest Neighbor)

**Function**: `performLocalOptimization()` in `GoogleMapsService.swift`

**Purpose**: Reorder waypoints to minimize total route distance **before** sending to Google API.

**Algorithm**:
1. Start from origin
2. Find nearest unvisited waypoint
3. Move to that waypoint
4. Repeat until all waypoints visited
5. Return to origin

**Why?**
- Google's `optimize:true` requires **Premium SKU** ($40/month)
- We use **Essentials SKU** ($0.20 per 1000 requests)
- Local optimization gives 80-90% of Google's optimization quality
- Saves $39.80/month

### MapKit Optimization

**Function**: `optimizeWaypointOrder()` in `GoogleMapsService.swift`

**Purpose**: Reorder waypoints for MapKit routes (when not using Google)

**Algorithm**: Similar Nearest Neighbor approach

---

## 4. API Usage & Costs

### Google Directions API (Legacy REST)

**SKU**: Essentials
- **Cost**: $0.20 per 1000 requests
- **Daily limit**: 100 calls (configurable)
- **Format**: `origin={lat},{lng}&destination={lat},{lng}&waypoints={waypoints}&mode=walking`

**Optimization**:
- ❌ **No `optimize:true`** (requires Premium SKU)
- ✅ **Local optimization** before API call
- ✅ **Coordinate format**: `%.6f,%.6f` (6 decimal places)

### Apple MapKit

**Cost**: FREE
- **Rate limit**: 50 requests per 60 seconds
- **Semaphore**: Prevents concurrent calls (iOS limitation)
- **Rate limit detection**: Tracks requests, waits when approaching limit

### OSRM (Open Source Routing Machine)

**Cost**: FREE
- **No rate limits** (self-hosted or public mirrors)
- **Calibration**: Adjusts durations based on MapKit comparisons
- **Fallback**: Used when MapKit rate-limited

---

## 5. Route Quality Checks

### Suspicious Route Detection

**Ratio**: `route_distance / straight_line_distance`

- **Ratio < 1.10**: Suspicious (likely shortcut through fields)
- **Fix**: Try OSRM → Google → Keep MapKit if all fail

### Point Density Check

- **<20 points/km**: Low density warning (may not follow roads precisely)
- **Preferred**: Step polylines from Google (higher density)

### Duration Tolerance

- **Initial generation**: 70-130% of target duration
- **Google fallback**: 80-100% of target duration
- **Routes >130%**: Never shown to user (hard cap)

---

## 6. Key Functions Reference

### Initial Generation
- `generateLocalRouteWithRetry()` - Main entry point
- `generateLocalRoute()` - Core generation logic
- `getGoogleDirectionsRoute()` - Google fallback for generation

### Route Refresh
- `refreshRouteWithGoogleThenMapKit()` - Primary refresh (Google → MapKit)
- `refreshRouteWithMapKit()` - MapKit-only refresh
- `getMapKitDirectionsForRoute()` - MapKit directions helper

### Optimization
- `performLocalOptimization()` - Nearest Neighbor for Google API
- `optimizeWaypointOrder()` - Nearest Neighbor for MapKit

### Fallbacks
- `getOSRMWalkingDirections()` - OSRM fallback
- `getWalkingDirections()` - Unified directions (MapKit → OSRM)

---

## 7. Current Issues (from your logs)

1. **Google Directions API**: `REQUEST_DENIED` - Legacy API not enabled
   - **Fix**: Enable "Directions API (Legacy)" in Google Cloud Console
   - **Or**: Migrate to Routes API (newer, but different format)

2. **Google Places API**: `HTTP 403` - API not enabled
   - **Fix**: Enable "Places API (New)" in Google Cloud Console

3. **Gemini API**: `HTTP 403` - IP address restriction
   - **Fix**: Remove IP restriction or add your IP to allowlist

---

## 8. Summary Flow Diagram

```
INITIAL GENERATION:
  POI Selection (OSM + Apple + Google)
    ↓
  MapKit Route Calculation
    ↓
  [If outside tolerance]
    ↓
  Google Directions API (fallback)

ROUTE REFRESH (Let's Go):
  Google Directions API (primary)
    ↓
  [If quota/error]
    ↓
  MapKit Refresh
    ↓
  [If rate-limited/suspicious]
    ↓
  OSRM Fallback
```

---

## 9. Cost Optimization Strategies

1. **Local optimization** instead of Google's `optimize:true` → Saves $39.80/month
2. **MapKit first** for initial generation → FREE
3. **OSRM fallback** when MapKit rate-limited → FREE
4. **Coordinate precision**: `%.6f,%.6f` (6 decimals) → Optimal balance
5. **Waypoint cap**: Max 10 waypoints → Stays in Essentials SKU
6. **Daily quota**: 100 Google calls → ~$0.02/day = $0.60/month

**Total estimated cost**: ~$0.60-1.00/month (mostly Google Directions refresh calls)
