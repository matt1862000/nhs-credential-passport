# Instructions: Merge Geograph POI Integration into Main Build

## Overview
This adds Geograph.org.uk as a 4th POI source alongside Google Places, Apple Maps, and OpenStreetMap. Geograph provides 8+ million geotagged photos covering Great Britain and Ireland that can serve as unique landmarks and points of interest.

**License**: Geograph photos are CC BY-SA 2.0 - attribution required when displaying.

---

## Step 1: Add Geograph to POISource Enum

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: Find the `POISource` enum (around line 130)

**Action**: Add `.geograph` case:

```swift
enum POISource: String, Codable {
    case google = "google"
    case apple = "apple"
    case osm = "osm"
    case geograph = "geograph"  // ADD THIS LINE
    case unknown = "unknown"
}
```

---

## Step 2: Add Geograph API Key Property

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: In the `GoogleMapsService` class, after the `apiKey` property (around line 155)

**Action**: Add the Geograph API key property:

```swift
    // Geograph API Key - optional, request from https://www.geograph.org.uk/help/api
    private var geographApiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "GEOGRAPH_API_KEY") as? String ?? ""
    }
```

---

## Step 3: Add Geograph API Key to Info.plist

**File**: `WalkingWR/Info.plist`

**Location**: Add after the existing API keys (around line 29)

**Action**: Add the Geograph API key entry:

```xml
<key>GEOGRAPH_API_KEY</key>
<string>YOUR_API_KEY_HERE</string>
```

**Note**: 
- Replace `YOUR_API_KEY_HERE` with your actual API key from https://www.geograph.org.uk/help/api
- If you don't have an API key yet, use an empty string: `<string></string>`
- The app will gracefully skip Geograph if the key is empty (no errors)

---

## Step 4: Add searchGeographForPOIs() Function

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: Add before the "Search OpenStreetMap for POIs" section (around line 2438)

**Action**: Add the complete Geograph search function:

```swift
    // MARK: - Geograph POI Search (Experimental)
    
    /// Searches Geograph.org.uk for geotagged photos that can serve as POIs
    /// Uses the Syndicator API: https://www.geograph.org.uk/help/api
    /// Returns photos with location data that can be used as landmarks/POIs
    /// 
    /// LICENSE: Geograph photos are licensed under CC BY-SA 2.0
    /// Attribution: When displaying Geograph data, credit the photographer and Geograph.org.uk
    /// Note: Requires API key from Geograph (request at https://www.geograph.org.uk/help/api)
    private func searchGeographForPOIs(location: CLLocationCoordinate2D, radiusMeters: Int) async -> [PlaceResult] {
        // Check if API key is available
        guard !geographApiKey.isEmpty else {
            print("📸 Geograph: No API key configured - skipping")
            return []
        }
        
        // Convert radius from meters to kilometers (Geograph API uses km)
        let radiusKm = Double(radiusMeters) / 1000.0
        
        // Build API URL with location and distance parameters
        // Format: lat,lon (e.g., "53.3811,-1.4701")
        let locationString = "\(location.latitude),\(location.longitude)"
        
        // Geograph Syndicator API endpoint
        // Parameters:
        // - key: API key
        // - location: lat,lon or grid reference
        // - distance: radius in km
        // - perpage: max results (up to 1000)
        // - format: JSON
        // - ll: include lat/lon in response
        // - thumb: include thumbnail URL
        // - desc: include description
        let baseUrl = "https://api.geograph.org.uk/syndicator.php"
        var components = URLComponents(string: baseUrl)
        components?.queryItems = [
            URLQueryItem(name: "key", value: geographApiKey),
            URLQueryItem(name: "location", value: locationString),
            URLQueryItem(name: "distance", value: "\(Int(radiusKm))"),
            URLQueryItem(name: "perpage", value: "100"),
            URLQueryItem(name: "format", value: "JSON"),
            URLQueryItem(name: "ll", value: "1"),
            URLQueryItem(name: "thumb", value: "1"),
            URLQueryItem(name: "desc", value: "1")
        ]
        
        guard let url = components?.url else {
            print("📸 Geograph: Failed to build URL")
            return []
        }
        
        print("📸 Geograph: Requesting URL: \(url.absoluteString.replacingOccurrences(of: geographApiKey, with: "[API_KEY]"))")
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10  // 10 second timeout
        request.setValue("WalkingWR/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("📸 Geograph: Invalid response")
                return []
            }
            
            // Log response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("📸 Geograph: Response preview (first 500 chars): \(String(responseString.prefix(500)))")
            }
            
            guard httpResponse.statusCode == 200 else {
                print("📸 Geograph: HTTP error \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("📸 Geograph: Error response: \(errorString)")
                }
                return []
            }
            
            // Parse JSON response
            // Geograph API returns different formats depending on format parameter
            // For JSON format, it typically returns an array or object with items
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Try parsing as array
                if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    print("📸 Geograph: Parsed as array with \(jsonArray.count) items")
                    return parseGeographResults(jsonArray: jsonArray, location: location, radiusMeters: radiusMeters, sourceLabel: "")
                }
                print("📸 Geograph: Invalid JSON format - could not parse as object or array")
                print("📸 Geograph: Data size: \(data.count) bytes")
                return []
            }
            
            print("📸 Geograph: Parsed as object with keys: \(json.keys.joined(separator: ", "))")
            
            // Handle object format - look for items, entries, or similar keys
            if let items = json["items"] as? [[String: Any]] {
                print("📸 Geograph: Found 'items' array with \(items.count) items")
                return parseGeographResults(jsonArray: items, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            } else if let entries = json["entries"] as? [[String: Any]] {
                print("📸 Geograph: Found 'entries' array with \(entries.count) entries")
                return parseGeographResults(jsonArray: entries, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            } else if let jsonArray = json.values.first as? [[String: Any]] {
                print("📸 Geograph: Found array in first value with \(jsonArray.count) items")
                return parseGeographResults(jsonArray: jsonArray, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            }
            
            // Try to find any array in the JSON
            for (key, value) in json {
                if let array = value as? [[String: Any]] {
                    print("📸 Geograph: Found array in key '\(key)' with \(array.count) items")
                    return parseGeographResults(jsonArray: array, location: location, radiusMeters: radiusMeters, sourceLabel: "")
                }
            }
            
            print("📸 Geograph: Unexpected JSON structure - no arrays found")
            print("📸 Geograph: JSON keys: \(json.keys.joined(separator: ", "))")
            return []
            
        } catch {
            print("📸 Geograph: Network error - \(error.localizedDescription)")
            if let urlError = error as? URLError {
                print("📸 Geograph: URL error code: \(urlError.code.rawValue), description: \(urlError.localizedDescription)")
            }
            return []
        }
    }
    
    /// Helper to parse Geograph API results into PlaceResult objects
    private func parseGeographResults(jsonArray: [[String: Any]], location: CLLocationCoordinate2D, radiusMeters: Int, sourceLabel: String = "") -> [PlaceResult] {
        var results: [PlaceResult] = []
        let maxRealisticDistance = Double(radiusMeters) * 2.0
        
        let label = sourceLabel.isEmpty ? "Geograph" : "Geograph [\(sourceLabel)]"
        print("📸 \(label): Parsing \(jsonArray.count) items...")
        
        // Log first item structure for debugging
        if let firstItem = jsonArray.first {
            print("📸 \(label): First item keys: \(firstItem.keys.joined(separator: ", "))")
            if let firstItemJson = try? JSONSerialization.data(withJSONObject: firstItem, options: .prettyPrinted),
               let firstItemString = String(data: firstItemJson, encoding: .utf8) {
                print("📸 \(label): First item preview:\n\(String(firstItemString.prefix(1000)))")
            }
        }
        
        for (index, item) in jsonArray.enumerated() {
            // Extract title/name - try multiple possible field names
            var title: String?
            if let t = item["title"] as? String { title = t }
            else if let t = item["name"] as? String { title = t }
            else if let t = item["caption"] as? String { title = t }
            else if let t = item["subject"] as? String { title = t }
            
            guard let finalTitle = title, !finalTitle.isEmpty else {
                if index < 3 { // Log first few failures
                    print("📸 \(label): Item \(index) missing title/name - keys: \(item.keys.joined(separator: ", "))")
                }
                continue
            }
            
            // Extract coordinates - try multiple possible field names
            // Geograph API uses "lat" and "long" (not "lon") as strings
            var lat: Double?
            var lon: Double?
            
            // Try Geograph-specific format first: "lat" and "long" as strings
            if let latStr = item["lat"] as? String, let longStr = item["long"] as? String {
                lat = Double(latStr)
                lon = Double(longStr)
            }
            // Try "lat" and "lon" as strings
            else if let latStr = item["lat"] as? String, let lonStr = item["lon"] as? String {
                lat = Double(latStr)
                lon = Double(lonStr)
            }
            // Try "lat" and "lon" as numbers
            else if let latNum = item["lat"] as? Double, let lonNum = item["lon"] as? Double {
                lat = latNum
                lon = lonNum
            }
            // Try standard "latitude" and "longitude" as numbers
            else if let latitude = item["latitude"] as? Double, let longitude = item["longitude"] as? Double {
                lat = latitude
                lon = longitude
            }
            // Try standard "latitude" and "longitude" as strings
            else if let latitude = item["latitude"] as? String, let longitude = item["longitude"] as? String {
                lat = Double(latitude)
                lon = Double(longitude)
            }
            // Try nested objects
            else if let geo = item["geo"] as? [String: Any] {
                lat = geo["latitude"] as? Double ?? (geo["lat"] as? String).flatMap(Double.init)
                lon = geo["longitude"] as? Double ?? (geo["lon"] as? String ?? geo["long"] as? String).flatMap(Double.init)
            } else if let point = item["point"] as? [String: Any] {
                lat = point["latitude"] as? Double ?? (point["lat"] as? String).flatMap(Double.init)
                lon = point["longitude"] as? Double ?? (point["lon"] as? String ?? point["long"] as? String).flatMap(Double.init)
            } else if let locationObj = item["location"] as? [String: Any] {
                lat = locationObj["latitude"] as? Double ?? (locationObj["lat"] as? String).flatMap(Double.init)
                lon = locationObj["longitude"] as? Double ?? (locationObj["lon"] as? String ?? locationObj["long"] as? String).flatMap(Double.init)
            }
            
            guard let finalLat = lat, let finalLon = lon else {
                // Log ALL failures for postcode searches (not just first 3)
                let titleForLog = title ?? "unknown"
                let shouldLogAll = !sourceLabel.isEmpty  // Log all for postcode searches
                if shouldLogAll || index < 3 {
                    print("📸 \(label): Item \(index) '\(titleForLog)' missing coordinates")
                    print("📸 \(label):   Available keys: \(item.keys.joined(separator: ", "))")
                    // Try to show what coordinate fields exist
                    if let latVal = item["lat"], let lonVal = item["long"] {
                        print("📸 \(label):   Found lat=\(latVal), long=\(lonVal) (types: \(type(of: latVal)), \(type(of: lonVal)))")
                        // Try to parse them manually to see why it's failing
                        if let latStr = latVal as? String, let lonStr = lonVal as? String {
                            if let latParsed = Double(latStr), let lonParsed = Double(lonStr) {
                                print("📸 \(label):   ✅ Manual parse successful: lat=\(latParsed), lon=\(lonParsed)")
                            } else {
                                print("📸 \(label):   ❌ Manual parse failed: latStr='\(latStr)', lonStr='\(lonStr)'")
                            }
                        }
                    } else if let latVal = item["lat"] {
                        print("📸 \(label):   Found lat=\(latVal) but missing long")
                    } else if let lonVal = item["long"] {
                        print("📸 \(label):   Found long=\(lonVal) but missing lat")
                    } else {
                        print("📸 \(label):   No lat/long fields found")
                    }
                }
                continue
            }
            
            // Filter by distance (same as other sources)
            // Skip distance filter if location is (0,0) - means it's from postcode search
            let coordinate = CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon)
            let shouldFilterByDistance = !(location.latitude == 0 && location.longitude == 0)
            if shouldFilterByDistance {
                let distance = distanceBetween(location, coordinate)
                if distance > maxRealisticDistance {
                    continue
                }
            }
            
            // Extract description/vicinity if available
            let description = item["description"] as? String ?? item["desc"] as? String
            let vicinity = description?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Extract image ID for placeId
            let imageId = item["id"] as? Int ?? item["image_id"] as? Int ?? finalTitle.hashValue
            
            // Extract photographer/submitter info if available (for attribution)
            // Note: We store this in vicinity if not already set, or could be added to a future attribution field
            let submitter = item["submitter"] as? String ?? item["user"] as? String
            var finalVicinity = vicinity
            if let submitter = submitter, finalVicinity == nil {
                // Add photographer credit to vicinity if available
                finalVicinity = "Photo by \(submitter) / Geograph.org.uk"
            } else if let submitter = submitter, let existingVicinity = finalVicinity {
                // Append photographer credit if vicinity already exists
                finalVicinity = "\(existingVicinity) (Photo by \(submitter))"
            }
            
            // Create PlaceResult
            // Note: Geograph photos are CC BY-SA 2.0 - attribution should be shown when displaying
            let placeResult = PlaceResult(
                placeId: "geograph_\(imageId)",
                name: finalTitle,
                vicinity: finalVicinity,
                geometry: PlaceGeometry(
                    location: PlaceLocation(lat: finalLat, lng: finalLon)
                ),
                types: ["geograph_photo", "landmark"],  // Tag as Geograph photo/landmark
                source: .geograph
            )
            
            results.append(placeResult)
        }
        
        print("📸 \(label): Found \(results.count) POIs (from \(jsonArray.count) items)")
        return results
    }
```

---

## Step 5: Integrate Geograph into findNearbyPlaces()

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: In the `findNearbyPlaces()` function, after the cache hit section and before the parallel fetch section (around line 1330)

**Action**: Add Geograph fetching after other sources are processed:

```swift
            // Always fetch Geograph regardless of cache
            if !geographApiKey.isEmpty {
                let geographPOIs = await searchGeographForPOIs(location: location, radiusMeters: radiusMeters)
                
                // Filter by distance (relative to current location)
                let maxRealisticDistance = Double(radiusMeters) * 2.0
                let filteredGeographPOIs = geographPOIs.filter { poi in
                    let distance = distanceBetween(location, poi.coordinate)
                    return distance <= maxRealisticDistance
                }
                
                // Merge with existing results - use less aggressive deduplication for Geograph
                // Geograph photos can be of the same location but different angles/views, so we want to keep them
                let beforeCount = allResults.count
                var addedCount = 0
                
                for geographPOI in filteredGeographPOIs {
                    // Check if this Geograph POI is a duplicate of existing POIs
                    // Use stricter matching: same name AND very close (10m), OR exact same location (5m)
                    let isDuplicate = allResults.contains { existing in
                        let distance = distanceBetween(existing.coordinate, geographPOI.coordinate)
                        // Only consider duplicate if:
                        // 1. Same name AND within 10m (stricter than normal 50m)
                        // 2. OR exact same location (within 5m, stricter than normal 20m)
                        let sameNameAndVeryClose = existing.name.lowercased() == geographPOI.name.lowercased() && distance < 10
                        let exactSameLocation = distance < 5
                        return sameNameAndVeryClose || exactSameLocation
                    }
                    
                    if !isDuplicate {
                        allResults.append(geographPOI)
                        addedCount += 1
                    }
                }
                
                // Final deduplication pass on all results (in case Geograph POIs duplicate each other)
                let beforeFinalDedup = allResults.count
                allResults = deduplicatePOIs(allResults)
                let finalAdded = allResults.count - beforeCount
                let removedInFinalDedup = beforeFinalDedup - allResults.count
                
                // Count how many Geograph POIs are in final results
                let geographInFinal = allResults.filter { $0.source == .geograph }.count
                
                print("📸 Geograph: Successfully integrated!")
                print("   📊 Fetched: \(geographPOIs.count) POIs")
                print("   ✅ Passed initial check: \(addedCount) POIs")
                print("   🔄 Removed in final dedup: \(removedInFinalDedup) POIs")
                print("   📍 Final Geograph POIs in results: \(geographInFinal)")
                print("   📈 Net added: \(finalAdded) total new POIs (including Geograph)")
            }
```

**Note**: This code should be placed AFTER the cache hit section processes results, but BEFORE the final return statement. It runs regardless of cache status to always include fresh Geograph results.

---

## Step 6: Add Geograph to Parallel Fetch (Optional Enhancement)

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: In the parallel fetch section of `findNearbyPlaces()` (around line 1459)

**Action**: Add Geograph to the parallel fetch sources:

Find the section that creates `SourcedPOIs` for different sources and add:

```swift
                    // 📸 Geograph (FREE, experimental - requires API key)
                    if !geographApiKey.isEmpty {
                        Task {
                            let pois = await self.searchGeographForPOIs(location: location, radiusMeters: radiusMeters)
                            // Already tagged with source in searchGeographForPOIs
                            return SourcedPOIs(source: .geograph, pois: pois)
                        }
                    }
```

**Note**: This is optional - the main integration in Step 5 is sufficient. This adds Geograph to the parallel fetch for better performance during cache misses.

---

## Step 7: Update Logging to Include Geograph Count

**File**: `WalkingWR/Services/GoogleMapsService.swift`

**Location**: In any summary logging sections that list POI counts

**Action**: Add Geograph count to logging statements. For example:

```swift
print("📊 Sources: Google=\(googleCount), Apple=\(appleCount), OSM=\(osmCount), Geograph=\(geographCount)")
```

---

## Step 8: Request Geograph API Key

**Action**: Visit https://www.geograph.org.uk/help/api and request an API key.

**Required Information**:
- Project name: WalkingWR
- Project URL: (your app URL)
- Intended use: POI/landmark identification for walking route generation
- Contact email: (your email)

**Note**: The API key is free but requires approval. You can test without it (app will skip Geograph gracefully).

---

## Step 9: Testing

1. **Build the project** - Should compile without errors
2. **Test without API key**:
   - Leave `GEOGRAPH_API_KEY` empty in Info.plist
   - Run the app and trigger a POI search
   - Check logs for: `📸 Geograph: No API key configured - skipping`
   - App should work normally without Geograph
3. **Test with API key**:
   - Add your API key to Info.plist
   - Clear POI cache (or use a new location)
   - Trigger a POI search
   - Check logs for Geograph results
   - Verify POIs include `.geograph` source
4. **Verify in route generation**:
   - Generate a route
   - Check that Geograph POIs appear in route waypoints
   - Verify attribution is included in POI details

---

## Important Notes

1. **License Compliance**: Geograph photos are CC BY-SA 2.0. When displaying Geograph POIs:
   - Credit the photographer (stored in `vicinity` field)
   - Credit Geograph.org.uk
   - Include license information if displaying photos

2. **API Key Security**: The API key is stored in Info.plist. For production, consider:
   - Using a backend proxy to hide the key
   - Or keeping it in Info.plist (acceptable for this use case as it's a public API)

3. **Graceful Degradation**: The app works perfectly fine without a Geograph API key - it simply skips Geograph and uses the other 3 sources.

4. **Performance**: Geograph API has a 10-second timeout. It runs in parallel with other sources, so it won't slow down the main POI fetch.

5. **Coverage**: Geograph primarily covers Great Britain and Ireland. Results may be limited outside these areas.

---

## Summary of Changes

- ✅ Added `.geograph` to `POISource` enum
- ✅ Added `geographApiKey` property
- ✅ Added `GEOGRAPH_API_KEY` to Info.plist
- ✅ Added `searchGeographForPOIs()` function (~280 lines)
- ✅ Added `parseGeographResults()` helper function
- ✅ Integrated Geograph into `findNearbyPlaces()`
- ✅ Updated logging to include Geograph counts

**Total Lines Added**: ~350 lines of code

---

## Verification Checklist

- [ ] Code compiles without errors
- [ ] Geograph enum case added
- [ ] API key property added
- [ ] Info.plist updated (with or without API key)
- [ ] `searchGeographForPOIs()` function added
- [ ] `parseGeographResults()` helper added
- [ ] Integration code added to `findNearbyPlaces()`
- [ ] Logging includes Geograph counts
- [ ] Tested without API key (graceful skip)
- [ ] Tested with API key (returns results)
- [ ] Geograph POIs appear in routes
- [ ] Attribution is preserved

---

## API Key Example

In `Info.plist` (values come from Secrets.xcconfig at build time):
```xml
<key>GEOGRAPH_API_KEY</key>
<string>$(GEOGRAPH_API_KEY)</string>
```

**Note**: Set `GEOGRAPH_API_KEY` in Secrets.xcconfig (or get your key from Geograph.org.uk). For Python scripts, set the `GEOGRAPH_API_KEY` environment variable.
