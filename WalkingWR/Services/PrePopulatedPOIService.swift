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
    
    // Prevent concurrent downloads
    private var isDownloading = false
    
    // Postcode areas to pre-populate (All Sheffield districts + Wakefield)
    // Organized by district: S1, S2, S3, etc.
    private let targetPostcodes = [
        "WF2 0GU",  // Wakefield area
        "S1",       // Sheffield city centre
        "S2",       // Sheffield S2
        "S3",       // Sheffield S3
        "S4",       // Sheffield S4
        "S5",       // Sheffield S5 (Northern General Hospital area)
        "S6",       // Sheffield S6
        "S7",       // Sheffield S7
        "S8",       // Sheffield S8
        "S9",       // Sheffield S9
        "S10",      // Sheffield S10 (Hillsborough area)
        "S11",      // Sheffield S11 (Ecclesall area)
        "S12",      // Sheffield S12
        "S13",      // Sheffield S13
        "S14",      // Sheffield S14
        "S17",      // Sheffield S17
        "S20",      // Sheffield S20
        "S21",      // Sheffield S21
        "S25",      // Sheffield S25
        "S26",      // Sheffield S26
        "S35",      // Sheffield S35
        "S36"       // Sheffield S36
    ]
    
    /// Max pre-populated routes to return per (postcode, duration). "Best" = least total time from user (route start + loop). Script emits all; app filters here because user location varies.
    private let maxPrePopulatedRoutesPerBucket = 10

    // Firebase Storage reference for pre-populated POI database
    private let storage = Storage.storage()
    private let databaseFileName = "prepopulated_pois.json"
    
    // URL for downloading pre-populated POI database
    // Tries postcode-specific file first (smaller ~500KB), falls back to full database (11MB)
    private func getDatabaseURL(for postcodeDistrict: String? = nil) async -> URL? {
        // If postcode district is provided, try postcode-specific file first
        if let district = postcodeDistrict {
            let postcodeFileName = "prepopulated_pois_\(district).json"
            let postcodeRef = storage.reference().child(postcodeFileName)
            do {
                let downloadURL = try await postcodeRef.downloadURL()
                print("📦 Pre-populated DB: Found postcode-specific file: \(postcodeFileName) (~500KB)")
                print("\(Self.telem) FIREBASE_URL source=postcode_\(district) file=\(postcodeFileName)")
                return downloadURL
            } catch {
                let nsError = error as NSError?
                print("📦 Pre-populated DB: Postcode-specific file '\(postcodeFileName)' not found, trying full database")
                print("\(Self.telem) FIREBASE_URL postcode_file_missing district=\(district) error=\(error.localizedDescription)")
                print("📦 Pre-populated DB: Error details: \(error.localizedDescription)")
                if let nsError = nsError {
                    print("📦 Pre-populated DB: Error code: \(nsError.code), domain: \(nsError.domain)")
                }
            }
        }
        
        // Fallback to full database
        let storageRef = storage.reference().child(databaseFileName)
        do {
            // Get download URL from Firebase Storage
            let downloadURL = try await storageRef.downloadURL()
            print("📦 Pre-populated DB: Using full database: \(databaseFileName)")
            print("\(Self.telem) FIREBASE_URL source=full file=\(databaseFileName)")
            return downloadURL
        } catch {
            let nsError = error as NSError?
            print("📦 Pre-populated DB: Failed to get Firebase Storage URL: \(error.localizedDescription)")
            print("\(Self.telem) FIREBASE_URL source=none error=\(error.localizedDescription)")
            print("📦 Pre-populated DB: No bundled database - will use cached database if available, otherwise API calls")
            return nil
        }
    }
    
    // Local storage key
    private let storageKey = "prepopulatedPOIs_v1"
    private let downloadCompleteKey = "prepopulatedPOIsDownloaded"
    /// Telemetry: which Firebase file was used (postcode district e.g. "S10", or "full"; unset if never downloaded)
    private let databaseSourceKey = "prepopulatedPOIs_source"
    
    private init() {}
    
    /// Telemetry prefix for database/route logs (filter logs by this)
    private static let telem = "📊 [TELEM]"
    
    /// Known postcode area centers (must match generate_database.py / Apps Script). Used for fallback when DB center is (0,0).
    private static let postcodeCenters: [(postcode: String, lat: Double, lon: Double)] = [
        ("WF2 0GU", 53.7029, -1.5496),
        ("S1", 53.3800, -1.4700), ("S2", 53.3750, -1.4600), ("S3", 53.3850, -1.4850),
        ("S4", 53.3900, -1.4700), ("S5", 53.4100, -1.4600), ("S6", 53.4000, -1.5000),
        ("S7", 53.3600, -1.4900), ("S8", 53.3500, -1.4800), ("S9", 53.3900, -1.4400),
        ("S10", 53.3800, -1.5000), ("S11", 53.3700, -1.5000), ("S12", 53.3600, -1.4400),
        ("S13", 53.3850, -1.4200), ("S14", 53.4000, -1.4400), ("S17", 53.3550, -1.5100),
        ("S20", 53.3400, -1.4500), ("S21", 53.3300, -1.4800), ("S25", 53.4200, -1.4200),
        ("S26", 53.3450, -1.4200), ("S35", 53.4200, -1.4800), ("S36", 53.4350, -1.5000)
    ]
    
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
            
            /// Accept both camelCase and snake_case for center (some generators use center_latitude/center_longitude)
            enum CodingKeys: String, CodingKey {
                case postcode, radiusMeters, pois, routes
                case centerLatitude
                case centerLongitude
                case center_latitude
                case center_longitude
            }
            
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                postcode = try c.decode(String.self, forKey: .postcode)
                centerLatitude = try c.decodeIfPresent(Double.self, forKey: .centerLatitude)
                    ?? c.decodeIfPresent(Double.self, forKey: .center_latitude)
                    ?? 0
                centerLongitude = try c.decodeIfPresent(Double.self, forKey: .centerLongitude)
                    ?? c.decodeIfPresent(Double.self, forKey: .center_longitude)
                    ?? 0
                radiusMeters = try c.decode(Int.self, forKey: .radiusMeters)
                pois = try c.decode([PrePopulatedPOI].self, forKey: .pois)
                routes = try c.decodeIfPresent([PrePopulatedRoute].self, forKey: .routes)
            }
            
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(postcode, forKey: .postcode)
                try c.encode(centerLatitude, forKey: .centerLatitude)
                try c.encode(centerLongitude, forKey: .centerLongitude)
                try c.encode(radiusMeters, forKey: .radiusMeters)
                try c.encode(pois, forKey: .pois)
                try c.encodeIfPresent(routes, forKey: .routes)
            }
            
            /// Memberwise init for generator/callers that build areas programmatically
            init(postcode: String, centerLatitude: Double, centerLongitude: Double, radiusMeters: Int, pois: [PrePopulatedPOI], routes: [PrePopulatedRoute]?) {
                self.postcode = postcode
                self.centerLatitude = centerLatitude
                self.centerLongitude = centerLongitude
                self.radiusMeters = radiusMeters
                self.pois = pois
                self.routes = routes
            }
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
            let areaCenter = effectiveCenter(for: area)
            let distanceToArea = distanceBetween(location, areaCenter)
            let searchRadius = Double(area.radiusMeters)
            let inRadius = distanceToArea <= searchRadius + radiusMeters
            // If user location is within this postcode area's coverage
            // (user search radius + area coverage radius = overlap zone)
            if inRadius {
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
            print("\(Self.telem) DB_LOADED loaded=false reason=not_downloaded requested=\(durationMinutes)")
            return nil
        }
        
        // Round to nearest 5 minutes (matching RouteCacheService behavior)
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        let dbSource = UserDefaults.standard.string(forKey: databaseSourceKey) ?? "unknown"
        let areaList = database.postcodeAreas.map { $0.postcode }.joined(separator: ",")
        print("\(Self.telem) DB_LOADED loaded=true source=\(dbSource) areaCount=\(database.postcodeAreas.count) areas=[\(areaList)] requested=\(durationMinutes) rounded=\(roundedDuration) location=(\(String(format: "%.5f", location.latitude)),\(String(format: "%.5f", location.longitude)))")
        
        // Check each postcode area
        for area in database.postcodeAreas {
            guard let routes = area.routes else {
                print("\(Self.telem) DB_AREA postcode=\(area.postcode) inRadius=skipped reason=no_routes_in_area")
                continue
            }
            
            let areaCenter = effectiveCenter(for: area)
            let distanceToArea = distanceBetween(location, areaCenter)
            let searchRadius = Double(area.radiusMeters)
            let inRadius = distanceToArea <= searchRadius + radiusMeters
            let routeCountInArea = routes.flatMap { $0.routes }.count
            let durationBuckets = routes.map { "\($0.durationMinutes)" }.joined(separator: ",")
            print("\(Self.telem) DB_AREA postcode=\(area.postcode) distanceToCenter=\(Int(distanceToArea))m inRadius=\(inRadius) routeCount=\(routeCountInArea) durationBuckets=[\(durationBuckets)]")
            
            // If user location is within this postcode area's coverage
            if inRadius {
                print("📦 Pre-populated DB: User location matches postcode area '\(area.postcode)' for routes (distance: \(Int(distanceToArea))m from center)")
                
                // Check exact duration first, then adjacent buckets (±5, ±10) so e.g. a 15min ask can use 10min or 20min DB routes if total is within 80–120%
                let durationsToCheck = [roundedDuration, roundedDuration - 5, roundedDuration + 5, roundedDuration - 10, roundedDuration + 10]
                    .filter { $0 >= 5 && $0 <= 60 }
                print("\(Self.telem) DB_QUERY postcode=\(area.postcode) requested=\(durationMinutes) rounded=\(roundedDuration) durationBucketsChecked=[\(durationsToCheck.map { String($0) }.joined(separator: ","))]")
                
                // Collect routes; when requireMinWaypoints == 2 (for duration > 10 min), skip single-waypoint routes. Use 0 to allow all.
                let collectRoutes: (Int) -> [RouteCacheService.CachedRouteWithMetadata] = { requireMinWaypoints in
                    var result: [RouteCacheService.CachedRouteWithMetadata] = []
                    for checkDuration in durationsToCheck {
                        guard let routeGroup = routes.first(where: { $0.durationMinutes == checkDuration }) else { continue }
                        let fromAdjacent = (checkDuration != roundedDuration)
                        if fromAdjacent {
                            print("📦 Pre-populated DB: Checking adjacent duration bucket \(checkDuration)min for \(roundedDuration)min request")
                        }
                        for routeData in routeGroup.routes {
                            let routeName = routeData.name ?? "nil"
                            if requireMinWaypoints >= 2 && routeData.places.count < 2 {
                                continue
                            }
                                // Travel time from current GPS to the route start.
                            // Use first waypoint as start (stored route is first waypoint → … → first waypoint).
                            let routeStart: CLLocationCoordinate2D
                            if let first = routeData.places.first {
                                routeStart = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
                            } else {
                                routeStart = areaCenter
                            }
                            let distanceToStart = self.distanceBetween(location, routeStart)
                            let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)  // m/min
                            let timeToStartSeconds = Int((distanceToStart / walkingSpeedMperMin) * 60)  // Convert to seconds
                            // Total = route loop (first → … → first) + walk from GPS to first waypoint
                            let totalDurationSeconds = routeData.durationSeconds + timeToStartSeconds
                            let totalDurationMinutes = totalDurationSeconds / 60
                            
                            // Accept only when total is 80–120% of requested (75–125% for edge cases e.g. 5min/55min)
                            let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
                            let (minPercent, maxPercent) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
                            let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)
                            let maxAcceptableMinutes = Int(Double(roundedDuration) * maxPercent)
                            
                            if totalDurationMinutes < minAcceptableMinutes || totalDurationMinutes > maxAcceptableMinutes {
                                let travelMin = timeToStartSeconds / 60
                                print("📦 Route '\(routeData.name ?? "nil")': REJECTED - Total duration \(totalDurationMinutes)min (route: \(routeData.durationSeconds/60)min + travel to start: \(travelMin)min) outside 80–120% [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min for requested \(roundedDuration)min")
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=duration totalMin=\(totalDurationMinutes) routeMin=\(routeData.durationSeconds/60) travelMin=\(travelMin) allowed=\(minAcceptableMinutes)-\(maxAcceptableMinutes) requested=\(roundedDuration)")
                                continue
                            }
                            
                            if fromAdjacent {
                                print("📦 Route '\(routeData.name ?? "nil")': ACCEPTED from \(checkDuration)min bucket - Total \(totalDurationMinutes)min within 80–120% of \(roundedDuration)min request (route: \(routeData.durationSeconds/60)min + \(timeToStartSeconds/60)min travel)")
                            } else {
                                print("📦 Route '\(routeData.name ?? "nil")': Added \(timeToStartSeconds/60)min travel from GPS (\(Int(distanceToStart))m) to first waypoint. Route: \(routeData.durationSeconds/60)min → Total: \(totalDurationMinutes)min (within \(minAcceptableMinutes)–\(maxAcceptableMinutes)min)")
                            }
                            
                            // Remove waypoints that are too close so POI trigger zones (~200m) don't overlap. Drops "middle" waypoints (e.g. Village Hall → Outwood → Star Inn becomes Village Hall → Star Inn when Outwood is <200m from Village Hall).
                            let minDist = self.minWaypointDistanceForTriggerZone
                            guard let filteredPOIs = self.filterCloseWaypoints(places: routeData.places, minDistance: minDist) else {
                                print("📦 Route '\(routeData.name ?? "nil")': SKIPPED - after removing waypoints < \(Int(minDist))m apart (trigger zone), no waypoints remain")
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=waypoint_filter minDist=\(Int(minDist)) waypointsRemaining=0")
                                continue
                            }
                            let filteredPlaces = filteredPOIs.map { poi -> PlaceResult in
                                PlaceResult(
                                    placeId: poi.placeId,
                                    name: poi.name,
                                    vicinity: poi.vicinity,
                                    geometry: PlaceGeometry(
                                        location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)
                                    ),
                                    types: poi.types,
                                    source: POISource.fromString(poi.source)
                                )
                            }
                            
                            // Create GeneratedRoute
                            let generatedRoute = GeneratedRoute(
                                places: filteredPlaces,
                                polyline: routeData.polyline,
                                distanceMeters: routeData.distanceMeters,
                                durationSeconds: totalDurationSeconds,  // Includes travel time from GPS to first waypoint
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
                                directions: walkingDirections,
                                isFromPrePopulatedDatabase: true  // Route is first waypoint → … → first; we prepend GPS→first when displaying
                            )
                            
                            result.append(cachedRoute)
                        }
                    }
                    return result
                }
                
                var cachedRoutes = collectRoutes(roundedDuration > 10 ? 2 : 0)
                if cachedRoutes.isEmpty && roundedDuration > 10 {
                    print("📦 Pre-populated DB: No 2+ waypoint routes for \(roundedDuration)min; including 1-waypoint routes as fallback")
                    print("\(Self.telem) DB_FALLBACK postcode=\(area.postcode) reason=no_2plus_waypoints requested=\(roundedDuration)")
                    cachedRoutes = collectRoutes(0)
                }
                
                print("\(Self.telem) DB_CANDIDATES postcode=\(area.postcode) beforeDedupe=\(cachedRoutes.count) requested=\(roundedDuration)")
                
                if !cachedRoutes.isEmpty {
                    // Dedupe routes by same ordered sequence of POIs. Waypoints are the same POI if coords round to the same location (~100m),
                    // so "War Memorial" / "War Memorial, Kirkhamgate" / "War memorial in Kirkhamgate." (one POI, multiple aliases) → one waypoint.
                    func routeKey(_ r: RouteCacheService.CachedRouteWithMetadata) -> String {
                        r.route.places.map { p in
                            let c = p.coordinate
                            return String(format: "%.3f,%.3f", c.latitude, c.longitude)
                        }.joined(separator: "|")
                    }
                    var seen = Set<String>()
                    var unique = [RouteCacheService.CachedRouteWithMetadata]()
                    for r in cachedRoutes {
                        let k = routeKey(r)
                        if seen.contains(k) { continue }
                        seen.insert(k)
                        unique.append(r)
                    }
                    if unique.count < cachedRoutes.count {
                        print("📦 Deduped pre-populated routes: \(cachedRoutes.count) → \(unique.count) unique (by ordered POI sequence)")
                    }
                    print("\(Self.telem) DB_DEDUPE postcode=\(area.postcode) before=\(cachedRoutes.count) after=\(unique.count) requested=\(roundedDuration)")
                    // Sort by total time from user (route.durationSeconds = travel to start + loop), then prefer more direct to POI (shorter distance to first waypoint), then waypoint count and route distance
                    let sorted = unique.sorted { a, b in
                        if a.route.durationSeconds != b.route.durationSeconds {
                            return a.route.durationSeconds < b.route.durationSeconds
                        }
                        // Prefer more direct: shorter distance from user to first POI
                        let distToFirstA = a.route.places.first.map { self.distanceBetween(location, $0.coordinate) } ?? .infinity
                        let distToFirstB = b.route.places.first.map { self.distanceBetween(location, $0.coordinate) } ?? .infinity
                        if distToFirstA != distToFirstB {
                            return distToFirstA < distToFirstB
                        }
                        return (a.route.places.count, -a.route.distanceMeters) > (b.route.places.count, -b.route.distanceMeters)
                    }
                    let capped = Array(sorted.prefix(maxPrePopulatedRoutesPerBucket))
                    if capped.count < sorted.count {
                        print("📦 Best-per-bucket: \(sorted.count) routes → \(capped.count) (max \(maxPrePopulatedRoutesPerBucket) by user location)")
                    }
                    print("\(Self.telem) DB_CAP postcode=\(area.postcode) before=\(sorted.count) after=\(capped.count) maxPerBucket=\(maxPrePopulatedRoutesPerBucket) requested=\(roundedDuration)")
                    print("📦 ✅ PRE-POPULATED ROUTES HIT! Found \(capped.count) routes for \(roundedDuration)min from postcode area '\(area.postcode)' - using database (no route generation needed)")
                    print("\(Self.telem) DB_RESULT returned=\(capped.count) postcode=\(area.postcode) requested=\(roundedDuration)")
                    return capped
                } else {
                    print("📦 Pre-populated DB: Postcode area '\(area.postcode)' has routes but none passed filters for \(roundedDuration)min (checked \(roundedDuration)±5,±10 min buckets)")
                }
            }
        }
        
        print("📦 Pre-populated DB: No routes found - user location not in any postcode area or no routes for \(roundedDuration)min")
        print("\(Self.telem) DB_RESULT returned=0 reason=no_matching_area_or_all_filtered requested=\(durationMinutes) rounded=\(roundedDuration)")
        // 🔧 DEBUG: Database-only mode - log extra details
        if RoutingToggles.databaseOnlyMode {
            print("🚫 [DATABASE-ONLY MODE] Database route lookup failed:")
            print("   📍 User location: \(location.latitude), \(location.longitude)")
            print("   ⏱️ Requested duration: \(durationMinutes)min (rounded: \(roundedDuration)min)")
            print("   📦 Database has \(database.postcodeAreas.count) postcode areas:")
            for area in database.postcodeAreas {
                let routeCount = area.routes?.flatMap { $0.routes }.count ?? 0
                let durations = area.routes?.map { "\($0.durationMinutes)min" }.joined(separator: ", ") ?? "none"
                print("      - \(area.postcode): \(routeCount) routes, durations: \(durations)")
            }
        }
        return nil
    }
    
    /// Determine which postcode district a location belongs to
    /// Returns the postcode district (e.g., "S10") or nil if not in any target area
    private func getPostcodeDistrict(for location: CLLocationCoordinate2D) -> String? {
        var closestPostcode: String? = nil
        var closestDistance: Double = Double.infinity
        
        // Find the closest postcode area center (uses shared postcodeCenters)
        for (postcode, centerLat, centerLon) in Self.postcodeCenters {
            let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
            let distance = distanceBetween(location, center)
            
            // Check if within the area's radius (2500m)
            if distance <= 2500.0 && distance < closestDistance {
                closestPostcode = postcode
                closestDistance = distance
            }
        }
        
        if let postcode = closestPostcode {
            // Extract district (S10 -> S10, WF2 0GU -> WF2)
            if postcode.hasPrefix("S") {
                // Extract number part for S postcodes
                let district = String(postcode.prefix(while: { $0.isLetter || $0.isNumber }))
                return district
            } else if postcode.hasPrefix("WF") {
                return "WF2"  // Wakefield area
            }
            return postcode
        }
        
        return nil
    }
    
    /// Effective center for an area: use stored center if valid; else resolve from known postcode centers (fixes DB with 0,0 or wrong keys).
    private func effectiveCenter(for area: PrePopulatedPOIDatabase.PostcodeAreaPOIs) -> CLLocationCoordinate2D {
        let stored = CLLocationCoordinate2D(latitude: area.centerLatitude, longitude: area.centerLongitude)
        let isZeroOrInvalid = abs(area.centerLatitude) < 0.01 && abs(area.centerLongitude) < 0.01
        if !isZeroOrInvalid { return stored }
        let district = extractPostcodeDistrict(area.postcode)
        for (postcode, lat, lon) in Self.postcodeCenters {
            let knownDistrict = extractPostcodeDistrict(postcode)
            if postcode == area.postcode || knownDistrict == district
                || postcode.hasPrefix(area.postcode) || area.postcode.hasPrefix(postcode) {
                print("📦 Pre-populated DB: Using known center for '\(area.postcode)' (stored center was 0,0)")
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return stored
    }
    
    /// Calculate distance between two coordinates
    private func distanceBetween(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let location2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return location1.distance(from: location2)
    }
    
    /// Minimum distance (m) between waypoints so POI trigger zones don't overlap. POIs are "triggered" within ~200m, so adjacent waypoints must be at least this far apart.
    private let minWaypointDistanceForTriggerZone: Double = 200.0
    
    /// Filter out waypoints that are too close together: walks route in order and drops any waypoint within minDistance of an already-kept one (removes "middle" waypoints, e.g. Village Hall → Outwood → Star Inn becomes Village Hall → Star Inn when Outwood is <200m from Village Hall).
    /// Returns nil only if no waypoints remain. Routes with 1 waypoint are allowed (better to show a single-POI route than skip).
    private func filterCloseWaypoints(places: [PrePopulatedPOIDatabase.PrePopulatedPOI], minDistance: Double) -> [PrePopulatedPOIDatabase.PrePopulatedPOI]? {
        guard !places.isEmpty else { return nil }
        var kept: [PrePopulatedPOIDatabase.PrePopulatedPOI] = []
        for poi in places {
            let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
            let tooClose = kept.contains { other in
                distanceBetween(coord, CLLocationCoordinate2D(latitude: other.latitude, longitude: other.longitude)) < minDistance
            }
            if !tooClose { kept.append(poi) }
        }
        return kept.isEmpty ? nil : kept
    }
    
    /// Download pre-populated database on app start
    /// ALWAYS downloads from Firebase Storage - never uses bundled database
    /// PRIORITY: This ensures database is always up-to-date from Firebase
    /// If location is provided, only downloads the relevant postcode area to save storage
    func downloadDatabaseIfNeeded(userLocation: CLLocationCoordinate2D? = nil) async {
        // Prevent concurrent downloads
        if isDownloading {
            print("📦 Pre-populated DB: Download already in progress, skipping duplicate request")
            return
        }
        
        isDownloading = true
        defer { isDownloading = false }
        
        // Determine postcode district from location for smaller download
        var postcodeDistrict: String? = nil
        if let userLocation = userLocation {
            postcodeDistrict = getPostcodeDistrict(for: userLocation)
            if let district = postcodeDistrict {
                print("📦 Pre-populated DB: User in postcode district '\(district)' - trying smaller file first (GPS-based)")
                print("\(Self.telem) DOWNLOAD_START attemptedPostcode=\(district) location=(\(String(format: "%.5f", userLocation.latitude)),\(String(format: "%.5f", userLocation.longitude)))")
            } else {
                print("\(Self.telem) DOWNLOAD_START attemptedPostcode=none location=(\(String(format: "%.5f", userLocation.latitude)),\(String(format: "%.5f", userLocation.longitude)))")
            }
        } else {
            print("📦 Pre-populated DB: No user location provided - downloading full database (postcode-specific not used)")
            print("\(Self.telem) DOWNLOAD_START attemptedPostcode=none location=nil (will use full DB)")
        }
        
        // Try to get download URL (postcode-specific first, then full database)
        guard let url = await getDatabaseURL(for: postcodeDistrict) else {
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
        let firebaseJsonFile = postcodeDistrict.map { "prepopulated_pois_\($0).json" } ?? databaseFileName
        print("\(Self.telem) FIREBASE_JSON_FILE file=\(firebaseJsonFile) postcode=\(postcodeDistrict ?? "full")")
        
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
        print("\(Self.telem) FIREBASE_DOWNLOAD_START file=\(firebaseJsonFile)")
        
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
            
            // Log download info
            let downloadSize = Double(data.count) / 1024.0
            print("📦 Pre-populated DB: Downloaded \(String(format: "%.1f", downloadSize))KB")
            
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
            
            // Save filtered database to local storage
            saveDatabase(database)
            
            // Mark as downloaded
            UserDefaults.standard.set(true, forKey: downloadCompleteKey)
            UserDefaults.standard.set(database.version, forKey: "prepopulatedPOIs_version")
            let sourceValue = postcodeDistrict ?? "full"
            UserDefaults.standard.set(sourceValue, forKey: databaseSourceKey)
            
            let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
            let totalRoutes = database.postcodeAreas.compactMap { $0.routes }.flatMap { $0 }.reduce(0) { $0 + $1.routes.count }
            let areaList = database.postcodeAreas.map { a in "\(a.postcode):\((a.routes?.flatMap { $0.routes })?.count ?? 0)" }.joined(separator: " ")
            print("\(Self.telem) FIREBASE_DOWNLOAD_COMPLETE file=\(firebaseJsonFile)")
            print("\(Self.telem) DOWNLOAD_SUCCESS source=\(sourceValue) areaCount=\(database.postcodeAreas.count) totalPOIs=\(totalPOIs) totalRoutes=\(totalRoutes) areas=[\(areaList)]")
            print("📦 ✅ Pre-populated DB: Downloaded successfully from Firebase Storage!")
            if postcodeDistrict != nil {
                print("📦   Used GPS-based postcode slice (\(postcodeDistrict!)) - appropriate POIs/routes loaded quickly")
            }
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
        UserDefaults.standard.removeObject(forKey: databaseSourceKey)
        print("📦 Pre-populated DB: Cleared (database, download flag, version, and source)")
    }
    
    /// Get database statistics
    func getDatabaseStats() -> (postcodeAreas: Int, totalPOIs: Int)? {
        guard let database = loadDatabase() else {
            return nil
        }
        
        let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
        return (database.postcodeAreas.count, totalPOIs)
    }
    
    /// Get all postcode areas from the database (for batch testing)
    func getAllPostcodeAreas() -> [PrePopulatedPOIDatabase.PostcodeAreaPOIs]? {
        guard let database = loadDatabase() else {
            return nil
        }
        return database.postcodeAreas
    }
    
    /// Extract postcode district from full postcode (e.g., "S10 1FG" -> "S10", "WF2 0GU" -> "WF2")
    private func extractPostcodeDistrict(_ postcode: String) -> String {
        let cleaned = postcode.replacingOccurrences(of: " ", with: "").uppercased()
        
        // Find where the number starts
        var district = ""
        for char in cleaned {
            if char.isLetter {
                district.append(char)
            } else if char.isNumber {
                district.append(char)
                // Continue adding numbers until we hit a letter (for S10, S11, etc.)
                var remaining = String(cleaned.dropFirst(district.count))
                for nextChar in remaining {
                    if nextChar.isNumber {
                        district.append(nextChar)
                    } else {
                        break
                    }
                }
                break
            }
        }
        
        return district.isEmpty ? postcode : district
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
