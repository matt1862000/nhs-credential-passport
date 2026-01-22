//
//  PrePopulatedPOIService.swift
//  WalkingWR
//
//  Pre-populated POI database for common NHS clinic postcode areas
//  Downloads on first app start to speed up POI fetching
//

import Foundation
import CoreLocation
import FirebaseStorage

/// Service for managing pre-populated POI database
/// Downloads POIs for common NHS clinic postcode areas on first app start
class PrePopulatedPOIService {
    static let shared = PrePopulatedPOIService()
    
    // Postcode areas to pre-populate (Sheffield/Wakefield NHS clinics)
    private let targetPostcodes = [
        "WF2 0GU",  // Wakefield area
        "S5 7JT",   // Sheffield area
        "S35 0JW",  // Sheffield area
        "S1 4JP",   // Sheffield city centre
        "S5 7AU",   // Sheffield area
        "S8 8BG",   // Sheffield area
        "S35 1RQ",  // Sheffield area
        "S11 9BF"   // Sheffield area
    ]
    
    // Firebase Storage reference for pre-populated POI database
    private let storage = Storage.storage()
    private let databaseFileName = "prepopulated_pois.json"
    
    // URL for downloading pre-populated POI database
    // Uses Firebase Storage - no bundled database fallback
    private func getDatabaseURL() async -> URL? {
        let storageRef = storage.reference().child(databaseFileName)
        
        do {
            // Get download URL from Firebase Storage
            let downloadURL = try await storageRef.downloadURL()
            print("📦 Pre-populated DB: Got Firebase Storage URL: \(downloadURL.absoluteString)")
            return downloadURL
        } catch {
            print("📦 Pre-populated DB: Failed to get Firebase Storage URL: \(error.localizedDescription)")
            print("📦 Pre-populated DB: No bundled database - will use cached database if available, otherwise API calls")
            return nil
        }
    }
    
    // Local storage key
    private let storageKey = "prepopulatedPOIs_v1"
    private let downloadCompleteKey = "prepopulatedPOIsDownloaded"
    
    private init() {}
    
    // MARK: - Database Structure
    
    struct PrePopulatedPOIDatabase: Codable {
        let version: Int
        let lastUpdated: Date
        let postcodeAreas: [PostcodeAreaPOIs]
        
        struct PostcodeAreaPOIs: Codable {
            let postcode: String
            let centerLatitude: Double
            let centerLongitude: Double
            let radiusMeters: Int
            let pois: [PrePopulatedPOI]
            let routes: [PrePopulatedRoute]?  // Optional: routes for this postcode area
        }
        
        struct PrePopulatedPOI: Codable {
            let placeId: String
            let name: String
            let latitude: Double
            let longitude: Double
            let types: [String]
            let vicinity: String?
            let source: String  // "osm", "geograph" (Apple POIs not cached - Apple restriction)
            let rating: Double?  // Optional rating (e.g., 1.0 to 5.0)
        }
        
        struct PrePopulatedRoute: Codable {
            let durationMinutes: Int
            let routes: [PrePopulatedRouteData]  // Multiple routes for this duration
            
            struct PrePopulatedRouteData: Codable {
                let places: [PrePopulatedPOI]  // POIs in the route
                let polyline: String  // Encoded polyline
                let distanceMeters: Int
                let durationSeconds: Int
                let name: String?  // Gemini-generated name
                let description: String?  // Gemini-generated description
                let directions: [PrePopulatedDirection]?  // Turn-by-turn directions
            }
            
            struct PrePopulatedDirection: Codable {
                let instruction: String
                let distance: String
                let distanceMeters: Int
                let duration: String
                let maneuver: String?
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Check if pre-populated database has been downloaded
    var hasDownloadedDatabase: Bool {
        UserDefaults.standard.bool(forKey: downloadCompleteKey)
    }
    
    /// Get POIs from pre-populated database near the given location
    /// Returns POIs if within any postcode area's radius, nil otherwise
    /// PRIORITY: This is checked FIRST before any API calls
    func getPrePopulatedPOIs(near location: CLLocationCoordinate2D, radiusMeters: Double = 2500) -> [PlaceResult]? {
        guard let database = loadDatabase() else {
            print("📦 Pre-populated DB: No database loaded (not downloaded or bundled)")
            return nil
        }
        
        var matchingPOIs: [PlaceResult] = []
        var matchedPostcode: String? = nil
        
        // Check each postcode area
        for area in database.postcodeAreas {
            let areaCenter = CLLocationCoordinate2D(
                latitude: area.centerLatitude,
                longitude: area.centerLongitude
            )
            
            let distanceToArea = distanceBetween(location, areaCenter)
            let searchRadius = Double(area.radiusMeters)
            
            // If user location is within this postcode area's coverage
            // (user search radius + area coverage radius = overlap zone)
            if distanceToArea <= searchRadius + radiusMeters {
                matchedPostcode = area.postcode
                print("📦 Pre-populated DB: User location matches postcode area '\(area.postcode)' (distance: \(Int(distanceToArea))m from center)")
                
                // Filter POIs within the user's search radius
                for poi in area.pois {
                    let poiCoord = CLLocationCoordinate2D(
                        latitude: poi.latitude,
                        longitude: poi.longitude
                    )
                    let distanceToPOI = distanceBetween(location, poiCoord)
                    
                    if distanceToPOI <= radiusMeters {
                        // Convert to PlaceResult
                        let placeResult = PlaceResult(
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
                        // Note: rating is stored in PrePopulatedPOI but not used in PlaceResult
                        // Can be accessed via PrePopulatedPOIService if needed for filtering/scoring
                        matchingPOIs.append(placeResult)
                    }
                }
                
                // Found matching area - no need to check others
                break
            }
        }
        
        if !matchingPOIs.isEmpty {
            print("📦 ✅ PRE-POPULATED DB HIT! Found \(matchingPOIs.count) POIs from postcode area '\(matchedPostcode ?? "unknown")' - using database (no API calls needed)")
            return matchingPOIs
        } else if matchedPostcode != nil {
            print("📦 Pre-populated DB: User in postcode area '\(matchedPostcode!)' but no POIs found within \(Int(radiusMeters))m radius")
        } else {
            print("📦 Pre-populated DB: User location not in any postcode area coverage zone")
        }
        
        return nil
    }
    
    /// Get routes from pre-populated database near the given location
    /// Returns routes for the specified duration if within any postcode area's radius, nil otherwise
    /// PRIORITY: This is checked FIRST before generating new routes
    func getPrePopulatedRoutes(near location: CLLocationCoordinate2D, durationMinutes: Int, radiusMeters: Double = 2500) -> [RouteCacheService.CachedRouteWithMetadata]? {
        guard let database = loadDatabase() else {
            print("📦 Pre-populated DB: No database loaded for routes (not downloaded or bundled)")
            return nil
        }
        
        // Round to nearest 5 minutes (matching RouteCacheService behavior)
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        
        // Check each postcode area
        for area in database.postcodeAreas {
            guard let routes = area.routes else { continue }
            
            let areaCenter = CLLocationCoordinate2D(
                latitude: area.centerLatitude,
                longitude: area.centerLongitude
            )
            
            let distanceToArea = distanceBetween(location, areaCenter)
            let searchRadius = Double(area.radiusMeters)
            
            // If user location is within this postcode area's coverage
            if distanceToArea <= searchRadius + radiusMeters {
                print("📦 Pre-populated DB: User location matches postcode area '\(area.postcode)' for routes (distance: \(Int(distanceToArea))m from center)")
                
                // Find routes for this duration
                if let routeGroup = routes.first(where: { $0.durationMinutes == roundedDuration }) {
                    // Convert to CachedRouteWithMetadata format
                    var cachedRoutes: [RouteCacheService.CachedRouteWithMetadata] = []
                    
                    for routeData in routeGroup.routes {
                        // Convert POIs to PlaceResult
                        let places = routeData.places.map { poi -> PlaceResult in
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
                        
                        // Create GeneratedRoute
                        let generatedRoute = GeneratedRoute(
                            places: places,
                            polyline: routeData.polyline,
                            distanceMeters: routeData.distanceMeters,
                            durationSeconds: routeData.durationSeconds,
                            legs: []  // Legs not stored in pre-populated database
                        )
                        
                        // Convert directions
                        let walkingDirections = routeData.directions?.map { dir -> WalkingDirection in
                            WalkingDirection(
                                instruction: dir.instruction,
                                distance: dir.distance,
                                distanceMeters: dir.distanceMeters,
                                duration: dir.duration,
                                maneuver: dir.maneuver
                            )
                        }
                        
                        // Create CachedRouteWithMetadata
                        let cachedRoute = RouteCacheService.CachedRouteWithMetadata(
                            route: generatedRoute,
                            name: routeData.name,
                            description: routeData.description,
                            directions: walkingDirections
                        )
                        
                        cachedRoutes.append(cachedRoute)
                    }
                    
                    if !cachedRoutes.isEmpty {
                        print("📦 ✅ PRE-POPULATED ROUTES HIT! Found \(cachedRoutes.count) routes for \(roundedDuration)min from postcode area '\(area.postcode)' - using database (no route generation needed)")
                        return cachedRoutes
                    } else {
                        print("📦 Pre-populated DB: Postcode area '\(area.postcode)' has routes but none for \(roundedDuration)min duration")
                    }
                } else {
                    print("📦 Pre-populated DB: Postcode area '\(area.postcode)' has no routes for \(roundedDuration)min duration")
                }
            }
        }
        
        print("📦 Pre-populated DB: No routes found - user location not in any postcode area or no routes for \(roundedDuration)min")
        return nil
    }
    
    /// Download pre-populated database on app start
    /// ALWAYS downloads from Firebase Storage - never uses bundled database
    /// PRIORITY: This ensures database is always up-to-date from Firebase
    func downloadDatabaseIfNeeded() async {
        // ALWAYS try to get download URL from Firebase Storage
        guard let url = await getDatabaseURL() else {
            // No Firebase Storage URL available - use cached database if available, otherwise fail
            if hasDownloadedDatabase {
                print("📦 Pre-populated DB: No Firebase Storage URL available, using cached database")
                print("📦 Pre-populated DB: ⚠️  Will retry Firebase download on next app launch")
            } else {
                print("📦 Pre-populated DB: ❌ No Firebase Storage URL available and no cached database")
                print("📦 Pre-populated DB: ⚠️  App will use API calls until Firebase is available")
            }
            return
        }
        
        // Check if we need to download (first time or version update)
        // First verify the database actually exists (not just the version key)
        let databaseExists = UserDefaults.standard.data(forKey: storageKey) != nil
        let currentVersion = getCurrentDatabaseVersion()
        var shouldDownload = !hasDownloadedDatabase || !databaseExists
        
        // If database doesn't exist but version key does, we need to download
        if !databaseExists && currentVersion != nil {
            print("📦 Pre-populated DB: Version key exists but database data missing - will download")
            shouldDownload = true
        }
        
        // If we have a cached version, check if Firebase has a newer one
        if let currentVersion = currentVersion, databaseExists {
            print("📦 Pre-populated DB: Current cached version: \(currentVersion)")
            // We'll check the version after downloading to see if it's newer
            shouldDownload = true  // Always check for updates
        }
        
        if !shouldDownload && hasDownloadedDatabase && databaseExists {
            print("📦 Pre-populated DB: Already downloaded, ready for use")
            return
        }
        
        print("📦 Pre-populated DB: Starting download from Firebase Storage...")
        print("📦   URL: \(url.absoluteString)")
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("📦 Pre-populated DB: ❌ Download failed - invalid response (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                if hasDownloadedDatabase {
                    print("📦 Pre-populated DB: Using cached database, will retry Firebase download on next launch")
                } else {
                    print("📦 Pre-populated DB: ⚠️  No cached database available - app will use API calls")
                }
                return
            }
            
            let decoder = createJSONDecoder()
            let database = try decoder.decode(PrePopulatedPOIDatabase.self, from: data)
            
            // Check if database actually exists (not just version key)
            let databaseExists = UserDefaults.standard.data(forKey: storageKey) != nil
            
            // Check if this version is newer than what we have
            if let currentVersion = currentVersion, databaseExists {
                if database.version <= currentVersion {
                    print("📦 Pre-populated DB: Firebase version (\(database.version)) is not newer than cached version (\(currentVersion)), keeping cached database")
                    print("📦 Pre-populated DB: To force update, clear database using debug button or increment version in Firebase")
                    return
                } else {
                    print("📦 Pre-populated DB: Firebase version (\(database.version)) is newer than cached version (\(currentVersion)) - updating database")
                }
            } else {
                if !databaseExists {
                    print("📦 Pre-populated DB: Database data missing (version key may exist but data is gone) - saving new database (version: \(database.version))")
                } else {
                    print("📦 Pre-populated DB: No cached version found - saving new database (version: \(database.version))")
                }
            }
            
            // Save to local storage
            saveDatabase(database)
            
            // Mark as downloaded
            UserDefaults.standard.set(true, forKey: downloadCompleteKey)
            UserDefaults.standard.set(database.version, forKey: "prepopulatedPOIs_version")
            
            let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
            let totalRoutes = database.postcodeAreas.compactMap { $0.routes }.flatMap { $0 }.reduce(0) { $0 + $1.routes.count }
            print("📦 ✅ Pre-populated DB: Downloaded successfully from Firebase Storage!")
            print("📦   Version: \(database.version)")
            print("📦   Postcode areas: \(database.postcodeAreas.count)")
            print("📦   Total POIs: \(totalPOIs)")
            print("📦   Total routes: \(totalRoutes)")
            print("📦   Database will be used PRIORITY 0 for POI/route fetching")
            return
            
        } catch {
            print("📦 Pre-populated DB: ❌ Download error: \(error.localizedDescription)")
            if hasDownloadedDatabase {
                print("📦 Pre-populated DB: Using cached database, will retry Firebase download on next launch")
            } else {
                print("📦 Pre-populated DB: ⚠️  No cached database available - app will use API calls")
            }
            return
        }
    }
    
    /// Get the version of the currently cached database
    /// Returns nil if database doesn't exist, even if version key exists
    private func getCurrentDatabaseVersion() -> Int? {
        // First check if database data actually exists
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            // Database doesn't exist - clear version key if it exists (stale data)
            if UserDefaults.standard.object(forKey: "prepopulatedPOIs_version") != nil {
                UserDefaults.standard.removeObject(forKey: "prepopulatedPOIs_version")
                print("📦 Pre-populated DB: Cleared stale version key (database data missing)")
            }
            return nil
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? Int {
                return version
            }
        } catch {
            // Ignore errors - return nil if can't parse
        }
        
        return nil
    }
    
    /// Load pre-populated database from cache (UserDefaults)
    /// Database is always downloaded from Firebase - no bundled database
    /// Made public for route generation
    func loadBundledDatabase() -> PrePopulatedPOIDatabase? {
        // No bundled database - always use cached database from Firebase download
        return loadDatabase()
    }
    
    /// Clear pre-populated database (for testing/reset)
    func clearDatabase() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: downloadCompleteKey)
        UserDefaults.standard.removeObject(forKey: "prepopulatedPOIs_version")  // Also clear version key
        print("📦 Pre-populated DB: Cleared (database, download flag, and version)")
    }
    
    /// Get database statistics
    func getDatabaseStats() -> (postcodeAreas: Int, totalPOIs: Int)? {
        guard let database = loadDatabase() else {
            return nil
        }
        
        let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
        return (database.postcodeAreas.count, totalPOIs)
    }
    
    // MARK: - Private Methods
    
    /// Create JSONDecoder with proper date decoding strategy for ISO8601 with fractional seconds
    private func createJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            
            // Decode as string (new format from Python script)
            let dateString = try container.decode(String.self)
            
            // Try with fractional seconds first
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Fallback to standard ISO8601
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }
        return decoder
    }
    
    private func loadDatabase() -> PrePopulatedPOIDatabase? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            // No cached database - don't use bundled, return nil
            print("📦 Pre-populated DB: No cached database in UserDefaults - will use API calls")
            print("📦 Pre-populated DB: ⚠️  Database should download from Firebase on next app launch")
            return nil
        }
        
        do {
            // First, check if the cached data has numeric timestamps (old format)
            // If so, convert it to the new string format before decoding
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lastUpdated = json["lastUpdated"],
               lastUpdated is NSNumber {
                // Old format detected - clear cache
                print("📦 Pre-populated DB: ⚠️  Old cached format detected (numeric timestamp) - clearing cache")
                print("📦 Pre-populated DB:   This should not happen if database was downloaded from Firebase")
                print("📦 Pre-populated DB:   Database may need to be regenerated with new format")
                clearDatabase()
                print("📦 Pre-populated DB: Will download fresh database from Firebase on next app launch")
                return nil
            }
            
            let decoder = createJSONDecoder()
            let database = try decoder.decode(PrePopulatedPOIDatabase.self, from: data)
            
            // Log which database source is being used
            print("📦 Pre-populated DB: ✅ Using CACHED database from UserDefaults")
            print("📦   Version: \(database.version)")
            print("📦   Postcode areas: \(database.postcodeAreas.count)")
            let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
            print("📦   Total POIs: \(totalPOIs)")
            
            return database
        } catch {
            print("📦 Pre-populated DB: Failed to load cached database - \(error.localizedDescription)")
            print("📦 Pre-populated DB: Error details: \(error)")
            // Clear potentially corrupted cache
            clearDatabase()
            print("📦 Pre-populated DB: Will download fresh database from Firebase on next app launch")
            return nil
        }
    }
    
    private func saveDatabase(_ database: PrePopulatedPOIDatabase) {
        do {
            // Use ISO8601 date encoding to match our decoding strategy
            // This prevents the "old format" detection on next load
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(database)
            UserDefaults.standard.set(data, forKey: storageKey)
            print("📦 Pre-populated DB: Saved to UserDefaults with ISO8601 date format")
        } catch {
            print("📦 Pre-populated DB: Failed to save - \(error.localizedDescription)")
        }
    }
    
    private func distanceBetween(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let loc2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return loc1.distance(from: loc2)
    }
}

// MARK: - POISource Extension

extension POISource {
    static func fromString(_ string: String) -> POISource {
        switch string.lowercased() {
        case "google": return .google
        case "apple": return .apple
        case "osm": return .osm
        case "geograph": return .geograph
        default: return .unknown
        }
    }
}
