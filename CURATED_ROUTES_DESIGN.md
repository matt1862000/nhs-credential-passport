# Curated Routes Design - Elegant Solutions

## Problem Statement

You want to create **curated routes** (manually selected waypoints), but the **final route duration** depends on the user's current location (travel time to postcode center). This makes it impossible to know the exact duration when curating routes.

## Current Approach

- Routes stored under specific `durationMinutes` (e.g., 15min routes)
- Base route duration calculated (center → waypoints → center)
- Travel time to center added dynamically
- Routes filtered if total exceeds requested duration

**Limitation**: Routes must be assigned to a specific duration bucket, even though final duration is unknown.

## Proposed Solutions

### 🎯 **Solution 1: Route Templates with Dynamic Duration (RECOMMENDED)**

Store curated routes as **templates** without a fixed duration bucket. Calculate and rank them dynamically.

**Database Structure:**
```json
{
  "postcodeAreas": [{
    "postcode": "WF2 0GU",
    "curatedRoutes": [
      {
        "id": "route_001",
        "name": "Historic Village Walk",
        "description": "Explore Kirkhamgate's heritage",
        "waypointPlaceIds": ["poi_123", "poi_456", "poi_789"],
        "baseDurationSeconds": 600,  // Route duration from center
        "baseDistanceMeters": 1200,
        "polyline": "...",
        "tags": ["historic", "scenic", "heritage"],
        "intendedDurationRange": [10, 20]  // Suggested range for curation
      }
    ],
    "routes": [...]  // Keep existing generated routes
  }]
}
```

**App Logic:**
1. Load all curated routes for postcode area
2. Calculate total duration: `baseDuration + travelToCenter`
3. Rank routes by how well they match requested duration
4. Return top N routes within tolerance

**Benefits:**
- ✅ Routes aren't locked to specific duration buckets
- ✅ Can show routes for multiple duration requests
- ✅ More flexible curation
- ✅ Can rank by "best fit" rather than exact match

---

### 🎯 **Solution 2: Route Categories/Intents**

Store routes by **intent** rather than duration.

**Database Structure:**
```json
{
  "curatedRoutes": [
    {
      "category": "quick_walk",      // or "scenic", "shopping", "heritage"
      "baseDurationSeconds": 600,
      "waypoints": [...],
      "suitableForDurations": [10, 15, 20]  // Can work for these durations
    },
    {
      "category": "leisurely_stroll",
      "baseDurationSeconds": 1200,
      "waypoints": [...],
      "suitableForDurations": [20, 30, 45]
    }
  ]
}
```

**App Logic:**
- User requests 15min walk
- Show all routes where `suitableForDurations` includes 15min
- Calculate actual duration and filter/rank

**Benefits:**
- ✅ Routes organized by purpose, not duration
- ✅ More intuitive for curation
- ✅ Can suggest alternatives ("Want a longer walk? Try leisurely stroll")

---

### 🎯 **Solution 3: Duration Ranges with Fuzzy Matching**

Store routes with **min/max duration ranges** instead of exact duration.

**Database Structure:**
```json
{
  "curatedRoutes": [
    {
      "name": "Village Heritage Trail",
      "baseDurationSeconds": 900,
      "durationRange": {
        "minMinutes": 12,  // With close user location
        "maxMinutes": 25   // With far user location
      },
      "waypoints": [...]
    }
  ]
}
```

**App Logic:**
- Calculate actual duration
- Match if within `durationRange` (with tolerance)
- Rank by how close to requested duration

**Benefits:**
- ✅ Explicit about duration variability
- ✅ Can pre-filter routes that definitely won't work
- ✅ Clear curation guidelines

---

### 🎯 **Solution 4: Hybrid - Curated Routes + Generated Routes**

Keep curated routes separate from generated routes, with different matching logic.

**Database Structure:**
```json
{
  "postcodeAreas": [{
    "curatedRoutes": [
      {
        "id": "manual_001",
        "name": "Curated: Historic Walk",
        "waypoints": [...],
        "baseDurationSeconds": 600,
        "priority": "high"  // Always show if suitable
      }
    ],
    "generatedRoutes": [
      {
        "durationMinutes": 15,
        "routes": [...]  // Existing structure
      }
    ]
  }]
}
```

**App Logic:**
1. **First**: Check curated routes - calculate duration, filter, rank
2. **Then**: Check generated routes (existing logic)
3. **Combine**: Merge results, prioritize curated routes

**Benefits:**
- ✅ Best of both worlds
- ✅ Curated routes get priority
- ✅ Generated routes fill gaps
- ✅ Minimal changes to existing code

---

## 🏆 **Recommended Approach: Solution 1 (Route Templates)**

### Implementation Steps

1. **Update Database Schema:**
   - Add `curatedRoutes` array to `PostcodeAreaPOIs`
   - Each route has: `id`, `name`, `description`, `waypointPlaceIds`, `baseDurationSeconds`, `polyline`, `tags`

2. **Update Google Apps Script:**
   - Add "Curated Routes" sheet/tab
   - Columns: `Postcode`, `Route Name`, `Description`, `Waypoint 1`, `Waypoint 2`, `Waypoint 3`, `Tags`
   - Generate polyline and base duration when saving

3. **Update iOS App:**
   - Modify `PrePopulatedPOIService` to load curated routes
   - Calculate total duration dynamically
   - Rank routes by duration match score
   - Return top N routes within tolerance

4. **Route Matching Algorithm:**
   ```swift
   func scoreRoute(route: CuratedRoute, requestedDuration: Int, actualDuration: Int) -> Double {
       let difference = abs(actualDuration - requestedDuration)
       let tolerance = requestedDuration * 0.2  // 20% tolerance
       
       if difference > tolerance {
           return 0.0  // Out of range
       }
       
       // Score: 1.0 = perfect match, 0.0 = at tolerance limit
       return 1.0 - (Double(difference) / Double(tolerance))
   }
   ```

### Example Usage

**Curator creates route:**
- Selects waypoints: "Village Hall", "Oriental Chef", "Primary School"
- Saves as "Historic Village Walk"
- Base duration: 10 minutes (from center)

**User requests 15min walk:**
- App calculates: User is 3min from center
- Total duration: 10 + 3 = 13 minutes ✅
- Route shown as "13 min walk"

**User requests 10min walk:**
- App calculates: User is 8min from center  
- Total duration: 10 + 8 = 18 minutes ❌
- Route filtered out (exceeds tolerance)

**User requests 20min walk:**
- App calculates: User is 2min from center
- Total duration: 10 + 2 = 12 minutes ✅
- Route shown (within 20min tolerance)

---

## Migration Path

1. **Phase 1**: Add `curatedRoutes` alongside existing `routes` structure
2. **Phase 2**: Update app to load and display curated routes
3. **Phase 3**: Add curation UI in Google Sheets
4. **Phase 4**: (Optional) Deprecate duration-bucketed routes if curated routes work well

---

## Alternative: Simpler Approach

If you want minimal changes, just **remove the duration bucket requirement**:

- Store curated routes under a special key: `"curated": true`
- When loading routes, check curated routes for ALL duration requests
- Calculate actual duration and filter dynamically
- Keep existing generated routes in duration buckets

This requires minimal schema changes but gives you the flexibility you need.
