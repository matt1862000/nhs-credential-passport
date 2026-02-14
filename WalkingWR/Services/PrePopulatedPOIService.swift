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
    
    // #region agent log
    /// Path for debug instrumentation (same as RouteSelectionView: app Documents on device so log can be retrieved).
    private static func _agentLogPath() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.map { $0.appendingPathComponent("debug.log").path } ?? "/Users/raihant/Documents/WalkingWR/.cursor/debug.log"
    }
    // #endregion agent log
    
    // Prevent concurrent downloads; in-flight task so callers can await it
    private var isDownloading = false
    private var downloadTask: Task<Void, Never>?
    
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
    
    /// Postcode districts we have prepop JSON for (GPS → reverse geocode → match this set → download).
    private static let supportedDistricts: Set<String> = [
        "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12", "S13", "S14",
        "S17", "S20", "S21", "S25", "S26", "S35", "S36",
        "WF1", "WF2", "WF3", "WF4", "WF5", "WF6", "WF7", "WF8", "WF9", "WF10",
        "WF11", "WF12", "WF13", "WF14", "WF15", "WF16", "WF17"
    ]
    
    /// Max pre-populated routes to return per (postcode, duration). "Best" = least total time from user (route start + loop). Script emits all; app filters here because user location varies.
    private let maxPrePopulatedRoutesPerBucket = 10

    /// Canonical name for single-waypoint dedupe: same physical place with different labels (e.g. "War Memorial", "War memorial in Kirkhamgate.") maps to one key.
    private static func canonicalNameForSingleWaypoint(placeName: String) -> String {
        let cleaned = GoogleMapsService.cleanPOIDisplayName(placeName).lowercased()
        let noPunctuation = cleaned.unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0) }
            .map { Character($0) }
        let words = String(noPunctuation).split(separator: " ").map(String.init)
        let stopwords: Set<String> = ["the", "in", "on", "a", "of", "at", "to"]
        let significant = words.filter { !stopwords.contains($0) && !$0.isEmpty }
        let firstTwo = Array(significant.prefix(2)).sorted()
        let joined = firstTwo.joined(separator: " ")
        return joined.isEmpty ? "poi" : joined
    }

    // Firebase Storage reference for pre-populated POI database
    private let storage = Storage.storage()
    
    // URL for downloading pre-populated POI database
    // Only tries postcode-specific file (no full database fallback)
    private func getDatabaseURL(for postcodeDistrict: String?) async -> URL? {
        guard let district = postcodeDistrict else { return nil }
        let postcodeFileName = "prepopulated_pois_\(district).json"
        let postcodeRef = storage.reference().child(postcodeFileName)
        do {
            let downloadURL = try await postcodeRef.downloadURL()
            print("📦 Pre-populated DB: Found postcode-specific file: \(postcodeFileName) (~500KB)")
            print("\(Self.telem) FIREBASE_URL source=postcode_\(district) file=\(postcodeFileName)")
            print("\(Self.telem) \(Self.prepopTimingTag) stage=json_found at=\(Self.prepopTimingStamp())")
            return downloadURL
        } catch {
            let nsError = error as NSError?
            print("📦 Pre-populated DB: Postcode-specific file '\(postcodeFileName)' not found (no full DB fallback)")
            print("\(Self.telem) FIREBASE_URL postcode_file_missing district=\(district) error=\(error.localizedDescription)")
            print("📦 Pre-populated DB: Error details: \(error.localizedDescription)")
            if let nsError = nsError {
                print("📦 Pre-populated DB: Error code: \(nsError.code), domain: \(nsError.domain)")
            }
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
    /// Single tag for prepop timing telemetry (search console for "PREPOP_TIMING")
    private static let prepopTimingTag = "PREPOP_TIMING"
    private static func prepopTimingStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Identifier for logging: route name if set, otherwise first POIs e.g. "POI1 → POI2"
    private func routeIdentifier(name: String?, places: [PrePopulatedPOIDatabase.PrePopulatedPOI]) -> String {
        if let n = name, !n.isEmpty { return n }
        let names = places.prefix(3).map { $0.name }
        return names.isEmpty ? "nil" : names.joined(separator: " → ")
    }
    
    /// Known postcode area centers (must match generate_database.py / Apps Script). Used for fallback when DB center is (0,0).
    private static let postcodeCenters: [(postcode: String, lat: Double, lon: Double)] = [
        // Wakefield districts
        ("WF1", 53.683, -1.498),     // Wakefield city centre
        ("WF2", 53.703, -1.550),     // Wakefield south-west (Sandal, Walton)
        ("WF3", 53.720, -1.555),     // East Ardsley, Tingley
        ("WF4", 53.660, -1.530),     // Horbury, Crigglestone
        ("WF5", 53.693, -1.563),     // Ossett
        ("WF6", 53.710, -1.410),     // Normanton
        ("WF7", 53.665, -1.435),     // Pontefract (south)
        ("WF8", 53.690, -1.310),     // Pontefract
        ("WF9", 53.620, -1.330),     // South Elmsall, Hemsworth
        ("WF10", 53.720, -1.360),    // Castleford
        ("WF11", 53.715, -1.280),    // Knottingley
        ("WF12", 53.685, -1.640),    // Dewsbury
        ("WF13", 53.690, -1.690),    // Dewsbury (west)
        ("WF14", 53.680, -1.720),    // Mirfield
        ("WF15", 53.710, -1.730),    // Liversedge
        ("WF16", 53.700, -1.710),    // Heckmondwike
        ("WF17", 53.730, -1.690),    // Batley
        // Sheffield districts
        ("S1", 53.3800, -1.4700), ("S2", 53.3750, -1.4600), ("S3", 53.3850, -1.4850),
        ("S4", 53.3900, -1.4700), ("S5", 53.4100, -1.4600), ("S6", 53.4000, -1.5000),
        ("S7", 53.3600, -1.4900), ("S8", 53.3500, -1.4800), ("S9", 53.3900, -1.4400),
        ("S10", 53.3800, -1.5000), ("S11", 53.3700, -1.5000), ("S12", 53.3600, -1.4400),
        ("S13", 53.3850, -1.4200), ("S14", 53.4000, -1.4400), ("S17", 53.3550, -1.5100),
        ("S20", 53.3400, -1.4500), ("S21", 53.3300, -1.4800), ("S25", 53.4200, -1.4200),
        ("S26", 53.3450, -1.4200), ("S35", 53.4200, -1.4800), ("S36", 53.4350, -1.5000)
    ]
    
    /// Normalise full UK postcode to district (outward code): "WF1 1QY" → "WF1", "S10 1AA" → "S10".
    /// UK format is "OUTWARD INWARD"; we want the first part only (split on space).
    private static func normaliseToDistrict(_ postalCode: String?) -> String? {
        guard let raw = postalCode?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let firstPart = raw.split(separator: " ").first.map { String($0) } ?? raw
        let s = firstPart.uppercased()
        return s.isEmpty ? nil : s
    }
    
    /// Reverse geocode: GPS → postcode district if in supported list. Returns nil on failure or unsupported district.
    private func getPostcodeDistrictFromGeocode(for location: CLLocationCoordinate2D) async -> String? {
        let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(loc)
            guard let placemark = placemarks.first else { return nil }
            let district = Self.normaliseToDistrict(placemark.postalCode)
            guard let d = district, Self.supportedDistricts.contains(d) else {
                if let pc = placemark.postalCode {
                    print("📦 Pre-populated DB: Geocode returned postcode '\(pc)' (district '\(district ?? "nil")') - not in supported list")
                }
                return nil
            }
            print("📦 Pre-populated DB: Geocode → postcode '\(placemark.postalCode ?? "?")' → district '\(d)' (in supported list)")
            return d
        } catch {
            print("📦 Pre-populated DB: Reverse geocode failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Database Structure
    
    struct PrePopulatedPOIDatabase: Codable {
        let version: Int
        let lastUpdated: Date
        let postcodeAreas: [PostcodeAreaPOIs]
        
        // MARK: - Sector (v2 format)
        /// POIs grouped by postcode sector (e.g. "WF1 1"). Present only in v2 sector-indexed files.
        struct SectorPOIs: Codable {
            let sector: String           // e.g. "WF1 1"
            let centerLatitude: Double
            let centerLongitude: Double
            let pois: [PrePopulatedPOI]
        }
        
        struct PostcodeAreaPOIs: Codable {
            let postcode: String
            let centerLatitude: Double
            let centerLongitude: Double
            let radiusMeters: Int
            /// Flat POI list — present in v1; in v2 derived from sectors on decode.
            let pois: [PrePopulatedPOI]
            let routes: [PrePopulatedRoute]?  // Optional: routes for this postcode area
            /// Sector-indexed POIs (v2 only). nil for v1 databases.
            let sectors: [SectorPOIs]?
            
            /// Accept both camelCase and snake_case for center (some generators use center_latitude/center_longitude)
            enum CodingKeys: String, CodingKey {
                case postcode, radiusMeters, pois, routes, sectors
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
                routes = try c.decodeIfPresent([PrePopulatedRoute].self, forKey: .routes)
                sectors = try c.decodeIfPresent([SectorPOIs].self, forKey: .sectors)
                
                // v2: if sectors exist, flatten their POIs into the top-level `pois` array
                // v1: decode pois directly from the top-level `pois` key
                if let sectors = sectors, !sectors.isEmpty {
                    pois = sectors.flatMap { $0.pois }
                } else {
                    pois = (try? c.decode([PrePopulatedPOI].self, forKey: .pois)) ?? []
                }
            }
            
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(postcode, forKey: .postcode)
                try c.encode(centerLatitude, forKey: .centerLatitude)
                try c.encode(centerLongitude, forKey: .centerLongitude)
                try c.encode(radiusMeters, forKey: .radiusMeters)
                // Only encode pois if v1 (no sectors); v2 pois are derived
                if sectors == nil {
                    try c.encode(pois, forKey: .pois)
                }
                try c.encodeIfPresent(routes, forKey: .routes)
                try c.encodeIfPresent(sectors, forKey: .sectors)
            }
            
            /// Memberwise init for generator/callers that build areas programmatically
            init(postcode: String, centerLatitude: Double, centerLongitude: Double, radiusMeters: Int, pois: [PrePopulatedPOI], routes: [PrePopulatedRoute]?, sectors: [SectorPOIs]? = nil) {
                self.postcode = postcode
                self.centerLatitude = centerLatitude
                self.centerLongitude = centerLongitude
                self.radiusMeters = radiusMeters
                self.pois = pois
                self.routes = routes
                self.sectors = sectors
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
    
    /// Duration-aware search radius: shorter walks need POIs closer to the user, longer walks can reach further.
    /// Walking speed ~80 m/min, half for out-and-back = 40 m/min effective radius per minute.
    /// Returns radius in meters.
    static func durationAwareRadius(forMinutes minutes: Int) -> Double {
        let base = Double(max(5, minutes)) * 40.0   // 5min → 200m, 10min → 400m, 30min → 1200m
        let clamped = min(max(base, 400), 2500)      // floor 400m, cap 2500m
        return clamped
    }
    
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
        var matchedSector: String? = nil
        
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
                
                // --- v2 Sector-aware selection ---
                if let sectors = area.sectors, !sectors.isEmpty {
                    // Find nearest sector to the user
                    let sortedSectors = sectors.sorted {
                        let d1 = distanceBetween(location, CLLocationCoordinate2D(latitude: $0.centerLatitude, longitude: $0.centerLongitude))
                        let d2 = distanceBetween(location, CLLocationCoordinate2D(latitude: $1.centerLatitude, longitude: $1.centerLongitude))
                        return d1 < d2
                    }
                    
                    if let nearest = sortedSectors.first {
                        let nearestDist = distanceBetween(location, CLLocationCoordinate2D(latitude: nearest.centerLatitude, longitude: nearest.centerLongitude))
                        matchedSector = nearest.sector
                        print("📦 Pre-populated DB: Nearest sector '\(nearest.sector)' (\(Int(nearestDist))m from user)")
                    }
                    
                    // Collect POIs from nearest sector first, then expand to adjacent sectors
                    var seenPlaceIds = Set<String>()
                    for sector in sortedSectors {
                        let sectorCenter = CLLocationCoordinate2D(latitude: sector.centerLatitude, longitude: sector.centerLongitude)
                        let sectorDist = distanceBetween(location, sectorCenter)
                        // Include sector if its center is within the search radius * 2 (sector + user overlap)
                        guard sectorDist <= radiusMeters * 2 else { continue }
                        
                        for poi in sector.pois {
                            guard !seenPlaceIds.contains(poi.placeId) else { continue }
                            let poiCoord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                            let distanceToPOI = distanceBetween(location, poiCoord)
                            if distanceToPOI <= radiusMeters {
                                if GoogleMapsService.isJunkPOIName(poi.name) { continue }
                                seenPlaceIds.insert(poi.placeId)
                                matchingPOIs.append(PlaceResult(
                                    placeId: poi.placeId,
                                    name: poi.name,
                                    vicinity: poi.vicinity,
                                    geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                                    types: poi.types,
                                    source: POISource.fromString(poi.source)
                                ))
                            }
                        }
                    }
                    
                    print("📦 Pre-populated DB: Sector-aware selection found \(matchingPOIs.count) POIs across \(sortedSectors.filter { distanceBetween(location, CLLocationCoordinate2D(latitude: $0.centerLatitude, longitude: $0.centerLongitude)) <= radiusMeters * 2 }.count) sectors")
                } else {
                    // --- v1 flat POI list (no sectors) ---
                    for poi in area.pois {
                        let poiCoord = CLLocationCoordinate2D(
                            latitude: poi.latitude,
                            longitude: poi.longitude
                        )
                        let distanceToPOI = distanceBetween(location, poiCoord)
                        
                        if distanceToPOI <= radiusMeters {
                            if GoogleMapsService.isJunkPOIName(poi.name) { continue }
                            matchingPOIs.append(PlaceResult(
                                placeId: poi.placeId,
                                name: poi.name,
                                vicinity: poi.vicinity,
                                geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                                types: poi.types,
                                source: POISource.fromString(poi.source)
                            ))
                        }
                    }
                }
                
                // Found matching area - no need to check others
                break
            }
        }
        
        if !matchingPOIs.isEmpty {
            let sectorInfo = matchedSector.map { " (nearest sector: \($0))" } ?? ""
            print("📦 ✅ PRE-POPULATED DB HIT! Found \(matchingPOIs.count) POIs from postcode area '\(matchedPostcode ?? "unknown")'\(sectorInfo) - using database (no API calls needed)")
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
            let inRadius = distanceToArea <= searchRadius
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
                        print("\(Self.telem) DB_PREPOP_BUCKET duration=\(checkDuration) routes_in_bucket=\(routeGroup.routes.count) requested=\(roundedDuration)")
                        for routeData in routeGroup.routes {
                            let routeName = self.routeIdentifier(name: routeData.name, places: routeData.places)
                            // Prefer multi-waypoint routes: no longer replace with single first-POI when it fits (was first-POI precedence).
                            if requireMinWaypoints >= 2 && routeData.places.count < 2 {
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=single_waypoint placesCount=\(routeData.places.count) requireMinWaypoints=\(requireMinWaypoints)")
                                continue
                            }
                            // Travel time from current GPS to the route: use MIN over all waypoints so routes
                            // with any waypoint near the user can be used (stored "first" waypoint may be far).
                            let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)  // m/min
                            let (timeToStartSeconds, distanceToStart): (Int, Double) = {
                                guard !routeData.places.isEmpty else {
                                    let d = self.distanceBetween(location, areaCenter)
                                    return (Int((d / walkingSpeedMperMin) * 60), d)
                                }
                                var minDist = Double.infinity
                                for poi in routeData.places {
                                    let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                                    let d = self.distanceBetween(location, coord)
                                    if d < minDist { minDist = d }
                                }
                                return (Int((minDist / walkingSpeedMperMin) * 60), minDist)
                            }()
                            // Total = route loop + walk from GPS to closest waypoint
                            let totalDurationSeconds = routeData.durationSeconds + timeToStartSeconds
                            let totalDurationMinutes = totalDurationSeconds / 60
                            
                            // Accept only when total is 80–120% of requested (75–125% for edge cases e.g. 5min/55min)
                            let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
                            let (minPercent, maxPercent) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
                            let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)
                            let maxAcceptableMinutes = Int(Double(roundedDuration) * maxPercent)
                            
                            if totalDurationMinutes < minAcceptableMinutes || totalDurationMinutes > maxAcceptableMinutes {
                                let travelMin = timeToStartSeconds / 60
                                let tooLong = totalDurationMinutes > maxAcceptableMinutes
                                // If route is too long and has 3+ waypoints: try drop 1 (first, middle or last), then if none fit try drop 2
                                if tooLong && routeData.places.count >= 3 {
                                    let places = routeData.places
                                    var addedDrop1 = false
                                    // Phase 1 – Drop 1: try removing first, then each middle, then last
                                    for dropIndex in 0..<places.count {
                                        let sub = places.enumerated().filter { $0.offset != dropIndex }.map(\.element)
                                        guard sub.count >= 2 else { continue }
                                        var totalM = 0.0
                                        var prev = location
                                        for poi in sub {
                                            let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                                            totalM += self.distanceBetween(prev, coord)
                                            prev = coord
                                        }
                                        totalM += self.distanceBetween(prev, location)
                                        let sec = Int((totalM / walkingSpeedMperMin) * 60)
                                        let min = sec / 60
                                        guard min >= minAcceptableMinutes && min <= maxAcceptableMinutes else { continue }
                                        // Exclusion: do not add a drop-1 variant whose first waypoint has real single-waypoint time outside the band.
                                        if let subFirst = sub.first, let subFirstSingleMin = self.singleWaypointDurationMinutes(poi: subFirst, location: location),
                                           subFirstSingleMin < minAcceptableMinutes || subFirstSingleMin > maxAcceptableMinutes {
                                            continue
                                        }
                                        let coords = [location] + sub.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } + [location]
                                        let placeResults = sub.map { poi -> PlaceResult in
                                            PlaceResult(placeId: poi.placeId, name: poi.name, vicinity: poi.vicinity, geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)), types: poi.types, source: POISource.fromString(poi.source))
                                        }
                                        let polyline = self.encodeSimplePolyline(coords)
                                        let generatedRoute = GeneratedRoute(places: placeResults, polyline: polyline, distanceMeters: Int(totalM), durationSeconds: sec, legs: [])
                                        let cached = RouteCacheService.CachedRouteWithMetadata(route: generatedRoute, name: nil, description: nil, directions: nil, isFromPrePopulatedDatabase: true)
                                        result.append(cached)
                                        addedDrop1 = true
                                        let names = sub.map(\.name).joined(separator: "–")
                                        print("📦 Drop 1 (idx \(dropIndex)): '\(routeName)' → \(names) (\(min)min) for \(roundedDuration)min request")
                                        print("\(Self.telem) ROUTE_ADDED name=\"\(names)\" reason=drop_1 totalMin=\(min) requested=\(roundedDuration)")
                                    }
                                    // Phase 2 – Drop 2: if no drop-1 fit, try each single waypoint (we only have up to 3-waypoint routes)
                                    if !addedDrop1 {
                                        for poi in places {
                                            guard let cached = self.createSingleWaypointRoute(poi: poi, location: location, roundedDuration: roundedDuration) else { continue }
                                            result.append(cached)
                                            let min = cached.route.durationSeconds / 60
                                            print("📦 Drop 2: '\(routeName)' → \(poi.name) only (\(min)min) for \(roundedDuration)min request")
                                            print("\(Self.telem) ROUTE_ADDED name=\"\(poi.name)\" reason=drop_2_single totalMin=\(min) requested=\(roundedDuration)")
                                        }
                                    }
                                }
                                print("📦 Route '\(routeName)': REJECTED - Total duration \(totalDurationMinutes)min (route: \(routeData.durationSeconds/60)min + travel to closest: \(travelMin)min, \(Int(distanceToStart))m) outside 80–120% [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min for requested \(roundedDuration)min")
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=duration totalMin=\(totalDurationMinutes) routeMin=\(routeData.durationSeconds/60) travelMin=\(travelMin) distToClosestM=\(Int(distanceToStart)) allowed=\(minAcceptableMinutes)-\(maxAcceptableMinutes) requested=\(roundedDuration)")
                                continue
                            }
                            
                            if fromAdjacent {
                                print("📦 Route '\(routeName)': ACCEPTED from \(checkDuration)min bucket - Total \(totalDurationMinutes)min within 80–120% of \(roundedDuration)min request (route: \(routeData.durationSeconds/60)min + \(timeToStartSeconds/60)min travel to closest)")
                            } else {
                                print("📦 Route '\(routeName)': Added \(timeToStartSeconds/60)min travel from GPS (\(Int(distanceToStart))m) to closest waypoint. Route: \(routeData.durationSeconds/60)min → Total: \(totalDurationMinutes)min (within \(minAcceptableMinutes)–\(maxAcceptableMinutes)min)")
                            }
                            
                            // Remove waypoints that are too close so POI trigger zones (~200m) don't overlap. Drops "middle" waypoints (e.g. Village Hall → Outwood → Star Inn becomes Village Hall → Star Inn when Outwood is <200m from Village Hall).
                            let minDist = self.minWaypointDistanceForTriggerZone
                            guard let filteredPOIsUnordered = self.filterCloseWaypoints(places: routeData.places, minDistance: minDist) else {
                                print("📦 Route '\(routeName)': SKIPPED - after removing waypoints < \(Int(minDist))m apart (trigger zone), no waypoints remain")
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=waypoint_filter minDist=\(Int(minDist)) waypointsRemaining=0")
                                continue
                            }
                            // Rotate so the waypoint closest to the user is first (so "start at closest").
                            let filteredPOIs: [PrePopulatedPOIDatabase.PrePopulatedPOI] = {
                                guard filteredPOIsUnordered.count > 1 else { return filteredPOIsUnordered }
                                var bestIdx = 0
                                var bestD = Double.infinity
                                for (i, poi) in filteredPOIsUnordered.enumerated() {
                                    let d = self.distanceBetween(location, CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                                    if d < bestD { bestD = d; bestIdx = i }
                                }
                                if bestIdx == 0 { return filteredPOIsUnordered }
                                return Array(filteredPOIsUnordered[bestIdx...]) + Array(filteredPOIsUnordered[..<bestIdx])
                            }()
                            // Exclusion: do not offer a multi-waypoint route whose first stop has a real single-waypoint time outside the band (e.g. Village Hall 6min shown as 18min for 15min request).
                            if let firstPOI = filteredPOIs.first, let firstSingleMin = self.singleWaypointDurationMinutes(poi: firstPOI, location: location),
                               firstSingleMin < minAcceptableMinutes || firstSingleMin > maxAcceptableMinutes {
                                print("📦 Route '\(routeName)': SKIPPED - first waypoint '\(firstPOI.name)' has real single-waypoint time \(firstSingleMin)min outside [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min for \(roundedDuration)min request")
                                print("\(Self.telem) ROUTE_DISCARDED name=\"\(routeName)\" reason=first_poi_duration_mismatch firstPOI=\(firstPOI.name) firstSingleMin=\(firstSingleMin) allowed=\(minAcceptableMinutes)-\(maxAcceptableMinutes) requested=\(roundedDuration)")
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
                            
                            // User-based duration: single-waypoint = round-trip from user; multi-waypoint = user → WP1 → … → WPn → user.
                            // Uses route-specific OSRM-derived ratio (real walking distance / straight-line total) instead of generic pathFactor. No API.
                            let routeRatio = self.osrmDerivedRatio(routeData: routeData, areaCenter: areaCenter)
                            let (displayDurationSeconds, displayDistanceMeters, displayPolyline, travelToStartSeconds): (Int, Int, String, Int?) = {
                                if filteredPlaces.count == 1, let firstPOI = filteredPOIs.first {
                                    let poiCoord = CLLocationCoordinate2D(latitude: firstPOI.latitude, longitude: firstPOI.longitude)
                                    let dPath = distanceToStart * routeRatio
                                    let roundTripSeconds = Int(2 * (dPath / walkingSpeedMperMin) * 60)
                                    let roundTripMeters = Int(2 * dPath)
                                    let userPolyline = self.encodeSimplePolyline([location, poiCoord, location])
                                    print("📦 Route '\(routeName)': single waypoint — using user round-trip \(roundTripSeconds/60)min (\(Int(roundTripMeters))m) instead of DB loop \(routeData.durationSeconds/60)min (osrmRatio=\(String(format: "%.2f", routeRatio)) vs pathFactor=\(self.pathFactor(straightLineM: distanceToStart)))")
                                    return (roundTripSeconds, roundTripMeters, userPolyline, nil)
                                }
                                if filteredPlaces.count >= 2 {
                                    var totalSeconds = 0.0
                                    var totalMeters = 0.0
                                    var prev = location
                                    for poi in filteredPOIs {
                                        let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                                        let dStraight = self.distanceBetween(prev, coord)
                                        let dPath = dStraight * routeRatio
                                        totalSeconds += (dPath / walkingSpeedMperMin) * 60
                                        totalMeters += dPath
                                        prev = coord
                                    }
                                    let dStraightBack = self.distanceBetween(prev, location)
                                    let dPathBack = dStraightBack * routeRatio
                                    totalSeconds += (dPathBack / walkingSpeedMperMin) * 60
                                    totalMeters += dPathBack
                                    let coords = [location] + filteredPOIs.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } + [location]
                                    let userPolyline = self.encodeSimplePolyline(coords)
                                    print("📦 Route '\(routeName)': multi-waypoint — using user-based \(Int(totalSeconds)/60)min (\(Int(totalMeters))m) instead of DB loop \(routeData.durationSeconds/60)min + travel (osrmRatio=\(String(format: "%.2f", routeRatio)))")
                                    return (Int(totalSeconds), Int(totalMeters), userPolyline, nil)
                                }
                                return (routeData.durationSeconds, routeData.distanceMeters, routeData.polyline, timeToStartSeconds)
                            }()
                            
                            // On-route POIs: add POIs that lie on the path (no extra time) when under requested duration or when route has few waypoints. MapKit/Google refresh will use the full list.
                            var finalFilteredPOIs = filteredPOIs
                            var finalFilteredPlaces = filteredPlaces
                            let totalDurationMin = displayDurationSeconds / 60 + (travelToStartSeconds ?? 0) / 60
                            let decodedPolyline = PolylineDecoder.decode(displayPolyline)
                            if (totalDurationMin < roundedDuration || filteredPOIs.count <= 2),
                               decodedPolyline.count >= 2 {
                                let existingIds = Set(filteredPOIs.map(\.placeId))
                                // Only add POIs not further from origin than the route's furthest waypoint (keep duration believable).
                                let maxDistFromOrigin: Double = {
                                    guard !filteredPOIs.isEmpty else { return .infinity }
                                    let maxD = filteredPOIs.map { poi in
                                        self.distanceBetween(location, CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                                    }.max() ?? 0
                                    return maxD * 1.15
                                }()
                                let candidates = area.pois
                                    .filter { !existingIds.contains($0.placeId) }
                                    .filter { poi in
                                        guard !GoogleMapsService.isJunkPOIName(poi.name) else { return false }
                                        return self.distanceBetween(location, CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)) <= maxDistFromOrigin
                                    }
                                    .map { RouteGeometryHelper.Candidate(id: $0.placeId, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
                                let existingCoords = filteredPOIs.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                                let onRouteResults = RouteGeometryHelper.selectOnRoutePOIs(
                                    polyline: decodedPolyline,
                                    candidates: candidates,
                                    origin: location,
                                    existingWaypointCoords: existingCoords,
                                    minDistanceBetweenWaypoints: self.minWaypointDistanceForTriggerZone,
                                    onRouteThresholdMeters: 50,
                                    maxToAdd: 3
                                )
                                if !onRouteResults.isEmpty {
                                    let areaPoiById = Dictionary(uniqueKeysWithValues: area.pois.map { ($0.placeId, $0) })
                                    var withProgress: [(poi: PrePopulatedPOIDatabase.PrePopulatedPOI, progress: Double)] = []
                                    for poi in filteredPOIs {
                                        let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                                        if let proj = RouteGeometryHelper.projectOntoPolyline(coordinate: coord, polyline: decodedPolyline) {
                                            let len = RouteGeometryHelper.polylineLength(decodedPolyline)
                                            let progress = len > 0 ? RouteGeometryHelper.distanceAlongPolyline(polyline: decodedPolyline, segmentIndex: proj.segmentIndex, t: proj.t) / len : 0
                                            withProgress.append((poi, progress))
                                        } else {
                                            withProgress.append((poi, 0))
                                        }
                                    }
                                    for res in onRouteResults {
                                        if let poi = areaPoiById[res.candidate.id] {
                                            withProgress.append((poi, res.progress))
                                        }
                                    }
                                    withProgress.sort { $0.progress < $1.progress }
                                    finalFilteredPOIs = withProgress.map(\.poi)
                                    finalFilteredPlaces = finalFilteredPOIs.map { poi in
                                        PlaceResult(
                                            placeId: poi.placeId,
                                            name: poi.name,
                                            vicinity: poi.vicinity,
                                            geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                                            types: poi.types,
                                            source: POISource.fromString(poi.source)
                                        )
                                    }
                                    print("📦 On-route POIs added: \(onRouteResults.count) for '\(routeName)' (was \(filteredPOIs.count) waypoints, now \(finalFilteredPOIs.count))")
                                }
                            }
                            
                            // Create GeneratedRoute: show route-only duration in preview; travel-to-start is used for session pill when they tap Let's Go
                            let generatedRoute = GeneratedRoute(
                                places: finalFilteredPlaces,
                                polyline: displayPolyline,
                                distanceMeters: displayDistanceMeters,
                                durationSeconds: displayDurationSeconds,
                                legs: [],  // Legs not stored in pre-populated database
                                travelToStartSeconds: travelToStartSeconds
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
                // Single-waypoint options: synthesize from POIs in duration buckets and from area's full POI list (so e.g. Oriental Chef in WF2 can appear even if not a route waypoint).
                let syntheticSingleWP = buildSyntheticSingleWaypointRoutes(routes: routes, durationsToCheck: durationsToCheck, location: location, roundedDuration: roundedDuration, areaPOIs: area.pois)
                if !syntheticSingleWP.isEmpty {
                    print("📦 Pre-populated DB: Added \(syntheticSingleWP.count) single-waypoint options (from POIs in duration buckets)")
                    print("\(Self.telem) DB_SINGLE_WP added=\(syntheticSingleWP.count) requested=\(roundedDuration)")
                    cachedRoutes.append(contentsOf: syntheticSingleWP)
                }
                
                print("\(Self.telem) DB_CANDIDATES postcode=\(area.postcode) beforeDedupe=\(cachedRoutes.count) requested=\(roundedDuration)")
                
                if !cachedRoutes.isEmpty {
                    // Dedupe routes by same set of waypoints (order-independent).
                    // Single-waypoint: coordinate + canonical name so same location and name variants (e.g. War Memorial / War memorial in Kirkhamgate.) dedupe to one route.
                    // Multi-waypoint: use place IDs when available; fall back to coordinates for routes without stable place IDs.
                    func routeKeyNormalized(_ r: RouteCacheService.CachedRouteWithMetadata) -> String {
                        let places = r.route.places
                        if places.count == 1, let p = places.first {
                            let c = p.coordinate
                            let canonical = Self.canonicalNameForSingleWaypoint(placeName: p.name)
                            return String(format: "1@%.3f,%.3f@%@", c.latitude, c.longitude, canonical)
                        }
                        let allHavePlaceIds = !places.isEmpty && places.allSatisfy { !$0.placeId.isEmpty }
                        if allHavePlaceIds {
                            return "n|" + places.map(\.placeId).sorted().joined(separator: "|")
                        }
                        let coords = places.map { p in
                            let c = p.coordinate
                            return String(format: "%.3f,%.3f", c.latitude, c.longitude)
                        }
                        return "n|" + coords.sorted().joined(separator: "|")
                    }
                    let targetMinutes = roundedDuration
                    var bestByKey: [String: RouteCacheService.CachedRouteWithMetadata] = [:]
                    for r in cachedRoutes {
                        let k = routeKeyNormalized(r)
                        let durationMin = r.route.durationSeconds / 60
                        if let existing = bestByKey[k] {
                            let existingMin = existing.route.durationSeconds / 60
                            if abs(durationMin - targetMinutes) < abs(existingMin - targetMinutes) {
                                bestByKey[k] = r
                            }
                        } else {
                            bestByKey[k] = r
                        }
                    }
                    let unique = Array(bestByKey.values)
                    if unique.count < cachedRoutes.count {
                        print("📦 Deduped pre-populated routes: \(cachedRoutes.count) → \(unique.count) unique (same waypoints → kept duration closest to \(roundedDuration)min)")
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
                    // One route per primary POI (first waypoint): avoid same POI appearing as e.g. "2 of 7" and "4 of 7" (Village Stores twice).
                    var primaryPOIKeys: Set<String> = []
                    let primaryDeduped = sorted.filter { r in
                        guard let first = r.route.places.first else { return true }
                        let c = first.coordinate
                        let canonical = Self.canonicalNameForSingleWaypoint(placeName: first.name)
                        let key = String(format: "1@%.3f,%.3f@%@", c.latitude, c.longitude, canonical)
                        if primaryPOIKeys.contains(key) { return false }
                        primaryPOIKeys.insert(key)
                        return true
                    }
                    if primaryDeduped.count < sorted.count {
                        print("📦 Primary-POI dedupe: \(sorted.count) → \(primaryDeduped.count) (same first waypoint shown once)")
                    }
                    let capped = Array(primaryDeduped.prefix(maxPrePopulatedRoutesPerBucket))
                    if capped.count < primaryDeduped.count {
                        print("📦 Best-per-bucket: \(primaryDeduped.count) routes → \(capped.count) (max \(maxPrePopulatedRoutesPerBucket) by user location)")
                    }
                    print("\(Self.telem) DB_CAP postcode=\(area.postcode) before=\(primaryDeduped.count) after=\(capped.count) maxPerBucket=\(maxPrePopulatedRoutesPerBucket) requested=\(roundedDuration)")
                    // Enforce 80–120% band on final list: never return routes below min or above max (e.g. 15min request → 12–18min only)
                    let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
                    let (minPercent, maxPercent) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
                    let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)
                    let maxAcceptableMinutes = Int(Double(roundedDuration) * maxPercent)
                    let bandFiltered = capped.filter { r in
                        let min = r.route.durationSeconds / 60
                        return min >= minAcceptableMinutes && min <= maxAcceptableMinutes
                    }
                    if bandFiltered.count < capped.count {
                        let dropped = capped.filter { r in
                            let min = r.route.durationSeconds / 60
                            return min < minAcceptableMinutes || min > maxAcceptableMinutes
                        }
                        for r in dropped {
                            print("📦 Band filter: dropped \(r.route.durationSeconds / 60)min route (outside [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min for \(roundedDuration)min request)")
                        }
                        print("📦 Band filter: \(capped.count) → \(bandFiltered.count) (removed \(capped.count - bandFiltered.count) routes outside 80–120%)")
                        print("\(Self.telem) DB_BAND_FILTER before=\(capped.count) after=\(bandFiltered.count) allowed=\(minAcceptableMinutes)-\(maxAcceptableMinutes) requested=\(roundedDuration)")
                    }
                    // Prefer routes in 90-110% of target (duration-accurate), then by closest to target
                    let sortedByDurationAccuracy = bandFiltered.sorted { r1, r2 in
                        let min1 = r1.route.durationSeconds / 60
                        let min2 = r2.route.durationSeconds / 60
                        let ratio1 = Double(min1) / Double(roundedDuration)
                        let ratio2 = Double(min2) / Double(roundedDuration)
                        let inSweetSpot1 = ratio1 >= 0.90 && ratio1 <= 1.10
                        let inSweetSpot2 = ratio2 >= 0.90 && ratio2 <= 1.10
                        if inSweetSpot1 != inSweetSpot2 { return inSweetSpot1 }
                        return abs(ratio1 - 1.0) < abs(ratio2 - 1.0)
                    }
                    print("📦 ✅ PRE-POPULATED ROUTES HIT! Found \(sortedByDurationAccuracy.count) routes for \(roundedDuration)min from postcode area '\(area.postcode)' - using database (no route generation needed)")
                    print("\(Self.telem) DB_RESULT returned=\(sortedByDurationAccuracy.count) postcode=\(area.postcode) requested=\(roundedDuration)")
                    print("\(Self.telem) \(Self.prepopTimingTag) stage=routes_used at=\(Self.prepopTimingStamp()) count=\(sortedByDurationAccuracy.count) requested=\(roundedDuration)")
                    // #region agent log
                    if let first = sortedByDurationAccuracy.first {
                        let firstMin = first.route.durationSeconds / 60
                        let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "PrePopulatedPOIService:prepop_routes_returned", "message": "prepop_routes_returned", "data": ["source": "prepop", "requestedDuration": roundedDuration, "firstRouteActualMinutes": firstMin, "routeCount": sortedByDurationAccuracy.count, "inBand10pct": (firstMin >= Int(Double(roundedDuration) * 0.9) && firstMin <= Int(Double(roundedDuration) * 1.1))], "hypothesisId": "H6"]
                        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: Self._agentLogPath()) }
                    }
                    // #endregion agent log
                    return sortedByDurationAccuracy
                } else {
                    let totalInBuckets = durationsToCheck.reduce(0) { sum, d in sum + (routes.first(where: { $0.durationMinutes == d })?.routes.count ?? 0) }
                    print("📦 Pre-populated DB: Postcode area '\(area.postcode)' has routes but none passed filters for \(roundedDuration)min (checked \(roundedDuration)±5,±10 min buckets; total routes in those buckets=\(totalInBuckets))")
                    print("\(Self.telem) DB_RESULT returned=0 reason=all_filtered postcode=\(area.postcode) total_in_buckets=\(totalInBuckets) requested=\(roundedDuration) (filter by ROUTE_DISCARDED to see reason=duration|waypoint_filter|single_waypoint)")
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
    
    /// Returns up to 2 short routes from the lower duration bucket (extendToDuration - 5) plus area POIs as extend candidates.
    /// Caller should extend these routes to extendToDuration (e.g. add detour waypoints) and append to the main list.
    /// Does not replace or reduce normal routes; use as an additional source.
    func getLowerBucketRoutesForExtend(near location: CLLocationCoordinate2D, extendToDuration: Int) -> (routes: [RouteCacheService.CachedRouteWithMetadata], candidatePOIs: [PlaceResult])? {
        guard extendToDuration >= 10 else { return nil }  // Lower bucket would be < 5 min
        let lowerBucket = extendToDuration - 5
        guard let database = loadDatabase() else { return nil }
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(extendToDuration)
        let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
        let (minPercent, _) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
        let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)  // Routes we want have total < this (short)
        
        for area in database.postcodeAreas {
            guard let routes = area.routes else { continue }
            let areaCenter = effectiveCenter(for: area)
            let distanceToArea = distanceBetween(location, areaCenter)
            guard distanceToArea <= Double(area.radiusMeters) else { continue }
            guard let routeGroup = routes.first(where: { $0.durationMinutes == lowerBucket }) else { continue }
            
            let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)
            var toExtend: [RouteCacheService.CachedRouteWithMetadata] = []
            for routeData in routeGroup.routes {
                let (timeToStartSeconds, distanceToStart) = {
                    guard !routeData.places.isEmpty else {
                        let d = distanceBetween(location, areaCenter)
                        return (Int((d / walkingSpeedMperMin) * 60), d)
                    }
                    var minDist = Double.infinity
                    for poi in routeData.places {
                        let d = distanceBetween(location, CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                        if d < minDist { minDist = d }
                    }
                    return (Int((minDist / walkingSpeedMperMin) * 60), minDist)
                }()
                let totalDurationMinutes = (routeData.durationSeconds + timeToStartSeconds) / 60
                guard totalDurationMinutes < minAcceptableMinutes else { continue }
                guard let filteredPOIsUnordered = filterCloseWaypoints(places: routeData.places, minDistance: minWaypointDistanceForTriggerZone) else { continue }
                let filteredPOIs: [PrePopulatedPOIDatabase.PrePopulatedPOI] = {
                    guard filteredPOIsUnordered.count > 1 else { return filteredPOIsUnordered }
                    var bestIdx = 0
                    var bestD = Double.infinity
                    for (i, poi) in filteredPOIsUnordered.enumerated() {
                        let d = distanceBetween(location, CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                        if d < bestD { bestD = d; bestIdx = i }
                    }
                    if bestIdx == 0 { return filteredPOIsUnordered }
                    return Array(filteredPOIsUnordered[bestIdx...]) + Array(filteredPOIsUnordered[..<bestIdx])
                }()
                let filteredPlaces = filteredPOIs.map { poi in
                    PlaceResult(placeId: poi.placeId, name: poi.name, vicinity: poi.vicinity,
                               geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                               types: poi.types, source: POISource.fromString(poi.source))
                }
                let routeRatio = osrmDerivedRatio(routeData: routeData, areaCenter: areaCenter)
                let (displayDurationSeconds, displayDistanceMeters, displayPolyline): (Int, Int, String) = {
                    if filteredPlaces.count == 1, let first = filteredPOIs.first {
                        let dPath = distanceToStart * routeRatio
                        let roundTripSeconds = Int(2 * (dPath / walkingSpeedMperMin) * 60)
                        let roundTripMeters = Int(2 * dPath)
                        let coord = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
                        return (roundTripSeconds, roundTripMeters, encodeSimplePolyline([location, coord, location]))
                    }
                    if filteredPlaces.count >= 2 {
                        var totalSeconds = 0.0
                        var totalMeters = 0.0
                        var prev = location
                        for poi in filteredPOIs {
                            let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                            let dPath = distanceBetween(prev, coord) * routeRatio
                            totalSeconds += (dPath / walkingSpeedMperMin) * 60
                            totalMeters += dPath
                            prev = coord
                        }
                        totalSeconds += (distanceBetween(prev, location) * routeRatio / walkingSpeedMperMin) * 60
                        totalMeters += distanceBetween(prev, location) * routeRatio
                        let coords = [location] + filteredPOIs.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } + [location]
                        return (Int(totalSeconds), Int(totalMeters), encodeSimplePolyline(coords))
                    }
                    return (routeData.durationSeconds, routeData.distanceMeters, routeData.polyline)
                }()
                let generatedRoute = GeneratedRoute(places: filteredPlaces, polyline: displayPolyline, distanceMeters: displayDistanceMeters, durationSeconds: displayDurationSeconds, legs: [], travelToStartSeconds: timeToStartSeconds)
                let walkingDirections = routeData.directions?.map { dir in
                    WalkingDirection(instruction: dir.instruction, distance: dir.distance, distanceMeters: dir.distanceMeters, duration: dir.duration, maneuver: dir.maneuver)
                }
                let cached = RouteCacheService.CachedRouteWithMetadata(route: generatedRoute, name: routeData.name, description: routeData.description, directions: walkingDirections, isFromPrePopulatedDatabase: true)
                toExtend.append(cached)
                if toExtend.count >= 2 { break }
            }
            if !toExtend.isEmpty {
                let candidatePOIs = area.pois.map { poi in
                    PlaceResult(placeId: poi.placeId, name: poi.name, vicinity: poi.vicinity,
                               geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                               types: poi.types, source: POISource.fromString(poi.source))
                }
                print("📦 Lower-bucket for extend: \(toExtend.count) short \(lowerBucket)min route(s) to extend to \(extendToDuration)min, \(candidatePOIs.count) candidate POIs")
                return (toExtend, candidatePOIs)
            }
        }
        return nil
    }
    
    /// Fallback: determine district by distance to known postcode centers (2500m radius). Used when reverse geocode fails or is unavailable.
    private func getPostcodeDistrictFromCenters(for location: CLLocationCoordinate2D) -> String? {
        var closestPostcode: String? = nil
        var closestDistance: Double = Double.infinity
        for (postcode, centerLat, centerLon) in Self.postcodeCenters {
            let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
            let distance = distanceBetween(location, center)
            if distance <= 2500.0 && distance < closestDistance {
                closestPostcode = postcode
                closestDistance = distance
            }
        }
        guard let postcode = closestPostcode else { return nil }
        if postcode.hasPrefix("S") {
            return String(postcode.prefix(while: { $0.isLetter || $0.isNumber }))
        }
        if postcode.hasPrefix("WF") {
            return String(postcode.split(separator: " ").first ?? Substring(postcode))
        }
        return postcode
    }
    
    /// Determine postcode district for a location: 1) Reverse geocode → normalise → match supported list; 2) Fallback: distance to known centers (2500m).
    private func getPostcodeDistrict(for location: CLLocationCoordinate2D) async -> String? {
        if let district = await getPostcodeDistrictFromGeocode(for: location) {
            return district
        }
        return getPostcodeDistrictFromCenters(for: location)
    }
    
    /// Effective center for an area: prefer known postcode center when we have one (avoids swapped/wrong stored lat/lon); else use stored if valid.
    private func effectiveCenter(for area: PrePopulatedPOIDatabase.PostcodeAreaPOIs) -> CLLocationCoordinate2D {
        let district = extractPostcodeDistrict(area.postcode)
        for (postcode, lat, lon) in Self.postcodeCenters {
            let knownDistrict = extractPostcodeDistrict(postcode)
            if postcode == area.postcode || knownDistrict == district
                || postcode.hasPrefix(area.postcode) || area.postcode.hasPrefix(postcode) {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        let stored = CLLocationCoordinate2D(latitude: area.centerLatitude, longitude: area.centerLongitude)
        let isZeroOrInvalid = abs(area.centerLatitude) < 0.01 && abs(area.centerLongitude) < 0.01
        if !isZeroOrInvalid { return stored }
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
            // Skip POIs with junk names (e.g. "Unnamed" grit bins, "West Walk (0.6km)")
            if GoogleMapsService.isJunkPOIName(poi.name) { continue }
            let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
            let tooClose = kept.contains { other in
                distanceBetween(coord, CLLocationCoordinate2D(latitude: other.latitude, longitude: other.longitude)) < minDistance
            }
            if !tooClose { kept.append(poi) }
        }
        return kept.isEmpty ? nil : kept
    }
    
    // MARK: - Synthetic single-waypoint routes (from POIs already in duration buckets)
    /// Encode coordinates to Google polyline format (for synthetic user→POI→user line).
    private func encodeSimplePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encoded = ""
        var prevLat = 0, prevLng = 0
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            encoded += encodePolylineSignedNumber(lat - prevLat)
            encoded += encodePolylineSignedNumber(lng - prevLng)
            prevLat = lat
            prevLng = lng
        }
        return encoded
    }
    private func encodePolylineSignedNumber(_ num: Int) -> String {
        var sgn = num << 1
        if num < 0 { sgn = ~sgn }
        return encodePolylineNumber(sgn)
    }
    private func encodePolylineNumber(_ num: Int) -> String {
        var encoded = ""
        var n = num
        while n >= 0x20 {
            encoded += String(UnicodeScalar((0x20 | (n & 0x1f)) + 63)!)
            n >>= 5
        }
        encoded += String(UnicodeScalar(n + 63)!)
        return encoded
    }
    
    /// Straight-line underestimates walking path. Distance-dependent factor: 1.5 for short hops, taper to 1.25 for longer.
    private func pathFactor(straightLineM: Double) -> Double {
        if straightLineM <= 400 { return 1.5 }
        if straightLineM <= 800 { return 1.35 }
        return 1.25
    }
    
    /// Derive the real straight-line-to-walking ratio from stored OSRM data for a specific route.
    /// Uses the stored OSRM walking distance and the straight-line distances between the stored
    /// loop waypoints (areaCenter → WP1 → … → WPn → areaCenter) to compute a route-specific
    /// winding factor. Falls back to 1.35 (mid-tier pathFactor) if data is insufficient.
    private func osrmDerivedRatio(
        routeData: PrePopulatedPOIDatabase.PrePopulatedRoute.PrePopulatedRouteData,
        areaCenter: CLLocationCoordinate2D
    ) -> Double {
        guard routeData.distanceMeters > 0, !routeData.places.isEmpty else { return 1.35 }
        // Compute straight-line total for the stored loop: areaCenter → WP1 → … → WPn → areaCenter
        var straightTotal = 0.0
        var prev = areaCenter
        for poi in routeData.places {
            let coord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
            straightTotal += distanceBetween(prev, coord)
            prev = coord
        }
        straightTotal += distanceBetween(prev, areaCenter)
        guard straightTotal > 50 else { return 1.35 }  // avoid divide-by-near-zero
        let ratio = Double(routeData.distanceMeters) / straightTotal
        // Clamp to reasonable range (1.1 – 2.0) to guard against bad data
        return min(2.0, max(1.1, ratio))
    }
    
    /// Returns the single-waypoint round-trip duration in minutes for the given POI (pathFactor applied). Nil if POI is restricted.
    private func singleWaypointDurationMinutes(poi: PrePopulatedPOIDatabase.PrePopulatedPOI, location: CLLocationCoordinate2D) -> Int? {
        let placeResult = PlaceResult(
            placeId: poi.placeId,
            name: poi.name,
            vicinity: poi.vicinity,
            geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
            types: poi.types,
            source: POISource.fromString(poi.source)
        )
        if GoogleMapsService.shared.isRestrictedPOI(placeResult) { return nil }
        let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)
        let poiCoord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
        let dStraight = distanceBetween(location, poiCoord)
        let factor = pathFactor(straightLineM: dStraight)
        let roundTripM = 2 * dStraight * factor
        return Int((roundTripM / walkingSpeedMperMin))
    }
    
    /// Build a single-waypoint route for the given POI if round-trip duration is within 80–120% of requested.
    /// Returns nil if duration is outside band or POI is restricted.
    private func createSingleWaypointRoute(poi: PrePopulatedPOIDatabase.PrePopulatedPOI, location: CLLocationCoordinate2D, roundedDuration: Int) -> RouteCacheService.CachedRouteWithMetadata? {
        let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)
        let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
        let (minPercent, maxPercent) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
        let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)
        let maxAcceptableMinutes = Int(Double(roundedDuration) * maxPercent)
        let placeResult = PlaceResult(
            placeId: poi.placeId,
            name: poi.name,
            vicinity: poi.vicinity,
            geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
            types: poi.types,
            source: POISource.fromString(poi.source)
        )
        if GoogleMapsService.shared.isRestrictedPOI(placeResult) { return nil }
        let poiCoord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
        let dStraight = distanceBetween(location, poiCoord)
        let factor = pathFactor(straightLineM: dStraight)
        let dPath = dStraight * factor
        let roundTripM = 2 * dPath
        let sec = Int((roundTripM / walkingSpeedMperMin) * 60)
        let min = sec / 60
        guard min >= minAcceptableMinutes && min <= maxAcceptableMinutes else { return nil }
        let polyline = encodeSimplePolyline([location, poiCoord, location])
        let generatedRoute = GeneratedRoute(
            places: [placeResult],
            polyline: polyline,
            distanceMeters: Int(roundTripM),
            durationSeconds: sec,
            legs: []
        )
        return RouteCacheService.CachedRouteWithMetadata(
            route: generatedRoute,
            name: nil,
            description: nil,
            directions: nil,
            isFromPrePopulatedDatabase: true
        )
    }
    
    /// Build single-waypoint routes from POIs in duration buckets and optionally from the area's full POI list.
    /// For each unique POI, if round-trip from user is 80–120% of requested duration, add a synthetic route.
    /// areaPOIs: when provided, POIs that are in the area but not used as route waypoints (e.g. Oriental Chef in WF2) are also considered.
    private func buildSyntheticSingleWaypointRoutes(
        routes: [PrePopulatedPOIDatabase.PrePopulatedRoute],
        durationsToCheck: [Int],
        location: CLLocationCoordinate2D,
        roundedDuration: Int,
        areaPOIs: [PrePopulatedPOIDatabase.PrePopulatedPOI]? = nil
    ) -> [RouteCacheService.CachedRouteWithMetadata] {
        var result: [RouteCacheService.CachedRouteWithMetadata] = []
        var seenPlaceIds = Set<String>()
        let walkingSpeedMperMin = Double(GoogleMapsService.shared.adaptiveWalkingSpeed)
        let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
        let (minPercent, maxPercent) = isEdgeCase ? (0.75, 1.25) : (0.80, 1.20)
        let minAcceptableMinutes = Int(Double(roundedDuration) * minPercent)
        let maxAcceptableMinutes = Int(Double(roundedDuration) * maxPercent)
        
        func addSingleWaypointIfValid(poi: PrePopulatedPOIDatabase.PrePopulatedPOI) {
            guard !seenPlaceIds.contains(poi.placeId) else { return }
            seenPlaceIds.insert(poi.placeId)
            let placeResult = PlaceResult(
                placeId: poi.placeId,
                name: poi.name,
                vicinity: poi.vicinity,
                geometry: PlaceGeometry(location: PlaceLocation(lat: poi.latitude, lng: poi.longitude)),
                types: poi.types,
                source: POISource.fromString(poi.source)
            )
            if GoogleMapsService.shared.isRestrictedPOI(placeResult) {
                if poi.name.lowercased().contains("oriental") { print("📦 Single-waypoint skip '\(poi.name)': restricted POI type") }
                return
            }
            let poiCoord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
            let dStraight = distanceBetween(location, poiCoord)
            let factor = self.pathFactor(straightLineM: dStraight)
            let dPath = dStraight * factor
            let roundTripSeconds = Int(2 * (dPath / walkingSpeedMperMin) * 60)
            let totalDurationMinutes = roundTripSeconds / 60
            if totalDurationMinutes < minAcceptableMinutes || totalDurationMinutes > maxAcceptableMinutes {
                if poi.name.lowercased().contains("oriental") { print("📦 Single-waypoint skip '\(poi.name)': round-trip \(totalDurationMinutes)min outside [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min (dist \(Int(dStraight))m)") }
                return
            }
            let polyline = encodeSimplePolyline([location, poiCoord, location])
            let distanceMeters = Int(2 * dPath)
            let generatedRoute = GeneratedRoute(
                places: [placeResult],
                polyline: polyline,
                distanceMeters: distanceMeters,
                durationSeconds: roundTripSeconds,
                legs: []
            )
            let cached = RouteCacheService.CachedRouteWithMetadata(
                route: generatedRoute,
                name: nil,
                description: nil,
                directions: nil,
                isFromPrePopulatedDatabase: true
            )
            result.append(cached)
            print("📦 Single-waypoint option '\(poi.name)': \(totalDurationMinutes)min round-trip (\(Int(dPath))m each way) within [\(minAcceptableMinutes)–\(maxAcceptableMinutes)]min for \(roundedDuration)min request")
            print("\(Self.telem) ROUTE_ADDED name=\"\(poi.name)\" reason=single_waypoint_synthetic totalMin=\(totalDurationMinutes) distM=\(Int(dPath)) requested=\(roundedDuration)")
        }
        
        // 1) POIs that appear as waypoints in routes in the duration buckets
        for checkDuration in durationsToCheck {
            guard let routeGroup = routes.first(where: { $0.durationMinutes == checkDuration }) else { continue }
            for routeData in routeGroup.routes {
                for poi in routeData.places {
                    addSingleWaypointIfValid(poi: poi)
                }
            }
        }
        // 2) Area's full POI list (so POIs like Oriental Chef in WF2 appear even if not used in any route)
        // Pre-filter by max one-way distance (use 1.5x so POIs slightly farther still get duration check).
        // Sort by distance so closest POIs are evaluated first and more likely to pass.
        if let areaPOIs = areaPOIs {
            let maxOneWayM = (Double(maxAcceptableMinutes) * walkingSpeedMperMin) / 2.0 * 1.5
            let byDistance = areaPOIs.sorted { a, b in
                distanceBetween(location, CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude))
                < distanceBetween(location, CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude))
            }
            for poi in byDistance {
                let poiCoord = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                if distanceBetween(location, poiCoord) > maxOneWayM { continue }
                addSingleWaypointIfValid(poi: poi)
            }
        }
        return result
    }
    
    /// Call this before using the database (e.g. in findNearbyPlaces) so the first use waits for Firebase download to complete.
    func ensureDatabaseDownloaded(userLocation: CLLocationCoordinate2D? = nil) async {
        await downloadDatabaseIfNeeded(userLocation: userLocation)
    }

    /// Wait until the prepop download finishes OR `waitUpToSeconds` (wall-clock) has passed, whichever comes first.
    /// Caller stays on "Finding places nearby" until this returns. Does not cancel an in-flight download on timeout.
    func ensureDatabaseReadyWithTimeout(userLocation: CLLocationCoordinate2D?, waitUpToSeconds: TimeInterval) async {
        guard let userLocation = userLocation else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitUpToSeconds) { resumeOnce() }
            Task {
                await downloadDatabaseIfNeeded(userLocation: userLocation)
                resumeOnce()
            }
        }
    }

    /// Returns true if the coordinate is in a target postcode area (we have prepop data for it).
    /// Uses reverse geocode first, then fallback to distance-to-centers.
    func isInTargetPostcodeArea(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        await getPostcodeDistrict(for: coordinate) != nil
    }

    /// Download pre-populated database when we have a user location.
    /// Only downloads the relevant postcode JSON; full database is never used.
    func downloadDatabaseIfNeeded(userLocation: CLLocationCoordinate2D? = nil) async {
        // Require location: only download postcode-specific file, never full DB
        guard let userLocation = userLocation else {
            print("📦 Pre-populated DB: No user location yet - skipping download until first location")
            print("\(Self.telem) DOWNLOAD_SKIP reason=no_location")
            return
        }
        print("\(Self.telem) \(Self.prepopTimingTag) stage=location_given at=\(Self.prepopTimingStamp())")

        // If a download is already in progress, wait for it so caller gets the DB when ready
        if let existing = downloadTask {
            print("📦 Pre-populated DB: Download already in progress, waiting for it...")
            await existing.value
            return
        }

        // Already have cache and no need to re-download — unless user is in a different postcode (e.g. moved from WF2 to S5)
        let cachedSource = UserDefaults.standard.string(forKey: databaseSourceKey)
        let currentPostcode = await getPostcodeDistrict(for: userLocation)
        if UserDefaults.standard.data(forKey: storageKey) != nil, hasDownloadedDatabase {
            if let postcode = currentPostcode, postcode == cachedSource {
                return
            }
            if currentPostcode == nil {
                return
            }
            // User is in a different postcode than cache — proceed to download current area and replace cache
        }

        isDownloading = true
        // Assign downloadTask immediately when creating the task so any other caller
        // (e.g. findNearbyPlaces from EARLY PREFETCH) sees it and awaits instead of starting a second download.
        downloadTask = Task {
            defer { isDownloading = false; downloadTask = nil }
        
        // Determine postcode district from location: reverse geocode first, then fallback to distance-to-centers
        let postcodeDistrict = await getPostcodeDistrict(for: userLocation)
        if let district = postcodeDistrict {
            print("📦 Pre-populated DB: User in postcode district '\(district)' - downloading postcode file only")
            print("\(Self.telem) DOWNLOAD_START attemptedPostcode=\(district) location=(\(String(format: "%.5f", userLocation.latitude)),\(String(format: "%.5f", userLocation.longitude)))")
        } else {
            print("📦 Pre-populated DB: User location not in any target postcode area - no download")
            print("\(Self.telem) DOWNLOAD_START attemptedPostcode=none location=(\(String(format: "%.5f", userLocation.latitude)),\(String(format: "%.5f", userLocation.longitude)))")
        }
        
        // Try to get download URL (postcode-specific only)
        guard let postcodeDistrict = postcodeDistrict else {
            print("📦 Pre-populated DB: User not in any target postcode area - no download")
            print("\(Self.telem) DOWNLOAD_SKIP reason=no_matching_postcode")
            return
        }
        guard let url = await getDatabaseURL(for: postcodeDistrict) else {
            // Postcode file not found in Firebase - use cached database if available, otherwise API only
            if hasDownloadedDatabase {
                print("📦 Pre-populated DB: Postcode file not in Firebase, using cached database")
            } else {
                print("📦 Pre-populated DB: ❌ Postcode file not in Firebase and no cache - app will use API calls")
            }
            return
        }
        let firebaseJsonFile = "prepopulated_pois_\(postcodeDistrict).json"
        print("\(Self.telem) FIREBASE_JSON_FILE file=\(firebaseJsonFile) postcode=\(postcodeDistrict)")
        
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
        
        let maxAttempts = 3
        let downloadTimeoutSeconds: TimeInterval = 20
        var data: Data?
        var response: URLResponse?
        
        for attempt in 1...maxAttempts {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = downloadTimeoutSeconds
                let result = try await URLSession.shared.data(for: request)
                data = result.0
                response = result.1
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if attempt < maxAttempts {
                        print("📦 Pre-populated DB: Attempt \(attempt)/\(maxAttempts) failed - invalid response (status: \(status)), retrying...")
                    } else {
                        print("📦 Pre-populated DB: ❌ Download failed after \(maxAttempts) attempts - invalid response (status: \(status))")
                    }
                    continue
                }
                break
            } catch {
                if attempt < maxAttempts {
                    print("📦 Pre-populated DB: Attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)), retrying (max \(Int(downloadTimeoutSeconds))s per attempt)...")
                } else {
                    print("📦 Pre-populated DB: ❌ Download error after \(maxAttempts) attempts: \(error.localizedDescription)")
                }
            }
        }
        
        guard let data = data, let response = response,
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if hasDownloadedDatabase {
                print("📦 Pre-populated DB: Using cached database, will retry Firebase download on next launch")
            } else {
                print("📦 Pre-populated DB: ⚠️  No cached database available - app will use API calls")
            }
            return
        }
        
        do {
            let decoder = createJSONDecoder()
            let database = try decoder.decode(PrePopulatedPOIDatabase.self, from: data)
            
            // Log download info
            let downloadSize = Double(data.count) / 1024.0
            print("📦 Pre-populated DB: Downloaded \(String(format: "%.1f", downloadSize))KB")
            
            // Check if database actually exists (not just version key)
            let databaseExists = UserDefaults.standard.data(forKey: storageKey) != nil
            let cachedSource = UserDefaults.standard.string(forKey: databaseSourceKey)
            
            // Replace cache when: (1) downloaded file is for a different postcode than cached (user moved), or (2) same postcode but newer version, or (3) no cache yet
            let cacheIsForDifferentArea = cachedSource != nil && cachedSource != postcodeDistrict
            if cacheIsForDifferentArea {
                print("📦 Pre-populated DB: Cached database is for '\(cachedSource!)', user is in '\(postcodeDistrict)' - replacing with current area (version: \(database.version))")
            } else if let currentVersion = currentVersion, databaseExists {
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
            print("\(Self.telem) \(Self.prepopTimingTag) stage=downloaded at=\(Self.prepopTimingStamp())")

            // Mark as downloaded
            UserDefaults.standard.set(true, forKey: downloadCompleteKey)
            UserDefaults.standard.set(database.version, forKey: "prepopulatedPOIs_version")
            let sourceValue = postcodeDistrict
            UserDefaults.standard.set(sourceValue, forKey: databaseSourceKey)
            
            let totalPOIs = database.postcodeAreas.reduce(0) { $0 + $1.pois.count }
            let totalRoutes = database.postcodeAreas.compactMap { $0.routes }.flatMap { $0 }.reduce(0) { $0 + $1.routes.count }
            let areaList = database.postcodeAreas.map { a in "\(a.postcode):\((a.routes?.flatMap { $0.routes })?.count ?? 0)" }.joined(separator: " ")
            print("\(Self.telem) FIREBASE_DOWNLOAD_COMPLETE file=\(firebaseJsonFile)")
            print("\(Self.telem) DOWNLOAD_SUCCESS source=\(sourceValue) areaCount=\(database.postcodeAreas.count) totalPOIs=\(totalPOIs) totalRoutes=\(totalRoutes) areas=[\(areaList)]")
            print("📦 ✅ Pre-populated DB: Downloaded successfully from Firebase Storage!")
            print("📦   Used GPS-based postcode slice (\(postcodeDistrict)) - appropriate POIs/routes loaded quickly")
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
        await downloadTask!.value
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
            let totalSectors = database.postcodeAreas.compactMap { $0.sectors?.count }.reduce(0, +)
            if totalSectors > 0 {
                print("📦   Total sectors: \(totalSectors) (v2 sector-indexed)")
            }
            
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
