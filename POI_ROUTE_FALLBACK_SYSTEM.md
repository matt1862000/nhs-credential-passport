# POI, Map, and Route Generation Fallback System

## Overview
Your app uses a sophisticated multi-tier fallback system to ensure reliable POI fetching and route generation, minimizing API costs while maintaining functionality even when services fail.

---

## 1. POI (Point of Interest) Fetching System

### Fallback Chain

```
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 1: Cache Check (FREE, Instant)                │
│ ✅ Check POICacheService for cached POIs within 1km     │
│    → CACHE HIT: Return immediately (no API calls)      │
│    → CACHE MISS: Continue to API fetch                 │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 2: Parallel API Fetch (Cache Miss Only)       │
│                                                          │
│ Fetch from ALL sources SIMULTANEOUSLY:                  │
│                                                          │
│ 1. Google Places API (Paid, ~$0.02/location)           │
│    - Highest quality, verified data                     │
│    - May have quota limits                              │
│    - Can be skipped if no API key                       │
│                                                          │
│ 2. Apple Maps (FREE, no limits)                         │
│    - Uses MKLocalSearch with natural language queries   │
│    - Fast mode: ~40 queries (reduced from 120+)         │
│    - Always called to supplement                        │
│                                                          │
│ 3. OpenStreetMap (OSM) (FREE, no limits)               │
│    - Uses Overpass API                                  │
│    - Community-maintained data                          │
│    - Always called to supplement                        │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 3: Merge & Deduplicate                         │
│                                                          │
│ Priority: Google > Apple > OSM                          │
│                                                          │
│ Deduplication Rules:                                    │
│ - Same name AND within 50m → duplicate                 │
│ - Very close (<20m) regardless of name → duplicate     │
│ - Otherwise → keep as distinct POI                      │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 4: Filtering                                   │
│                                                          │
│ 1. Distance Filter:                                     │
│    - Remove POIs > 2x search radius away               │
│                                                          │
│ 2. Restricted Area Filter:                             │
│    - Filter POIs in restricted areas (schools,          │
│      hospitals) without road access                     │
│                                                          │
│ 3. Restricted POI Filter:                              │
│    - Remove playcare, nursery, playground POIs         │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 5: Cache Results                               │
│                                                          │
│ Save combined results for future use:                   │
│ - Removes duplicates within 1km                         │
│ - Limits to 10 locations (removes oldest if full)       │
│ - No expiry (POIs are landmarks, they don't move)       │
└─────────────────────────────────────────────────────────┘
```

### POI Cache Service

**Storage**: UserDefaults (JSON encoded)
**Match Radius**: 1km
**Max Locations**: 10
**Expiry**: None (POIs don't move)

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

### API Failure Fallbacks

1. **Google API Fails**:
   - Continue with Apple Maps + OSM
   - App still works, just with fewer POIs
   - No user-facing error

2. **All APIs Fail**:
   - Use cached POIs (if available)
   - Cache persists across app restarts
   - Graceful degradation

3. **No Cache, All APIs Fail**:
   - Return empty array
   - User can retry later
   - No crash or error

---

## 2. Route Generation System

### Fallback Chain

```
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 1: Route Cache Check (FREE, Instant)           │
│                                                          │
│ Check RouteCacheService:                                │
│ - Match within 10m of location                          │
│ - Same duration (rounded to nearest 5min)              │
│ - Routes within 80-120% tolerance (75-125% for edges)   │
│                                                          │
│ ✅ CACHE HIT: Return immediately                        │
│ ❌ CACHE MISS: Continue to generation                  │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 2: MapKit Route Generation (FREE)              │
│                                                          │
│ Strategy 1: Endpoint-First Approach                   │
│ - Find POI at half target distance                     │
│ - Route there and back                                 │
│ - Simpler, more predictable                            │
│                                                          │
│ Strategy 2: Loop Approach (if endpoint fails)          │
│ - Create loops with multiple waypoints                  │
│ - Maximize POIs while staying within time limit         │
│ - Angular diversity scoring for feasibility             │
│                                                          │
│ Strategy 3: Multi-Waypoint (for 30+ min routes)        │
│ - Only for longer routes where it helps                 │
│ - Shorter routes use simpler approaches                 │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 3: Google Directions Fallback (Paid)           │
│                                                          │
│ ONLY if NO valid routes (80-100% of target) found      │
│ via MapKit. This is the ONLY place Google Directions    │
│ should be called.                                        │
│                                                          │
│ Fallback Conditions:                                    │
│ - MapKit route < 80% of target duration                 │
│ - OR MapKit route > 100% of target duration             │
│ - AND no valid fallback routes available                │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ PRIORITY 4: Guaranteed Fallback Route                   │
│                                                          │
│ If ALL strategies fail, create simple route:            │
│ - Out-and-back to closest POI                           │
│ - At roughly half target walking distance               │
│ - Ensures we ALWAYS return something                    │
│ - Hard cap: Never return routes > 130% of target        │
└─────────────────────────────────────────────────────────┘
```

### Route Cache Service

**Storage**: UserDefaults (JSON encoded)
**Match Radius**: 10m (very tight - route start/end must match)
**Duration Rounding**: Nearest 5 minutes (e.g., 42min → 40min)
**Expiry**: 24 hours (routes become stale)
**Max Entries**: 50 route sets
**Max Routes per Duration**: 10 routes

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

### Route Cache Matching

1. **Exact Match**:
   - Check exact duration (rounded to 5min)
   - Within 10m of location
   - Routes within 80-120% tolerance

2. **Adjacent Duration Fallback**:
   - If exact not found, check ±5, ±10, ±15 min
   - Still validates tolerance
   - Logs fallback usage

3. **Dead Zone Escape**:
   - If no routes ≥75% of target
   - Return best 70-74% route
   - Ensures something is always returned

### Quality Scoring

Routes are scored based on:
- **Duration accuracy** (0-40 points): Closer to target = better
- **POI variety** (0-30 points): More diverse types = better
- **POI count** (0-15 points): More waypoints = more interesting (up to 5)
- **Skip penalty** (-10 per skip): Users didn't like this route
- **Freshness bonus** (+5 if <1 hour old): Newer routes preferred

### Smart Merging

When adding new routes to cache:
- **>50% overlap**: Replace only if new route has better quality
- **<50% overlap**: Add if under limit, or replace worst if better
- **Quality-based**: Keeps best routes, replaces worst

---

## 3. Map Rendering System

### Map Data Sources

The map itself uses:
1. **Apple Maps** (Primary):
   - Built into iOS
   - Always available
   - No API calls needed

2. **Google Maps** (Route Data):
   - Used for route polylines only
   - Fallback to MapKit if unavailable

3. **Cached Route Preview**:
   - Shows cached routes when no active route
   - Passive display (doesn't block interaction)
   - Uses cached polyline data

### Map Fallbacks

1. **Route Polyline**:
   - Primary: Google route path (if available)
   - Fallback: MapKit MKRoute polyline
   - Fallback: Direct line between waypoints

2. **POI Display**:
   - Active route: Show waypoints from route
   - Preview mode: Show cached POIs
   - Always available (from cache or API)

---

## 4. Complete Fallback Hierarchy

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

### Route Generation Fallback Chain:
```
1. Route Cache (within 10m, same duration ±5min) → ✅ Instant
   ↓ (if miss)
2. MapKit Route Generation:
   - Endpoint-first approach
   - Loop approach
   - Multi-waypoint (30+ min only)
   ↓ (if no valid routes)
3. Google Directions API (paid, only if MapKit fails)
   ↓ (if all fail)
4. Guaranteed Fallback Route (simple out-and-back)
   ↓
5. Cache routes for 24 hours
```

### API Failure Handling:
- **Google API fails** → Continue with Apple + OSM (still works)
- **All APIs fail** → Use cached POIs (if available)
- **No cache, all APIs fail** → Return empty array (graceful degradation)
- **Route generation fails** → Guaranteed fallback route (always returns something)

---

## 5. Cost Optimization

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

## 6. Key Design Decisions

1. **No POI expiry**: POIs are landmarks, they don't move
2. **1km cache radius**: Balances cache hit rate vs. accuracy
3. **10m route cache radius**: Very tight, ensures route matches user position
4. **5min duration rounding**: Reduces cache fragmentation
5. **Parallel fetching**: Faster than sequential, same cost
6. **Quality-based merging**: Keeps best routes, replaces worst
7. **Skip tracking**: Learns user preferences over time
8. **Dead zone escape**: Always returns something, even if not perfect
9. **Guaranteed fallback**: Never leaves user waiting with no route

---

## 7. Error Handling

### POI Fetch Errors:
- Google API quota exceeded → Continue with Apple + OSM
- Network failure → Use cached POIs
- All sources fail → Return empty array (graceful)

### Route Generation Errors:
- MapKit fails → Try Google Directions
- Google Directions fails → Create guaranteed fallback
- All fail → Return error (should never happen due to guaranteed fallback)

### Cache Errors:
- Cache corruption → Clear and rebuild
- Storage full → Remove oldest entries
- Decode failure → Return nil, regenerate

---

## Summary

Your app has **robust fallback mechanisms** at every level:

1. **POI Fetching**: Cache → Parallel APIs → Filter → Cache
2. **Route Generation**: Cache → MapKit → Google → Guaranteed Fallback
3. **Map Rendering**: Apple Maps (always available) + Cached data

The system is designed to:
- ✅ Minimize API costs (aggressive caching)
- ✅ Always return something (guaranteed fallbacks)
- ✅ Gracefully degrade (no crashes on API failures)
- ✅ Learn from usage (skip tracking, quality scoring)
