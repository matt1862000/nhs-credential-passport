# Geograph POI Merge Strategy with Google/Apple/OSM

## Current Deduplication Flow

### Existing System (Google/Apple/OSM)
1. **Parallel Fetch**: All sources fetch simultaneously
2. **Merge Order**: Google → Apple → OSM (priority-based)
3. **Deduplication Rules** (in `deduplicatePOIs()`):
   - Same name AND within 50m → duplicate
   - Very close (<20m) regardless of name → duplicate
   - Otherwise → keep as distinct POI

### Current Geograph Integration (Basic)
- Geograph is added AFTER other sources
- Uses stricter deduplication (10m for same name, 5m for same location)
- Final deduplication pass on all results

---

## Proposed Enhanced Merge Strategy

### Step 1: Pre-process Geograph POIs (PB-POIRS)
Before merging with other sources, Geograph POIs should be:
1. **Clustered** (within 30m or same feature name)
2. **Scored** (0-10 quality score)
3. **Filtered** (remove zero-scored POIs)

### Step 2: Smart Cross-Source Deduplication
When merging Geograph with Google/Apple/OSM, use intelligent matching:

#### Priority Order (when duplicates found):
1. **Google** (highest quality, most up-to-date)
2. **Geograph** (if score ≥ 6.0, better name/context)
3. **Apple** (good quality)
4. **OSM** (community data, may be outdated)

#### Deduplication Rules:
```swift
func isDuplicate(geographPOI: PlaceResult, existingPOI: PlaceResult) -> Bool {
    let distance = distanceBetween(geographPOI.coordinate, existingPOI.coordinate)
    let geographScore = geographQualityScore(geographPOI)
    
    // Rule 1: Exact same location (< 10m)
    if distance < 10.0 {
        return true  // Definitely same place
    }
    
    // Rule 2: Same name AND close (within 30m)
    let nameSimilarity = calculateNameSimilarity(geographPOI.name, existingPOI.name)
    if nameSimilarity > 0.8 && distance < 30.0 {
        return true  // Same feature, different angle
    }
    
    // Rule 3: Very close (< 20m) AND similar category
    if distance < 20.0 && sameCategory(geographPOI, existingPOI) {
        return true  // Same type of place
    }
    
    return false
}
```

#### When Duplicate Found - Which to Keep?
```swift
func chooseBestPOI(geographPOI: PlaceResult, existingPOI: PlaceResult) -> PlaceResult {
    let geographScore = geographQualityScore(geographPOI)
    
    // Prefer Google over everything
    if existingPOI.source == .google {
        return existingPOI
    }
    
    // Prefer high-quality Geograph over Apple/OSM
    if geographScore >= 6.0 && (existingPOI.source == .apple || existingPOI.source == .osm) {
        // Check if Geograph has better name/description
        if geographPOI.name.count > existingPOI.name.count ||
           (geographPOI.vicinity?.count ?? 0) > (existingPOI.vicinity?.count ?? 0) {
            return geographPOI  // Geograph has better metadata
        }
    }
    
    // Default: keep existing (preserves priority order)
    return existingPOI
}
```

---

## Implementation Plan

### Option A: Enhanced Current Flow (Recommended)
1. Fetch Google/Apple/OSM in parallel (existing)
2. Pre-process Geograph:
   - Cluster Geograph POIs
   - Score Geograph POIs
   - Filter zero-scored
3. Merge Geograph with existing results:
   - Use smart deduplication
   - Prefer higher quality when duplicates found
4. Final deduplication pass

### Option B: Unified Processing
1. Fetch all sources in parallel (including Geograph)
2. Cluster ALL POIs together (not just Geograph)
3. Score all POIs (Geograph uses PB-POIRS, others use existing scoring)
4. Deduplicate with priority-based selection

---

## Code Changes Needed

### 1. Update `findNearbyPlaces()` to pre-process Geograph
```swift
// After fetching Geograph POIs
let rawGeographPOIs = await searchGeographForPOIs(...)

// Apply PB-POIRS processing
let clusteredGeograph = clusterGeographPOIs(rawGeographPOIs, origin: location)
let scoredGeograph = clusteredGeograph.map { poi -> (poi: PlaceResult, score: Double) in
    let score = geographQualityScore(poi)
    return (poi, score)
}
let filteredGeograph = scoredGeograph.filter { $0.score > 0.0 }.map { $0.poi }

// Now merge with other sources using smart deduplication
```

### 2. Create `smartMergePOIs()` function
```swift
func smartMergePOIs(
    existing: [PlaceResult],
    newGeograph: [PlaceResult],
    origin: CLLocationCoordinate2D
) -> [PlaceResult] {
    var merged = existing
    
    for geographPOI in newGeograph {
        let geographScore = geographQualityScore(geographPOI)
        
        // Check for duplicates
        if let duplicateIndex = merged.firstIndex(where: { existing in
            isDuplicate(geographPOI: geographPOI, existingPOI: existing)
        }) {
            // Duplicate found - choose best
            let existingPOI = merged[duplicateIndex]
            let best = chooseBestPOI(geographPOI: geographPOI, existingPOI: existingPOI)
            
            if best.placeId == geographPOI.placeId {
                // Replace with Geograph version
                merged[duplicateIndex] = geographPOI
            }
            // Otherwise keep existing
        } else {
            // No duplicate - add Geograph POI
            merged.append(geographPOI)
        }
    }
    
    return merged
}
```

### 3. Update `deduplicatePOIs()` to be source-aware
```swift
private func deduplicatePOIs(_ pois: [PlaceResult]) -> [PlaceResult] {
    var result: [PlaceResult] = []
    
    // Sort by source priority: Google > Geograph (high score) > Apple > OSM > Geograph (low score)
    let sorted = pois.sorted { first, second in
        let firstPriority = sourcePriority(first)
        let secondPriority = sourcePriority(second)
        if firstPriority != secondPriority {
            return firstPriority < secondPriority
        }
        // If same priority, prefer higher quality Geograph
        if first.source == .geograph && second.source == .geograph {
            return geographQualityScore(first) > geographQualityScore(second)
        }
        return false
    }
    
    for poi in sorted {
        let isDuplicate = result.contains { existing in
            let distance = distanceBetween(existing.coordinate, poi.coordinate)
            let sameNameAndClose = existing.name.lowercased() == poi.name.lowercased() && distance < 50
            let veryClose = distance < 20
            return sameNameAndClose || veryClose
        }
        
        if !isDuplicate {
            result.append(poi)
        }
    }
    
    return result
}

private func sourcePriority(_ poi: PlaceResult) -> Int {
    switch poi.source {
    case .google: return 1
    case .geograph:
        // High-quality Geograph gets priority 2, low-quality gets 4
        return geographQualityScore(poi) >= 6.0 ? 2 : 4
    case .apple: return 3
    case .osm: return 5
    case .unknown: return 6
    }
}
```

---

## Benefits of This Approach

1. **No Duplicates**: Smart deduplication prevents same place appearing multiple times
2. **Best Quality**: Higher quality POIs are preferred when duplicates exist
3. **Geograph Value**: High-quality Geograph POIs (score ≥ 6.0) can replace lower-quality Apple/OSM POIs
4. **Preserves Google**: Google POIs always win (most accurate/up-to-date)
5. **Context Rich**: Geograph POIs with better descriptions can enhance existing POIs

---

## Example Scenarios

### Scenario 1: Same Church from Multiple Sources
- **Google**: "St. Mary's Church" (53.410, -1.457)
- **Apple**: "St Mary's Church" (53.410, -1.457)
- **Geograph**: "St. Mary's Church, Kirkhamgate" (53.410, -1.457) - Score 8.5

**Result**: Keep Google (highest priority), but could enhance with Geograph description

### Scenario 2: Geograph Has Better Name
- **OSM**: "Building" (53.410, -1.457)
- **Geograph**: "Clock Tower, Northern General Hospital" (53.410, -1.457) - Score 9.0

**Result**: Replace OSM with Geograph (better name, high score)

### Scenario 3: Geograph Adds Unique POI
- **Google/Apple/OSM**: No results for location
- **Geograph**: "Grinding Wheels, NGH" (53.411, -1.458) - Score 7.0

**Result**: Add Geograph POI (unique, no duplicates)

---

## Summary

The enhanced merge strategy:
1. ✅ Pre-processes Geograph with PB-POIRS (cluster, score, filter)
2. ✅ Uses smart deduplication that considers source quality
3. ✅ Prefers higher quality POIs when duplicates exist
4. ✅ Preserves Google priority (most accurate)
5. ✅ Allows high-quality Geograph to enhance/replace lower-quality sources
6. ✅ Prevents duplicate POIs in final results

This ensures Geograph adds value without creating duplicates, and high-quality Geograph POIs can improve the overall POI dataset.
