//
//  GoogleMapsService.swift
//  WalkingWR
//
//  Created for local route generation using Google APIs
//

import Foundation
import CoreLocation

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
    
    // MARK: - Find Nearby Places
    /// Finds points of interest near a location using Google Places API
    /// Note: The Places API 'type' parameter only accepts ONE type at a time
    func findNearbyPlaces(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500,
        types: [String] = ["point_of_interest"]
    ) async throws -> [PlaceResult] {
        guard !apiKey.isEmpty else {
            throw GoogleMapsError.missingAPIKey
        }
        
        var allResults: [PlaceResult] = []
        
        // The Places API only accepts one type at a time, so we'll search with a single type
        // Using "point_of_interest" or no type restriction gives best results
        let primaryType = types.first ?? "point_of_interest"
        
        // Build URL - can also omit 'type' entirely to get all nearby places
        var urlString = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?"
        urlString += "location=\(location.latitude),\(location.longitude)"
        urlString += "&radius=\(radiusMeters)"
        
        // Only add type if it's not a generic search
        if primaryType != "establishment" && primaryType != "point_of_interest" {
            urlString += "&type=\(primaryType)"
        }
        
        urlString += "&key=\(apiKey)"
        
        print("🗺️ Places API URL: \(urlString.replacingOccurrences(of: apiKey, with: "***"))")
        
        guard let url = URL(string: urlString) else {
            throw GoogleMapsError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("🗺️ Places API HTTP error: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            throw GoogleMapsError.serverError
        }
        
        // Debug: print raw response
        if let jsonString = String(data: data, encoding: .utf8) {
            print("🗺️ Places API response (first 500 chars): \(String(jsonString.prefix(500)))")
        }
        
        let placesResponse = try JSONDecoder().decode(PlacesResponse.self, from: data)
        
        print("🗺️ Places API status: \(placesResponse.status), results count: \(placesResponse.results.count)")
        
        if placesResponse.status != "OK" && placesResponse.status != "ZERO_RESULTS" {
            throw GoogleMapsError.apiError(placesResponse.status)
        }
        
        allResults.append(contentsOf: placesResponse.results)
        
        return allResults
    }
    
    // MARK: - Get Walking Directions
    /// Gets walking directions between points using Google Directions API
    func getWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = []
    ) async throws -> DirectionsResult {
        guard !apiKey.isEmpty else {
            throw GoogleMapsError.missingAPIKey
        }
        
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(origin.latitude),\(origin.longitude)"
        urlString += "&destination=\(destination.latitude),\(destination.longitude)"
        urlString += "&mode=walking"
        
        if !waypoints.isEmpty {
            // Use optimize:true to let Google order waypoints for the most efficient route
            let waypointString = waypoints.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|")
            urlString += "&waypoints=optimize:true|\(waypointString)"
        }
        
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            throw GoogleMapsError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GoogleMapsError.serverError
        }
        
        let directionsResponse = try JSONDecoder().decode(DirectionsResponse.self, from: data)
        
        if directionsResponse.status != "OK" {
            throw GoogleMapsError.apiError(directionsResponse.status)
        }
        
        guard let route = directionsResponse.routes.first else {
            throw GoogleMapsError.noRouteFound
        }
        
        return route
    }
    
    // MARK: - Generate Local Walking Route
    /// Generates a circular walking route from user's location using nearby POIs
    /// DYNAMICALLY adjusts number of waypoints to match target duration
    /// Keeps trying different combinations until within ±3 minutes of target
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil
    ) async throws -> GeneratedRoute {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        // STRICT TIMING: Route can be shorter but NEVER exceed requested time
        // Acceptable range: 80% to 100% of target
        let minPercent = 0.80
        let minAcceptableMinutes = max(1, Int(Double(targetDurationMinutes) * minPercent))
        let maxAcceptableMinutes = targetDurationMinutes  // 100% - never exceed
        let minAcceptableDuration = minAcceptableMinutes * 60
        let maxAcceptableDuration = maxAcceptableMinutes * 60
        
        print("🗺️ STRICT: \(minAcceptableMinutes)min to \(maxAcceptableMinutes)min (80-100% of \(targetDurationMinutes)min, never exceed)")
        
        // Walking speed ~80m/min
        let walkingSpeedMeterPerMin = 80
        let totalDistanceTarget = targetDurationMinutes * walkingSpeedMeterPerMin
        
        // Search radius based on route length
        let searchRadius = max(600, totalDistanceTarget / 2)
        
        print("🗺️ Target: \(targetDurationMinutes)min")
        print("🗺️ Search radius: \(searchRadius)m")
        
        // Step 1: Find nearby POIs - need enough for 1 per 5 minutes
        let desiredSpots = max(2, targetDurationMinutes / 5)
        var places = try await findNearbyPlaces(
            location: location,
            radiusMeters: searchRadius
        )
        
        print("🗺️ Found \(places.count) POIs (need \(desiredSpots) for route)")
        
        // For longer routes, we need more POIs - do additional searches at different points
        if places.count < desiredSpots * 2 && targetDurationMinutes > 20 {
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
        
        // PRIORITY: 1) Timing within 125%  2) Maximum POIs
        // Strategy: Start with MAXIMUM waypoints and reduce if route too long
        // This ensures we get as many verified walkable POIs as possible
        
        // Desired waypoints (1 per 5 min)
        let desiredWaypoints = max(2, targetDurationMinutes / 5)
        let maxWaypoints = min(desiredWaypoints, 8, places.count)
        
        // Try waypoint counts in DESCENDING order (most first, then fewer)
        // First valid route (within 125%) wins - maximizing POI count
        let waypointCountsToTry = Array((1...maxWaypoints).reversed())
        
        print("🗺️ Will try waypoint counts: \(waypointCountsToTry) (maximize POIs within 125% time)")
        
        var totalAttempts = 0
        let maxTotalAttempts = 25
        
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
            let combinationsToTry = min(8, candidatesForCount.count)
            var triedCombinations = Set<String>()
            
            for comboIndex in 0..<combinationsToTry {
                guard totalAttempts < maxTotalAttempts else { break }
                
                var selectedWaypoints: [PlaceResult] = []
                
                if comboIndex == 0 {
                    // FIRST ATTEMPT: Use the best candidates (no randomization)
                    selectedWaypoints = Array(candidatesForCount.prefix(waypointCount))
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
        // PRIORITY: 1) Most waypoints  2) Closest to target time
        if !validRoutes.isEmpty {
            // Sort by: most waypoints first, then closest to target
            let sorted = validRoutes.sorted { route1, route2 in
                // First: more waypoints is better
                if route1.places.count != route2.places.count {
                    return route1.places.count > route2.places.count
                }
                // Second: closer to target is better (all are at or under)
                let diff1 = targetDurationMinutes - route1.durationSeconds / 60
                let diff2 = targetDurationMinutes - route2.durationSeconds / 60
                return diff1 < diff2  // Prefer routes closer to target
            }
            
            var selected = sorted.first!
            
            // Remove waypoints that are too close together (within 100m)
            selected = removeCloseWaypoints(from: selected, minDistance: 100)
            
            let finalMins = selected.durationSeconds / 60
            print("🗺️ ✓ SUCCESS! Selected: \(finalMins)min, \(selected.places.count) POIs (target: \(targetDurationMinutes)min)")
            
            return selected
        }
        
        // ALWAYS return the best fallback - all POIs are verified walkable
        if var best = bestFallbackRoute {
            // Remove waypoints that are too close together
            best = removeCloseWaypoints(from: best, minDistance: 100)
            
            let mins = best.durationSeconds / 60
            print("🗺️ ⚠️ No route within tolerance. Best found: \(mins)min with \(best.places.count) POIs (target: \(targetDurationMinutes)min)")
            return best
        }
        
        throw GoogleMapsError.noRouteFound
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
        
        // Sort based on difficulty preference
        let sorted: [PlaceResult]
        switch difficulty {
        case .easy:
            // Easy: prefer closer POIs (sort by distance ascending, but still reasonable)
            sorted = filtered.sorted { p1, p2 in
                let d1 = distanceBetween(origin, p1.coordinate)
                let d2 = distanceBetween(origin, p2.coordinate)
                // Prefer closer, but not too close (penalize very close ones slightly)
                let score1 = d1 < idealDistance * 0.5 ? d1 + 100 : d1
                let score2 = d2 < idealDistance * 0.5 ? d2 + 100 : d2
                return score1 < score2
            }
            print("🗺️ Sorting: EASY - preferring closer POIs")
            
        case .challenging:
            // Hard: prefer further POIs (sort by distance descending, but within range)
            sorted = filtered.sorted { p1, p2 in
                let d1 = distanceBetween(origin, p1.coordinate)
                let d2 = distanceBetween(origin, p2.coordinate)
                return d1 > d2
            }
            print("🗺️ Sorting: HARD - preferring further POIs")
            
        case .moderate, .none:
            // Moderate/None: prefer POIs closest to ideal distance
            sorted = filtered.sorted { p1, p2 in
                let d1 = abs(distanceBetween(origin, p1.coordinate) - idealDistance)
                let d2 = abs(distanceBetween(origin, p2.coordinate) - idealDistance)
                return d1 < d2
            }
            print("🗺️ Sorting: MODERATE - preferring ideal distance POIs")
        }
        
        print("🗺️ Candidate waypoints: \(sorted.count) (ideal: \(Int(idealDistance))m, range: \(Int(minDistance))-\(Int(maxDistance))m)")
        for (i, place) in sorted.prefix(5).enumerated() {
            let dist = distanceBetween(origin, place.coordinate)
            print("🗺️   \(i+1). '\(place.name)' at \(Int(dist))m")
        }
        
        return sorted
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

