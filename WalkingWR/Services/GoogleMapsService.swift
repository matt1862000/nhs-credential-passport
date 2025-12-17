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
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) async throws -> GeneratedRoute {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        // Walking speed ~80m/min (5km/h)
        // For circular route: Origin → Waypoint → Origin
        // Total distance = targetDurationMinutes * 80m
        // 5 min = 400m total → waypoint at ~150m (out and back)
        // 10 min = 800m total → waypoint at ~300m
        // 15 min = 1200m total → waypoint at ~400m
        // 20 min = 1600m total → waypoint at ~500m
        
        let totalDistanceTarget = targetDurationMinutes * 80 // meters
        
        // For a simple out-and-back route with 1 waypoint:
        // waypoint distance from origin = total / 2.5 (accounting for route not being straight)
        let idealWaypointDistance = totalDistanceTarget / 3
        
        // Search radius: find places around the ideal distance, with some buffer
        // Cap the radius to prevent finding places too far away
        let searchRadius = max(200, min(idealWaypointDistance + 150, 500))
        
        print("🗺️ Target: \(targetDurationMinutes)min (\(totalDistanceTarget)m), ideal waypoint: \(idealWaypointDistance)m, search radius: \(searchRadius)m")
        
        // Step 1: Find nearby POIs
        var places: [PlaceResult] = []
        
        places = try await findNearbyPlaces(
            location: location,
            radiusMeters: searchRadius
        )
        
        print("🗺️ Found \(places.count) POIs")
        
        // If not enough places, try slightly larger radius
        if places.count < 2 {
            print("🗺️ Not enough POIs, trying larger radius...")
            let morePlaces = try await findNearbyPlaces(
                location: location,
                radiusMeters: min(searchRadius + 200, 700)
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
        
        // Step 2: Use only 1 waypoint for most routes to keep distance controlled
        // Multiple waypoints spread out = much longer routes
        let waypointCount = 1  // Keep it simple - 1 waypoint for all local routes
        let selectedPlaces = selectBestWaypoints(from: places, count: waypointCount, origin: location, targetDurationMinutes: targetDurationMinutes)
        
        print("🗺️ Selected \(selectedPlaces.count) waypoints: \(selectedPlaces.map { $0.name })")
        
        // If no waypoints could be selected, throw error
        guard !selectedPlaces.isEmpty else {
            throw GoogleMapsError.noPlacesFound
        }
        
        // Step 3: Get walking directions (circular route back to origin)
        let waypoints = selectedPlaces.map { $0.coordinate }
        
        print("🗺️ Getting directions with \(waypoints.count) waypoints")
        
        let directions = try await getWalkingDirections(
            origin: location,
            destination: location,
            waypoints: waypoints
        )
        
        // Step 4: Build the generated route
        let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
        let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
        
        print("🗺️ Route: \(totalDistance)m, \(totalDuration)s, polyline length: \(directions.overviewPolyline.points.count)")
        
        // Validate the route has meaningful data
        guard totalDistance > 0 && totalDuration > 0 else {
            print("🗺️ Route has zero distance/duration!")
            throw GoogleMapsError.noRouteFound
        }
        
        return GeneratedRoute(
            places: selectedPlaces,
            polyline: directions.overviewPolyline.points,
            distanceMeters: totalDistance,
            durationSeconds: totalDuration,
            legs: directions.legs
        )
    }
    
    // MARK: - Helper Methods
    
    private func selectBestWaypoints(from places: [PlaceResult], count: Int, origin: CLLocationCoordinate2D, targetDurationMinutes: Int = 10) -> [PlaceResult] {
        guard !places.isEmpty else { return [] }
        
        // Calculate ideal waypoint distance for this route duration
        // For out-and-back: waypoint at totalDistance / 2.5
        let totalDistanceTarget = targetDurationMinutes * 80
        let idealDistance = Double(totalDistanceTarget) / 2.5
        
        // Minimum distance: at least 100m to avoid "arrived immediately"
        // Maximum distance: don't go further than ideal + 50% or route will be too long
        let minDistance: Double = 100
        let maxDistance: Double = idealDistance * 1.3
        
        print("🗺️ Waypoint selection: ideal=\(Int(idealDistance))m, min=\(Int(minDistance))m, max=\(Int(maxDistance))m")
        
        // Filter out places that are:
        // 1. Too close OR too far from origin
        // 2. Transit stations (bus stops) - not interesting destinations
        // 3. Localities (town names) - not walkable destinations
        let excludedTypes = Set(["transit_station", "locality", "political", "sublocality"])
        
        let filteredPlaces = places.filter { place in
            let distance = distanceBetween(origin, place.coordinate)
            let types = Set(place.types ?? [])
            let hasExcludedType = !types.isDisjoint(with: excludedTypes)
            
            let isValidDistance = distance >= minDistance && distance <= maxDistance
            let isValidType = !hasExcludedType
            
            if distance < minDistance {
                print("🗺️ Filtered out '\(place.name)' - too close (\(Int(distance))m)")
            } else if distance > maxDistance {
                print("🗺️ Filtered out '\(place.name)' - too far (\(Int(distance))m > \(Int(maxDistance))m)")
            }
            if !isValidType {
                print("🗺️ Filtered out '\(place.name)' - excluded type")
            }
            
            return isValidDistance && isValidType
        }
        
        print("🗺️ After filtering: \(filteredPlaces.count) places (from \(places.count))")
        
        guard !filteredPlaces.isEmpty else {
            print("🗺️ No places after filtering, using closest valid place")
            // Fallback: find closest place that's not a transit station
            let validPlaces = places.filter { place in
                let types = Set(place.types ?? [])
                let distance = distanceBetween(origin, place.coordinate)
                return types.isDisjoint(with: excludedTypes) && distance >= minDistance
            }
            .sorted { distanceBetween(origin, $0.coordinate) < distanceBetween(origin, $1.coordinate) }
            
            return Array(validPlaces.prefix(count))
        }
        
        // Score places: prefer places CLOSEST to ideal distance, with bonus for ratings
        let scored = filteredPlaces.map { place -> (PlaceResult, Double) in
            let distance = distanceBetween(origin, place.coordinate)
            let rating = place.rating ?? 3.0
            
            // Score: distance close to ideal is most important
            // Lower deviation from ideal = higher score
            let distanceDeviation = abs(distance - idealDistance)
            let distanceScore = 100 - (distanceDeviation / 5) // Lose 1 point per 5m deviation
            let ratingScore = rating * 5 // Rating is secondary
            let score = distanceScore + ratingScore
            
            return (place, score)
        }
        .sorted { $0.1 > $1.1 }
        
        // Take top place(s)
        var selected: [PlaceResult] = []
        
        for (place, score) in scored {
            if selected.count >= count { break }
            
            let distance = distanceBetween(origin, place.coordinate)
            print("🗺️ Selected: '\(place.name)' (score: \(Int(score)), dist: \(Int(distance))m, ideal: \(Int(idealDistance))m)")
            selected.append(place)
        }
        
        // If we couldn't find enough spread out places, just take top ones
        if selected.count < count {
            for (place, _) in scored {
                if selected.count >= count { break }
                if !selected.contains(where: { $0.placeId == place.placeId }) {
                    selected.append(place)
                }
            }
        }
        
        return selected
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

