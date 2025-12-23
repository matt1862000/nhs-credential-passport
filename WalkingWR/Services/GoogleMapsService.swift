//
//  GoogleMapsService.swift
//  WalkingWR
//
//  Created for local route generation using Google APIs
//

import Foundation
import CoreLocation
import MapKit

// MARK: - MapKit Rate Limiter
/// Prevents hitting Apple's 50 requests/60 seconds limit
actor MapKitRateLimiter {
    static let shared = MapKitRateLimiter()
    
    private var requestTimes: [Date] = []
    private let maxRequests = 40  // Stay under 50 limit with buffer
    private let windowSeconds: TimeInterval = 60
    private var isThrottled = false
    private var throttleResetTime: Date?
    
    /// Wait if necessary before making a request
    func waitForSlot() async {
        // If throttled, wait until reset time
        if isThrottled, let resetTime = throttleResetTime {
            let waitTime = resetTime.timeIntervalSinceNow
            if waitTime > 0 {
                print("⏳ MapKit throttled - waiting \(Int(waitTime))s...")
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            isThrottled = false
            requestTimes.removeAll()
        }
        
        // Clean old requests outside the window
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        requestTimes = requestTimes.filter { $0 > cutoff }
        
        // If at limit, wait for oldest request to expire
        if requestTimes.count >= maxRequests {
            if let oldest = requestTimes.first {
                let waitTime = oldest.timeIntervalSinceNow + windowSeconds + 1
                if waitTime > 0 {
                    print("⏳ MapKit rate limit - waiting \(Int(waitTime))s for slot...")
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                    requestTimes.removeAll { $0 <= oldest }
                }
            }
        }
        
        requestTimes.append(Date())
    }
    
    /// Mark that we've been throttled by Apple
    func markThrottled(resetInSeconds: TimeInterval = 60) {
        isThrottled = true
        throttleResetTime = Date().addingTimeInterval(resetInSeconds)
        print("🛑 MapKit throttled! Will retry after \(Int(resetInSeconds))s")
    }
    
    /// Get current request count in window
    func currentCount() -> Int {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        return requestTimes.filter { $0 > cutoff }.count
    }
}

// MARK: - Google Maps Service
class GoogleMapsService: ObservableObject {
    static let shared = GoogleMapsService()
    
    // API Key - bundled with app in Info.plist
    // For production, consider using a backend proxy to hide the key
    private var apiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String ?? ""
    }
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let session = URLSession.shared
    private let rateLimiter = MapKitRateLimiter.shared
    
    // MARK: - Find Nearby Places
    /// Finds points of interest near a location using Google Places API
    /// Searches multiple place types in parallel for maximum variety
    /// Uses POI cache to reduce API calls - POIs don't move!
    func findNearbyPlaces(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500,
        types: [String] = ["point_of_interest"]
    ) async throws -> [PlaceResult] {
        
        // 🎯 CHECK CACHE FIRST - Save £££ on API calls!
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: location) {
            let stats = POICacheService.shared.getCacheStats()
            print("💰 SAVED API CALLS! Using \(cachedPOIs.count) cached POIs (\(stats.locations) locations cached)")
            return cachedPOIs
        }
        
        guard !apiKey.isEmpty else {
            throw GoogleMapsError.missingAPIKey
        }
        
        // Search multiple specific types in parallel to maximize POI variety
        // Google's default "prominence" ranking favors famous places over local businesses
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
                        print("🗺️ Search failed for type '\(placeType)': \(error)")
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
        
        print("🗺️ Multi-type search found \(allResults.count) unique POIs from \(placeTypesToSearch.count) categories")
        
        // 💾 CACHE RESULTS - Next time at this location = FREE!
        if !allResults.isEmpty {
            POICacheService.shared.cachePOIs(allResults, for: location)
            print("💰 Cached \(allResults.count) POIs - future calls at this location will be FREE!")
        }
        
        return allResults
    }
    
    /// Search for a single place type
    private func searchSingleType(
        location: CLLocationCoordinate2D,
        radiusMeters: Int,
        type: String
    ) async throws -> [PlaceResult] {
        var urlString = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?"
        urlString += "location=\(location.latitude),\(location.longitude)"
        urlString += "&radius=\(radiusMeters)"
        urlString += "&type=\(type)"
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            throw GoogleMapsError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GoogleMapsError.serverError
        }
        
        let placesResponse = try JSONDecoder().decode(PlacesResponse.self, from: data)
        
        if placesResponse.status != "OK" && placesResponse.status != "ZERO_RESULTS" {
            throw GoogleMapsError.apiError(placesResponse.status)
        }
        
        return placesResponse.results
    }
    
    // MARK: - Get Walking Directions (Apple MapKit - FREE!)
    /// Gets walking directions between points using Apple MapKit (FREE, unlimited!)
    /// Replaces Google Directions API to eliminate costs
    func getWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = []
    ) async throws -> DirectionsResult {
        
        // Build list of all points: origin → waypoints → destination
        var allPoints = [origin] + waypoints + [destination]
        
        // For circular routes (origin == destination), we need at least one waypoint
        if waypoints.isEmpty && origin.latitude == destination.latitude && origin.longitude == destination.longitude {
            throw GoogleMapsError.noRouteFound
        }
        
        var allLegs: [DirectionsLeg] = []
        var totalDistance: Int = 0
        var totalDuration: Int = 0
        var allPolylinePoints: [CLLocationCoordinate2D] = []
        var optimizedWaypointOrder: [Int]? = nil
        
        // If we have waypoints, try to optimize their order (simple nearest-neighbor)
        if waypoints.count > 1 {
            let optimized = optimizeWaypointOrder(from: origin, waypoints: waypoints, to: destination)
            allPoints = [origin] + optimized.waypoints + [destination]
            optimizedWaypointOrder = optimized.order
            print("🍎 MapKit: Optimized waypoint order: \(optimized.order)")
        } else if waypoints.count == 1 {
            optimizedWaypointOrder = [0] // Single waypoint, no reordering needed
        }
        
        // Calculate directions for each leg (point to point)
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            // Wait for rate limiter slot before making request
            await rateLimiter.waitForSlot()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            
            let response: MKDirections.Response
            do {
                response = try await directions.calculate()
            } catch let error as NSError {
                // Check if this is a throttle error
                if error.domain == "GEOErrorDomain" && error.code == -3 {
                    // Extract reset time from error if available
                    let resetTime = error.userInfo["timeUntilReset"] as? TimeInterval ?? 60
                    await rateLimiter.markThrottled(resetInSeconds: resetTime + 1)
                    print("🍎 MapKit leg \(i+1) throttled - will retry after wait")
                    throw GoogleMapsError.noRouteFound
                }
                print("🍎 MapKit leg \(i+1) failed: \(error.localizedDescription)")
                throw GoogleMapsError.noRouteFound
            }
            
            guard let route = response.routes.first else {
                throw GoogleMapsError.noRouteFound
            }
            
            // Extract polyline points
            let polyline = route.polyline
            let pointCount = polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            
            // Append to overall polyline (skip first point of subsequent legs to avoid duplicates)
            if allPolylinePoints.isEmpty {
                allPolylinePoints.append(contentsOf: coords)
            } else {
                allPolylinePoints.append(contentsOf: coords.dropFirst())
            }
            
            // Extract step-by-step directions from MapKit
            var legSteps: [DirectionsStep] = []
            for step in route.steps {
                // Skip steps with no instructions (usually the first "depart" step)
                guard !step.instructions.isEmpty else { continue }
                
                let stepDistance = Int(step.distance)
                // Estimate duration based on walking speed (~80m/min)
                let stepDuration = max(1, stepDistance / 80) * 60
                
                // Encode step polyline
                let stepPolylineCount = step.polyline.pointCount
                var stepCoords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: stepPolylineCount)
                step.polyline.getCoordinates(&stepCoords, range: NSRange(location: 0, length: stepPolylineCount))
                let stepPolylineEncoded = encodePolyline(stepCoords)
                
                let directionsStep = DirectionsStep(
                    distance: DirectionsValue(text: formatDistance(stepDistance), value: stepDistance),
                    duration: DirectionsValue(text: formatDuration(stepDuration), value: stepDuration),
                    htmlInstructions: step.instructions,
                    polyline: StepPolyline(points: stepPolylineEncoded)
                )
                legSteps.append(directionsStep)
            }
            
            // Create leg data
            let legDistance = Int(route.distance)
            let legDuration = Int(route.expectedTravelTime)
            totalDistance += legDistance
            totalDuration += legDuration
            
            let leg = DirectionsLeg(
                distance: DirectionsValue(text: formatDistance(legDistance), value: legDistance),
                duration: DirectionsValue(text: formatDuration(legDuration), value: legDuration),
                startAddress: nil,
                endAddress: nil,
                steps: legSteps.isEmpty ? nil : legSteps
            )
            allLegs.append(leg)
        }
        
        // Encode combined polyline to Google's format (for compatibility)
        let encodedPolyline = encodePolyline(allPolylinePoints)
        
        print("🍎 MapKit: \(allLegs.count) legs, \(totalDistance)m, \(totalDuration/60)min (FREE!)")
        
        return DirectionsResult(
            legs: allLegs,
            overviewPolyline: OverviewPolyline(points: encodedPolyline),
            summary: nil,
            warnings: nil,
            waypointOrder: optimizedWaypointOrder
        )
    }
    
    // MARK: - Waypoint Optimization (Nearest Neighbor)
    /// Simple nearest-neighbor algorithm to order waypoints efficiently
    private func optimizeWaypointOrder(
        from origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        to destination: CLLocationCoordinate2D
    ) -> (waypoints: [CLLocationCoordinate2D], order: [Int]) {
        var remaining = Array(waypoints.enumerated())
        var ordered: [CLLocationCoordinate2D] = []
        var orderIndices: [Int] = []
        var currentPoint = origin
        
        while !remaining.isEmpty {
            // Find nearest unvisited waypoint
            let nearest = remaining.min(by: { 
                distanceBetween(currentPoint, $0.element) < distanceBetween(currentPoint, $1.element)
            })!
            
            ordered.append(nearest.element)
            orderIndices.append(nearest.offset)
            currentPoint = nearest.element
            remaining.removeAll { $0.offset == nearest.offset }
        }
        
        return (ordered, orderIndices)
    }
    
    // MARK: - Polyline Encoding (Google format for compatibility)
    /// Encodes coordinates to Google's polyline format
    private func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encodedString = ""
        var prevLat: Int = 0
        var prevLng: Int = 0
        
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            
            encodedString += encodeSignedNumber(lat - prevLat)
            encodedString += encodeSignedNumber(lng - prevLng)
            
            prevLat = lat
            prevLng = lng
        }
        
        return encodedString
    }
    
    private func encodeSignedNumber(_ num: Int) -> String {
        var sgn_num = num << 1
        if num < 0 {
            sgn_num = ~sgn_num
        }
        return encodeNumber(sgn_num)
    }
    
    private func encodeNumber(_ num: Int) -> String {
        var encoded = ""
        var number = num
        
        while number >= 0x20 {
            let nextValue = (0x20 | (number & 0x1f)) + 63
            encoded += String(UnicodeScalar(nextValue)!)
            number >>= 5
        }
        encoded += String(UnicodeScalar(number + 63)!)
        
        return encoded
    }
    
    // MARK: - Formatting Helpers
    private func formatDistance(_ meters: Int) -> String {
        if meters < 1000 {
            return "\(meters) m"
        } else {
            return String(format: "%.1f km", Double(meters) / 1000.0)
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins < 60 {
            return "\(mins) mins"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(hours) hour\(hours > 1 ? "s" : "") \(remainingMins) mins"
        }
    }
    
    // MARK: - Retry Status
    @Published var retryStatus: String?
    
    // MARK: - Generate Route with Auto-Retry
    /// Wrapper that implements multi-stage retry:
    /// 1. Random selection (fast)
    /// 2. If fails: Systematic selection with expanded search
    /// 3. If still fails: Try shorter durations (drop 5 min at a time)
    /// 4. If all fails: Throw no route found
    func generateLocalRouteWithRetry(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        
        // Stage 1: Random selection (current behavior)
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                prefetchedPOIs: prefetchedPOIs,
                useSystematicSelection: false
            )
            await MainActor.run { retryStatus = nil }
            return route
        } catch {
            print("🔄 Stage 1 (random) failed, trying systematic...")
        }
        
        // Stage 2: Systematic selection with expanded search
        await MainActor.run { retryStatus = "Retrying with expanded search..." }
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                prefetchedPOIs: nil,  // Fresh POI fetch with larger radius
                useSystematicSelection: true,
                expandedSearch: true
            )
            await MainActor.run { retryStatus = nil }
            return route
        } catch {
            print("🔄 Stage 2 (systematic) failed, trying shorter durations...")
        }
        
        // Stage 3: Try shorter durations (drop 5 min at a time, but not below 5 min)
        for reducedDuration in stride(from: targetDurationMinutes - 5, through: 5, by: -5) {
            let currentDuration = reducedDuration  // Capture for concurrent access
            await MainActor.run { retryStatus = "Trying \(currentDuration) min route..." }
            do {
                let route = try await generateLocalRoute(
                    from: location,
                    targetDurationMinutes: currentDuration,
                    difficulty: difficulty,
                    excludePlaceIds: excludePlaceIds,
                    prefetchedPOIs: nil,
                    useSystematicSelection: true,
                    expandedSearch: true
                )
                await MainActor.run { retryStatus = nil }
                print("🔄 Found route at \(currentDuration) min (originally requested \(targetDurationMinutes) min)")
                return route
            } catch {
                print("🔄 \(currentDuration) min also failed...")
            }
        }
        
        // All stages failed
        await MainActor.run { retryStatus = nil }
        throw GoogleMapsError.noRouteFound
    }
    
    // MARK: - Generate Local Walking Route
    /// Generates a circular walking route from user's location using nearby POIs
    /// DYNAMICALLY adjusts number of waypoints to match target duration
    /// Keeps trying different combinations until within ±3 minutes of target
    /// - Parameter prefetchedPOIs: Optional pre-fetched POIs to skip the Places API call (faster generation)
    /// - Parameter useSystematicSelection: If true, tries POI combinations in order of likelihood to succeed
    /// - Parameter expandedSearch: If true, uses larger search radius
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        prefetchedPOIs: [PlaceResult]? = nil,
        useSystematicSelection: Bool = false,
        expandedSearch: Bool = false
    ) async throws -> GeneratedRoute {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        // ADAPTIVE TIMING: More flexible for short routes in dense urban areas
        // Short routes (≤15 min): 50-100% acceptable (dense areas have clustered POIs)
        // Medium routes (16-30 min): 65-100% acceptable
        // Long routes (>30 min): 75-100% acceptable (more options available)
        // When in expanded search mode, be even more flexible
        let minPercent: Double
        if expandedSearch {
            minPercent = 0.40  // Very flexible during retry
        } else if targetDurationMinutes <= 15 {
            minPercent = 0.50  // Very flexible for short routes
        } else if targetDurationMinutes <= 30 {
            minPercent = 0.65  // Moderately flexible
        } else {
            minPercent = 0.75  // Standard for long routes
        }
        
        let minAcceptableMinutes = max(1, Int(Double(targetDurationMinutes) * minPercent))
        // Allow 20% over target - MapKit routing is unpredictable (follows roads, not straight lines)
        let maxAcceptableMinutes = Int(Double(targetDurationMinutes) * 1.2)
        let minAcceptableDuration = minAcceptableMinutes * 60
        let maxAcceptableDuration = maxAcceptableMinutes * 60
        
        print("🗺️ ADAPTIVE: \(minAcceptableMinutes)min to \(maxAcceptableMinutes)min (\(Int(minPercent * 100))-120% of \(targetDurationMinutes)min)")
        
        // Walking speed ~80m/min
        let walkingSpeedMeterPerMin = 80
        let totalDistanceTarget = targetDurationMinutes * walkingSpeedMeterPerMin
        
        // Search radius - LARGER for short routes to find POIs at better distances
        // In dense areas, nearby POIs are too close for a proper loop
        // Expanded search uses 2x radius to find more options
        let baseRadius = max(600, totalDistanceTarget / 2)
        let searchRadius: Int
        if expandedSearch {
            searchRadius = baseRadius * 2  // Double radius for retry
        } else if targetDurationMinutes <= 15 {
            searchRadius = max(800, baseRadius * 3 / 2)
        } else {
            searchRadius = baseRadius
        }
        
        let searchMode = expandedSearch ? "EXPANDED" : (useSystematicSelection ? "SYSTEMATIC" : "RANDOM")
        print("🗺️ Target: \(targetDurationMinutes)min [\(searchMode)]")
        print("🗺️ Search radius: \(searchRadius)m")
        
        // Step 1: Find nearby POIs - use pre-fetched if available (faster!)
        let desiredSpots = max(2, targetDurationMinutes / 5)
        var places: [PlaceResult]
        
        if let prefetched = prefetchedPOIs, !prefetched.isEmpty {
            // Use pre-fetched POIs - skip API call!
            places = prefetched
            print("🗺️ ⚡ Using \(places.count) pre-fetched POIs (faster!)")
        } else {
            // Fetch POIs now
            places = try await findNearbyPlaces(
                location: location,
                radiusMeters: searchRadius
            )
            print("🗺️ Found \(places.count) POIs (need \(desiredSpots) for route)")
        }
        
        // Filter out previously shown places to ensure variety
        if !excludePlaceIds.isEmpty {
            let beforeCount = places.count
            places = places.filter { !excludePlaceIds.contains($0.placeId) }
            print("🗺️ Excluded \(beforeCount - places.count) previously shown POIs, \(places.count) remaining")
        }
        
        // For longer routes OR short routes with few POIs, do additional searches at different points
        // Short routes in dense areas need POIs at BETTER distances, not just more nearby ones
        let needsMorePOIs = places.count < desiredSpots * 2 || 
                           (targetDurationMinutes <= 15 && places.count < 10)
        if needsMorePOIs {
            print("🗺️ Fetching more POIs for \(targetDurationMinutes)min route...")
            
            // Search at cardinal directions from origin
            let offsetDistance = 0.005 // ~500m in lat/lng
            let searchOffsets = [
                (lat: offsetDistance, lng: 0.0),
                (lat: -offsetDistance, lng: 0.0),
                (lat: 0.0, lng: offsetDistance),
                (lat: 0.0, lng: -offsetDistance)
            ]
            
            for offset in searchOffsets {
                let offsetLocation = CLLocationCoordinate2D(
                    latitude: location.latitude + offset.lat,
                    longitude: location.longitude + offset.lng
                )
                if let morePlaces = try? await findNearbyPlaces(
                    location: offsetLocation,
                    radiusMeters: 800
                ) {
                    for place in morePlaces {
                        if !places.contains(where: { $0.placeId == place.placeId }) {
                            places.append(place)
                        }
                    }
                }
                
                // Stop if we have enough
                if places.count >= desiredSpots * 3 { break }
            }
            print("🗺️ Now have \(places.count) total POIs")
        }
        
        guard !places.isEmpty else {
            throw GoogleMapsError.noPlacesFound
        }
        
        print("🗺️ Have \(places.count) POIs to select from")
        
        // Step 3: MAXIMIZE POIs while staying within time limit
        var validRoutes: [GeneratedRoute] = []
        var bestFallbackRoute: GeneratedRoute?
        var bestFallbackDiff = Int.max
        
        // PRIORITY: 1) Timing within tolerance  2) Maximum POIs
        // Strategy: Start with realistic waypoint count based on duration
        // MapKit routes follow roads (not straight lines), adding ~50% overhead
        
        // Realistic waypoints based on actual MapKit routing behavior:
        // - Each waypoint adds ~3-4 min to route (road following overhead)
        // - 10 min walk → 2-3 waypoints max
        // - 15 min walk → 3-4 waypoints max
        // - 20 min walk → 4-5 waypoints max
        let maxWaypoints: Int
        if targetDurationMinutes <= 10 {
            maxWaypoints = min(3, places.count)  // 10 min: max 3 waypoints
        } else if targetDurationMinutes <= 15 {
            maxWaypoints = min(4, places.count)  // 15 min: max 4 waypoints
        } else if targetDurationMinutes <= 20 {
            maxWaypoints = min(5, places.count)  // 20 min: max 5 waypoints
        } else {
            maxWaypoints = min(targetDurationMinutes / 4, 8, places.count)  // Longer: ~1 per 4 min
        }
        
        // Try waypoint counts in DESCENDING order (most first, then fewer)
        // First valid route (within tolerance) wins - maximizing POI count
        let waypointCountsToTry = Array((1...maxWaypoints).reversed())
        
        print("🗺️ Will try waypoint counts: \(waypointCountsToTry) (maximize POIs within 125% time)")
        
        var totalAttempts = 0
        // REDUCED to respect MapKit rate limit (50 req/60s)
        // Each attempt with N waypoints = N+1 MapKit requests
        // So 5 waypoints = 6 requests. Keep total attempts low!
        let maxTotalAttempts: Int
        if expandedSearch || useSystematicSelection {
            maxTotalAttempts = 8  // Reduced from 50
        } else if targetDurationMinutes <= 15 {
            maxTotalAttempts = 6  // Reduced from 35
        } else {
            maxTotalAttempts = 5  // Reduced from 25
        }
        
        for waypointCount in waypointCountsToTry {
            guard totalAttempts < maxTotalAttempts else { break }
            guard validRoutes.count < 3 else { break } // Stop if we have enough valid routes
            
            // IMPORTANT: Scale ideal distance based on waypoint count
            // For circular route: total segments = waypointCount + 1
            // Each segment = totalDistance / (waypointCount + 1)
            // Ideal waypoint distance = varies, but roughly totalDistance / 2 for the furthest point
            let segmentsInRoute = waypointCount + 1
            let idealSegmentDistance = totalDistanceTarget / segmentsInRoute
            
            // Re-select candidates with appropriate distance for this waypoint count
            let candidatesForCount = selectCandidateWaypoints(
                from: places,
                origin: location,
                idealWaypointDistance: idealSegmentDistance,
                difficulty: difficulty
            )
            
            print("🗺️ --- Trying \(waypointCount) waypoint(s) (ideal segment: \(idealSegmentDistance)m) ---")
            
            guard candidatesForCount.count >= waypointCount else {
                print("🗺️ Not enough candidates (\(candidatesForCount.count)) for \(waypointCount) waypoints")
                continue
            }
            
            // Try multiple combinations with this waypoint count
            // FIRST attempt uses best candidates (deterministic), then randomize for variety
            // REDUCED to avoid MapKit rate limiting (50 req/60s)
            let combinationsToTry = min(3, candidatesForCount.count)
            var triedCombinations = Set<String>()
            
            for comboIndex in 0..<combinationsToTry {
                guard totalAttempts < maxTotalAttempts else { break }
                
                var selectedWaypoints: [PlaceResult] = []
                
                if comboIndex == 0 {
                    // FIRST ATTEMPT: Select angularly diverse waypoints for better loops
                    selectedWaypoints = selectAngularlyDiverseWaypoints(
                        from: candidatesForCount,
                        origin: location,
                        count: waypointCount
                    )
                } else {
                    // SUBSEQUENT ATTEMPTS: Use weighted randomization for variety
                    var availableIndices = Array(0..<candidatesForCount.count)
                    
                    for _ in 0..<waypointCount {
                        guard !availableIndices.isEmpty else { break }
                        
                        // Weighted random: prefer lower indices (better candidates) but allow variety
                        let weights = availableIndices.map { idx in 
                            exp(-Double(idx) * 0.3)  // Decay factor
                        }
                        let totalWeight = weights.reduce(0, +)
                        var random = Double.random(in: 0..<totalWeight)
                        
                        var selectedIdx = 0
                        for (i, weight) in weights.enumerated() {
                            random -= weight
                            if random <= 0 {
                                selectedIdx = i
                                break
                            }
                        }
                        
                        let candidateIndex = availableIndices[selectedIdx]
                        selectedWaypoints.append(candidatesForCount[candidateIndex])
                        availableIndices.remove(at: selectedIdx)
                    }
                }
                
                guard selectedWaypoints.count == waypointCount else { continue }
                
                // Skip if we've already tried this exact combination
                let comboKey = selectedWaypoints.map { $0.placeId }.sorted().joined(separator: ",")
                guard !triedCombinations.contains(comboKey) else { continue }
                triedCombinations.insert(comboKey)
                
                totalAttempts += 1
                let waypointNames = selectedWaypoints.prefix(3).map { $0.name }.joined(separator: ", ")
                let suffix = selectedWaypoints.count > 3 ? "..." : ""
                print("🗺️ Attempt \(totalAttempts): \(waypointCount) POIs [\(waypointNames)\(suffix)]")
                
                // Small delay between attempts to respect rate limits
                if totalAttempts > 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 second
                }
                
                // Try this combination
                if let route = await tryRouteAndEvaluate(
                    origin: location,
                    waypoints: selectedWaypoints,
                    targetDurationMinutes: targetDurationMinutes,
                    minAcceptable: minAcceptableDuration,
                    maxAcceptable: maxAcceptableDuration,
                    validRoutes: &validRoutes,
                    bestFallback: &bestFallbackRoute,
                    bestFallbackDiff: &bestFallbackDiff
                ) {
                    let routeMins = route.durationSeconds / 60
                    // Since we try DESCENDING (most waypoints first):
                    // If route is within tolerance, we found a good one with max POIs
                    if routeMins >= minAcceptableMinutes && routeMins <= maxAcceptableMinutes {
                        print("🗺️ ✓ Found valid route with \(waypointCount) POIs")
                    }
                    // If route is too long, continue to try fewer waypoints
                    if routeMins > maxAcceptableMinutes {
                        print("🗺️ Route too long (\(routeMins)min), trying fewer waypoints...")
                    }
                }
            }
        }
        
        // Return best valid route (50-100% of target, never exceeds)
        // PRIORITY: 1) Most waypoints  2) Less backtracking  3) Closest to target time
        if !validRoutes.isEmpty {
            // Calculate backtracking scores for all valid routes
            let routesWithScores = validRoutes.map { route -> (route: GeneratedRoute, backtrackScore: Double) in
                let score = calculateBacktrackingScore(polyline: route.polyline)
                return (route, score)
            }
            
            // Sort by: most waypoints, then least backtracking, then closest to target
            let sorted = routesWithScores.sorted { r1, r2 in
                // First: more waypoints is better
                if r1.route.places.count != r2.route.places.count {
                    return r1.route.places.count > r2.route.places.count
                }
                // Second: less backtracking is better (lower score = more loop-like)
                if abs(r1.backtrackScore - r2.backtrackScore) > 0.1 {
                    return r1.backtrackScore < r2.backtrackScore
                }
                // Third: closer to target is better (all are at or under)
                let diff1 = targetDurationMinutes - r1.route.durationSeconds / 60
                let diff2 = targetDurationMinutes - r2.route.durationSeconds / 60
                return diff1 < diff2  // Prefer routes closer to target
            }
            
            var selected = sorted.first!.route
            let selectedScore = sorted.first!.backtrackScore
            print("🗺️ Route backtracking score: \(String(format: "%.0f", selectedScore * 100))% (lower = more loop-like)")
            
            // Remove waypoints that are too close together (within 100m)
            selected = removeCloseWaypoints(from: selected, minDistance: 100)
            
            let finalMins = selected.durationSeconds / 60
            print("🗺️ ✓ SUCCESS! Selected: \(finalMins)min, \(selected.places.count) POIs (target: \(targetDurationMinutes)min)")
            
            return selected
        }
        
        // Only return fallback if it meets minimum duration (75% of target)
        if var best = bestFallbackRoute {
            let mins = best.durationSeconds / 60
            
            // Check if fallback meets minimum threshold
            if mins >= minAcceptableMinutes {
                // Remove waypoints that are too close together
                best = removeCloseWaypoints(from: best, minDistance: 100)
                print("🗺️ ⚠️ Using fallback route: \(mins)min with \(best.places.count) POIs (target: \(targetDurationMinutes)min, min: \(minAcceptableMinutes)min)")
                return best
            } else {
                print("🗺️ ❌ Fallback route too short: \(mins)min (need at least \(minAcceptableMinutes)min)")
            }
        }
        
        throw GoogleMapsError.noRouteFound
    }
    
    /// Calculate how much a route backtracks on itself (0.0 = perfect loop, 1.0 = complete out-and-back)
    /// Compares outbound path to return path - if they overlap significantly, score is high
    private func calculateBacktrackingScore(polyline: String) -> Double {
        let points = decodePolyline(polyline)
        guard points.count >= 4 else { return 0.5 }  // Not enough points to analyze
        
        // Split route at midpoint
        let midIndex = points.count / 2
        let outbound = Array(points.prefix(midIndex))
        let returnPath = Array(points.suffix(from: midIndex))
        
        guard !outbound.isEmpty && !returnPath.isEmpty else { return 0.5 }
        
        // Sample points from return path and check how close they are to outbound path
        let sampleCount = min(10, returnPath.count)
        let sampleInterval = max(1, returnPath.count / sampleCount)
        
        var closePointCount = 0
        let closeThresholdMeters: Double = 30  // Points within 30m are considered "same path"
        
        for i in stride(from: 0, to: returnPath.count, by: sampleInterval) {
            let returnPoint = returnPath[i]
            
            // Check if this return point is close to any outbound point
            let isCloseToOutbound = outbound.contains { outboundPoint in
                distanceBetween(outboundPoint, returnPoint) < closeThresholdMeters
            }
            
            if isCloseToOutbound {
                closePointCount += 1
            }
        }
        
        let sampledPoints = (returnPath.count + sampleInterval - 1) / sampleInterval
        let backtrackRatio = Double(closePointCount) / Double(max(1, sampledPoints))
        
        return backtrackRatio  // 0.0 = no overlap (good loop), 1.0 = full overlap (out-and-back)
    }
    
    /// Remove waypoints that are too close together (keeps first one in each cluster)
    private func removeCloseWaypoints(from route: GeneratedRoute, minDistance: Double) -> GeneratedRoute {
        guard route.places.count > 1 else { return route }
        
        var filteredPlaces: [PlaceResult] = []
        
        for place in route.places {
            // Check if this place is too close to any already-kept place
            let tooClose = filteredPlaces.contains { kept in
                distanceBetween(kept.coordinate, place.coordinate) < minDistance
            }
            
            if !tooClose {
                filteredPlaces.append(place)
            } else {
                print("🗺️ Removed '\(place.name)' - too close to another waypoint")
            }
        }
        
        return GeneratedRoute(
            places: filteredPlaces,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
    }
    
    /// Generate waypoint counts to try, starting from estimated and branching out
    private func generateWaypointCounts(estimated: Int, min: Int, max: Int) -> [Int] {
        var counts: [Int] = [estimated]
        
        // Add counts branching out from estimate
        for offset in 1...4 {
            if estimated - offset >= min {
                counts.append(estimated - offset)
            }
            if estimated + offset <= max {
                counts.append(estimated + offset)
            }
        }
        
        // Remove duplicates and sort by distance from estimate
        return Array(Set(counts)).sorted { abs($0 - estimated) < abs($1 - estimated) }
    }
    
    /// Try a route and evaluate if it's within tolerance
    private func tryRouteAndEvaluate(
        origin: CLLocationCoordinate2D,
        waypoints: [PlaceResult],
        targetDurationMinutes: Int,
        minAcceptable: Int,
        maxAcceptable: Int,
        validRoutes: inout [GeneratedRoute],
        bestFallback: inout GeneratedRoute?,
        bestFallbackDiff: inout Int
    ) async -> GeneratedRoute? {
        do {
            let waypointCoords = waypoints.map { $0.coordinate }
            let directions = try await getWalkingDirections(
                origin: origin,
                destination: origin,
                waypoints: waypointCoords
            )
            
            let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
            let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
            let durationMin = totalDuration / 60
            let diff = abs(durationMin - targetDurationMinutes)
            
            // EARLY REJECTION: If route is more than double target, skip entirely
            if durationMin > targetDurationMinutes * 2 {
                print("🗺️ ✗ REJECTED: \(durationMin)min is way too long (target: \(targetDurationMinutes)min)")
                return nil
            }
            
            let polylinePoints = directions.overviewPolyline.points
            let decodedCount = PolylineDecoder.decode(polylinePoints).count
            
            // Reorder waypoints based on Google's optimized order
            var orderedWaypoints = waypoints
            if let waypointOrder = directions.waypointOrder, waypointOrder.count == waypoints.count {
                orderedWaypoints = waypointOrder.compactMap { index in
                    index < waypoints.count ? waypoints[index] : nil
                }
                print("🗺️ Waypoints reordered by Google: \(waypointOrder)")
            }
            
            let route = GeneratedRoute(
                places: orderedWaypoints,
                polyline: polylinePoints,
                distanceMeters: totalDistance,
                durationSeconds: totalDuration,
                legs: directions.legs
            )
            
            if totalDuration >= minAcceptable && totalDuration <= maxAcceptable {
                print("🗺️ ✓ VALID: \(durationMin)min, \(totalDistance)m, \(decodedCount) polyline points")
                validRoutes.append(route)
            } else {
                print("🗺️ ✗ Outside tolerance: \(durationMin)min (diff: \(diff)min)")
            }
            
            // Track best fallback - ONLY consider routes that don't exceed target
            let isUnderOrAtTarget = durationMin <= targetDurationMinutes
            
            // Only track as fallback if it doesn't exceed the target time
            if isUnderOrAtTarget {
                let currentBestPOIs = bestFallback?.places.count ?? 0
                let thisPOIs = route.places.count
                
                // Prefer: more POIs, then closer to target time
                let shouldUpdate = bestFallback == nil ||
                    thisPOIs > currentBestPOIs ||
                    (thisPOIs == currentBestPOIs && diff < bestFallbackDiff)
                
                if shouldUpdate {
                    bestFallbackDiff = diff
                    bestFallback = route
                }
            }
            
            return route
        } catch {
            print("🗺️ Route failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Select candidate waypoints sorted by preference
    /// Difficulty affects order: easy prefers closer, hard prefers further (within reasonable range)
    private func selectCandidateWaypoints(from places: [PlaceResult], origin: CLLocationCoordinate2D, idealWaypointDistance: Int, difficulty: RouteDifficulty?) -> [PlaceResult] {
        let idealDistance = Double(idealWaypointDistance)
        
        // Minimum distance to avoid "arrived immediately" issues
        let minDistance: Double = max(100, idealDistance * 0.3)
        
        // Maximum distance - don't go too far or route will be too long
        let maxDistance: Double = idealDistance * 1.5
        
        // Excluded types
        let excludedTypes = Set(["transit_station", "locality", "political", "sublocality"])
        
        // Filter places within acceptable range
        let filtered = places.filter { place in
            let distance = distanceBetween(origin, place.coordinate)
            let types = Set(place.types ?? [])
            let hasExcludedType = !types.isDisjoint(with: excludedTypes)
            return distance >= minDistance && distance <= maxDistance && !hasExcludedType
        }
        
        // Calculate bearing (angle) from origin for each POI
        let placesWithAngles = filtered.map { place -> (place: PlaceResult, distance: Double, angle: Double) in
            let distance = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            return (place, distance, angle)
        }
        
        // Sort based on difficulty preference, but also consider angular diversity
        let sorted: [PlaceResult]
        switch difficulty {
        case .easy:
            // Easy: prefer closer POIs
            sorted = placesWithAngles.sorted { p1, p2 in
                let score1 = p1.distance < idealDistance * 0.5 ? p1.distance + 100 : p1.distance
                let score2 = p2.distance < idealDistance * 0.5 ? p2.distance + 100 : p2.distance
                return score1 < score2
            }.map { $0.place }
            print("🗺️ Sorting: EASY - preferring closer POIs")
            
        case .challenging:
            // Hard: prefer further POIs
            sorted = placesWithAngles.sorted { $0.distance > $1.distance }.map { $0.place }
            print("🗺️ Sorting: HARD - preferring further POIs")
            
        case .moderate, .none:
            // Moderate/None: Select POIs that are well-distributed angularly for better loops
            // Group POIs by direction (8 sectors of 45 degrees each)
            var sectors: [[PlaceResult]] = Array(repeating: [], count: 8)
            for item in placesWithAngles {
                let sectorIndex = Int((item.angle + 180) / 45) % 8
                sectors[sectorIndex].append(item.place)
            }
            
            // Pick best POI from each sector (closest to ideal distance)
            var diverseSelection: [PlaceResult] = []
            for sector in sectors {
                if let best = sector.min(by: { p1, p2 in
                    abs(distanceBetween(origin, p1.coordinate) - idealDistance) <
                    abs(distanceBetween(origin, p2.coordinate) - idealDistance)
                }) {
                    diverseSelection.append(best)
                }
            }
            
            // Then add remaining POIs sorted by ideal distance
            let diverseIds = Set(diverseSelection.map { $0.placeId })
            let remaining = placesWithAngles
                .filter { !diverseIds.contains($0.place.placeId) }
                .sorted { abs($0.distance - idealDistance) < abs($1.distance - idealDistance) }
                .map { $0.place }
            
            sorted = diverseSelection + remaining
            print("🗺️ Sorting: MODERATE - preferring angular diversity for better loops (\(diverseSelection.count) sectors covered)")
        }
        
        print("🗺️ Candidate waypoints: \(sorted.count) (ideal: \(Int(idealDistance))m, range: \(Int(minDistance))-\(Int(maxDistance))m)")
        for (i, place) in sorted.prefix(5).enumerated() {
            let dist = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            print("🗺️   \(i+1). '\(place.name)' at \(Int(dist))m, \(Int(angle))°")
        }
        
        return sorted
    }
    
    /// Calculate bearing (angle) from one coordinate to another in degrees (-180 to 180)
    private func bearingBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let lat1 = c1.latitude * .pi / 180
        let lat2 = c2.latitude * .pi / 180
        let dLon = (c2.longitude - c1.longitude) * .pi / 180
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        
        let bearing = atan2(y, x) * 180 / .pi
        return bearing  // -180 to 180 degrees
    }
    
    /// Select waypoints that are angularly spread around the origin to form better loops
    /// This avoids selecting multiple POIs in the same direction (which causes backtracking)
    private func selectAngularlyDiverseWaypoints(from places: [PlaceResult], origin: CLLocationCoordinate2D, count: Int) -> [PlaceResult] {
        guard count > 0, !places.isEmpty else { return [] }
        guard count > 1 else { return Array(places.prefix(1)) }  // Single waypoint - just use first
        
        // Calculate angle for each place
        let placesWithAngles = places.map { place -> (place: PlaceResult, angle: Double) in
            let angle = bearingBetween(origin, place.coordinate)
            return (place, angle)
        }
        
        // Target angular spread for N waypoints: 360/N degrees apart
        let targetSpread = 360.0 / Double(count)
        let minAngularDistance = targetSpread * 0.4  // At least 40% of ideal spread
        
        var selected: [PlaceResult] = []
        var selectedAngles: [Double] = []
        
        for (place, angle) in placesWithAngles {
            // Check if this angle is far enough from already selected angles
            let isAngularlyDistinct = selectedAngles.allSatisfy { existingAngle in
                let diff = abs(angle - existingAngle)
                let angularDistance = min(diff, 360 - diff)  // Handle wrap-around
                return angularDistance >= minAngularDistance
            }
            
            if isAngularlyDistinct || selected.isEmpty {
                selected.append(place)
                selectedAngles.append(angle)
                
                if selected.count >= count {
                    break
                }
            }
        }
        
        // If we couldn't find enough angularly diverse POIs, fill with remaining
        if selected.count < count {
            let selectedIds = Set(selected.map { $0.placeId })
            for place in places where !selectedIds.contains(place.placeId) {
                selected.append(place)
                if selected.count >= count {
                    break
                }
            }
        }
        
        if selected.count > 1 {
            let angles = selected.map { Int(bearingBetween(origin, $0.coordinate)) }
            print("🗺️ Selected \(selected.count) angularly diverse waypoints: \(angles)°")
        }
        
        return selected
    }
    
    /// Add additional discovery spots along the route polyline without affecting timing
    /// These are display-only POIs that weren't used in the Directions API call
    private func addDiscoverySpotsAlongRoute(
        route: GeneratedRoute,
        allPlaces: [PlaceResult],
        desiredCount: Int,
        origin: CLLocationCoordinate2D
    ) async -> GeneratedRoute {
        let routePath = PolylineDecoder.decode(route.polyline)
        guard routePath.count > 2 else { return route }
        
        var existingPlaceIds = Set(route.places.map { $0.placeId })
        let spotsToAdd = desiredCount - route.places.count
        
        guard spotsToAdd > 0 else { return route }
        
        print("🗺️ Adding up to \(spotsToAdd) discovery spots along route (have \(allPlaces.count) POIs available)...")
        
        var additionalSpots: [PlaceResult] = []
        
        // Calculate ideal spacing based on route length
        // Route distance in meters (approximate from polyline)
        var totalRouteDistance: Double = 0
        for i in 1..<routePath.count {
            totalRouteDistance += distanceBetween(routePath[i-1], routePath[i])
        }
        
        // Ideal spacing = route distance / (total spots + 1) to distribute evenly
        let totalSpotsIncludingExisting = route.places.count + spotsToAdd
        let idealSpacing = totalRouteDistance / Double(totalSpotsIncludingExisting + 1)
        let minSpacing = max(150, idealSpacing * 0.6)  // At least 60% of ideal, min 150m
        
        // Reduce min spacing for longer routes to fit more POIs
        let adjustedMinSpacing = max(100, min(minSpacing, totalRouteDistance / Double(spotsToAdd + 2)))
        
        print("🗺️ Route ~\(Int(totalRouteDistance))m, ideal spacing: \(Int(idealSpacing))m, min: \(Int(adjustedMinSpacing))m")
        
        for i in 1...spotsToAdd {
            // Calculate position along route (skip first 8% and last 8%)
            let fraction = 0.08 + (0.84 * Double(i) / Double(spotsToAdd + 1))
            let targetIndex = Int(Double(routePath.count - 1) * fraction)
            let targetPoint = routePath[targetIndex]
            
            // All existing waypoint coordinates (original + already added)
            let existingCoords = route.places.map { $0.coordinate } + additionalSpots.map { $0.coordinate }
            
            // Try progressively larger radii to find POIs near the route
            var nearestPOI: PlaceResult? = nil
            
            for maxDistanceFromRoute in [100.0, 200.0, 300.0, 500.0] {
                let candidatePOIs = allPlaces.filter { place in
                    guard !existingPlaceIds.contains(place.placeId) else { return false }
                    guard distanceBetween(origin, place.coordinate) > 60 else { return false }
                    
                    // Check minimum spacing from existing waypoints (relaxed for later attempts)
                    let effectiveMinSpacing = maxDistanceFromRoute > 200 ? adjustedMinSpacing * 0.7 : adjustedMinSpacing
                    let tooCloseToExisting = existingCoords.contains { coord in
                        distanceBetween(coord, place.coordinate) < effectiveMinSpacing
                    }
                    guard !tooCloseToExisting else { return false }
                    
                    // Check if POI is near the target point on route
                    return distanceBetween(targetPoint, place.coordinate) < maxDistanceFromRoute
                }
                
                // Pick the one closest to our target point
                nearestPOI = candidatePOIs.min { p1, p2 in
                    distanceBetween(targetPoint, p1.coordinate) < distanceBetween(targetPoint, p2.coordinate)
                }
                
                if nearestPOI != nil { break }
            }
            
            if let poi = nearestPOI {
                additionalSpots.append(poi)
                existingPlaceIds.insert(poi.placeId)
                let dist = Int(distanceBetween(targetPoint, poi.coordinate))
                print("🗺️   Spot \(i): \(poi.name) (\(dist)m from route)")
            } else {
                print("🗺️   Spot \(i): No POI found near this section")
            }
        }
        
        // Merge original waypoints with additional spots, sorted by position along route
        var allWaypoints = route.places + additionalSpots
        
        // Sort by distance along route
        allWaypoints.sort { p1, p2 in
            let pos1 = findPositionAlongRoute(p1.coordinate, routePath: routePath)
            let pos2 = findPositionAlongRoute(p2.coordinate, routePath: routePath)
            return pos1 < pos2
        }
        
        print("🗺️ Route now has \(allWaypoints.count) discovery spots (added \(additionalSpots.count))")
        
        return GeneratedRoute(
            places: allWaypoints,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
    }
    
    /// Find approximate position (0.0 to 1.0) of a coordinate along the route
    private func findPositionAlongRoute(_ coord: CLLocationCoordinate2D, routePath: [CLLocationCoordinate2D]) -> Double {
        var closestIndex = 0
        var closestDistance = Double.infinity
        
        for (index, point) in routePath.enumerated() {
            let dist = distanceBetween(coord, point)
            if dist < closestDistance {
                closestDistance = dist
                closestIndex = index
            }
        }
        
        return Double(closestIndex) / Double(max(1, routePath.count - 1))
    }
    
    // MARK: - Helper Methods
    
    /// Decode a Google Maps encoded polyline string into coordinates
    private func decodePolyline(_ encodedPath: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encodedPath.startIndex
        var lat: Int32 = 0
        var lng: Int32 = 0
        
        while index < encodedPath.endIndex {
            // Decode latitude
            var shift: Int32 = 0
            var result: Int32 = 0
            var byte: Int32
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += deltaLat
            
            // Decode longitude
            shift = 0
            result = 0
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += deltaLng
            
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            )
            coordinates.append(coordinate)
        }
        
        return coordinates
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
    
    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }
}

// MARK: - Error Types
enum GoogleMapsError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case serverError
    case apiError(String)
    case noRouteFound
    case noPlacesFound
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Google Maps API key is not configured"
        case .invalidURL:
            return "Invalid request URL"
        case .serverError:
            return "Server error occurred"
        case .apiError(let status):
            return "API error: \(status)"
        case .noRouteFound:
            return "No walking route found"
        case .noPlacesFound:
            return "No nearby places found"
        }
    }
}

// MARK: - API Response Models

struct PlacesResponse: Codable {
    let status: String
    let results: [PlaceResult]
}

struct PlaceResult: Codable, Identifiable {
    let placeId: String
    let name: String
    let vicinity: String?
    let geometry: PlaceGeometry
    let rating: Double?
    let types: [String]?
    let businessStatus: String?
    
    var id: String { placeId }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: geometry.location.lat,
            longitude: geometry.location.lng
        )
    }
    
    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, vicinity, geometry, rating, types
        case businessStatus = "business_status"
    }
}

struct PlaceGeometry: Codable {
    let location: PlaceLocation
}

struct PlaceLocation: Codable {
    let lat: Double
    let lng: Double
}

struct DirectionsResponse: Codable {
    let status: String
    let routes: [DirectionsResult]
}

struct DirectionsResult: Codable {
    let legs: [DirectionsLeg]
    let overviewPolyline: OverviewPolyline
    let summary: String?
    let warnings: [String]?
    let waypointOrder: [Int]?  // Optimized order when using optimize:true
    
    enum CodingKeys: String, CodingKey {
        case legs
        case overviewPolyline = "overview_polyline"
        case summary, warnings
        case waypointOrder = "waypoint_order"
    }
}

struct DirectionsLeg: Codable {
    let distance: DirectionsValue
    let duration: DirectionsValue
    let startAddress: String?
    let endAddress: String?
    let steps: [DirectionsStep]?
    
    enum CodingKeys: String, CodingKey {
        case distance, duration, steps
        case startAddress = "start_address"
        case endAddress = "end_address"
    }
}

struct DirectionsValue: Codable {
    let text: String
    let value: Int
}

struct DirectionsStep: Codable {
    let distance: DirectionsValue
    let duration: DirectionsValue
    let htmlInstructions: String?
    let polyline: StepPolyline?
    
    enum CodingKeys: String, CodingKey {
        case distance, duration, polyline
        case htmlInstructions = "html_instructions"
    }
}

struct StepPolyline: Codable {
    let points: String
}

struct OverviewPolyline: Codable {
    let points: String
}

// MARK: - Generated Route Result
struct GeneratedRoute {
    let places: [PlaceResult]
    let polyline: String
    let distanceMeters: Int
    let durationSeconds: Int
    let legs: [DirectionsLeg]
    
    var durationMinutes: Int {
        durationSeconds / 60
    }
    
    var formattedDuration: String {
        let mins = durationSeconds / 60
        if mins < 60 {
            return "\(mins) min"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(hours)h \(remainingMins)m"
        }
    }
    
    var formattedDistance: String {
        if distanceMeters < 1000 {
            return "\(distanceMeters)m"
        } else {
            let km = Double(distanceMeters) / 1000.0
            return String(format: "%.1f km", km)
        }
    }
}

