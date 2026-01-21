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

/// Utility class to generate pre-populated POI database
/// Call generateDatabase() to create the JSON file
class PrePopulatedPOIGenerator: ObservableObject {
    
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
    
    /// Generate the pre-populated POI database by fetching POIs for each postcode area
    /// This will query OSM and Geograph APIs to build the database
    func generateDatabase() async throws -> PrePopulatedPOIService.PrePopulatedPOIDatabase {
        await MainActor.run {
            isGenerating = true
            totalPostcodes = postcodeAreas.count
            currentStatus = "Starting database generation..."
        }
        
        print("📦 Starting database generation for \(postcodeAreas.count) postcode areas...")
        
        var postcodeAreaPOIs: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PostcodeAreaPOIs] = []
        
        for (index, area) in postcodeAreas.enumerated() {
            await MainActor.run {
                currentPostcodeIndex = index + 1
                currentPostcode = area.postcode
                currentStatus = "Processing \(area.postcode)..."
            }
            
            print("\n📦 Processing postcode area \(index + 1)/\(postcodeAreas.count): \(area.postcode)")
            print("   Location: (\(area.lat), \(area.lon))")
            
            let location = CLLocationCoordinate2D(latitude: area.lat, longitude: area.lon)
            let radiusMeters = 2500
            
            // Fetch POIs using the existing service (will use OSM + Geograph)
            do {
                await MainActor.run {
                    currentStatus = "Fetching POIs from OSM and Geograph..."
                }
                
                // Skip Google to save costs - we only want free sources
                let pois = try await GoogleMapsService.shared.findNearbyPlaces(
                    location: location,
                    radiusMeters: radiusMeters,
                    skipGoogle: true
                )
                
                await MainActor.run {
                    currentStatus = "Found \(pois.count) POIs - generating routes..."
                }
                
                print("   ✅ Found \(pois.count) POIs")
                
                // Convert PlaceResult to PrePopulatedPOI
                let prePopulatedPOIs = pois.map { poi -> PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI in
                    PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedPOI(
                        placeId: poi.placeId,
                        name: poi.name,
                        latitude: poi.coordinate.latitude,
                        longitude: poi.coordinate.longitude,
                        types: poi.types ?? [],
                        vicinity: poi.vicinity,
                        source: poi.source.rawValue
                    )
                }
                
                // Generate routes for common durations (5, 10, 15, 20, 30, 45, 60 minutes)
                print("   🗺️ Generating routes...")
                var routeGroups: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute] = []
                let durationsToGenerate = [5, 10, 15, 20, 30, 45, 60]
                
                for duration in durationsToGenerate {
                    await MainActor.run {
                        currentDuration = duration
                        currentStatus = "Generating \(duration)min route..."
                    }
                    
                    do {
                        // Generate routes for this duration
                        let result = try await GoogleMapsService.shared.generateLocalRoute(
                            from: location,
                            targetDurationMinutes: duration,
                            difficulty: nil,
                            excludePlaceIds: [],
                            excludePOIs: [],
                            prefetchedPOIs: pois
                        )
                        
                        // Validate route
                        guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                            print("      ⚠️ Skipping \(duration)min route (validation failed)")
                            continue
                        }
                        
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
                                source: place.source.rawValue
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
                                    currentStatus = "Added \(duration)min route (\(updatedRoutes.count)/3) - \(routesGenerated) total"
                                }
                                
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
                                currentStatus = "Generated \(duration)min route (\(routesGenerated) total)"
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
                    currentStatus = "Completed \(area.postcode) - \(routeGroups.count) route groups"
                }
                
                print("   ✅ Generated routes for \(routeGroups.count) duration(s)")
                
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
                print("   ❌ Error fetching POIs for \(area.postcode): \(error.localizedDescription)")
                // Continue with other postcodes even if one fails
            }
            
            // Add a small delay between requests to be respectful to APIs
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        // Create database structure
        let database = PrePopulatedPOIService.PrePopulatedPOIDatabase(
            version: 1,
            lastUpdated: Date(),
            postcodeAreas: postcodeAreaPOIs
        )
        
        let totalPOIs = postcodeAreaPOIs.reduce(0) { $0 + $1.pois.count }
        
        await MainActor.run {
            isGenerating = false
            currentStatus = "✅ Complete! \(totalPOIs) POIs, \(routesGenerated) routes"
        }
        
        print("\n📦 Database generation complete!")
        print("   Total postcode areas: \(postcodeAreaPOIs.count)")
        print("   Total POIs: \(totalPOIs)")
        
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
    
    /// Generate and save database in one call
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
            let placeResults = area.pois.map { poi -> PlaceResult in
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
            
            let location = CLLocationCoordinate2D(
                latitude: area.centerLatitude,
                longitude: area.centerLongitude
            )
            
            // Generate routes for common durations (5, 10, 15, 20, 30, 45, 60 minutes)
            print("   🗺️ Generating routes using MapKit...")
            var routeGroups: [PrePopulatedPOIService.PrePopulatedPOIDatabase.PrePopulatedRoute] = []
            let durationsToGenerate = [5, 10, 15, 20, 30, 45, 60]
            
            for duration in durationsToGenerate {
                await MainActor.run {
                    currentDuration = duration
                    currentStatus = "\(area.postcode): Generating \(duration)min route..."
                }
                
                do {
                    // Generate routes for this duration using existing POIs
                    let result = try await GoogleMapsService.shared.generateLocalRoute(
                        from: location,
                        targetDurationMinutes: duration,
                        difficulty: nil,
                        excludePlaceIds: [],
                        excludePOIs: [],
                        prefetchedPOIs: placeResults  // Use existing POIs from database
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
                            source: place.source.rawValue
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

// MARK: - Usage Example
/*
 To use this generator, you can call it from anywhere in your app:
 
 Task {
     let generator = PrePopulatedPOIGenerator()
     do {
         let fileURL = try await generator.generateAndSaveDatabase()
         print("✅ Database generated at: \(fileURL.path)")
         // Then copy the file to your Xcode project and add it to the bundle
     } catch {
         print("❌ Error generating database: \(error)")
     }
 }
 
 Or add a button in your debug/settings view to trigger it:
 
 Button("Generate POI Database") {
     Task {
         let generator = PrePopulatedPOIGenerator()
         do {
             let fileURL = try await generator.generateAndSaveDatabase()
             // Show success message
         } catch {
             // Show error message
         }
     }
 }
 */
