//
//  PrePopulatedPOIGenerator.swift
//  WalkingWR
//
//  Utility to generate pre-populated POI database for common NHS clinic postcode areas
//  Run this once to generate the database JSON file
//

import Foundation
import CoreLocation
import SwiftUI

// Timeout helper for preventing hanging API calls
// Note: Using a different name to avoid conflict with GoogleMapsService's TimeoutError
fileprivate enum POIGeneratorTimeoutError: Error {
    case timeout
}

fileprivate func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Start the operation
        group.addTask {
            try await operation()
        }
        
        // Start timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw POIGeneratorTimeoutError.timeout
        }
        
        // Return first completed task, cancel the other
        guard let result = try await group.next() else {
            throw POIGeneratorTimeoutError.timeout
        }
        group.cancelAll()
        return result
    }
}

/// Utility class to generate pre-populated POI database
/// Call generateDatabase() to create the JSON file
/// IMPORTANT: Only caches OSM and Geograph POIs (Apple POIs filtered out)
/// Routes are generated using OSRM (not MapKit) to comply with Apple's restrictions
class PrePopulatedPOIGenerator: ObservableObject {
    
    // MARK: - OSRM Route Generation (for pre-populated database)
    
    /// Generate a route using OSRM (Open Source Routing Machine)
    /// Uses OpenStreetMap data - can be cached legally
    private func generateOSRMRoute(
        from origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        pois: [PlaceResult]
    ) async throws -> GeneratedRoute {
        // Select waypoints from POIs (simple selection algorithm)
        let waypoints = selectWaypointsForRoute(
            pois: pois,
            origin: origin,
            targetDurationMinutes: targetDurationMinutes
        )
        
        guard !waypoints.isEmpty else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "No waypoints selected"])
        }
        
        // Build coordinates: origin -> waypoints -> origin (loop)
        var allCoords: [CLLocationCoordinate2D] = [origin]
        allCoords.append(contentsOf: waypoints)
        allCoords.append(origin)
        
        // Call OSRM API
        let (distance, duration, polylinePoints) = try await callOSRMAPI(coordinates: allCoords)
        
        // Convert waypoint coordinates back to PlaceResults
        let routePOIs = waypoints.compactMap { coord -> PlaceResult? in
            // Find the closest POI to this coordinate
            pois.min(by: { distanceBetween($0.coordinate, coord) < distanceBetween($1.coordinate, coord) })
        }
        
        // Encode polyline
        let encodedPolyline = encodePolyline(polylinePoints)
        
        return GeneratedRoute(
            places: routePOIs,
            polyline: encodedPolyline,
            distanceMeters: distance,
            durationSeconds: duration,
            legs: []  // OSRM doesn't provide detailed legs
        )
    }
    
    /// Select waypoints from POIs for a target duration
    private func selectWaypointsForRoute(
        pois: [PlaceResult],
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) -> [CLLocationCoordinate2D] {
        guard !pois.isEmpty else { return [] }
        
        // Calculate ideal distance (walking speed ~80m/min, routes are ~1.5-2x longer)
        let walkingSpeedMetersPerMin = 80.0
        let routeOverheadFactor = 0.65  // Conservative estimate
        let idealDistance = Double(targetDurationMinutes) * walkingSpeedMetersPerMin * routeOverheadFactor
        
        // Sort POIs by distance from origin
        let poisWithDistance = pois.map { poi -> (poi: PlaceResult, distance: Double) in
            let dist = distanceBetween(origin, poi.coordinate)
            return (poi, dist)
        }.sorted { $0.distance < $1.distance }
        
        // Select waypoints that fit within target distance
        var selected: [CLLocationCoordinate2D] = []
        var cumulativeDistance: Double = 0
        
        for (poi, distance) in poisWithDistance {
            // *2 for return journey
            if cumulativeDistance + (distance * 2) <= idealDistance {
                selected.append(poi.coordinate)
                cumulativeDistance += distance * 2
                if selected.count >= 3 {  // Limit to 3 waypoints
                    break
                }
            }
        }
        
        return selected
    }
    
    /// Call OSRM API to get route
    private func callOSRMAPI(coordinates: [CLLocationCoordinate2D]) async throws -> (distance: Int, duration: Int, polyline: [CLLocationCoordinate2D]) {
        guard coordinates.count >= 2 else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Need at least 2 coordinates"])
        }
        
        // Build coordinate string: lon,lat;lon,lat;...
        let coordStrings = coordinates.map { "\($0.longitude),\($0.latitude)" }
        let coordsPath = coordStrings.joined(separator: ";")
        
        // OSRM public server (using driving profile, we'll convert to walking time)
        let urlString = "https://router.project-osrm.org/route/v1/driving/\(coordsPath)?overview=full&geometries=polyline"
        
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid OSRM URL"])
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "OSRM HTTP error"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String,
              code == "Ok",
              let routes = json["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let distance = firstRoute["distance"] as? Double,
              let geometry = firstRoute["geometry"] as? String else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "OSRM invalid response"])
        }
        
        // Decode polyline
        let polylinePoints = decodePolyline(geometry)
        
        guard !polylinePoints.isEmpty else {
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "OSRM empty polyline"])
        }
        
        // Convert driving time to walking time (OSRM public server uses driving profile)
        let walkingSpeedMetersPerMin = 80.0
        let walkingMinutes = distance / walkingSpeedMetersPerMin
        let walkingDurationSeconds = Int(walkingMinutes * 60)
        
        return (distance: Int(distance), duration: walkingDurationSeconds, polyline: polylinePoints)
    }
    
    /// Decode polyline string to coordinates
    private func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        // Simple polyline decoder (Google's encoded polyline format)
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat: Int = 0
        var lng: Int = 0
        
        while index < encoded.endIndex {
            // Decode latitude
            var shift = 0
            var result = 0
            var value: Int = 0
            repeat {
                guard index < encoded.endIndex else { break }
                let char = encoded[index]
                value = Int(char.asciiValue ?? 0) - 63
                result |= (value & 0x1F) << shift
                shift += 5
                index = encoded.index(after: index)
            } while value >= 0x20
            
            let deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += deltaLat
            
            // Decode longitude
            shift = 0
            result = 0
            value = 0  // Reset for longitude decoding
            repeat {
                guard index < encoded.endIndex else { break }
                let char = encoded[index]
                value = Int(char.asciiValue ?? 0) - 63
                result |= (value & 0x1F) << shift
                shift += 5
                index = encoded.index(after: index)
            } while value >= 0x20
            
            let deltaLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += deltaLng
            
            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            ))
        }
        
        return coordinates
    }
    
    /// Encode coordinates to polyline string
    private func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encoded = ""
        var prevLat = 0
        var prevLng = 0
        
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            
            let dLat = lat - prevLat
            let dLng = lng - prevLng
            
            encoded += encodeValue(dLat)
            encoded += encodeValue(dLng)
            
            prevLat = lat
            prevLng = lng
        }
        
        return encoded
    }
    
    private func encodeValue(_ value: Int) -> String {
        var value = value
        value = value < 0 ? ~(value << 1) : value << 1
        var encoded = ""
        while value >= 0x20 {
            encoded += String(Character(UnicodeScalar((0x20 | (value & 0x1F)) + 63)!))
            value >>= 5
        }
        encoded += String(Character(UnicodeScalar(value + 63)!))
        return encoded
    }
    
    /// Calculate distance between two coordinates (Haversine)
    private func distanceBetween(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let loc2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return loc1.distance(from: loc2)
    }
    
    // Progress tracking for UI
    @Published var currentStatus: String = ""
    @Published var currentPostcode: String = ""
    @Published var currentPostcodeIndex: Int = 0
    @Published var totalPostcodes: Int = 8
    @Published var currentDuration: Int = 0
    @Published var routesGenerated: Int = 0
    @Published var isGenerating: Bool = false
    
    // Postcode areas with their center coordinates
    private let postcodeAreas: [(postcode: String, lat: Double, lon: Double)] = [
        ("WF2 0GU", 53.7029, -1.5496),  // Wakefield area
        ("S5 7JT", 53.4109, -1.4603),   // Sheffield area (Northern General Hospital)
        ("S35 0JW", 53.4200, -1.4800),  // Sheffield area
        ("S1 4JP", 53.3800, -1.4700),   // Sheffield city centre
        ("S5 7AU", 53.4100, -1.4500),   // Sheffield area
        ("S8 8BG", 53.3500, -1.4800),   // Sheffield area
        ("S35 1RQ", 53.4300, -1.4900),  // Sheffield area
        ("S11 9BF", 53.3700, -1.5000)   // Sheffield area
    ]
    
    // Note: We'll access GoogleMapsService methods directly since they're internal
    // This generator should be run from within the app context where GoogleMapsService is available
    
    // NOTE: Full database generation is now done on computer using generate_database.py
    // This function is kept for reference but should not be used
    // Use the Python script instead: python3 generate_database.py
    @available(*, deprecated, message: "Use generate_database.py script on computer instead")
    private func generateDatabase() async throws -> PrePopulatedPOIService.PrePopulatedPOIDatabase {
        await MainActor.run {
            isGenerating = true
            totalPostcodes = postcodeAreas.count
            routesGenerated = 0
            currentStatus = "Initializing... (8 areas, 7 routes each)"
        }
        
        print("📦 ========================================")
        print("📦 Starting database generation")
        print("📦 ========================================")
        print("📦 Postcode areas: \(postcodeAreas.count)")
        print("📦 Route durations: 5, 10, 15, 20, 30, 45, 60 minutes")
        print("📦 Expected routes: ~\(postcodeAreas.count * 7) (some may fail validation)")
        print("📦 ========================================")
        
        var postcodeAreaPOIs: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PostcodeAreaPOIs] = []
        
        for (index, area) in postcodeAreas.enumerated() {
            await MainActor.run {
                currentPostcodeIndex = index + 1
                currentPostcode = area.postcode
                currentStatus = "Area \(index + 1)/8: \(area.postcode)"
            }
            
            print("\n📦 [\(index + 1)/8] Processing postcode area: \(area.postcode)")
            print("   📍 Location: (\(area.lat), \(area.lon))")
            
            let location = CLLocationCoordinate2D(latitude: area.lat, longitude: area.lon)
            let radiusMeters = 2500
            
            // Fetch POIs using the existing service (will use OSM + Geograph)
            do {
                await MainActor.run {
                    currentStatus = "\(area.postcode): Fetching POIs (OSM + Geograph)..."
                }
                print("   🔍 Starting POI fetch from OSM and Geograph APIs...")
                
                // Skip Google to save costs - we only want free sources
                // Add timeout to prevent hanging (OSM can be very slow)
                let startTime = Date()
                let pois = try await withTimeout(seconds: 60.0) {
                    try await GoogleMapsService.shared.findNearbyPlaces(
                        location: location,
                        radiusMeters: radiusMeters,
                        skipGoogle: true
                    )
                }
                let fetchTime = Date().timeIntervalSince(startTime)
                
                await MainActor.run {
                    currentStatus = "\(area.postcode): Found \(pois.count) POIs (\(String(format: "%.1f", fetchTime))s) - Starting routes..."
                }
                
                print("   ✅ Found \(pois.count) POIs in \(String(format: "%.1f", fetchTime))s")
                
                // Count POIs by source for logging
                let osmCount = pois.filter { $0.source == .osm }.count
                let geographCount = pois.filter { $0.source == .geograph }.count
                let appleCount = pois.filter { $0.source == .apple }.count
                print("   📊 POI breakdown: OSM=\(osmCount), Geograph=\(geographCount), Apple=\(appleCount)")
                
                // IMPORTANT: Filter out Apple POIs - Apple doesn't allow caching their POI data
                // Only cache OSM and Geograph POIs (open data)
                let cacheablePOIs = pois.filter { $0.source == .osm || $0.source == .geograph }
                let filteredCount = pois.count - cacheablePOIs.count
                if filteredCount > 0 {
                    print("   ⚠️ Filtered out \(filteredCount) Apple POIs (not allowed to cache)")
                }
                print("   ✅ Caching \(cacheablePOIs.count) POIs (OSM + Geograph only)")
                
                // Convert PlaceResult to PrePopulatedPOI (only cacheable sources)
                let prePopulatedPOIs = cacheablePOIs.map { poi -> PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI in
                    PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI(
                        placeId: poi.placeId,
                        name: poi.name,
                        latitude: poi.coordinate.latitude,
                        longitude: poi.coordinate.longitude,
                        types: poi.types ?? [],
                        vicinity: poi.vicinity,
                        source: poi.source.rawValue,
                        rating: nil
                    )
                }
                
                // Generate routes for common durations (5, 10, 15, 20, 30, 45, 60 minutes)
                print("   🗺️ Generating routes for 7 durations (5, 10, 15, 20, 30, 45, 60 min)...")
                var routeGroups: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute] = []
                let durationsToGenerate = [5, 10, 15, 20, 30, 45, 60]
                
                for (durationIndex, duration) in durationsToGenerate.enumerated() {
                    await MainActor.run {
                        currentDuration = duration
                        currentStatus = "\(area.postcode): Route \(durationIndex + 1)/7 (\(duration)min)..."
                    }
                    print("   🗺️ [\(durationIndex + 1)/7] Generating \(duration)min route...")
                    
                    do {
                        // IMPORTANT: Use OSRM for route generation (not MapKit)
                        // Apple doesn't allow caching MapKit routes
                        // OSRM uses OpenStreetMap data and can be cached
                        print("      🗺️ Generating \(duration)min route using OSRM (OSM data)...")
                        let result = try await generateOSRMRoute(
                            from: location,
                            targetDurationMinutes: duration,
                            pois: cacheablePOIs
                        )
                        
                        // Validate route
                        guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                            print("      ⚠️ Skipping \(duration)min route - validation failed (places: \(result.places.count), distance: \(result.distanceMeters)m, duration: \(result.durationSeconds)s)")
                            await MainActor.run {
                                currentStatus = "\(area.postcode): Skipped \(duration)min (invalid)"
                            }
                            continue
                        }
                        
                        print("      ✅ \(duration)min route: \(result.places.count) POIs, \(result.distanceMeters)m, \(result.durationSeconds/60)min")
                        
                        // Get route name and description (optional - can be nil)
                        // Note: Gemini names/descriptions would require additional API calls
                        // For now, we'll store routes without names (they can be generated later)
                        
                        // Convert to pre-populated format
                        let routePOIs = result.places.map { place -> PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI in
                    PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI(
                        placeId: place.placeId,
                        name: place.name,
                        latitude: place.coordinate.latitude,
                        longitude: place.coordinate.longitude,
                        types: place.types ?? [],
                        vicinity: place.vicinity,
                        source: place.source.rawValue,
                        rating: nil  // Optional rating (can be set via spreadsheet editing)
                    )
                        }
                        
                        // Get directions if available (from result.legs)
                        let directions: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute.PrePopulatedDirection]? = {
                            // Extract directions from legs if available
                            // Note: This depends on how GoogleMapsService returns directions
                            // For now, return nil (can be enhanced later)
                            return nil
                        }()
                        
                        let routeData = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute.PrePopulatedRouteData(
                            places: routePOIs,
                            polyline: result.polyline,
                            distanceMeters: result.distanceMeters,
                            durationSeconds: result.durationSeconds,
                            name: nil,  // Can be generated later with Gemini
                            description: nil,  // Can be generated later with Gemini
                            directions: directions
                        )
                        
                        // Check if we already have a route group for this duration
                        if let existingIndex = routeGroups.firstIndex(where: { $0.durationMinutes == duration }) {
                            // Add to existing group (limit to 3 routes per duration to keep file size manageable)
                            let existingGroup = routeGroups[existingIndex]
                            if existingGroup.routes.count < 3 {
                                var updatedRoutes = existingGroup.routes
                                updatedRoutes.append(routeData)
                                routeGroups[existingIndex] = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute(
                                    durationMinutes: duration,
                                    routes: updatedRoutes
                                )
                                
                                await MainActor.run {
                                    routesGenerated += 1
                                    currentStatus = "\(area.postcode): \(duration)min route (\(updatedRoutes.count)/3) - Total: \(routesGenerated)"
                                }
                                
                                print("      ✅ Added \(duration)min route (\(updatedRoutes.count)/3) - Total routes: \(routesGenerated)")
                            } else {
                                print("      ⏭️ Skipping \(duration)min route (already have 3)")
                            }
                        } else {
                            // Create new route group
                            let routeGroup = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute(
                                durationMinutes: duration,
                                routes: [routeData]
                            )
                            routeGroups.append(routeGroup)
                            
                            await MainActor.run {
                                routesGenerated += 1
                                currentStatus = "\(area.postcode): \(duration)min route - Total: \(routesGenerated)"
                            }
                            
                            print("      ✅ Generated \(duration)min route - Total routes: \(routesGenerated)")
                        }
                        
                        // Small delay between route generations
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        
                    } catch {
                        await MainActor.run {
                            currentStatus = "\(area.postcode): Error on \(duration)min route - continuing..."
                        }
                        print("      ❌ Error generating \(duration)min route: \(error.localizedDescription)")
                        print("      📝 Error details: \(error)")
                        // Continue with other durations
                    }
                }
                
                let totalRoutesInArea = routeGroups.reduce(0) { $0 + $1.routes.count }
                await MainActor.run {
                    currentStatus = "✅ \(area.postcode): \(totalRoutesInArea) routes (\(routeGroups.count) groups)"
                }
                
                print("   ✅ Completed \(area.postcode): \(totalRoutesInArea) routes across \(routeGroups.count) duration groups")
                
                // Create postcode area entry with POIs and routes
                let areaPOIs = PrePopulatedPOIService.PrePopulatedPOIDatabase.PostcodeAreaPOIs(
                    postcode: area.postcode,
                    centerLatitude: area.lat,
                    centerLongitude: area.lon,
                    radiusMeters: radiusMeters,
                    pois: prePopulatedPOIs,
                    routes: routeGroups.isEmpty ? nil : routeGroups
                )
                
                postcodeAreaPOIs.append(areaPOIs)
                
            } catch {
                let errorMessage: String
                if error is POIGeneratorTimeoutError {
                    errorMessage = "Timeout after 60 seconds - OSM/Geograph API too slow"
                } else {
                    errorMessage = error.localizedDescription
                }
                
                await MainActor.run {
                    currentStatus = "⚠️ \(area.postcode): Error - skipping area..."
                }
                
                print("   ❌ Error fetching POIs for \(area.postcode): \(errorMessage)")
                print("   📝 Full error: \(error)")
                print("   ⏭️ Continuing with next postcode area...")
                // Continue with other postcodes even if one fails
            }
            
            // Add a small delay between requests to be respectful to APIs
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        // Create database structure
        await MainActor.run {
            currentStatus = "Saving database to file..."
        }
        print("\n📦 Creating database structure...")
        
        let database = PrePopulatedPOIService.PrePopulatedPOIDatabase(
            version: 1,
            lastUpdated: Date(),
            postcodeAreas: postcodeAreaPOIs
        )
        
        let totalPOIs = postcodeAreaPOIs.reduce(0) { $0 + $1.pois.count }
        let totalRoutes = postcodeAreaPOIs.compactMap { $0.routes }.flatMap { $0 }.reduce(0) { $0 + $1.routes.count }
        
        await MainActor.run {
            isGenerating = false
            currentStatus = "✅ Complete! \(postcodeAreaPOIs.count) areas, \(totalPOIs) POIs, \(totalRoutes) routes"
        }
        
        print("\n📦 ✅ Database generation complete!")
        print("   📊 Summary:")
        print("   - Postcode areas: \(postcodeAreaPOIs.count)/8")
        print("   - Total POIs: \(totalPOIs)")
        print("   - Total routes: \(totalRoutes)")
        print("   - Routes generated this session: \(routesGenerated)")
        
        return database
    }
    
    /// Save database to JSON file
    func saveDatabaseToFile(_ database: PrePopulatedPOIService.PrePopulatedPOIDatabase, filename: String = "prepopulated_pois.json") throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(database)
        
        // Save to Documents directory (or you can change this to Desktop for easier access)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(filename)
        
        try data.write(to: fileURL)
        
        print("📦 Database saved to: \(fileURL.path)")
        return fileURL
    }
    
    // NOTE: Full database generation is now done on computer using generate_database.py
    // This function is kept for reference but should not be used
    @available(*, deprecated, message: "Use generate_database.py script on computer instead")
    func generateAndSaveDatabase() async throws -> URL {
        let database = try await generateDatabase()
        return try saveDatabaseToFile(database)
    }
    
    /// Add routes to existing database (loads POIs from existing file, only generates routes)
    /// Use this when POIs are already in the database and you only need to add routes
    func addRoutesToExistingDatabase() async throws -> URL {
        await MainActor.run {
            isGenerating = true
            routesGenerated = 0
            currentStatus = "Loading existing database..."
        }
        
        print("📦 Loading existing database to add routes...")
        
        // Load existing database from bundle
        guard let existingDatabase = PrePopulatedPOIService.shared.loadBundledDatabase() else {
            await MainActor.run {
                isGenerating = false
                currentStatus = "❌ No existing database found"
            }
            throw NSError(domain: "PrePopulatedPOIGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "No existing database found. Run generateDatabase() first."])
        }
        
        await MainActor.run {
            totalPostcodes = existingDatabase.postcodeAreas.count
            currentStatus = "Found \(existingDatabase.postcodeAreas.count) postcode areas with POIs"
        }
        
        print("📦 Found existing database with \(existingDatabase.postcodeAreas.count) postcode areas")
        let totalPOIs = existingDatabase.postcodeAreas.reduce(0) { $0 + $1.pois.count }
        print("📦 Total POIs in database: \(totalPOIs)")
        
        var updatedAreas: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PostcodeAreaPOIs] = []
        
        for (index, area) in existingDatabase.postcodeAreas.enumerated() {
            await MainActor.run {
                currentPostcodeIndex = index + 1
                currentPostcode = area.postcode
                currentStatus = "Processing \(area.postcode) (\(index + 1)/\(existingDatabase.postcodeAreas.count))..."
            }
            
            print("\n📦 Processing postcode area \(index + 1)/\(existingDatabase.postcodeAreas.count): \(area.postcode)")
            print("   Using \(area.pois.count) existing POIs")
            
            // Convert PrePopulatedPOI to PlaceResult for route generation
            // IMPORTANT: Only use OSM and Geograph POIs (Apple POIs already filtered out in database)
            let placeResults = area.pois
                .filter { poi -> Bool in
                    // Only use cacheable sources (OSM, Geograph)
                    let source = POISource.fromString(poi.source)
                    return source == .osm || source == .geograph
                }
                .map { poi -> PlaceResult in
                    PlaceResult(
                        placeId: poi.placeId,
                        name: poi.name,
                        vicinity: poi.vicinity,
                        geometry: PlaceGeometry(
                            location: PlaceLocation(
                                lat: poi.latitude,
                                lng: poi.longitude
                            )
                        ),
                        types: poi.types,
                        source: POISource.fromString(poi.source)
                    )
                }
            
            print("   ✅ Using \(placeResults.count) cacheable POIs (OSM + Geograph) for route generation")
            
            let location = CLLocationCoordinate2D(
                latitude: area.centerLatitude,
                longitude: area.centerLongitude
            )
            
            // Generate routes for common durations (5, 10, 15, 20, 30, 45, 60 minutes)
            // IMPORTANT: Use OSRM (not MapKit) - Apple doesn't allow caching MapKit routes
            print("   🗺️ Generating routes using OSRM (OSM data, cacheable)...")
            var routeGroups: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute] = []
            let durationsToGenerate = [5, 10, 15, 20, 30, 45, 60]
            
            for duration in durationsToGenerate {
                await MainActor.run {
                    currentDuration = duration
                    currentStatus = "\(area.postcode): Generating \(duration)min route (OSRM)..."
                }
                
                do {
                    // Generate routes using OSRM (OSM data, cacheable)
                    let result = try await generateOSRMRoute(
                        from: location,
                        targetDurationMinutes: duration,
                        pois: placeResults
                    )
                    
                    // Validate route
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        print("      ⚠️ Skipping \(duration)min route (validation failed)")
                        continue
                    }
                    
                    // Convert to pre-populated format
                    let routePOIs = result.places.map { place -> PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI in
                        PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI(
                            placeId: place.placeId,
                            name: place.name,
                            latitude: place.coordinate.latitude,
                            longitude: place.coordinate.longitude,
                            types: place.types ?? [],
                            vicinity: place.vicinity,
                            source: place.source.rawValue,
                            rating: nil  // Optional rating (can be set via spreadsheet editing)
                        )
                    }
                    
                    // Get directions if available (from result.legs)
                    let directions: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute.PrePopulatedDirection]? = {
                        // Extract directions from legs if available
                        // Note: This depends on how GoogleMapsService returns directions
                        // For now, return nil (can be enhanced later)
                        return nil
                    }()
                    
                    let routeData = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute.PrePopulatedRouteData(
                        places: routePOIs,
                        polyline: result.polyline,
                        distanceMeters: result.distanceMeters,
                        durationSeconds: result.durationSeconds,
                        name: nil,  // Can be generated later with Gemini
                        description: nil,  // Can be generated later with Gemini
                        directions: directions
                    )
                    
                    // Check if we already have a route group for this duration
                    if let existingIndex = routeGroups.firstIndex(where: { $0.durationMinutes == duration }) {
                        // Add to existing group (limit to 3 routes per duration to keep file size manageable)
                        let existingGroup = routeGroups[existingIndex]
                        if existingGroup.routes.count < 3 {
                            var updatedRoutes = existingGroup.routes
                            updatedRoutes.append(routeData)
                            routeGroups[existingIndex] = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute(
                                durationMinutes: duration,
                                routes: updatedRoutes
                            )
                            print("      ✅ Added \(duration)min route (\(updatedRoutes.count)/3)")
                        } else {
                            print("      ⏭️ Skipping \(duration)min route (already have 3)")
                        }
                        } else {
                            // Create new route group
                            let routeGroup = PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute(
                                durationMinutes: duration,
                                routes: [routeData]
                            )
                            routeGroups.append(routeGroup)
                            
                            await MainActor.run {
                                routesGenerated += 1
                                currentStatus = "\(area.postcode): Generated \(duration)min route (\(routesGenerated) total)"
                            }
                            
                            print("      ✅ Generated \(duration)min route")
                        }
                        
                        // Small delay between route generations
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    
                } catch {
                    print("      ❌ Error generating \(duration)min route: \(error.localizedDescription)")
                    // Continue with other durations
                }
            }
            
            await MainActor.run {
                currentStatus = "\(area.postcode): Completed (\(routeGroups.count) route groups)"
            }
            
            print("   ✅ Generated routes for \(routeGroups.count) duration(s)")
            
            // Create updated postcode area entry with existing POIs and new routes
            let updatedArea = PrePopulatedPOIService.PrePopulatedPOIDatabase.PostcodeAreaPOIs(
                postcode: area.postcode,
                centerLatitude: area.centerLatitude,
                centerLongitude: area.centerLongitude,
                radiusMeters: area.radiusMeters,
                pois: area.pois,  // Keep existing POIs
                routes: routeGroups.isEmpty ? nil : routeGroups  // Add new routes
            )
            
            updatedAreas.append(updatedArea)
            
            // Add a small delay between postcode areas
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        // Create updated database structure
        let updatedDatabase = PrePopulatedPOIService.PrePopulatedPOIDatabase(
            version: existingDatabase.version,
            lastUpdated: Date(),
            postcodeAreas: updatedAreas
        )
        
        let totalRoutes = updatedAreas.compactMap { $0.routes }.flatMap { $0 }.reduce(0) { $0 + $1.routes.count }
        
        await MainActor.run {
            isGenerating = false
            currentStatus = "✅ Complete! \(totalRoutes) routes added"
        }
        
        print("\n📦 Route generation complete!")
        print("   Total postcode areas: \(updatedAreas.count)")
        print("   Total POIs: \(totalPOIs) (unchanged)")
        print("   Total routes: \(totalRoutes)")
        
        return try saveDatabaseToFile(updatedDatabase)
    }
}

// MARK: - Usage Note
/*
 NOTE: Database generation is now done on computer using generate_database.py
 
 To generate the database:
 1. Run: python3 generate_database.py
 2. Copy prepopulated_pois.json to WalkingWR/ folder
 3. Add to Xcode project (if not auto-included)
 
 The app will automatically load the database from the bundle on first launch.
 
 Optional: Use addRoutesToExistingDatabase() if you need to add routes from the app.
 */
