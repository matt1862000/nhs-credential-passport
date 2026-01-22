# POI Deduplication Algorithm

## Overview
The app uses **THREE** deduplication systems:
1. **Early Deduplication** (`deduplicatePOIs`) - Quick pass to remove obvious duplicates from POI lists
2. **Canonical Deduplication** (`canonicalizePOIs`) - Sophisticated clustering with type awareness
3. **Route Deduplication** (`deduplicateRoutePlaces`) - Prevents duplicate POIs within the same route

---

## 1. Early Deduplication (`deduplicatePOIs`)

**Purpose:** Quick pass to remove obvious duplicates before canonical processing

**Source Priority Order:**
1. Google (priority 1)
2. Geograph high-quality (score ≥6.0, priority 2)
3. Apple (priority 3)
4. Geograph low-quality (score <6.0, priority 4)
5. OSM (priority 5)
6. Unknown (priority 6)

**Rules (in order of evaluation):**

### Rule 1: Exact Name Match
- **Condition:** Normalized names match exactly AND distance < 50m
- **Action:** Merge (keep higher priority source)
- **Example:** "The Star Inn" (OSM) vs "The Star Inn" (Google) → Keep Google

### Rule 2: Name Similarity
- **Condition:** Name similarity ≥0.7 AND distance < 50m
- **Action:** Merge
- **Example:** "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate" → Merge

### Rule 3: Very Close (FIXED)
- **Condition:** Distance < 20m AND (types compatible OR name similarity >0.9)
- **Action:** Merge only if types compatible or very high name similarity
- **⚠️ FIXED:** Previously merged ANY POIs within 20m regardless of type
- **Example (FIXED):** "Oriental Chef" (restaurant) vs "Lindale Methodist Church" (church) → **NO LONGER MERGES** (incompatible types)

### Rule 4: Same Category + Close + Similar Name
- **Condition:** Same category AND distance < 30m AND name similarity ≥0.6
- **Action:** Merge
- **Example:** Two restaurants with similar names nearby

---

## 2. Canonical Deduplication (`canonicalizePOIs`)

**Purpose:** Sophisticated clustering to create canonical POI representatives

**Process:**
1. Sort by source priority (same as early deduplication)
2. For each POI, find all POIs in its cluster
3. Choose best representative from cluster
4. Log all merged aliases

**Rules (evaluated in order, stops at first match):**

### RULE 1: Hard Spatial Merge
- **Distance:** ≤30m
- **Requirement:** Compatible types (ignores name mismatch)
- **Action:** Merge
- **Example:** Two POIs at same location, different names but compatible types

### RULE 2: Same Geograph Grid Reference
- **Distance:** ≤200m (standard) OR ≤400m with name similarity ≥0.85
- **Requirement:** Compatible types
- **Action:** Merge
- **Example:** "SE2922: The Star Inn" vs "SE2922: Lindale Methodist Church" → Merge if compatible

### RULE 2b: One-Sided Grid Reference
- **Distance:** ≤300m with name similarity ≥0.85 OR ≤500m with name similarity >0.9
- **Requirement:** Compatible types
- **Action:** Merge
- **Example:** "The Star Inn" (no grid ref) vs "SE2922: The Star Inn, Kirkhamgate" (has grid ref)

### RULE 3: Same OSM ID
- **Distance:** ≤200m (standard) OR ≤400m with name similarity ≥0.85
- **Requirement:** Compatible types
- **Action:** Merge
- **Example:** Same OSM node/way ID from different sources

### RULE 4: Medium Merge
- **Distance:** 30-60m
- **Requirement:** Name similarity ≥0.85 AND compatible types
- **Action:** Merge

### RULE 5: Wide Merge
- **Distance:** 60-80m
- **Requirement:** Name similarity ≥0.85 AND compatible types
- **Action:** Merge

### RULE 6: Very High Similarity
- **Distance:** 80-200m
- **Requirement:** Name similarity >0.9 AND compatible types
- **Action:** Merge

---

## Type Compatibility (`arePOITypesCompatible`)

**Returns `true` if POIs can be merged, `false` if incompatible**

### Compatibility Rules:

1. **Same Category:** If categories match (and not "Unknown") → Compatible
2. **Shared Types:** If both have types arrays and they overlap → Compatible
3. **Incompatible Pairs:** Explicitly blocked combinations:
   - Religious Building ↔ Restaurant/Cafe/Store
   - Pub/Inn ↔ Postbox/Post Office
   - Store ↔ Postbox
   - Religious Building ↔ Postbox
   - Community Building ↔ Postbox
   - Historic Building ↔ Postbox
   - Memorial/Monument ↔ Postbox
   - Pub/Inn ↔ Industrial Heritage
   - Store ↔ Industrial Heritage
   - Religious Building ↔ Industrial Heritage

4. **Postbox Detection:** Special handling for postboxes vs other types
   - Postbox vs Pub/Inn/Church/Chapel/Shop/Store/Hall/Memorial/Monument → Incompatible

5. **Default:** If none of above apply → **Compatible** (conservative approach)

---

## Name Similarity Calculation (`calculateNameSimilarity`)

**Returns:** 0.0 to 1.0 (1.0 = identical, 0.0 = no similarity)

**Algorithm:**
1. **Exact Match:** If names are identical (case-insensitive) → 1.0
2. **Substring Match:** If one contains the other → 0.9
3. **Jaccard Similarity:**
   - Remove common location words: "on", "at", "near", "the", "a", "an", "road", "street", "lane", "way", "avenue", "close", "drive", "kirkhamgate", "batley", "brandy", "carr"
   - Split into word sets
   - Calculate: `intersection / union`
4. **Boost:** If ≥2 core words match → add 0.05-0.15 boost
5. **Return:** Min of 1.0 and (jaccard + boost)

**Example:**
- "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate"
  - After normalization: "star inn" vs "star inn"
  - Similarity: ~0.9-1.0 (high)

---

## Name Normalization

**Functions:**
- `extractBaseFeatureName()` - Removes grid references, location suffixes
- `normalizePOIName()` - Normalizes for comparison (lowercase, removes punctuation)

**Example:**
- "SE2922: The Star Inn, Kirkhamgate" → "the star inn"
- "The Star Inn" → "the star inn"

---

## Current Issues & Fixes

### ✅ FIXED: Rule 3 in Early Deduplication
**Problem:** Merged ANY POIs within 20m regardless of type
**Fix:** Now requires type compatibility OR very high name similarity (>0.9)
**Impact:** Prevents "Oriental Chef" (restaurant) from merging with "Lindale Methodist Church" (church)

### ⚠️ POTENTIAL ISSUES:
Many suspicious merges in logs suggest other rules may be too aggressive:
- Rule 1 (exact name + <50m) - May merge different businesses with same name
- Rule 2 (similarity ≥0.7 + <50m) - May be too lenient
- Rule 4 (same category + <30m + similarity ≥0.6) - May merge different businesses

---

---

## 3. Route Deduplication (`deduplicateRoutePlaces`) - UNIFIED SYSTEM

**Purpose:** Prevents the same POI from appearing multiple times in a single route

**Problem:** The same POI (e.g., "Star Inn", "War Memorial") can appear multiple times in a route if:
- It comes from different sources (OSM, Apple Maps, Google) with different placeIds
- Route enhancement adds waypoints without checking for duplicates
- Discovery spots are added without duplicate checks
- Route extension adds POIs that are already in the route
- Cross-route exclusion misses duplicates due to threshold/case-sensitivity mismatches
- Inconsistent duplicate checks across different code paths

**Solution:** **UNIFIED DUPLICATE DETECTION SYSTEM** - Single source of truth for all duplicate checks

### Unified Duplicate Comparator (`isRouteDuplicate`)

**ONE FUNCTION USED EVERYWHERE** - Replaces all ad-hoc duplicate checks

A POI is considered a duplicate if ANY of these match:
1. **Same placeId** - Exact match
2. **Same location** - Within 20m of an existing waypoint (definitely the same place)
3. **Same name + close** - Same cleaned name (case-insensitive) AND within **100m**

**Implementation:**
```swift
private func isRouteDuplicate(_ a: PlaceResult, _ b: PlaceResult) -> Bool {
    // 1. Exact placeId match
    if !a.placeId.isEmpty && !b.placeId.isEmpty && a.placeId == b.placeId {
        return true
    }
    
    // 2. Same location (within 20m) - definitive same spot
    let distance = distanceBetween(a.coordinate, b.coordinate)
    if distance < 20.0 {
        return true
    }
    
    // 3. Same cleaned name and close (within 100m) - likely same place
    let nameA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
    let nameB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
    if nameA == nameB && distance < 100.0 {
        return true
    }
    
    return false
}
```

### Fingerprint Safety Net

**Additional layer to catch near-identical cases that slip through pairwise checks**

- Combines cleaned name, rounded coordinates (~150m bins), and category
- Applied as second pass after pairwise deduplication
- Catches edge cases where POIs are slightly outside thresholds

### Final Safety Wrapper (`finalizeRouteDedup`)

**Called at EVERY return site** - Ensures deduplication runs even if polyline regeneration fails

- Wraps all route return statements
- Guarantees deduplicated places are returned even if route regeneration fails
- Applied to: main route selection, endpoint-first routes, fallback routes, guaranteed fallback routes, discovery merge returns, route extension returns

**Key Changes (v1.9.24+):**
- ✅ **Unified comparator:** Single `isRouteDuplicate()` function replaces all ad-hoc checks
- ✅ **Threshold consistency:** All duplicate checks use 100m (was inconsistent: 50m in some places)
- ✅ **Case-insensitive:** All name comparisons use `.lowercased()` to catch "War Memorial" vs "War memorial"
- ✅ **Fingerprint safety net:** Additional layer catches near-identical cases
- ✅ **Final safety wrapper:** All returns wrapped with `finalizeRouteDedup()` to guarantee deduplication
- ✅ **Error handling:** If route regeneration fails after deduplication, still uses deduplicated places

### Where Unified Duplicate Detection is Applied

**ALL locations now use `isRouteDuplicate()` instead of ad-hoc checks:**

1. **Initial Waypoint Selection** (`selectAngularlyDiverseWaypoints`)
   - ✅ Uses `isRouteDuplicate()` to check duplicates before adding to selected list
   - ✅ Uses `isRouteDuplicate()` in fallback loop when filling remaining spots

2. **Endpoint-First Route Generation**
   - ✅ Uses `isRouteDuplicate()` to filter endpoint candidates against excluded POIs
   - ✅ Uses `isRouteDuplicate()` to filter POIs near route for enhancement
   - ✅ Uses `isRouteDuplicate()` to filter shorter endpoint candidates

3. **Route Enhancement** (`enhanceRouteWithWaypoints`)
   - ✅ Uses `isRouteDuplicate()` to filter available POIs before enhancement
   - ✅ Uses `isRouteDuplicate()` when checking if candidate is already in route
   - ✅ Uses `isRouteDuplicate()` in final deduplication pass
   - ✅ Wrapped with `finalizeRouteDedup()` on all return paths

4. **Discovery Spots** (`addDiscoverySpotsAlongRoute`)
   - ✅ Uses `isRouteDuplicate()` to check against route POIs
   - ✅ Uses `isRouteDuplicate()` to check against already-added spots
   - ✅ Uses `isRouteDuplicate()` in final deduplication when merging waypoints
   - ✅ Wrapped with `finalizeRouteDedup()` on all return paths

5. **Route Extension** (`tryExtendRoute`)
   - ✅ Uses `isRouteDuplicate()` before adding POIs to extend route
   - ✅ Wrapped with `finalizeRouteDedup()` on return path

6. **Cross-Route Exclusion** (when generating multiple routes)
   - ✅ Uses `isRouteDuplicate()` to exclude POIs from previous routes
   - ✅ Applied to both `places` filtering and `endpointCandidates` filtering

7. **Final Safety Check** (before returning any route)
   - ✅ `finalizeRouteDedup()` called at EVERY return site:
     - Main route selection
     - Endpoint-first routes (bestEnhanceable, firstValid)
     - Fallback routes
     - Guaranteed fallback routes
     - Extended routes
     - Discovery spot merged routes
     - Out-and-back routes
     - Last resort routes
   - ✅ Regenerates route polyline if duplicates removed
   - ✅ If regeneration fails, still uses deduplicated places (prevents returning original route with duplicates)

### Enhanced Logging

The deduplication function now provides detailed logging:
- `🔍 DEDUPLICATION: Checking X POIs for duplicates...` - Start of deduplication
- `✅ Route dedup [N/X]: Kept 'POI Name'` - POI kept (not a duplicate)
- `🚫 Route dedup [N/X]: Removed 'POI Name' (reason)` - Duplicate removed
- `⚠️ Potential duplicate not removed: 'POI1' vs 'POI2' - XXXm apart (threshold: 100m)` - Warning for duplicates >100m apart
- `🚫 Route deduplication: Removed X duplicate POI(s) from route` - Summary

### Example

**Before Fix:**
```
Route: Start → POI1 → POI2 → War Memorial → POI4 → War memorial → End
```
(Note: Case difference and/or >50m distance allowed duplicate to slip through)

**After Fix:**
```
Route: Start → POI1 → POI2 → War Memorial → POI4 → End
```
The second "War memorial" is detected as duplicate (same cleaned name, case-insensitive, within 100m) and removed.

### Unified System Implementation (v1.9.24+)

1. **✅ Unified Comparator (`isRouteDuplicate`):** Single function replaces all ad-hoc duplicate checks
   - Used in: waypoint selection, endpoint filtering, route enhancement, discovery spots, route extension, cross-route exclusion
   - Consistent logic: same placeId OR same location (<20m) OR same cleaned name + close (<100m)

2. **✅ Fingerprint Safety Net:** Additional layer catches near-identical cases
   - Combines cleaned name, rounded coordinates (~150m bins), and category
   - Applied as second pass after pairwise deduplication

3. **✅ Final Safety Wrapper (`finalizeRouteDedup`):** Called at EVERY return site
   - Wraps all route return statements
   - Guarantees deduplicated places are returned even if route regeneration fails
   - Applied to: main route selection, endpoint-first routes, fallback routes, guaranteed fallback routes, discovery merge returns, route extension returns, out-and-back routes, last resort routes

4. **✅ Chain Safeguard in Early Deduplication:**
   - Added `isChainPOI()` to detect chain names (Tesco, Co-op, Costa, Greggs, Starbucks, etc.)
   - Added `hasMatchingAddress()` to check plus-code/address matches
   - Modified `deduplicatePOIs()` to require ≤15m or address match for chain POIs
   - Prevents wrong early merges of chain locations that later conflict at route time

5. **✅ Diagnostic Logging:**
   - `debugNearbyNameDupes()`: Warns about nearby name duplicates that weren't caught
   - Enhanced logging shows why duplicates were removed (placeId, location, or name match)

---

## Recent Fixes & Improvements

### ✅ FIXED: Route Deduplication Threshold Inconsistencies (v1.9.24+)
**Problem:** Different parts of the code used different thresholds (50m vs 100m) and some were case-sensitive while others were case-insensitive, allowing duplicates to slip through.

**Fixes Applied:**
- ✅ All route-level duplicate checks now use **100m threshold** (consistent)
- ✅ All name comparisons are **case-insensitive** (consistent)
- ✅ Cross-route exclusion: 50m → 100m, case-sensitive → case-insensitive
- ✅ Discovery spots: 50m → 100m, case-sensitive → case-insensitive
- ✅ Route extension: 50m → 100m
- ✅ Error handling: Uses deduplicated places even if route regeneration fails

**Impact:** Prevents "War Memorial" appearing twice in same route, prevents "The Star Inn" appearing in multiple routes, etc.

### ✅ FIXED: Rule 3 in Early Deduplication
**Problem:** Merged ANY POIs within 20m regardless of type
**Fix:** Now requires type compatibility OR very high name similarity (>0.9)
**Impact:** Prevents "Oriental Chef" (restaurant) from merging with "Lindale Methodist Church" (church)

### ⚠️ POTENTIAL ISSUES:
Many suspicious merges in logs suggest other rules may be too aggressive:
- Rule 1 (exact name + <50m) - May merge different businesses with same name
- Rule 2 (similarity ≥0.7 + <50m) - May be too lenient
- Rule 4 (same category + <30m + similarity ≥0.6) - May merge different businesses

## Recommendations

1. **Test route deduplication** - Generate routes and check console for deduplication logs
2. **Monitor warnings** - Look for "⚠️ Potential duplicate not removed" warnings (indicates duplicates >100m apart)
3. **Review other suspicious merges** - Many businesses being merged incorrectly in early/canonical deduplication
4. **Consider tightening thresholds:**
   - Rule 1: Reduce distance from 50m to 30m
   - Rule 2: Increase similarity threshold from 0.7 to 0.85
   - Rule 4: Increase similarity threshold from 0.6 to 0.75
5. **Route duplicates** - If duplicates still appear, check console logs to see:
   - Distance between duplicates (may need to increase 100m threshold)
   - Whether deduplication is being called
   - Whether duplicates are being added after deduplication
