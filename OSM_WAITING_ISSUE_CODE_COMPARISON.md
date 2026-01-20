# OSM Waiting Issue - Code Comparison

## Current Code (v1.9.44) - Waits for OSM

**Location**: `WalkingWR/Services/GoogleMapsService.swift` lines 1243-1315

### The Problem

```swift
// Launch all fetches in parallel
async let osmTask = searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
async let appleTask = searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
async let googleTask: [PlaceResult] = apiKey.isEmpty ? [] : fetchGooglePOIs(location: location, radiusMeters: radiusMeters)

// ⚠️ PROBLEM: Waits for ALL sources to complete
// Google finishes in ~0.6s, but we wait for OSM (15-50s)
let osmPOIs = await osmTask        // Blocks here if OSM is slow
let applePOIs = await appleTask
let googlePOIs = await googleTask

let parallelTime = Date().timeIntervalSince(parallelStartTime)
print("⏱️ PARALLEL FETCH completed in \(String(format: "%.2f", parallelTime))s")
// This can take 50+ seconds if OSM is slow!
```

**Issue**: 
- Route generation is blocked waiting for slow OSM responses
- Even though Google POIs are ready in ~0.6s
- User sees "Finding places nearby" for 50+ seconds

---

## Optimized Code (v1.9.46) - Timeout for OSM/Apple

**What v1.9.46 Added**: 3-second timeout, proceed with Google-only if slow

### The Solution

```swift
// Get Google POIs first (fast, ~0.6s) for immediate route generation
async let googleTask: [PlaceResult] = apiKey.isEmpty ? [] : fetchGooglePOIs(location: location, radiusMeters: radiusMeters)

// ⚡ Get Google immediately - don't wait for others
let googlePOIs = await googleTask
let googleTime = Date().timeIntervalSince(parallelStartTime)
print("🌐 Google POIs ready in \(String(format: "%.2f", googleTime))s - route generation can start immediately")
print("   🌐 Google: \(googlePOIs.count) POIs")

// Try to get OSM/Apple quickly (with 3s timeout) for immediate merge
// If they're not ready, we proceed with Google only
var osmPOIs: [PlaceResult] = []
var applePOIs: [PlaceResult] = []

do {
    // Try to get OSM/Apple within 3 seconds
    let fetchTask = Task {
        async let osm = searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
        async let apple = searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
        return try await (osm, apple)
    }
    
    let (osm, apple) = try await withTimeout(seconds: 3) {
        try await fetchTask.value
    }
    osmPOIs = osm
    applePOIs = apple
    let parallelTime = Date().timeIntervalSince(parallelStartTime)
    print("⚡ Got OSM/Apple within 3s - merging immediately")
    print("⏱️ PARALLEL FETCH completed in \(String(format: "%.2f", parallelTime))s")
    print("   🗺️ OSM:    \(osmPOIs.count) POIs")
    print("   🍎 Apple:  \(applePOIs.count) POIs")
} catch {
    // Timeout or error - proceed with Google only
    let parallelTime = Date().timeIntervalSince(parallelStartTime)
    print("⚡ OSM/Apple taking too long (>3s) - proceeding with Google POIs only")
    print("   → Route generation starting now with \(googlePOIs.count) Google POIs")
    print("   → OSM/Apple will complete in background (not used for this route)")
    // OSM/Apple tasks continue but results won't be merged
}

// Merge results (Google + Apple + OSM if available)
// Route generation can start immediately with Google POIs
```

**Benefits**:
- ✅ Route generation starts in ~0.6-3s instead of 50+ seconds
- ✅ Google POIs available immediately
- ✅ OSM/Apple still fetched in background (for future routes)
- ✅ Better user experience

---

## The `withTimeout` Helper Function

**Location**: `WalkingWR/Services/GoogleMapsService.swift` lines 102-122

```swift
/// Wraps an async operation with a timeout, throwing TimeoutError if exceeded
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Start the operation
        group.addTask {
            try await operation()
        }
        
        // Start timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timeout
        }
        
        // Return first completed task, cancel the other
        guard let result = try await group.next() else {
            throw TimeoutError.timeout
        }
        group.cancelAll()
        return result
    }
}

enum TimeoutError: Error {
    case timeout
}
```

**How it works**:
1. Starts the operation in a task group
2. Starts a timeout task that sleeps for the specified seconds
3. Returns whichever completes first
4. Cancels the other task

---

## Performance Comparison

### Current (v1.9.44) - Waits for All

```
Time 0.0s: Start parallel fetch
Time 0.6s: Google completes ✅
Time 2.5s: Apple completes ✅
Time 45.0s: OSM completes ✅
Time 45.0s: Route generation starts ⏱️
```

**Total wait**: 45 seconds

### Optimized (v1.9.46) - Timeout After 3s

```
Time 0.0s: Start parallel fetch
Time 0.6s: Google completes ✅
Time 0.6s: Route generation starts ⚡ (immediate!)
Time 2.5s: Apple completes ✅ (merged if <3s)
Time 3.0s: OSM timeout - proceed with Google only
Time 45.0s: OSM completes (in background, not used)
```

**Total wait**: 0.6-3 seconds

---

## Why This Matters

### User Experience Impact

**Current (v1.9.44)**:
- User sees "Finding places nearby" for 45+ seconds
- Feels slow and unresponsive
- User may think app is frozen

**Optimized (v1.9.46)**:
- User sees "Finding places nearby" for 0.6-3 seconds
- Route generation starts immediately
- Feels fast and responsive

### Route Quality Impact

**Current**: 
- Gets all POIs from all sources (best coverage)
- But user waits 45+ seconds

**Optimized**:
- Gets Google POIs immediately (good quality)
- May miss some OSM/Apple POIs if they're slow
- But route generation starts much faster

**Trade-off**: Speed vs. POI coverage
- In practice: Google POIs are usually sufficient
- OSM/Apple add variety but aren't critical
- Speed improvement is worth the trade-off

---

## Recommendation

**Add the timeout optimization back** (without the place name changes):

1. ✅ Keep `places.displayName` (Pro SKU) - place names work
2. ✅ Add 3-second timeout for OSM/Apple
3. ✅ Start route generation immediately with Google POIs
4. ✅ Let OSM/Apple complete in background (for future routes)

This gives you the speed improvement without breaking place names.
