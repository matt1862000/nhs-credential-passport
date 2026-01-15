# All Places API Code Reference

This document contains all code that references Google Places API (New) in the WalkingWR codebase.

---

## 1. Main API Call Function: `searchSingleType`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1534-1664)

```swift
/// Search for a single place type using New Places API (Essentials tier - much cheaper!)
/// 
/// ⚠️ COST OPTIMIZATION (v1.9.15):
/// - Uses Essentials SKU only (places.id, places.displayName, places.location)
/// - Removed places.formattedAddress and places.types to avoid Pro SKU charges
/// - Pro SKU costs ~$32/1000 requests (£0.025 per request) - was causing £16.87 charges
/// - Essentials SKU is FREE with $200 monthly credit
/// - To reduce costs further, lower daily quota in Google Cloud Console (APIs & Services > Quotas)
/// 
/// Cost: Essentials ~$5/1k requests vs Pro $32/1k requests
private func searchSingleType(
    location: CLLocationCoordinate2D,
    radiusMeters: Int,
    type: String
) async throws -> [PlaceResult] {
    // New Places API endpoint
    guard let url = URL(string: "https://places.googleapis.com/v1/places:searchNearby") else {
        throw GoogleMapsError.invalidURL
    }
    
    // Build request body
    let requestBody: [String: Any] = [
        "includedTypes": [type],
        "maxResultCount": 20,
        "locationRestriction": [
            "circle": [
                "center": [
                    "latitude": location.latitude,
                    "longitude": location.longitude
                ],
                "radius": Double(radiusMeters)
            ]
        ]
    ]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // v1.9.13: Set explicit timeout for slow networks
    request.timeoutInterval = 30.0 // 30 second timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
    // Add iOS bundle ID for API key restrictions
    let bundleIdSent: Bool
    if let bundleId = Bundle.main.bundleIdentifier {
        request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        bundleIdSent = true
    } else {
        bundleIdSent = false
    }
    // ⚠️ COST OPTIMIZATION: Use Essentials SKU only (FREE with $200 monthly credit)
    // Requesting only: places.id, places.displayName, places.location
    // REMOVED: places.formattedAddress and places.types (trigger Pro SKU at $32/1000 requests)
    // REMOVED: rating, user_ratings_total, opening_hours, price_level, reviews (Enterprise SKU - very expensive!)
    // These fields are optional in PlaceResult, so we can safely omit them
    let fieldMask = "places.id,places.displayName,places.location"
    request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
    print("   🔒 FieldMask: \(fieldMask) (Essentials SKU only - no expensive fields)")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    
    let startTime = Date()
    // Use session with timeout configuration
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30.0
    config.timeoutIntervalForResource = 60.0
    let timeoutSession = URLSession(configuration: config)
    let (data, response) = try await timeoutSession.data(for: request)
    let responseTime = Date().timeIntervalSince(startTime)
    
    guard let httpResponse = response as? HTTPURLResponse else {
        print("   ❌ [\(type)] No HTTP response")
        recordAPICall(
            apiName: "Places API (New)",
            success: false,
            responseTime: responseTime,
            errorMessage: "No HTTP response",
            bundleIdSent: bundleIdSent,
            details: "type: \(type)"
        )
        throw GoogleMapsError.serverError
    }
    
    if httpResponse.statusCode != 200 {
        // Try to parse error message
        var errorMessage: String?
        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = errorJson["error"] as? [String: Any],
           let message = error["message"] as? String {
            errorMessage = message
            print("   ❌ [\(type)] HTTP \(httpResponse.statusCode) - \(message)")
        } else {
            errorMessage = "HTTP \(httpResponse.statusCode) - Unknown error"
            print("   ❌ [\(type)] \(errorMessage!)")
        }
        
        recordAPICall(
            apiName: "Places API (New)",
            success: false,
            httpStatus: httpResponse.statusCode,
            responseTime: responseTime,
            errorMessage: errorMessage,
            bundleIdSent: bundleIdSent,
            details: "type: \(type)"
        )
        throw GoogleMapsError.serverError
    }
    
    // Parse new API response format
    let newPlacesResponse = try JSONDecoder().decode(NewPlacesResponse.self, from: data)
    let count = newPlacesResponse.places?.count ?? 0
    
    if count > 0 {
        print("   ✓ [\(type)] → \(count) POIs")
    }
    
    // Record successful call
    recordAPICall(
        apiName: "Places API (New)",
        success: true,
        httpStatus: httpResponse.statusCode,
        responseTime: responseTime,
        bundleIdSent: bundleIdSent,
        details: "type: \(type), \(count) POIs"
    )
    
    // Convert to PlaceResult format
    // Note: vicinity and types are nil because we're using Essentials SKU (cost optimization)
    return newPlacesResponse.places?.map { place in
        PlaceResult(
            placeId: place.id ?? "unknown",
            name: place.displayName?.text ?? "Unknown",
            vicinity: nil, // Not requested (Essentials SKU only - saves ~£0.025 per request)
            geometry: PlaceGeometry(
                location: PlaceLocation(
                    lat: place.location?.latitude ?? 0,
                    lng: place.location?.longitude ?? 0
                )
            ),
            types: nil // Not requested (Essentials SKU only - saves ~£0.025 per request)
        )
    } ?? []
}
```

---

## 2. Fetch Function: `fetchGooglePOIs`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1408-1522)

```swift
/// Fetch POIs from Google Places API (called at most once per 24 hours)
private func fetchGooglePOIs(
    location: CLLocationCoordinate2D,
    radiusMeters: Int
) async -> [PlaceResult] {
    
    // Search multiple specific types in parallel to maximize POI variety
    let placeTypesToSearch = [
        // Retail & Shopping
        "store",              // General retail
        "convenience_store",  // Local corner shops
        "supermarket",        // Supermarkets
        "shopping_mall",      // Shopping centers
        "hardware_store",     // DIY shops
        "florist",            // Flower shops
        "pet_store",          // Pet shops
        "liquor_store",       // Off-licenses
        
        // Food & Drink
        "restaurant",         // Restaurants
        "cafe",               // Coffee shops
        "bar",                // Bars/pubs
        "bakery",             // Bakeries
        "meal_takeaway",      // Takeaways (fish & chips, kebabs)
        
        // Health & Wellness
        "pharmacy",           // Pharmacies
        "doctor",             // GP surgeries
        "dentist",            // Dental practices
        "veterinary_care",    // Vets
        "spa",                // Spas/wellness
        
        // Services
        "bank",               // Banks
        "post_office",        // Post offices
        "hair_care",          // Hairdressers/barbers
        "laundry",            // Launderettes
        "car_wash",           // Car washes
        "gas_station",        // Petrol stations
        
        // Culture & Leisure
        "park",               // Parks
        "museum",             // Museums
        "library",            // Libraries
        "art_gallery",        // Art galleries
        "book_store",         // Book shops
        "gym",                // Gyms
        "church",             // Churches/places of worship
        "movie_theater",      // Cinemas
        "bowling_alley",      // Bowling alleys
        
        // Education & Community
        "school",             // Schools
        "community_center",   // Community centres
        
        // Outdoors & Nature
        "cemetery",           // Cemeteries/churchyards
        "campground",         // Camping/green spaces
        
        // Transport
        "bus_station",        // Bus stations
        "train_station",      // Train stations
        
        // Lodging
        "lodging",            // Hotels, B&Bs
        
        // Government & Landmarks
        "local_government_office",  // Town halls
        "fire_station",       // Fire stations
        "police"              // Police stations
    ]
    
    var allResults: [PlaceResult] = []
    var seenPlaceIds = Set<String>()
    
    print("🌐 GOOGLE NEW PLACES API - Searching \(placeTypesToSearch.count) categories...")
    print("🌐 Categories: \(placeTypesToSearch.joined(separator: ", "))")
    print("🌐 Endpoint: places.googleapis.com/v1/places:searchNearby")
    print("🌐 Field Mask: places.id, places.displayName, places.location (Essentials SKU - FREE with $200 credit)")
    print("🌐 API Key present: \(!apiKey.isEmpty), key prefix: \(String(apiKey.prefix(10)))...")
    
    // Search each type in parallel using TaskGroup
    await withTaskGroup(of: [PlaceResult].self) { group in
        for placeType in placeTypesToSearch {
            group.addTask {
                do {
                    return try await self.searchSingleType(
                        location: location,
                        radiusMeters: radiusMeters,
                        type: placeType
                    )
                } catch {
                    print("   ❌ [\(placeType)] FAILED: \(error.localizedDescription)")
                    return []
                }
            }
        }
        
        // Collect results from all parallel searches
        for await results in group {
            for place in results {
                if !seenPlaceIds.contains(place.placeId) {
                    seenPlaceIds.insert(place.placeId)
                    allResults.append(place)
                }
            }
        }
    }
    
    print("🌐 GOOGLE COMPLETE: \(allResults.count) unique POIs from \(placeTypesToSearch.count) categories")
    
    // API calls are now recorded individually in searchSingleType
    
    return allResults
}
```

---

## 3. Public Interface: `findNearbyPlaces`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1100-1275)

This is the main public function that calls `fetchGooglePOIs` (line 1167):

```swift
func findNearbyPlaces(
    location: CLLocationCoordinate2D,
    radiusMeters: Int = 2500,
    types: [String] = ["point_of_interest"]
) async throws -> [PlaceResult] {
    // ... caching logic ...
    
    // Launch all fetches in parallel
    async let osmTask = searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
    async let appleTask = searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
    async let googleTask: [PlaceResult] = apiKey.isEmpty ? [] : fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
    
    // ... merge results ...
}
```

---

## 4. On-Demand Fetch: `fetchGooglePOIsOnDemand`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1361-1406)

```swift
/// Fetch additional POIs from Google Places API when Apple/OSM didn't find enough variety
/// Called when route generation only found 1-2 routes and more options are needed
/// Returns the NEW POIs that weren't already in the cache
func fetchGooglePOIsOnDemand(
    location: CLLocationCoordinate2D,
    radiusMeters: Int = 2500,
    existingPOIs: [PlaceResult]
) async -> [PlaceResult] {
    guard !apiKey.isEmpty else {
        print("🌐 GOOGLE ON-DEMAND: No API key, skipping")
        return []
    }
    
    print("🌐 ═══════════════════════════════════════════════════════")
    print("🌐 GOOGLE ON-DEMAND: Fetching additional POIs")
    print("🌐   📍 Location: (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
    print("🌐   📦 Existing POIs: \(existingPOIs.count)")
    print("🌐 ═══════════════════════════════════════════════════════")
    
    let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
    
    // Filter out POIs we already have (by name or proximity)
    var newPOIs: [PlaceResult] = []
    for poi in googlePOIs {
        let isDuplicate = existingPOIs.contains { existing in
            existing.name.lowercased() == poi.name.lowercased() ||
            distanceBetween(existing.coordinate, poi.coordinate) < 50
        }
        if !isDuplicate {
            newPOIs.append(poi)
        }
    }
    
    print("🌐 GOOGLE ON-DEMAND COMPLETE:")
    print("🌐   📊 Fetched: \(googlePOIs.count) POIs")
    print("🌐   ✨ New (after dedup): \(newPOIs.count) POIs")
    
    // Merge with cache for future use
    if !newPOIs.isEmpty {
        let mergedPOIs = existingPOIs + newPOIs
        POICacheService.shared.cachePOIs(mergedPOIs, for: location)
        print("🌐   💾 Cache updated: \(mergedPOIs.count) total POIs")
    }
    
    return newPOIs
}
```

---

## 5. Test Mode: `findNearbyPlacesWithoutCaching`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1277-1320)

```swift
/// Same as findNearbyPlaces but does NOT cache results - used for testing to bypass location limits
func findNearbyPlacesWithoutCaching(
    location: CLLocationCoordinate2D,
    radiusMeters: Int = 2500
) async throws -> [PlaceResult] {
    // ... 
    // 2. Google Places API (will fail if quota exceeded, but makes it a TRUE test)
    if !apiKey.isEmpty {
        print("🌐 GOOGLE (test mode) - Calling API...")
        let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
        // ...
    }
    // ...
}
```

---

## 6. Diagnostic Function: `runGooglePOIDiagnostic`

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 2134-2180)

```swift
/// Runs a diagnostic test to fetch all available POIs from Google Places API
func runGooglePOIDiagnostic(location: CLLocationCoordinate2D, radiusMeters: Int = 2000) async -> String {
    var results = "🔷 GOOGLE PLACES POI DIAGNOSTIC\n"
    results += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    results += "📍 Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))\n"
    results += "📏 Radius: \(radiusMeters)m\n"
    results += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    print("🔷 📊 DIAGNOSTIC: Fetching Google POIs...")
    
    let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
    
    // ... process and format results ...
    
    return results
}
```

---

## 7. Response Data Structures

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 7029-7054)

```swift
// Legacy Places API Response (kept for backwards compatibility)
struct PlacesResponse: Codable {
    let status: String
    let results: [PlaceResult]
}

// New Places API Response (Essentials tier - much cheaper!)
struct NewPlacesResponse: Codable {
    let places: [NewPlace]?
}

struct NewPlace: Codable {
    let id: String?
    let displayName: DisplayName?
    let location: NewPlaceLocation?
    // ⚠️ REMOVED: formattedAddress and types to prevent Pro SKU billing
    // These fields trigger Enterprise/Pro SKU charges even if not in FieldMask
    // Only decode the fields we explicitly request: id, displayName, location
}

struct DisplayName: Codable {
    let text: String?
    let languageCode: String?
}

struct NewPlaceLocation: Codable {
    let latitude: Double?
    let longitude: Double?
}
```

---

## 8. API Call Recording

**Location:** `WalkingWR/Services/GoogleMapsService.swift` (lines 1594-1646)

The `recordAPICall` function is called with:
- `apiName: "Places API (New)"`
- Success/failure status
- Response time
- Bundle ID sent status
- Details (place type, POI count)

---

## 9. Where Places API is Called From

### From `GoogleMapsService.swift`:
- Line 1058: Early prefetch
- Line 1167: Main `findNearbyPlaces` function
- Line 1296: Test mode `findNearbyPlacesWithoutCaching`
- Line 1380: On-demand fetch `fetchGooglePOIsOnDemand`
- Line 2144: Diagnostic function
- Line 4649: Route generation
- Line 4766: Expanded search for sparse areas

### From `RouteSelectionView.swift`:
- Line 1565: Main route selection
- Line 2825: On-demand fetch when not enough routes
- Line 3568: Test mode
- Line 3788: Test coordinate

### From `ProfileView.swift`:
- Line 3412: POI diagnostic
- Line 3594: POI diagnostic with coordinate

---

## 10. Key Configuration

**Endpoint:** `https://places.googleapis.com/v1/places:searchNearby`

**Field Mask (X-Goog-FieldMask):** `places.id,places.displayName,places.location`

**Excluded Fields (to avoid Pro/Enterprise SKU):**
- ❌ `places.formattedAddress` (Pro SKU)
- ❌ `places.types` (Pro SKU)
- ❌ `places.rating` (Enterprise SKU)
- ❌ `places.user_ratings_total` (Enterprise SKU)
- ❌ `places.opening_hours` (Enterprise SKU)
- ❌ `places.price_level` (Enterprise SKU)
- ❌ `places.reviews` (Enterprise SKU)

**Number of API Calls per Location:** 43 parallel calls (one per place type)

**Caching:** POIs are cached by location (1km radius) to avoid repeated API calls

---

## Summary

All Places API calls go through:
1. `searchSingleType` - Makes the actual HTTP request
2. `fetchGooglePOIs` - Orchestrates 43 parallel searches
3. `findNearbyPlaces` - Public interface with caching
4. Response parsing via `NewPlacesResponse` and `NewPlace` structs

The FieldMask is set **only once** in `searchSingleType` (line 1578) and includes only the three Essentials SKU fields.
