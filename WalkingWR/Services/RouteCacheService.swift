//
//  RouteCacheService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 26/12/2025.
//

import Foundation
import CoreLocation

/// Caches generated routes by location + duration to enable instant route display
/// - Routes cached for 24 hours (POIs may change, routes become stale)
/// - Matches within 500m of original location
/// - Stores up to 50 route sets
class RouteCacheService {
    static let shared = RouteCacheService()
    
    private let cacheKey = "cachedRoutes_v41"  // v41: Filter restricted POIs from cached routes (v1.9.16)
    private let maxCachedRouteSets = 50
    private let maxRoutesPerDuration = 10  // v1.6.46: Limit routes per location/duration to prevent unbounded growth
    private let matchRadiusMeters: Double = 10 // 10m - very tight since route start/end must match user position
    private let cacheExpiryHours: Double = 24 // Routes expire after 24 hours
    
    private init() {}
    
    // MARK: - Duration Rounding
    
    /// Round duration to nearest 5-minute interval for consistent caching
    /// e.g., 42min → 40min, 37min → 35min, 33min → 35min
    static func roundToNearest5Minutes(_ duration: Int) -> Int {
        return ((duration + 2) / 5) * 5  // +2 ensures proper rounding (not just floor)
    }
    
    // MARK: - Primary POI Detection (v1.9.52)
    
    /// Generic POI keywords that shouldn't be treated as primary attractions
    private static let genericPOIKeywords = [
        "footpath", "path", "road", "street", "lane", "avenue", "close", "drive",
        "bench", "bin", "post box", "telephone", "bollard", "sign", "lamp",
        "looking", "towards", "junction", "crossing", "corner"
    ]
    
    /// Extract the primary POI from a list of cached places
    /// The primary POI is the first meaningful (non-generic) location
    static func extractPrimaryPOI(from places: [CachedPlace]) -> String? {
        for place in places {
            let cleanedName = GoogleMapsService.cleanPOIDisplayName(place.name).lowercased()
            
            // Skip if too short (likely just a grid reference)
            guard cleanedName.count >= 3 else { continue }
            
            // Skip generic POIs
            let isGeneric = genericPOIKeywords.contains { cleanedName.contains($0) }
            if isGeneric { continue }
            
            // Found a meaningful POI - this is our primary
            return cleanedName
        }
        
        // Fallback: use first POI if no meaningful one found
        return places.first.map { GoogleMapsService.cleanPOIDisplayName($0.name).lowercased() }
    }
    
    /// Check if two routes share the same primary POI
    static func hasSamePrimaryPOI(_ route1: [CachedPlace], _ route2: [CachedPlace]) -> Bool {
        guard let primary1 = extractPrimaryPOI(from: route1),
              let primary2 = extractPrimaryPOI(from: route2) else {
            return false
        }
        return primary1 == primary2
    }
    
    // MARK: - Cache Entry Structure
    
    struct CachedRouteSet: Codable {
        let latitude: Double
        let longitude: Double
        let durationMinutes: Int
        let routes: [CachedRoute]
        let createdAt: Date
        
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        
        var isExpired: Bool {
            let expiryDate = createdAt.addingTimeInterval(24 * 60 * 60) // 24 hours
            return Date() > expiryDate
        }
    }
    
    struct CachedRoute: Codable {
        let places: [CachedPlace]
        let polyline: String
        let distanceMeters: Int
        let durationSeconds: Int
        let name: String?
        let description: String?
        let directions: [CachedDirection]?  // v1.6.45: Cache directions for instant load
        var skipCount: Int  // v1.6.46: Track how many times user shuffled past this route
        var createdAt: Date  // v1.6.46: Track when route was created (for tie-breaking)
        
        var durationMinutes: Int {
            durationSeconds / 60
        }
        
        /// v1.6.46: Calculate quality score for route comparison
        /// Higher score = better route. Factors:
        /// - Duration accuracy (closer to target = better)
        /// - POI variety (more diverse types = better)
        /// - Skip count (lower = better, users don't like this route)
        func qualityScore(targetDurationMinutes: Int) -> Double {
            // Duration accuracy: 0-40 points (perfect match = 40, 10min off = 0)
            let durationDiff = abs(durationMinutes - targetDurationMinutes)
            let durationScore = max(0, 40 - (durationDiff * 4))
            
            // POI variety: 0-30 points (unique type categories)
            let uniqueTypes = Set(places.flatMap { $0.types }).count
            let varietyScore = min(30, uniqueTypes * 5)
            
            // POI count: 0-15 points (more waypoints = more interesting, up to 5)
            let poiScore = min(15, places.count * 3)
            
            // Skip penalty: -10 points per skip (users didn't like this route)
            let skipPenalty = skipCount * 10
            
            // Freshness bonus: 0-5 points (routes less than 1 hour old get bonus)
            let ageHours = Date().timeIntervalSince(createdAt) / 3600
            let freshnessBonus = ageHours < 1 ? 5 : 0
            
            return Double(durationScore + varietyScore + poiScore - skipPenalty + freshnessBonus)
        }
        
        // v1.6.46: Initializer with defaults for backward compatibility
        init(places: [CachedPlace], polyline: String, distanceMeters: Int, durationSeconds: Int, 
             name: String?, description: String?, directions: [CachedDirection]?,
             skipCount: Int = 0, createdAt: Date = Date()) {
            self.places = places
            self.polyline = polyline
            self.distanceMeters = distanceMeters
            self.durationSeconds = durationSeconds
            self.name = name
            self.description = description
            self.directions = directions
            self.skipCount = skipCount
            self.createdAt = createdAt
        }
    }
    
    // v1.6.45: Cached walking directions for instant route load
    struct CachedDirection: Codable {
        let instruction: String
        let distance: String
        let distanceMeters: Int
        let duration: String
        let maneuver: String?
        
        func toWalkingDirection() -> WalkingDirection {
            WalkingDirection(
                instruction: instruction,
                distance: distance,
                distanceMeters: distanceMeters,
                duration: duration,
                maneuver: maneuver
            )
        }
        
        static func from(_ direction: WalkingDirection) -> CachedDirection {
            CachedDirection(
                instruction: direction.instruction,
                distance: direction.distance,
                distanceMeters: direction.distanceMeters,
                duration: direction.duration,
                maneuver: direction.maneuver
            )
        }
    }
    
    struct CachedPlace: Codable {
        let placeId: String
        let name: String
        let latitude: Double
        let longitude: Double
        let types: [String]
        let vicinity: String?
        
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    
    // MARK: - Public Methods
    
    /// Cached route with metadata (name, description, directions)
    struct CachedRouteWithMetadata {
        let route: GeneratedRoute
        let name: String?
        let description: String?
        let directions: [WalkingDirection]?  // v1.6.45: Cached directions for instant load
        var isDeadZoneFallback: Bool = false  // v1.6.39: True if route is 70-74% (closest available)
        var isFromPrePopulatedDatabase: Bool = false  // True when from PrePopulatedPOIService; route is first waypoint → … → first, we prepend GPS→first when displaying
    }
    
    /// Check if we have cached routes for this location and duration
    /// Returns cached routes WITH their Gemini names/descriptions if within 10m and same duration (rounded to 5min), nil otherwise
    /// Also validates that cached routes are within tolerance (80-120%, or 75-125% for edge cases)
    /// NEW: If exact duration not found, checks adjacent slots (±5, ±10, ±15 min) for valid routes
    /// PRIORITY 0: Checks pre-populated database first (fastest, no API calls)
    func getCachedRoutes(near location: CLLocationCoordinate2D, durationMinutes: Int) -> [CachedRouteWithMetadata]? {
        // 🎯 PRIORITY 0: Check pre-populated database first
        if let prePopulatedRoutes = PrePopulatedPOIService.shared.getPrePopulatedRoutes(near: location, durationMinutes: durationMinutes) {
            print("📦 PRE-POPULATED ROUTES HIT! Found \(prePopulatedRoutes.count) routes from pre-populated database")
            
            // v1.9.60: Filter out routes containing restricted POIs (playcare, nursery, etc.)
            // This catches routes in the database that include restricted POIs
            let filteredRoutes = prePopulatedRoutes.filter { routeWithMeta in
                let hasRestrictedPOI = routeWithMeta.route.places.contains { place in
                    GoogleMapsService.shared.isRestrictedPOI(place)
                }
                if hasRestrictedPOI {
                    let routeName = routeWithMeta.name ?? "Unnamed"
                    let restrictedPOIs = routeWithMeta.route.places.filter { GoogleMapsService.shared.isRestrictedPOI($0) }
                    let restrictedNames = restrictedPOIs.map { $0.name }.joined(separator: ", ")
                    print("📦 🏫 Filtered pre-populated route '\(routeName)' - contains restricted POI(s): \(restrictedNames)")
                }
                return !hasRestrictedPOI
            }
            
            let restrictedFilteredCount = prePopulatedRoutes.count - filteredRoutes.count
            if restrictedFilteredCount > 0 {
                print("📦 🏫 Filtered \(restrictedFilteredCount) pre-populated route(s) containing restricted POIs")
            }
            print("📦 🏫 PREPOP_RESTRICTED_SUMMARY before=\(prePopulatedRoutes.count) after_restricted_filter=\(filteredRoutes.count) filtered_out=\(restrictedFilteredCount) (restricted = playcare/daycare/nursery/playground etc)")
            
            // Only return if we still have valid routes after filtering
            if !filteredRoutes.isEmpty {
                print("ROUTES_SOURCE | source=prepop_database count=\(filteredRoutes.count) duration=\(durationMinutes) (pre-populated DB)")
                return filteredRoutes
            } else {
                print("📦 ⚠️ All pre-populated routes contained restricted POIs - falling back to regular cache")
            }
        }
        
        // 🎯 PRIORITY 1: Check regular cache
        let cached = loadCache()
        
        // Round to nearest 5 minutes for consistent caching (e.g., 42min → 40min)
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        
        // Calculate tolerance for the REQUESTED duration
        let isEdgeCase = roundedDuration <= 5 || roundedDuration >= 55
        let minPercent = isEdgeCase ? 0.75 : 0.80
        let maxPercent = isEdgeCase ? 1.25 : 1.20
        let minAcceptable = Int(Double(roundedDuration) * minPercent)
        let maxAcceptable = Int(Double(roundedDuration) * maxPercent)
        
        // Try exact duration first, then check adjacent durations
        // Order: exact → ±5 → ±10 → ±15 (closest first)
        let durationsToCheck = [
            roundedDuration,
            roundedDuration - 5, roundedDuration + 5,
            roundedDuration - 10, roundedDuration + 10,
            roundedDuration - 15, roundedDuration + 15
        ].filter { $0 >= 5 && $0 <= 60 }  // Keep within valid range (min 5 min)
        
        // v1.6.39: Track best dead-zone fallback routes (70-74%) in case no valid routes found
        var deadZoneFallbackRoutes: [CachedRouteWithMetadata] = []
        let deadZoneMinPercent = 0.70
        let deadZoneMinAcceptable = Int(Double(roundedDuration) * deadZoneMinPercent)
        
        for checkDuration in durationsToCheck {
            // Find matching cache entry for this duration
            for entry in cached {
                guard !entry.isExpired else { continue }
                guard entry.durationMinutes == checkDuration else { continue }
                
                let distance = distanceBetween(entry.coordinate, location)
                if distance <= matchRadiusMeters {
                    // Convert to metadata format
                    let allRoutes = convertToGeneratedRoutesWithMetadata(entry.routes)
                    
                    // v1.9.16: Filter out routes containing restricted POIs (playcare, nursery, etc.)
                    // This catches routes cached before the filter was implemented
                    let routesWithoutRestrictedPOIs = allRoutes.filter { routeWithMeta in
                        let hasRestrictedPOI = routeWithMeta.route.places.contains { place in
                            GoogleMapsService.shared.isRestrictedPOI(place)
                        }
                        if hasRestrictedPOI {
                            let routeName = routeWithMeta.name ?? "Unnamed"
                            let restrictedPOIs = routeWithMeta.route.places.filter { GoogleMapsService.shared.isRestrictedPOI($0) }
                            let restrictedNames = restrictedPOIs.map { $0.name }.joined(separator: ", ")
                            print("📦 🏫 Filtered cached route '\(routeName)' - contains restricted POI(s): \(restrictedNames)")
                        }
                        return !hasRestrictedPOI
                    }
                    
                    let restrictedFilteredCount = allRoutes.count - routesWithoutRestrictedPOIs.count
                    if restrictedFilteredCount > 0 {
                        print("📦 🏫 Filtered \(restrictedFilteredCount) cached route(s) containing restricted POIs")
                    }
                    
                    // Filter routes to only those within tolerance FOR THE REQUESTED DURATION
                    var validRoutes: [CachedRouteWithMetadata] = []
                    var filteredRoutes: [(name: String, duration: Int, reason: String)] = []
                    
                    for routeWithMeta in routesWithoutRestrictedPOIs {
                        let actualDuration = routeWithMeta.route.durationMinutes
                        if actualDuration >= minAcceptable && actualDuration <= maxAcceptable {
                            validRoutes.append(routeWithMeta)
                        } else {
                            let routeName = routeWithMeta.name ?? "Unnamed"
                            let reason = actualDuration < minAcceptable ? "too short (\(actualDuration)min < \(minAcceptable)min)" : "too long (\(actualDuration)min > \(maxAcceptable)min)"
                            filteredRoutes.append((name: routeName, duration: actualDuration, reason: reason))
                        }
                    }
                    
                    // Log filtered routes for debugging
                    if !filteredRoutes.isEmpty {
                        print("📦 ⚠️ Filtered \(filteredRoutes.count) cached routes:")
                        for filtered in filteredRoutes {
                            print("   ❌ '\(filtered.name)' - \(filtered.reason)")
                        }
                    }
                    
                    if !validRoutes.isEmpty {
                        if checkDuration == roundedDuration {
                            // Exact match
                            if validRoutes.count < allRoutes.count {
                                print("📦 Route Cache HIT! Found \(validRoutes.count)/\(allRoutes.count) valid routes cached \(Int(distance))m away for \(roundedDuration)min (filtered \(allRoutes.count - validRoutes.count) out-of-tolerance)")
                            } else {
                                print("📦 Route Cache HIT! Found \(validRoutes.count) routes cached \(Int(distance))m away for \(roundedDuration)min (requested \(durationMinutes)min)")
                            }
                        } else {
                            // Fallback from adjacent slot
                            let actualDurations = validRoutes.map { "\($0.route.durationMinutes)min" }.joined(separator: ", ")
                            print("📦 Route Cache FALLBACK! Using \(checkDuration)min slot for \(roundedDuration)min request → [\(actualDurations)] (within \(isEdgeCase ? "75-125%" : "80-120%") tolerance)")
                        }
                        print("ROUTES_SOURCE | source=memory_cache count=\(validRoutes.count) duration=\(durationMinutes) (in-memory/disk cache)")
                        return validRoutes
                    }
                    
                    // v1.6.39: DEAD ZONE ESCAPE HATCH
                    // If no valid routes (75%+), collect routes that are 70-74% as fallbacks
                    if deadZoneFallbackRoutes.isEmpty {
                        let escapableRoutes = allRoutes.filter { routeWithMeta in
                            let actualDuration = routeWithMeta.route.durationMinutes
                            return actualDuration >= deadZoneMinAcceptable && actualDuration < minAcceptable
                        }
                        if !escapableRoutes.isEmpty {
                            // Mark these as dead zone fallbacks
                            deadZoneFallbackRoutes = escapableRoutes.map { route in
                                var mutable = route
                                mutable.isDeadZoneFallback = true
                                return mutable
                            }
                        }
                    }
                }
            }
        }
        
        // v1.6.39: DEAD ZONE ESCAPE - If no valid routes found, return best 70-74% routes
        if !deadZoneFallbackRoutes.isEmpty {
            // Sort by closest to target (highest accuracy first)
            let sorted = deadZoneFallbackRoutes.sorted { r1, r2 in
                r1.route.durationMinutes > r2.route.durationMinutes  // Prefer longer (closer to target)
            }
            let bestFallback = sorted.first!
            let accuracy = Double(bestFallback.route.durationMinutes) / Double(roundedDuration) * 100
            print("📦 🆘 DEAD ZONE ESCAPE! No routes ≥75%, returning closest available: \(bestFallback.route.durationMinutes)min (\(Int(accuracy))% of \(roundedDuration)min target)")
            print("ROUTES_SOURCE | source=memory_cache count=1 dead_zone_fallback duration=\(durationMinutes)")
            return [sorted.first!]  // Return best single route
        }
        
        print("ROUTES_SOURCE | source=none cache_miss duration=\(durationMinutes)")
        return nil
    }
    
    /// Cache routes for a location and duration (rounded to nearest 5 minutes)
    /// v2.1.0: DISABLED for ToS compliance - dynamically generated routes use MapKit polylines
    /// which cannot be cached per Apple's Terms of Service.
    /// Only pre-populated database routes are available (via PrePopulatedPOIService).
    func cacheRoutes(_ routes: [GeneratedRoute], at location: CLLocationCoordinate2D, durationMinutes: Int, names: [String?] = [], descriptions: [String?] = [], directions: [[WalkingDirection]] = []) {
        // v2.1.0: Route caching disabled for ToS compliance
        // Dynamically generated routes use MapKit polylines which cannot be cached
        // Pre-populated routes are already in the database and don't need to be cached here
        print("📦 Route Cache: Skipping cache (ToS compliance - routes use MapKit polylines)")
        print("📦 Route Cache: \(routes.count) routes available for this session only")
    }
    
    /// Clear all cached routes
    func clearCache() {
        let beforeStats = getCacheStats()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        print("📦 ═══════════════════════════════════════════════════════════")
        print("📦 CACHE CLEARED! Removed \(beforeStats.totalRoutes) routes from \(beforeStats.routeSets) sets")
        print("📦 ═══════════════════════════════════════════════════════════")
    }
    
    /// Merge new routes into existing cache (smart quality-based update)
    /// v2.1.0: DISABLED for ToS compliance - dynamically generated routes use MapKit polylines
    /// which cannot be cached per Apple's Terms of Service.
    /// Returns: (added: 0, replaced: 0) - no caching performed
    func mergeRoutes(_ routes: [GeneratedRoute], at location: CLLocationCoordinate2D, durationMinutes: Int, names: [String?] = [], descriptions: [String?] = [], directions: [[WalkingDirection]] = []) -> (added: Int, replaced: Int) {
        // v2.1.0: Route caching disabled for ToS compliance
        print("📦 Route Merge: Skipping cache (ToS compliance - routes use MapKit polylines)")
        print("📦 Route Merge: \(routes.count) routes available for this session only")
        return (0, 0)
    }
    
    /// v1.6.46: Increment skip count for a route (user shuffled past it)
    /// This decreases the route's quality score, making it more likely to be replaced
    /// - Parameters:
    ///   - routeName: Name of the route that was skipped
    ///   - location: User's location when skip happened
    ///   - durationMinutes: Duration of the route set
    func incrementSkipCount(routeName: String?, at location: CLLocationCoordinate2D, durationMinutes: Int) {
        var cached = loadCache()
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        
        // Find the cache entry for this location/duration
        guard let entryIndex = cached.firstIndex(where: { entry in
            let distance = distanceBetween(entry.coordinate, location)
            return distance <= matchRadiusMeters && entry.durationMinutes == roundedDuration
        }) else {
            return // No matching cache entry
        }
        
        var routes = cached[entryIndex].routes
        
        // Find route by name and increment skip count
        for (routeIndex, route) in routes.enumerated() {
            if route.name == routeName {
                // Create new route with incremented skip count
                let updatedRoute = CachedRoute(
                    places: route.places,
                    polyline: route.polyline,
                    distanceMeters: route.distanceMeters,
                    durationSeconds: route.durationSeconds,
                    name: route.name,
                    description: route.description,
                    directions: route.directions,
                    skipCount: route.skipCount + 1,
                    createdAt: route.createdAt
                )
                routes[routeIndex] = updatedRoute
                
                let newQuality = updatedRoute.qualityScore(targetDurationMinutes: roundedDuration)
                print("📦 Skip tracked: '\(routeName ?? "Unnamed")' now has \(updatedRoute.skipCount) skips (quality: \(Int(newQuality)))")
                break
            }
        }
        
        // Update cache entry
        let updatedEntry = CachedRouteSet(
            latitude: cached[entryIndex].latitude,
            longitude: cached[entryIndex].longitude,
            durationMinutes: roundedDuration,
            routes: routes,
            createdAt: cached[entryIndex].createdAt
        )
        cached[entryIndex] = updatedEntry
        saveCache(cached)
    }
    
    /// Get cache statistics
    func getCacheStats() -> (routeSets: Int, totalRoutes: Int, oldestAge: TimeInterval?) {
        let cached = loadCache().filter { !$0.isExpired }
        let totalRoutes = cached.reduce(0) { $0 + $1.routes.count }
        let oldest = cached.min { $0.createdAt < $1.createdAt }
        let age = oldest.map { Date().timeIntervalSince($0.createdAt) }
        return (cached.count, totalRoutes, age)
    }
    
    /// v1.6.48: Get detailed cache contents for debug viewer
    /// Returns array of (duration, routes) grouped by duration
    func getCacheDetails() -> [(duration: Int, location: CLLocationCoordinate2D, routes: [(name: String?, pois: [String], actualDuration: Int, distance: Int, skipCount: Int)])] {
        let cached = loadCache().filter { !$0.isExpired }
        
        return cached.map { set in
            let routeDetails = set.routes.map { route in
                let poiNames = route.places.map { $0.name }
                return (
                    name: route.name,
                    pois: poiNames,
                    actualDuration: route.durationMinutes,
                    distance: route.distanceMeters,
                    skipCount: route.skipCount
                )
            }
            return (
                duration: set.durationMinutes,
                location: set.coordinate,
                routes: routeDetails
            )
        }.sorted { $0.duration < $1.duration }
    }
    
    // MARK: - Private Methods
    
    private func loadCache() -> [CachedRouteSet] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            return []
        }
        
        do {
            let decoded = try JSONDecoder().decode([CachedRouteSet].self, from: data)
            return decoded
        } catch {
            print("📦 Route Cache: Failed to decode - \(error.localizedDescription)")
            return []
        }
    }
    
    private func saveCache(_ cache: [CachedRouteSet]) {
        do {
            let data = try JSONEncoder().encode(cache)
            UserDefaults.standard.set(data, forKey: cacheKey)
        } catch {
            print("📦 Route Cache: Failed to encode - \(error.localizedDescription)")
        }
    }
    
    private func convertToGeneratedRoutesWithMetadata(_ cachedRoutes: [CachedRoute]) -> [CachedRouteWithMetadata] {
        return cachedRoutes.map { cached in
            let places = cached.places.map { place in
                PlaceResult(
                    placeId: place.placeId,
                    name: place.name,
                    vicinity: place.vicinity,
                    geometry: PlaceGeometry(
                        location: PlaceLocation(
                            lat: place.latitude,
                            lng: place.longitude
                        )
                    ),
                    types: place.types
                )
            }
            
            let route = GeneratedRoute(
                places: places,
                polyline: cached.polyline,
                distanceMeters: cached.distanceMeters,
                durationSeconds: cached.durationSeconds,
                legs: [] // Legs not cached, but not needed for display
            )
            
            // v1.6.45: Convert cached directions to WalkingDirection
            let walkingDirections = cached.directions?.map { $0.toWalkingDirection() }
            
            return CachedRouteWithMetadata(
                route: route,
                name: cached.name,
                description: cached.description,
                directions: walkingDirections
            )
        }
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
}

