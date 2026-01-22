# POI Threshold Analysis

## Current Threshold: **6 POIs**

The app currently uses Google API fallback when free sources return **< 6 POIs**.

## Route Generation Requirements

### Waypoints Needed by Duration:
- **10 min route**: 1 waypoint (`max(2, (10/5)-1) = 1`)
- **20 min route**: 3 waypoints (`max(2, (20/5)-1) = 3`)
- **30 min route**: 5 waypoints (`max(2, (30/5)-1) = 5`)
- **60 min route**: 11 waypoints (`max(2, (60/5)-1) = 11`)

### POI Requirements in Code:

1. **Minimum for route generation**: `desiredSpots * 2`
   - 10 min: 1 waypoint → needs **2 POIs** minimum
   - 20 min: 3 waypoints → needs **6 POIs** minimum
   - 30 min: 5 waypoints → needs **10 POIs** minimum

2. **Short routes (≤15 min)**: Wants at least **10 POIs**
   - Code: `(targetDurationMinutes <= 15 && places.count < 10)`

3. **Stops fetching more**: When `places.count >= desiredSpots * 3`
   - 10 min: stops at **3 POIs**
   - 20 min: stops at **9 POIs**
   - 30 min: stops at **15 POIs**

4. **Limited POI warning**: Shows when **< 50 POIs**
   - Indicates reduced route variety

5. **Multi-waypoint mode (30+ min)**: Requires **≥100 POIs**
   - Code: `if targetDurationMinutes >= 30 && (prefetchedPOIs?.count ?? 0) >= 100`

## Analysis

### Current Threshold (6 POIs):
- ✅ **Sufficient for**: 20 min routes (needs 6)
- ⚠️ **Marginal for**: 30 min routes (needs 10, but only has 6)
- ❌ **Insufficient for**: Short routes (wants 10), 30+ min multi-waypoint (wants 100)

### Optimal Thresholds:

**Option 1: Conservative (10 POIs)**
- ✅ Covers short routes (10 min needs 10)
- ✅ Covers 20 min routes (needs 6, has 10)
- ⚠️ Still marginal for 30 min routes (needs 10, has 10 - no buffer)
- **Best for**: Cost savings, acceptable route quality

**Option 2: Balanced (15 POIs)** ⭐ **RECOMMENDED**
- ✅ Covers all standard routes (10-30 min)
- ✅ Provides buffer for filtering/restricted POIs
- ✅ Allows route variety
- ⚠️ Still below multi-waypoint threshold (100)
- **Best for**: Good route quality with reasonable costs

**Option 3: Aggressive (25 POIs)**
- ✅ Excellent coverage for all routes
- ✅ Good buffer for filtering
- ✅ Better route variety
- ❌ More Google API calls (higher cost)
- **Best for**: Maximum route quality

**Option 4: Duration-Based (Dynamic)**
- 10 min routes: **10 POIs**
- 20 min routes: **15 POIs**
- 30+ min routes: **25 POIs**
- **Best for**: Optimal balance per route type

## Recommendation

**Change threshold from 6 to 15 POIs**

### Why 15?
1. **Covers all standard routes**: 10-30 min routes need 2-10 POIs, 15 provides buffer
2. **Handles filtering**: Restricted POIs, distance filters reduce available POIs
3. **Enables variety**: More POIs = more route combinations
4. **Cost-effective**: Still saves Google calls when free sources are sufficient
5. **Matches code logic**: Code wants `desiredSpots * 2` to `desiredSpots * 3`, 15 fits well

### Impact:
- **More Google calls** in sparse areas (< 15 POIs from free sources)
- **Better route quality** - more options for route generation
- **Fewer "no route found" errors** - sufficient POI pool
- **Better route variety** - can generate multiple unique routes

## Current Code Location

```swift
// Line 6630 in GoogleMapsService.swift
if places.count < 6 {
    // Fallback to Google
}
```

## Suggested Change

```swift
// Optimal threshold: 15 POIs
if places.count < 15 {
    // Fallback to Google
}
```

Or use duration-based:
```swift
let minPOIsNeeded = targetDurationMinutes <= 15 ? 10 : 
                    targetDurationMinutes <= 30 ? 15 : 25
if places.count < minPOIsNeeded {
    // Fallback to Google
}
```
