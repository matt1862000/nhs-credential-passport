# POI and Cache System Summary

## Overview
Your app uses a multi-tier caching and fallback system for Points of Interest (POIs) and routes to minimize API costs while ensuring reliable data availability.

---

## POI (Point of Interest) System

### 1. POI Cache Service (`POICacheService.swift`)

**Purpose**: Caches POIs by location to reduce Google Places API calls

**Key Features**:
- **No expiry**: POIs are landmarks, they don't move
- **Multiple locations**: Supports up to 10 cached locations
- **Match radius**: 1km radius for cache matching
- **Storage**: UserDefaults (JSON encoded)

**Cache Structure**:
```swift
CachedPOILocation {
    latitude, longitude
    pois: [CachedPOI]
    fetchedAt: Date
}

CachedPOI {
    placeId, name, latitude, longitude
    types: [String]
    vicinity: String?
}
```

**Cache Operations**:
- `getCachedPOIs(near:)` - Returns cached POIs if within 1km
- `cachePOIs(_:for:)` - Saves POIs for a location
- `clearCache()` - Clears all cached POIs
- Auto-deduplication on load (keeps entry with most POIs)

---

### 2. POI Fetch Flow (`GoogleMapsService.findNearbyPlaces()`)

**Priority Order**:

#### 🎯 **PRIORITY 1: Cache Check**
```
1. Check POICacheService for cached POIs within 1km
   ✅ CACHE HIT → Use cached POIs (FREE, instant)
   ❌ CACHE MISS → Continue to API fetch
```

**Cache Hit Processing**:
- Filter POIs > 2x radius away (cleanup old caches)
- Filter restricted POIs (playcare/nursery/playground)
- Return filtered results immediately

#### 🚀 **PRIORITY 2: Parallel API Fetch** (Cache Miss Only)
When cache miss, fetch from **ALL sources simultaneously**:

1. **Google Places API** (Paid, ~$0.02 per location)
   - Highest quality, verified data
   - May have quota limits
   - Can be skipped if no API key

2. **Apple Maps** (FREE, no limits)
   - Uses `MKLocalSearch` with natural language queries
   - Fast mode: ~40 queries (reduced from 120+)
   - Always called to supplement

3. **OpenStreetMap (OSM)** (FREE, no limits)
   - Uses Overpass API
   - Community-maintained data
   - Always called to supplement

**Parallel Fetch Strategy**:
```swift
async let osmTask = searchOpenStreetMapForPOIs(...)
async let appleTask = searchAppleMapsForPOIsFast(...)
async let googleTask = fetchGooglePOIs(...)

// Await all results simultaneously
let (osmPOIs, applePOIs, googlePOIs) = await (osmTask, appleTask, googleTask)
```

**Result Merging** (Priority: Google > Apple > OSM):
1. Add Google POIs first (highest quality)
2. Add Apple POIs (deduplicate by name + 50m OR <20m distance)
3. Add OSM POIs (deduplicate by name + 50m OR <20m distance)

**Deduplication Rules**:
- Same name AND within 50m → duplicate
- Very close (<20m) regardless of name → duplicate
- Otherwise → keep as distinct POI

#### 🚫 **PRIORITY 3: Filtering**

**Distance Filter**:
- Remove POIs > 2x search radius away
- Prevents unrealistic distant POIs from APIs

**Restricted Area Filter**:
- Filter POIs in restricted areas (schools, hospitals) without road access
- Uses `filterPOIsInRestrictedAreas()` async function

**Restricted POI Filter**:
- Remove playcare, nursery, playground POIs
- Safety net for cached POIs that were cached before filters existed

#### 💾 **PRIORITY 4: Cache Results**
After fetching and filtering:
```swift
POICacheService.shared.cachePOIs(allResults, for: location)
```
- Saves combined results for future use
- Removes duplicates within 1km
- Limits to 10 locations (removes oldest if full)

---

### 3. Fallback Mechanisms

#### **Google API Failure Fallback**:
- If Google API fails/quota exceeded → Continue with Apple + OSM
- App still works, just with fewer POIs

#### **Apple Maps Fallback**:
- Always available (FREE, no limits)
- Uses `MKLocalSearch` with natural language queries
- Fast mode: ~40 queries (reduced from 120+ for speed)

#### **OSM Fallback**:
- Always available (FREE, no limits)
- Uses Overpass API
- Community-maintained data

#### **Cache Fallback**:
- Even if all APIs fail, cached POIs are still available
- Cache persists across app restarts
- No expiry (POIs don't move)

---

## Route Cache System

### Route Cache Service (`RouteCacheService.swift`)

**Purpose**: Caches generated routes by location + duration for instant display

**Key Features**:
- **Expiry**: 24 hours (routes become stale)
- **Match radius**: 10m (very tight, route start/end must match)
- **Duration rounding**: Rounds to nearest 5 minutes (e.g., 42min → 40min)
- **Storage**: UserDefaults (JSON encoded)
- **Max entries**: 50 route sets
- **Max routes per duration**: 10 routes

**Cache Structure**:
```swift
CachedRouteSet {
    latitude, longitude
    durationMinutes: Int (rounded to 5min)
    routes: [CachedRoute]
    createdAt: Date
    isExpired: Bool (24 hours)
}

CachedRoute {
    places: [CachedPlace]
    polyline: String
    distanceMeters, durationSeconds
    name, description: String?
    directions: [CachedDirection]?  // Cached for instant load
    skipCount: Int  // Track user skips
    createdAt: Date
}
```

**Cache Operations**:
- `getCachedRoutes(near:durationMinutes:)` - Returns cached routes
- `cacheRoutes(_:at:durationMinutes:)` - Saves routes
- `mergeRoutes(...)` - Smart quality-based merge
- `incrementSkipCount(...)` - Track user skips

**Cache Matching**:
1. Round duration to nearest 5 minutes
2. Check exact duration first
3. Check adjacent durations (±5, ±10, ±15 min) if exact not found
4. Validate routes are within tolerance (80-120%, or 75-125% for edge cases)
5. **Dead Zone Escape**: If no valid routes (≥75%), return best 70-74% route

**Quality Scoring**:
Routes are scored based on:
- Duration accuracy (0-40 points)
- POI variety (0-30 points)
- POI count (0-15 points)
- Skip penalty (-10 per skip)
- Freshness bonus (+5 if <1 hour old)

**Smart Merging**:
- If new route has >50% overlap with existing → Replace only if better quality
- If new route is unique (<50% overlap) → Add if under limit, or replace worst if better

**Filtering**:
- Filters routes containing restricted POIs (playcare, nursery, etc.)
- Catches routes cached before filter was implemented

---

## Fallback Hierarchy Summary

### POI Fetch Fallback Chain:
```
1. Cache (within 1km) → ✅ Instant, FREE
   ↓ (if miss)
2. Parallel Fetch:
   - Google Places API (paid, best quality)
   - Apple Maps (FREE, always available)
   - OpenStreetMap (FREE, always available)
   ↓
3. Merge & Deduplicate (Google > Apple > OSM priority)
   ↓
4. Filter (distance, restricted areas, restricted POIs)
   ↓
5. Cache results for next time
```

### Route Fetch Fallback Chain:
```
1. Route Cache (within 10m, same duration ±5min) → ✅ Instant
   ↓ (if miss)
2. Generate new routes from POIs
   ↓
3. Cache routes for 24 hours
```

### API Failure Handling:
- **Google API fails** → Continue with Apple + OSM (still works)
- **All APIs fail** → Use cached POIs (if available)
- **No cache, all APIs fail** → Return empty array (graceful degradation)

---

## Cost Optimization

### POI Caching:
- **First fetch**: ~$0.02 per location (Google API call)
- **Cached locations**: FREE (no API calls)
- **Cache hit rate**: High (1km radius, no expiry)

### Route Caching:
- **First generation**: Uses cached POIs (no additional cost)
- **Cached routes**: FREE (instant display)
- **Cache hit rate**: High (10m radius, 5min duration rounding)

### Parallel Fetching:
- Only happens on cache miss
- All sources fetched simultaneously (faster)
- Cost: ~$0.02 per NEW location only

---

## Key Design Decisions

1. **No POI expiry**: POIs are landmarks, they don't move
2. **1km cache radius**: Balances cache hit rate vs. accuracy
3. **10m route cache radius**: Very tight, ensures route matches user position
4. **5min duration rounding**: Reduces cache fragmentation
5. **Parallel fetching**: Faster than sequential, same cost
6. **Quality-based merging**: Keeps best routes, replaces worst
7. **Skip tracking**: Learns user preferences over time
8. **Dead zone escape**: Always returns something, even if not perfect

---

## Cache Management

### POI Cache:
- Max 10 locations
- Auto-deduplication on load
- Manual clear via `clearCache()`
- Per-location deletion supported

### Route Cache:
- Max 50 route sets
- Max 10 routes per location/duration
- 24-hour expiry (auto-cleanup)
- Quality-based replacement when full

---

## Testing Mode

`findNearbyPlacesWithoutCaching()`:
- Bypasses cache write (for testing)
- Still checks cache read (uses if available)
- Fetches from all sources
- Does NOT save results (avoids quota limits)
