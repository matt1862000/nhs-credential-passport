# Detailed Route Generation & Place Names - Essentials SKU Strategy

## Table of Contents
1. [Route Generation Flow](#route-generation-flow)
2. [POI Fetching Architecture](#poi-fetching-architecture)
3. [Google Places API SKU Tiers](#google-places-api-sku-tiers)
4. [Place Name Extraction](#place-name-extraction)
5. [Current Implementation Analysis](#current-implementation-analysis)
6. [The Place Name Problem](#the-place-name-problem)
7. [Essentials SKU Strategy](#essentials-sku-strategy)
8. [Cost Analysis](#cost-analysis)
9. [Recommendations](#recommendations)

---

## Route Generation Flow

### Complete Flow Diagram

```
User Action: Selects Duration (10-30 min)
    ↓
┌─────────────────────────────────────────────────────────┐
│ STAGE 1: Finding Places Nearby (POI Fetch)             │
│ ─────────────────────────────────────────────────────── │
│ 1. Check POI Cache (within 1km)                        │
│    ├─ Cache HIT → Use cached POIs (instant)            │
│    └─ Cache MISS → Fetch from 3 sources in parallel    │
│                                                         │
│ 2. Parallel POI Fetch:                                 │
│    ├─ Google Places API (New)                          │
│    │   ├─ Field Mask: places.id, places.displayName,   │
│    │   │              places.location                  │
│    │   ├─ Single request: 43 categories batched        │
│    │   ├─ Response time: ~0.6s                        │
│    │   └─ Cost: Pro SKU ($32/1k) - displayName        │
│    │                                              │
│    ├─ Apple Maps (MKLocalSearch)                      │
│    │   ├─ 40 priority categories                      │
│    │   ├─ Rate limit: 50 requests/60s                 │
│    │   ├─ Response time: ~2-5s                        │
│    │   └─ Cost: FREE                                  │
│    │                                              │
│    └─ OpenStreetMap (Overpass API)                   │
│        ├─ 6 mirror servers (fallback)                 │
│        ├─ Response time: 15-50s (slow, unreliable)    │
│        └─ Cost: FREE                                  │
│                                                         │
│ 3. POI Processing:                                     │
│    ├─ Deduplication (50m proximity, name matching)     │
│    ├─ Filter restricted areas (schools, private)       │
│    ├─ Filter by walkability score                     │
│    └─ Pre-filter by duration (55-110% of target)      │
└─────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────┐
│ STAGE 2: Calculating Routes (Route Generation)         │
│ ─────────────────────────────────────────────────────── │
│ 1. Select Waypoints:                                   │
│    ├─ Angular diversity (spread across 8 sectors)       │
│    ├─ Distance filtering (ideal segment distance)      │
│    └─ Walkability scoring                              │
│                                                         │
│ 2. Route Calculation (MapKit):                         │
│    ├─ Optimize waypoint order (Nearest Neighbor)       │
│    ├─ Calculate legs: origin → waypoint1 → ... → origin│
│    ├─ Validate duration (70-130% of target)           │
│    ├─ Response time: 2-10s                            │
│    └─ Cost: FREE                                       │
│                                                         │
│ 3. Fallback (if needed):                              │
│    ├─ Google Directions API (Legacy REST)             │
│    │   ├─ Local waypoint optimization first           │
│    │   ├─ Cost: Essentials SKU ($0.20/1k)            │
│    │   └─ Daily limit: 100 calls                      │
│    └─ OSRM (if MapKit rate-limited)                   │
│        └─ Cost: FREE                                   │
└─────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────┐
│ STAGE 3: Getting Directions (Turn-by-Turn)            │
│ ─────────────────────────────────────────────────────── │
│ 1. Extract from MapKit/OSRM response                  │
│ 2. Generate step-by-step instructions                 │
│ 3. Fallback to Google Directions if needed             │
└─────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────┐
│ STAGE 4: Naming Your Route (AI Generation)            │
│ ─────────────────────────────────────────────────────── │
│ 1. Gemini API (AI-generated name)                     │
│    ├─ Timeout: 3 seconds                               │
│    ├─ Cost: FREE (within quota)                       │
│    └─ Fallback: Template if timeout/fails            │
│                                                         │
│ 2. Template Fallback:                                 │
│    └─ Format: "Via [POI Name]"                        │
└─────────────────────────────────────────────────────────┘
    ↓
STAGE 5: Complete - Route Ready
```

---

## POI Fetching Architecture

### Three-Source Strategy

**Why Three Sources?**
- **Redundancy**: If one fails, others can still provide POIs
- **Coverage**: Different sources have different POI databases
- **Cost Optimization**: Use free sources when possible, paid when needed

### Source Comparison

| Source | Cost | Speed | Reliability | POI Quality | Rate Limits |
|--------|------|-------|-------------|-------------|-------------|
| **Google Places** | $32/1k (Pro) | ~0.6s | High | Excellent | Daily quota |
| **Apple Maps** | FREE | ~2-5s | High | Good | 50/60s |
| **OSM** | FREE | 15-50s | Low | Variable | None |

### Current Implementation (v1.9.44)

**Location**: `WalkingWR/Services/GoogleMapsService.swift` - `findNearbyPlaces()`

```swift
// Parallel fetch strategy
async let googleTask = fetchGooglePOIs(...)
async let appleTask = searchAppleMapsForPOIs(...)
async let osmTask = searchOpenStreetMap(...)

// Wait for all to complete (or timeout)
let googlePOIs = await googleTask
let applePOIs = await appleTask
let osmPOIs = await osmTask

// Merge and deduplicate
```

**Problem**: Waits for slowest source (OSM can take 50+ seconds)

---

## Google Places API SKU Tiers

### SKU Tier Structure (2026)

Google Places API (New) has three pricing tiers:

#### 1. Essentials SKU
- **Cost**: $5.00 per 1,000 requests
- **Monthly Credit**: $200 free (40,000 requests/month)
- **Fields Available**:
  - `places.id` ✅
  - `places.location` ✅
  - `places.name` ✅ (internal identifier, NOT display name)
  - `places.primaryType` ✅
  - `places.types` ✅
  - `places.formattedAddress` ✅
  - `places.nationalPhoneNumber` ✅
  - `places.internationalPhoneNumber` ✅
  - `places.websiteUri` ✅
  - `places.businessStatus` ✅

#### 2. Pro SKU
- **Cost**: $32.00 per 1,000 requests
- **Additional Fields**:
  - `places.displayName` ⚠️ (moved to Pro in 2026)
  - `places.shortFormattedAddress` ⚠️
  - `places.editorialSummary` ⚠️
  - `places.priceLevel` ⚠️
  - `places.rating` ⚠️
  - `places.userRatingCount` ⚠️
  - `places.currentOpeningHours` ⚠️
  - `places.regularOpeningHours` ⚠️

#### 3. Enterprise SKU
- **Cost**: Custom pricing
- **Additional Fields**:
  - `places.reviews` (very expensive)
  - `places.photos` (very expensive)
  - Advanced features

### Critical Field: `places.displayName` vs `places.name`

**`places.displayName`** (Pro SKU - $32/1k):
- **Type**: Object with `text` and `languageCode`
- **Content**: Human-readable place name (e.g., "Corner Cafe", "Kirkhamgate Fisheries")
- **Localized**: Returns name in user's language
- **Example**:
  ```json
  {
    "displayName": {
      "text": "Corner Cafe",
      "languageCode": "en"
    }
  }
  ```

**`places.name`** (Essentials SKU - $5/1k):
- **Type**: String
- **Content**: Internal identifier or Place ID (e.g., "places/ChIJ3Wetb8lgeUgRbEZs6y0BqU8")
- **NOT a display name**: This is an internal reference
- **Example**:
  ```json
  {
    "name": "places/ChIJ3Wetb8lgeUgRbEZs6y0BqU8"
  }
  ```

**⚠️ IMPORTANT**: `places.name` does NOT return the actual place name. It returns an internal identifier.

---

## Place Name Extraction

### Current Implementation (v1.9.44)

**Location**: `WalkingWR/Services/GoogleMapsService.swift` lines 1679-1764

#### Step 1: Field Mask Request

```swift
// Current field mask (CLAIMS Essentials, but actually Pro SKU)
let fieldMask = "places.id,places.displayName,places.location"
request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
```

**⚠️ Issue**: The comment says "Essentials SKU only" but `places.displayName` is **Pro SKU** ($32/1k).

#### Step 2: API Response Structure

```swift
struct NewPlacesResponse: Codable {
    let places: [NewPlace]?
}

struct NewPlace: Codable {
    let id: String?
    let displayName: DisplayName?  // Pro SKU field
    let location: NewPlaceLocation?
}

struct DisplayName: Codable {
    let text: String?              // Actual place name
    let languageCode: String?
}
```

#### Step 3: Name Extraction

```swift
return newPlacesResponse.places?.map { place in
    PlaceResult(
        placeId: place.id ?? "unknown",
        name: place.displayName?.text ?? "Unknown",  // Extract text from displayName
        vicinity: nil,
        geometry: PlaceGeometry(...),
        types: nil
    )
} ?? []
```

**How it works**:
1. API returns `displayName` object with `text` field
2. Code extracts `place.displayName?.text`
3. Falls back to "Unknown" if missing

**Why it works**: `displayName.text` contains the actual place name.

---

## Current Implementation Analysis

### What We're Actually Using

**Field Mask**: `places.id,places.displayName,places.location`

**SKU Tier**: **Pro SKU** ($32/1,000 requests)
- Despite comments saying "Essentials SKU only"
- `places.displayName` triggers Pro SKU billing

**Cost per Route Generation**:
- 1 request per route generation
- Cost: $0.032 per route
- With $200 monthly credit: First 6,250 routes free, then $0.032 each

### Why Place Names Work (Currently)

Place names **DO work** in v1.9.44 because:
1. We're using `places.displayName` (Pro SKU)
2. `displayName.text` contains the actual place name
3. Code correctly extracts: `place.displayName?.text ?? "Unknown"`

**Example Flow**:
```
API Response:
{
  "displayName": {
    "text": "Corner Cafe",
    "languageCode": "en"
  }
}
    ↓
Code extracts: place.displayName?.text
    ↓
Result: "Corner Cafe" ✅
```

---

## The Place Name Problem

### What Happened in v1.9.45

**Attempted Change**: Downgrade to Essentials SKU

**Field Mask Changed To**: `places.id,places.location,places.name`

**What We Expected**:
- `places.name` would return place names
- Stay in Essentials SKU ($5/1k instead of $32/1k)
- Save $27 per 1,000 requests

**What Actually Happened**:
- `places.name` returned Place IDs (e.g., "places/ChIJ3Wetb8lgeUgRbEZs6y0BqU8")
- Place names showed as Place IDs in UI
- User experience degraded significantly

**Why It Failed**:
- `places.name` is NOT a display name field
- It's an internal identifier/reference
- Google's documentation is unclear about this

### The Confusion

**Google's Documentation Says**:
- `places.name` - "The resource name of the place"
- `places.displayName` - "The display name of the place"

**Reality**:
- `places.name` = Internal resource identifier (not human-readable)
- `places.displayName` = Actual place name (human-readable)

**Example**:
```json
// What we get with places.name (Essentials)
{
  "name": "places/ChIJ3Wetb8lgeUgRbEZs6y0BqU8"
}

// What we need (Pro SKU)
{
  "displayName": {
    "text": "Corner Cafe"
  }
}
```

---

## Essentials SKU Strategy

### Goal: Stay in Essentials SKU While Getting Place Names

**Challenge**: `places.displayName` is Pro SKU, but we need readable names.

### Option 1: Use `places.name` + Local Name Fetching ❌

**Approach**:
1. Get Place ID from `places.name` or `places.id`
2. Use reverse geocoding (CLGeocoder) to get address
3. Use MKLocalSearch to find POI name by coordinate

**Problems**:
- Adds latency (multiple API calls per POI)
- Not always accurate (geocoding returns addresses, not POI names)
- Complex implementation
- May not find the actual POI name

**Status**: Attempted in v1.9.45, didn't work well

### Option 2: Accept Pro SKU Cost ✅ (Current)

**Approach**:
- Use `places.displayName` (Pro SKU)
- Accept $32/1k cost
- With $200 monthly credit: ~6,250 routes free/month

**Pros**:
- Simple implementation
- Accurate place names
- Good user experience
- Works reliably

**Cons**:
- Higher cost after free credit
- ~$0.032 per route generation

**Status**: Current implementation (v1.9.44)

### Option 3: Hybrid Approach (Future)

**Approach**:
1. Use Essentials SKU for initial fetch (`places.id,places.location,places.name`)
2. Cache Place IDs
3. Batch fetch `displayName` for cached Place IDs (separate API call)
4. Use cached names for subsequent routes

**Pros**:
- Reduces API calls (cache names)
- Can optimize which POIs get names
- Lower cost for repeated locations

**Cons**:
- Complex implementation
- Two API calls needed
- Still uses Pro SKU for names

### Option 4: Use Apple Maps Names (Free)

**Approach**:
1. Get Place IDs from Google (Essentials)
2. Match coordinates with Apple Maps results
3. Use Apple Maps names (free)

**Pros**:
- No Google Pro SKU cost
- Apple Maps is free

**Cons**:
- Not all Google POIs exist in Apple Maps
- Matching by coordinates is imperfect
- May miss some POIs

---

## Cost Analysis

### Current Costs (v1.9.44 - Using Pro SKU)

**Per Route Generation**:
- Google Places API: 1 request (Pro SKU) = $0.032
- Google Directions: 0-1 requests (Essentials) = $0.000-$0.0002
- Apple Maps: FREE
- OSM: FREE
- **Total**: ~$0.032 per route

**Monthly Estimate** (assuming 1,000 routes/month):
- Google Places: 1,000 × $0.032 = $32.00
- Google Directions: ~100 × $0.0002 = $0.02
- **Total**: ~$32.02/month
- **With $200 credit**: FREE (first 6,250 routes)

### If We Switched to Essentials SKU

**Per Route Generation**:
- Google Places API: 1 request (Essentials) = $0.005
- **Total**: ~$0.005 per route

**Monthly Estimate** (1,000 routes):
- Google Places: 1,000 × $0.005 = $5.00
- **Total**: ~$5.00/month
- **With $200 credit**: FREE (first 40,000 routes)

**Savings**: $27/month (after free credit)

**Trade-off**: Place names would show as Place IDs (bad UX)

---

## Recommendations

### Short-Term (Keep Current)

**Recommendation**: Keep using Pro SKU (`places.displayName`)

**Reasoning**:
1. ✅ Place names work correctly
2. ✅ Good user experience
3. ✅ $200 monthly credit covers ~6,250 routes
4. ✅ Simple, reliable implementation
5. ✅ Cost is reasonable ($0.032/route after credit)

**Action**: Update comments to reflect Pro SKU usage

### Medium-Term (Optimize)

**Recommendation**: Implement aggressive POI caching

**Strategy**:
1. Cache POIs by location (1km radius)
2. Cache place names with Place IDs
3. Reuse cached names for subsequent routes
4. Only fetch new POIs when location changes significantly

**Expected Savings**: 50-80% reduction in API calls

### Long-Term (Hybrid Approach)

**Recommendation**: Implement Option 3 (Hybrid)

**Strategy**:
1. Initial fetch: Essentials SKU (get Place IDs + coordinates)
2. Batch fetch display names for top 20 POIs (Pro SKU)
3. Cache names aggressively
4. Use Apple Maps names as fallback

**Expected Savings**: 60-70% reduction in Pro SKU calls

---

## Code Reference

### Current Field Mask (v1.9.44)

**File**: `WalkingWR/Services/GoogleMapsService.swift` line 1679

```swift
// ⚠️ NOTE: This is actually Pro SKU, not Essentials
// displayName triggers Pro SKU billing ($32/1k)
let fieldMask = "places.id,places.displayName,places.location"
request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
print("   🔒 FieldMask: \(fieldMask) (Essentials SKU only - no expensive fields)")
// ⚠️ COMMENT IS WRONG - should say "Pro SKU - displayName required for place names"
```

### Name Extraction (v1.9.44)

**File**: `WalkingWR/Services/GoogleMapsService.swift` line 1754

```swift
PlaceResult(
    placeId: place.id ?? "unknown",
    name: place.displayName?.text ?? "Unknown",  // Extract from displayName.text
    vicinity: nil,
    geometry: PlaceGeometry(...),
    types: nil
)
```

### Data Structures

**File**: `WalkingWR/Services/GoogleMapsService.swift` lines 7500-7512

```swift
struct NewPlace: Codable {
    let id: String?
    let displayName: DisplayName?  // Pro SKU field
    let location: NewPlaceLocation?
}

struct DisplayName: Codable {
    let text: String?              // Actual place name
    let languageCode: String?
}
```

---

## Summary

### Current State (v1.9.44)

- ✅ **Place names work correctly** (using `displayName.text`)
- ⚠️ **Using Pro SKU** ($32/1k) despite comments saying Essentials
- ✅ **Good user experience** (readable place names)
- ✅ **Reasonable cost** ($0.032/route, free for first 6,250/month)

### The Problem

- Comments incorrectly state "Essentials SKU only"
- Attempted downgrade to Essentials broke place names
- `places.name` doesn't return display names (it's an identifier)

### The Solution

**Keep Pro SKU for now** because:
1. User experience > cost savings
2. $200 monthly credit covers most usage
3. Simple, reliable implementation
4. Cost is reasonable after credit

**Future optimization**: Implement aggressive caching to reduce API calls

---

## Key Takeaways

1. **`places.displayName` is Pro SKU** ($32/1k) - not Essentials
2. **`places.name` is NOT a display name** - it's an internal identifier
3. **Current implementation works** but uses Pro SKU (not Essentials)
4. **Place names show correctly** because we extract `displayName.text`
5. **Cost is acceptable** with $200 monthly credit
6. **Future optimization**: Caching can reduce costs by 50-80%

---

## Action Items

1. ✅ Update comments to reflect Pro SKU usage (not Essentials)
2. ✅ Document why we use Pro SKU (place names)
3. ⏳ Implement POI caching to reduce API calls
4. ⏳ Monitor API usage and costs
5. ⏳ Consider hybrid approach for future optimization
