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
            let waypointString = waypoints.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|")
            urlString += "&waypoints=\(waypointString)"
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
    /// Route duration will be within ±3 minutes of target - this is strictly enforced
    /// Difficulty affects POI prioritization: easy = prefer closer, hard = prefer further
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil
    ) async throws -> GeneratedRoute {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        // Tolerance: route MUST be within 3 minutes of target - strictly enforced
        let toleranceMinutes = 3
        let minAcceptableDuration = (targetDurationMinutes - toleranceMinutes) * 60 // in seconds
        let maxAcceptableDuration = (targetDurationMinutes + toleranceMinutes) * 60
        
        // Walking speed is constant ~80m/min for accurate time estimation
        let walkingSpeedMeterPerMin = 80
        
        // Calculate base target distance
        let totalDistanceTarget = targetDurationMinutes * walkingSpeedMeterPerMin
        
        // Ideal waypoint distance for the target duration
        let idealWaypointDistance = totalDistanceTarget / 3
        
        // Search radius: wide enough to find various POIs
        let searchRadius = max(400, idealWaypointDistance + 300)
        
        // Difficulty affects sorting preference, not the target time
        let difficultyDescription: String
        switch difficulty {
        case .easy:
            difficultyDescription = "EASY - will prefer closer POIs"
        case .challenging:
            difficultyDescription = "HARD - will prefer further POIs"
        case .moderate:
            difficultyDescription = "MODERATE - balanced selection"
        case .none:
            difficultyDescription = "None - balanced selection"
        }
        
        print("🗺️ Target: \(targetDurationMinutes)min (±\(toleranceMinutes)min STRICT), ideal waypoint: \(idealWaypointDistance)m")
        print("🗺️ Difficulty: \(difficultyDescription)")
        
        // Step 1: Find nearby POIs
        var places = try await findNearbyPlaces(
            location: location,
            radiusMeters: searchRadius
        )
        
        print("🗺️ Found \(places.count) POIs")
        
        // If not enough places, try larger radius
        if places.count < 5 {
            print("🗺️ Not enough POIs, trying larger radius...")
            let expandedRadius = searchRadius + 400
            let morePlaces = try await findNearbyPlaces(
                location: location,
                radiusMeters: expandedRadius
            )
            for place in morePlaces {
                if !places.contains(where: { $0.placeId == place.placeId }) {
                    places.append(place)
                }
            }
            print("🗺️ Now have \(places.count) total places")
        }
        
        guard !places.isEmpty else {
            print("🗺️ No places found at all!")
            throw GoogleMapsError.noPlacesFound
        }
        
        // Step 2: Get candidate waypoints sorted by distance from ideal
        let candidates = selectCandidateWaypoints(from: places, origin: location, idealWaypointDistance: idealWaypointDistance, difficulty: difficulty)
        
        guard !candidates.isEmpty else {
            throw GoogleMapsError.noPlacesFound
        }
        
        print("🗺️ Have \(candidates.count) candidate waypoints to try")
        
        // Step 3: Try candidates and collect all that are within tolerance
        var validRoutes: [GeneratedRoute] = []
        var bestFallbackRoute: GeneratedRoute?
        var bestFallbackDiff = Int.max
        
        // Try up to 8 candidates to find valid options
        let maxAttempts = min(8, candidates.count)
        
        for i in 0..<maxAttempts {
            let candidate = candidates[i]
            let distance = distanceBetween(location, candidate.coordinate)
            print("🗺️ Trying candidate \(i+1): '\(candidate.name)' at \(Int(distance))m")
            
            do {
                let directions = try await getWalkingDirections(
                    origin: location,
                    destination: location,
                    waypoints: [candidate.coordinate]
                )
                
                let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let durationMinutes = totalDuration / 60
                let durationDiff = durationMinutes - targetDurationMinutes
                
                print("🗺️ Route result: \(durationMinutes)min (\(totalDistance)m), diff: \(durationDiff)min")
                
                let route = GeneratedRoute(
                    places: [candidate],
                    polyline: directions.overviewPolyline.points,
                    distanceMeters: totalDistance,
                    durationSeconds: totalDuration,
                    legs: directions.legs
                )
                
                // Check if within tolerance
                if totalDuration >= minAcceptableDuration && totalDuration <= maxAcceptableDuration {
                    print("🗺️ ✓ Route within tolerance!")
                    validRoutes.append(route)
                } else {
                    // Track best fallback route (prefer slightly under target)
                    let absDiff = abs(durationDiff)
                    let adjustedDiff = durationDiff > 0 ? absDiff + 2 : absDiff
                    
                    if adjustedDiff < bestFallbackDiff {
                        bestFallbackDiff = adjustedDiff
                        bestFallbackRoute = route
                    }
                }
            } catch {
                print("🗺️ Failed to get directions for candidate: \(error.localizedDescription)")
                continue
            }
        }
        
        // If we have valid routes, randomly select from them
        if !validRoutes.isEmpty {
            let selected = validRoutes.randomElement()!
            let mins = selected.durationSeconds / 60
            print("🗺️ Found \(validRoutes.count) valid routes. Randomly selected: \(mins)min (target: \(targetDurationMinutes)min)")
            return selected
        }
        
        // Return best fallback route if no valid routes found
        if let best = bestFallbackRoute {
            let mins = best.durationSeconds / 60
            print("🗺️ No route within tolerance. Best found: \(mins)min (target: \(targetDurationMinutes)min)")
            return best
        }
        
        throw GoogleMapsError.noRouteFound
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
    
    enum CodingKeys: String, CodingKey {
        case legs
        case overviewPolyline = "overview_polyline"
        case summary, warnings
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

