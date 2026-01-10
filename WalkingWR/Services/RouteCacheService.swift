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
    
    private let cacheKey = "cachedRoutes_v33"  // v33: Cache directions for instant route load
    private let maxCachedRouteSets = 50
    private let matchRadiusMeters: Double = 10 // 10m - very tight since route start/end must match user position
    private let cacheExpiryHours: Double = 24 // Routes expire after 24 hours
    
    private init() {}
    
    // MARK: - Duration Rounding
    
    /// Round duration to nearest 5-minute interval for consistent caching
    /// e.g., 42min → 40min, 37min → 35min, 33min → 35min
    static func roundToNearest5Minutes(_ duration: Int) -> Int {
        return ((duration + 2) / 5) * 5  // +2 ensures proper rounding (not just floor)
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
        
        var durationMinutes: Int {
            durationSeconds / 60
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
    }
    
    /// Check if we have cached routes for this location and duration
    /// Returns cached routes WITH their Gemini names/descriptions if within 10m and same duration (rounded to 5min), nil otherwise
    /// Also validates that cached routes are within tolerance (80-120%, or 75-125% for edge cases)
    /// NEW: If exact duration not found, checks adjacent slots (±5, ±10, ±15 min) for valid routes
    func getCachedRoutes(near location: CLLocationCoordinate2D, durationMinutes: Int) -> [CachedRouteWithMetadata]? {
        let cached = loadCache()
        
        // Round to nearest 5 minutes for consistent caching (e.g., 42min → 40min)
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        
        // Calculate tolerance for the REQUESTED duration
        let isEdgeCase = roundedDuration <= 10 || roundedDuration >= 55
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
        ].filter { $0 >= 10 && $0 <= 60 }  // Keep within valid range (min 10 min)
        
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
                    
                    // Filter routes to only those within tolerance FOR THE REQUESTED DURATION
                    var validRoutes: [CachedRouteWithMetadata] = []
                    var filteredRoutes: [(name: String, duration: Int, reason: String)] = []
                    
                    for routeWithMeta in allRoutes {
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
            return [sorted.first!]  // Return best single route
        }
        
        return nil
    }
    
    /// Cache routes for a location and duration (rounded to nearest 5 minutes)
    /// v1.6.45: Now also caches directions for instant load
    func cacheRoutes(_ routes: [GeneratedRoute], at location: CLLocationCoordinate2D, durationMinutes: Int, names: [String?] = [], descriptions: [String?] = [], directions: [[WalkingDirection]] = []) {
        var cached = loadCache()
        
        // Round to nearest 5 minutes for consistent caching
        let roundedDuration = RouteCacheService.roundToNearest5Minutes(durationMinutes)
        
        // Remove expired entries
        cached = cached.filter { !$0.isExpired }
        
        // Remove any existing entry for this location/duration (using rounded)
        cached = cached.filter { entry in
            let distance = distanceBetween(entry.coordinate, location)
            return !(distance <= matchRadiusMeters && entry.durationMinutes == roundedDuration)
        }
        
        // Convert routes to cached format, filtering out duplicates (>50% POI overlap)
        var cachedRoutes: [CachedRoute] = []
        var seenPlaceIdSets: [Set<String>] = []
        
        for (index, route) in routes.enumerated() {
            let newPlaceIds = Set(route.places.map { $0.placeId })
            
            // Check for duplicate (>50% overlap with already-added routes)
            var isDuplicate = false
            for existingSet in seenPlaceIdSets {
                let overlap = newPlaceIds.intersection(existingSet).count
                let overlapPercent = Double(overlap) / Double(max(1, newPlaceIds.count))
                if overlapPercent > 0.50 {
                    isDuplicate = true
                    break
                }
            }
            
            if isDuplicate { continue }
            
            seenPlaceIdSets.append(newPlaceIds)
            
            // v1.6.45: Cache directions if provided
            let routeDirections: [CachedDirection]? = directions.indices.contains(index) && !directions[index].isEmpty
                ? directions[index].map { CachedDirection.from($0) }
                : nil
            
            cachedRoutes.append(CachedRoute(
                places: route.places.map { place in
                    CachedPlace(
                        placeId: place.placeId,
                        name: place.name,
                        latitude: place.coordinate.latitude,
                        longitude: place.coordinate.longitude,
                        types: place.types ?? [],
                        vicinity: place.vicinity
                    )
                },
                polyline: route.polyline,
                distanceMeters: route.distanceMeters,
                durationSeconds: route.durationSeconds,
                name: names.indices.contains(index) ? names[index] : nil,
                description: descriptions.indices.contains(index) ? descriptions[index] : nil,
                directions: routeDirections
            ))
        }
        
        // If all routes were duplicates, don't update cache
        guard !cachedRoutes.isEmpty else {
            print("📦 Route Cache: No unique routes to cache (all duplicates)")
            return
        }
        
        // Add new entry (using rounded duration)
        let newEntry = CachedRouteSet(
            latitude: location.latitude,
            longitude: location.longitude,
            durationMinutes: roundedDuration,
            routes: cachedRoutes,
            createdAt: Date()
        )
        cached.append(newEntry)
        
        // Trim to max size (remove oldest first)
        if cached.count > maxCachedRouteSets {
            cached.sort { $0.createdAt > $1.createdAt }
            cached = Array(cached.prefix(maxCachedRouteSets))
        }
        
        saveCache(cached)
        print("📦 Route Cache: Saved \(routes.count) routes for \(roundedDuration)min (requested \(durationMinutes)min) at (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
    }
    
    /// Clear all cached routes
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        print("📦 Route Cache: Cleared")
    }
    
    /// Get cache statistics
    func getCacheStats() -> (routeSets: Int, totalRoutes: Int, oldestAge: TimeInterval?) {
        let cached = loadCache().filter { !$0.isExpired }
        let totalRoutes = cached.reduce(0) { $0 + $1.routes.count }
        let oldest = cached.min { $0.createdAt < $1.createdAt }
        let age = oldest.map { Date().timeIntervalSince($0.createdAt) }
        return (cached.count, totalRoutes, age)
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

