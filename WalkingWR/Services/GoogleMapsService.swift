//
//  GoogleMapsService.swift
//  WalkingWR
//
//  Created for local route generation using Google APIs
//

import Foundation
import CoreLocation
import MapKit

// MARK: - MapKit Rate Limiter Actor (Thread-Safe)
/// Actor to manage MapKit rate limiting with thread-safe access from concurrent tasks
private actor MapKitRateLimiter {
    private var timestamps: [Date] = []
    
    struct RateLimitStatus {
        let currentCount: Int
        let shouldWait: Bool
        let waitTime: TimeInterval?
    }
    
    /// Check rate limit status and clean up old timestamps
    func checkAndCleanup(limit: Int, window: TimeInterval) -> RateLimitStatus {
        let now = Date()
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        
        let shouldWait = timestamps.count >= limit
        var waitTime: TimeInterval? = nil
        
        if shouldWait, let oldest = timestamps.first {
            waitTime = window - now.timeIntervalSince(oldest) + 1
        }
        
        return RateLimitStatus(currentCount: timestamps.count, shouldWait: shouldWait, waitTime: waitTime)
    }
    
    /// Record a new request timestamp
    func recordRequest() {
        timestamps.append(Date())
    }
    
    /// Get current count of requests in window
    func getCurrentCount(window: TimeInterval) -> Int {
        let now = Date()
        return timestamps.filter { now.timeIntervalSince($0) < window }.count
    }
}

// MARK: - Google Maps Service
class GoogleMapsService: ObservableObject {
    static let shared = GoogleMapsService()
    
    // API Key - bundled with app in Info.plist
    // For production, consider using a backend proxy to hide the key
    // For production, consider using a backend proxy to hide the key
    private var apiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String ?? ""
    }
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // v1.6.10: Low POI warning for sparse areas
    @Published var hasLimitedPOIs = false
    @Published var lastPOICount = 0
    static let limitedPOIThreshold = 50  // Below this, show warning
    
    // v1.6.21: Short route viability gate
    @Published var shortRouteNotViable = false  // True if 5-7min routes can't work here
    @Published var minimumViableMinutes = 5     // Suggested minimum duration for this area
    
    // v1.6.24: Early POI prefetching (when clinician is selected)
    @Published var isPrefetchingEarly = false
    @Published var earlyPrefetchComplete = false
    private var earlyPrefetchedPOIs: [PlaceResult] = []
    private var earlyPrefetchLocation: CLLocationCoordinate2D?
    
    private let session = URLSession.shared
    
    // MARK: - Alternative Routes Buffer
    // Stores valid endpoint routes that weren't returned as primary (e.g., "boring" single-waypoint routes)
    // Caller can retrieve these to add to the route pool for more variety
    private(set) var alternativeEndpointRoutes: [GeneratedRoute] = []
    
    // MARK: - MapKit Rate Limiting
    // MapKit allows 50 requests per 60 seconds
    // Using actor for thread-safe access from concurrent tasks
    private let rateLimiter = MapKitRateLimiter()
    private let mapKitRateLimit = 45  // Stay under 50 to be safe
    private let mapKitRateLimitWindow: TimeInterval = 60
    
    /// Check if we're approaching rate limit and wait if needed (thread-safe via actor)
    private func checkMapKitRateLimit() async {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        
        // If approaching limit, wait for oldest request to expire
        if status.shouldWait, let waitTime = status.waitTime, waitTime > 0 {
            print("⏳ Approaching MapKit rate limit (\(status.currentCount)/50), waiting \(Int(waitTime))s...")
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
    
    /// Record a MapKit request (thread-safe via actor)
    private func recordMapKitRequest() {
        Task { await rateLimiter.recordRequest() }
    }
    
    // MARK: - Leg Time Cache
    // Caches walking time between origin grid cells and POIs to avoid repeated MapKit calls
    // Key: (originGrid50m, poiId) → Value: (minutes, meters, timestamp)
    
    private struct LegCacheKey: Hashable {
        let originGrid: String  // Lat/Lon rounded to 50m grid
        let poiId: String
    }
    
    private struct LegCacheValue {
        let minutes: Int
        let meters: Int
        let polyline: String
        let updatedAt: Date
    }
    
    private var legCache: [LegCacheKey: LegCacheValue] = [:]
    private let legCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days
    
    /// Convert coordinate to 50m grid cell string
    private func gridKey(for coordinate: CLLocationCoordinate2D) -> String {
        // ~50m precision: 0.00045° latitude, 0.0007° longitude at UK latitudes
        let latGrid = round(coordinate.latitude / 0.00045) * 0.00045
        let lonGrid = round(coordinate.longitude / 0.0007) * 0.0007
        return String(format: "%.5f,%.4f", latGrid, lonGrid)
    }
    
    /// Get cached leg time if available
    private func getCachedLegTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult) -> LegCacheValue? {
        let key = LegCacheKey(originGrid: gridKey(for: origin), poiId: poi.placeId)
        
        guard let cached = legCache[key] else { return nil }
        
        // Check if cache is still valid
        if Date().timeIntervalSince(cached.updatedAt) > legCacheMaxAge {
            legCache.removeValue(forKey: key)
            return nil
        }
        
        return cached
    }
    
    /// Cache leg time for future use
    private func cacheLegTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult, minutes: Int, meters: Int, polyline: String) {
        let key = LegCacheKey(originGrid: gridKey(for: origin), poiId: poi.placeId)
        legCache[key] = LegCacheValue(minutes: minutes, meters: meters, polyline: polyline, updatedAt: Date())
        
        // Limit cache size
        if legCache.count > 500 {
            // Remove oldest entries
            let sortedKeys = legCache.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for (key, _) in sortedKeys.prefix(100) {
                legCache.removeValue(forKey: key)
            }
        }
    }
    
    // MARK: - Recently Used POI Tracking
    // Tracks POIs used in recent routes to encourage variety
    // Key: POI place ID → Value: timestamp when last used
    private var recentlyUsedPOIs: [String: Date] = [:]
    private let recentPOIPenaltyWindow: TimeInterval = 300  // 5 minutes
    
    /// Record a POI as recently used
    func markPOIAsUsed(_ placeId: String) {
        recentlyUsedPOIs[placeId] = Date()
        
        // Clean up old entries
        let cutoff = Date().addingTimeInterval(-recentPOIPenaltyWindow * 2)
        recentlyUsedPOIs = recentlyUsedPOIs.filter { $0.value > cutoff }
    }
    
    /// Get penalty for recently used POI (0.0 = no penalty, 1.0 = max penalty)
    private func recentUsePenalty(for placeId: String) -> Double {
        guard let lastUsed = recentlyUsedPOIs[placeId] else { return 0 }
        let secondsAgo = Date().timeIntervalSince(lastUsed)
        
        if secondsAgo < 60 { return 0.9 }       // Used <1 min ago: heavy penalty
        if secondsAgo < 180 { return 0.6 }      // Used <3 min ago: medium penalty
        if secondsAgo < recentPOIPenaltyWindow { return 0.3 }  // Used <5 min ago: light penalty
        return 0  // Old enough, no penalty
    }
    
    // MARK: - POI Walkability Score
    // Scores POIs by how pleasant they are as walking waypoints
    // Higher score = better for walking routes
    
    /// Calculate walkability score for a POI based on its type
    /// Returns score from -2 (avoid) to +2 (prefer)
    /// Check if POI is from Google (highest quality, most up-to-date)
    private func isGooglePOI(_ poi: PlaceResult) -> Bool {
        // Google POIs don't have "apple_" or "osm_" prefix
        return !poi.placeId.hasPrefix("apple_") && !poi.placeId.hasPrefix("osm_")
    }
    
    /// Source quality score - prefer Google POIs over OSM/Apple
    /// Google POIs are more accurate and up-to-date
    private func sourceQualityScore(for poi: PlaceResult, googlePOICount: Int) -> Double {
        // Only apply bonus if we have sufficient Google POIs (10+)
        // This ensures we still use OSM/Apple in sparse areas
        guard googlePOICount >= 10 else { return 0.0 }
        
        if isGooglePOI(poi) {
            return 3.0  // Strong preference for Google POIs
        } else {
            return 0.0  // No penalty, just no bonus
        }
    }
    
    private func walkabilityScore(for poi: PlaceResult) -> Double {
        let types = Set(poi.types ?? [])
        
        // Excellent walking destinations (+2)
        let excellent = Set(["park", "playground", "nature_reserve", "garden", "trail",
                            "hiking_area", "botanical_garden", "national_park"])
        if !types.isDisjoint(with: excellent) { return 2.0 }
        
        // Good walking destinations (+1)
        let good = Set(["cafe", "restaurant", "bakery", "landmark", "museum",
                       "art_gallery", "church", "historic_site", "monument",
                       "library", "community_center", "sports_club", "pub"])
        if !types.isDisjoint(with: good) { return 1.0 }
        
        // Avoid for walking (-1)
        let avoid = Set(["gas_station", "car_wash", "car_repair", "car_dealer",
                        "parking", "atm", "bank", "insurance_agency"])
        if !types.isDisjoint(with: avoid) { return -1.0 }
        
        // Strongly avoid (-2)
        let stronglyAvoid = Set(["industrial", "warehouse", "storage", "factory",
                                "transit_station", "bus_station", "train_station"])
        if !types.isDisjoint(with: stronglyAvoid) { return -2.0 }
        
        // Neutral (0)
        return 0.0
    }
    
    // MARK: - Pre-Filter POIs by Estimated Duration
    // Estimates round-trip time BEFORE expensive routing API calls
    // Rejects POIs that would create routes way outside target duration
    
    /// Get adaptive road factor based on POI type
    /// Parks/trails have more direct paths, urban areas have more roads
    private func adaptiveRoadFactor(for poi: PlaceResult) -> Double {
        let types = Set(poi.types ?? [])
        
        // Parks/nature: more direct walking paths (1.15-1.25)
        let parkTypes = Set(["park", "playground", "nature_reserve", "garden", "trail",
                            "hiking_area", "botanical_garden", "national_park", "forest",
                            "beach", "campground"])
        if !types.isDisjoint(with: parkTypes) {
            return 1.2
        }
        
        // Car-centric locations: more road detours (1.5)
        let carTypes = Set(["gas_station", "car_wash", "car_dealer", "car_repair",
                           "parking", "car_rental", "atm", "bank"])
        if !types.isDisjoint(with: carTypes) {
            return 1.5
        }
        
        // Default: mixed urban (1.35)
        return 1.35
    }
    
    /// Estimate round-trip walking time to a POI (in minutes)
    /// Uses straight-line distance × adaptive road factor × 2 (round trip)
    private func estimateRoundTripMinutes(from origin: CLLocationCoordinate2D, to poi: PlaceResult) -> Int {
        let straightLineDistance = distanceBetween(origin, poi.coordinate)
        
        // Road factor varies by POI type: parks 1.2, urban 1.35, car-centric 1.5
        let roadFactor = adaptiveRoadFactor(for: poi)
        let estimatedWalkingDistance = straightLineDistance * roadFactor * 2  // Round trip
        
        // Walking speed (use adaptive if available)
        let walkingSpeed = Double(adaptiveWalkingSpeed)  // m/min
        
        let estimatedMinutes = Int(estimatedWalkingDistance / walkingSpeed)
        return estimatedMinutes
    }
    
    /// Pre-filter POIs to only include those within reasonable duration range
    /// This prevents "Springwood Cott" (30min round-trip) from being considered for 5min routes
    func preFilterPOIsByDuration(
        _ pois: [PlaceResult],
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) -> [PlaceResult] {
        // DURATION-AWARE PRE-FILTER: 
        // v1.6.12: HARD CUTOFF for 5-minute routes (batch test showed 180% consistently)
        // The root cause is selection-dominated: we pick wrong POIs, not route wrong
        // For 5min routes: max 7min estimated round-trip (allows ~40% slack)
        
        // v1.6.21: Revert to tighter 7-min cutoff for 5-min routes
        // v1.6.15's 10min cap was too loose → 180% accuracy consistently
        // 7min cap worked better in v1.6.12: allows 40% slack, rejects far POIs
        if targetDurationMinutes == 5 {
            var accepted: [PlaceResult] = []
            var rejected: [(name: String, estimated: Int)] = []
            
            for poi in pois {
                let estimated = estimateRoundTripMinutes(from: origin, to: poi)
                if estimated <= 7 {  // Tight cutoff: max 7min estimated (40% slack)
                    accepted.append(poi)
                } else {
                    rejected.append((poi.name, estimated))
                }
            }
            
            // Debug: Show accepted candidates for 5-min routes
            print("🎯 5-MIN CANDIDATES: \(accepted.count) POIs with ≤10min estimated:")
            for poi in accepted.prefix(10) {
                let est = estimateRoundTripMinutes(from: origin, to: poi)
                print("   ✅ \(poi.name): ~\(est)min")
            }
            if accepted.count > 10 {
                print("   ... and \(accepted.count - 10) more")
            }
            
            print("🎯 ⏱️ 5-MIN HARD CUTOFF: Kept \(accepted.count)/\(pois.count) POIs (max 7min round-trip)")
            if !rejected.isEmpty {
                print("   ❌ Rejected \(rejected.count) POIs with >7min estimated")
            }
            
            // DEBUG: Check for specific nearby places
            let foodPlaces = pois.filter { poi in
                let types = Set(poi.types ?? [])
                return !types.isDisjoint(with: ["restaurant", "cafe", "meal_takeaway", "food", "bakery"])
            }
            print("🍽️ DEBUG: Found \(foodPlaces.count) food places nearby:")
            for fp in foodPlaces.prefix(10) {
                let est = estimateRoundTripMinutes(from: origin, to: fp)
                print("   🍽️ \(fp.name): ~\(est)min round-trip")
            }
            
            return accepted
        }
        
        // Standard percentage-based filter for other durations
        // v1.6.21: Revert to v1.6.12 tighter ranges - looser ranges = worse accuracy
        let minPercent: Int
        var baseMaxPercent: Int
        switch targetDurationMinutes {
        case 6...10:
            minPercent = 40; baseMaxPercent = 95   // Tight for short routes
        case 11...15:
            minPercent = 45; baseMaxPercent = 100  // Tight for 15min
        case 16...25:
            minPercent = 50; baseMaxPercent = 105  // Moderate
        case 26...40:
            minPercent = 55; baseMaxPercent = 110  // Moderate
        case 41...50:
            minPercent = 55; baseMaxPercent = 105  // Tighter for long
        default:  // 51+ min
            minPercent = 60; baseMaxPercent = 100  // Very tight for very long
        }
        
        // v1.6.27: DENSITY-AWARE TIGHTENING
        // In dense areas (lots of POIs), tighten maxPercent to prevent overshoot
        // This preserves all duration-specific tuning while adapting to POI availability
        let densityTightening: Double
        if pois.count > 300 {
            densityTightening = 0.75   // Very dense (Firth Park, 350 POIs) - 25% tighter
        } else if pois.count > 200 {
            densityTightening = 0.85   // Dense - 15% tighter
        } else if pois.count > 100 {
            densityTightening = 0.95   // Medium - 5% tighter
        } else {
            densityTightening = 1.0    // Sparse (Outwood, 115 POIs) - no change
        }
        
        let effectiveMaxPercent = Int(Double(baseMaxPercent) * densityTightening)
        
        if densityTightening < 1.0 {
            print("🎯 DENSITY TIGHTENING: \(pois.count) POIs → maxPercent \(baseMaxPercent)% → \(effectiveMaxPercent)%")
        }
        
        let minDuration = max(2, targetDurationMinutes * minPercent / 100)
        let maxDuration = targetDurationMinutes * effectiveMaxPercent / 100
        
        var accepted: [PlaceResult] = []
        var rejected: [(name: String, estimated: Int, reason: String)] = []
        
        for poi in pois {
            let estimated = estimateRoundTripMinutes(from: origin, to: poi)
            
            if estimated < minDuration {
                rejected.append((poi.name, estimated, "too short"))
            } else if estimated > maxDuration {
                rejected.append((poi.name, estimated, "too long"))
            } else {
                accepted.append(poi)
            }
        }
        
        if !rejected.isEmpty {
            let tooShort = rejected.filter { $0.reason == "too short" }.count
            let tooLong = rejected.filter { $0.reason == "too long" }.count
            print("🎯 ⏱️ PRE-FILTER: Kept \(accepted.count)/\(pois.count) POIs for \(targetDurationMinutes)min target (\(minPercent)-\(effectiveMaxPercent)% range)")
            if tooShort > 0 {
                print("   ❌ Too short (<\(minDuration)min): \(tooShort) POIs")
            }
            if tooLong > 0 {
                let examples = rejected.filter { $0.reason == "too long" }.prefix(3)
                    .map { "\($0.name) (~\($0.estimated)min)" }.joined(separator: ", ")
                print("   ❌ Too long (>\(maxDuration)min): \(tooLong) POIs (e.g., \(examples))")
            }
        }
        
        return accepted
    }
    
    /// Calculate combined POI score for ranking
    /// Higher score = better candidate for route
    /// - Parameter googlePOICount: Number of Google POIs available (for source prioritization)
    func calculatePOIScore(
        poi: PlaceResult,
        origin: CLLocationCoordinate2D,
        idealDistance: Double,
        targetDurationMinutes: Int,
        googlePOICount: Int = 0
    ) -> Double {
        let distance = distanceBetween(origin, poi.coordinate)
        
        // Base score: how close to ideal distance (0-1, 1 = perfect)
        let distanceDeviation = abs(distance - idealDistance) / idealDistance
        let distanceScore = max(0, 1.0 - distanceDeviation * 0.5)
        
        // Walkability bonus (-2 to +2)
        let walkability = walkabilityScore(for: poi)
        let walkabilityBonus = walkability * 0.15  // ±0.3 max impact
        
        // Recently used penalty (0 to 0.9)
        let recentPenalty = recentUsePenalty(for: poi.placeId)
        
        // v1.6.33: Source quality bonus - prefer Google POIs when plentiful
        let sourceBonus = sourceQualityScore(for: poi, googlePOICount: googlePOICount) * 0.1
        
        // Combined score
        let finalScore = distanceScore + walkabilityBonus - recentPenalty + sourceBonus
        
        return finalScore
    }
    
    // MARK: - Adaptive Walking Speed
    // Learns user's actual walking pace from completed walks
    // Uses moving average, clamped to 65-90 m/min
    
    private let walkSpeedKey = "adaptiveWalkingSpeed"
    private let walkSpeedSamplesKey = "walkingSpeedSamples"
    private let defaultWalkingSpeed = 80  // m/min baseline
    private let minWalkingSpeed = 65
    private let maxWalkingSpeed = 90
    private let maxSpeedSamples = 10  // Keep last 10 walks for average
    
    /// Get the adaptive walking speed (m/min)
    var adaptiveWalkingSpeed: Int {
        let stored = UserDefaults.standard.integer(forKey: walkSpeedKey)
        return stored > 0 ? stored : defaultWalkingSpeed
    }
    
    /// Record a completed walk to update adaptive speed
    /// Call this when user finishes a walk with actual distance and duration
    func recordCompletedWalk(distanceMeters: Int, durationMinutes: Int) {
        guard durationMinutes > 0 else { return }
        
        let actualSpeed = distanceMeters / durationMinutes
        
        // Ignore unrealistic speeds (user paused, drove, etc.)
        guard actualSpeed >= 40 && actualSpeed <= 120 else {
            print("🚶 Ignoring unrealistic speed: \(actualSpeed)m/min")
            return
        }
        
        // Get existing samples
        var samples = UserDefaults.standard.array(forKey: walkSpeedSamplesKey) as? [Int] ?? []
        samples.append(actualSpeed)
        
        // Keep only last N samples
        if samples.count > maxSpeedSamples {
            samples = Array(samples.suffix(maxSpeedSamples))
        }
        
        // Calculate moving average
        let average = samples.reduce(0, +) / samples.count
        
        // Clamp to reasonable range
        let clampedSpeed = min(maxWalkingSpeed, max(minWalkingSpeed, average))
        
        // Save
        UserDefaults.standard.set(samples, forKey: walkSpeedSamplesKey)
        UserDefaults.standard.set(clampedSpeed, forKey: walkSpeedKey)
        
        print("🚶 Updated walking speed: \(clampedSpeed)m/min (from \(samples.count) walks, this walk: \(actualSpeed)m/min)")
    }
    
    /// Get one-way walking time to a POI (uses cache if available)
    func getOneWayWalkingTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult) async -> (minutes: Int, meters: Int)? {
        // Check cache first
        if let cached = getCachedLegTime(from: origin, to: poi) {
            print("🗄️ Leg cache HIT: \(poi.name) = \(cached.minutes)min")
            return (cached.minutes, cached.meters)
        }
        
        // Calculate via MapKit
        do {
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: poi.coordinate))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            recordMapKitRequest()
            
            guard let route = response.routes.first else { return nil }
            
            let minutes = Int(route.expectedTravelTime / 60)
            let meters = Int(route.distance)
            
            // Encode polyline for cache
            let polylinePoints = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polylinePoints)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polylinePoints))
            let encodedPolyline = encodePolyline(coords)
            
            // Cache the result
            cacheLegTime(from: origin, to: poi, minutes: minutes, meters: meters, polyline: encodedPolyline)
            print("🗄️ Leg cache MISS: \(poi.name) = \(minutes)min (cached)")
            
            return (minutes, meters)
        } catch {
            print("🗄️ Leg time failed: \(poi.name) - \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Early POI Prefetching
    /// Prefetch POIs as soon as we have location permission and clinician is selected.
    /// This runs in the background so routes are ready faster when user wants to walk.
    /// Call this from ClinicianSelectionView after clinician is selected.
    func prefetchPOIsEarly(location: CLLocationCoordinate2D) {
        // Don't prefetch if already done for this location
        if let existingLocation = earlyPrefetchLocation {
            let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
                .distance(from: CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude))
            if distance < 50 {
                print("📦 Early prefetch: Already prefetched for this location")
                return
            }
        }
        
        // Don't prefetch if already in progress
        guard !isPrefetchingEarly else {
            print("📦 Early prefetch: Already in progress")
            return
        }
        
        isPrefetchingEarly = true
        earlyPrefetchComplete = false
        earlyPrefetchLocation = location
        
        print("🚀 EARLY PREFETCH: Starting background POI fetch...")
        print("📍 Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        
        Task {
            do {
                let pois = try await findNearbyPlaces(location: location, radiusMeters: 2500)
                await MainActor.run {
                    self.earlyPrefetchedPOIs = pois
                    self.earlyPrefetchComplete = true
                    self.isPrefetchingEarly = false
                    print("✅ EARLY PREFETCH COMPLETE: \(pois.count) POIs ready for instant route generation!")
                }
            } catch {
                await MainActor.run {
                    self.isPrefetchingEarly = false
                    print("⚠️ Early prefetch failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Get early prefetched POIs if available and still valid for the given location
    func getEarlyPrefetchedPOIs(for location: CLLocationCoordinate2D) -> [PlaceResult]? {
        guard earlyPrefetchComplete, !earlyPrefetchedPOIs.isEmpty else { return nil }
        guard let prefetchLocation = earlyPrefetchLocation else { return nil }
        
        // Check if still valid (within 50m of prefetch location)
        let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
            .distance(from: CLLocation(latitude: prefetchLocation.latitude, longitude: prefetchLocation.longitude))
        
        if distance < 50 {
            print("📦 Using \(earlyPrefetchedPOIs.count) early-prefetched POIs!")
            return earlyPrefetchedPOIs
        } else {
            print("📦 User moved \(Int(distance))m - early prefetch invalid, will re-fetch")
            return nil
        }
    }
    
    /// Clear early prefetch data (e.g., when user changes location significantly)
    func clearEarlyPrefetch() {
        earlyPrefetchedPOIs = []
        earlyPrefetchLocation = nil
        earlyPrefetchComplete = false
        isPrefetchingEarly = false
    }
    
    // MARK: - Find Nearby Places
    /// Finds points of interest near a location using multiple sources:
    /// 1. Google Places API (cached daily - one API call per 24 hours)
    /// 2. Apple Maps (FREE, always called to supplement)
    /// 3. OpenStreetMap (FREE, always called to supplement)
    func findNearbyPlaces(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 2500,  // Increased from 500m for better coverage
        types: [String] = ["point_of_interest"]
    ) async throws -> [PlaceResult] {
        
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        print("═══════════════════════════════════════════════════════════")
        print("🔍 POI FETCH START - Location: (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
        print("🔍 Search radius: \(radiusMeters)m")
        print("═══════════════════════════════════════════════════════════")
        
        // 🎯 PRIORITY 1: Check cached POI data
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: location) {
            print("💰 CACHE HIT! Using \(cachedPOIs.count) cached POIs")
            allResults = cachedPOIs
            for poi in allResults {
                seenPlaceIds.insert(poi.placeId)
            }
        } else {
            print("📭 CACHE MISS - No cached POIs within 1km")
            
            // ═══════════════════════════════════════════════════════════════
            // 🗺️ PRIORITY 1: OpenStreetMap FIRST (FREE, NO RATE LIMITS!)
            // OSM has comprehensive UK data and zero cost/limits
            // ═══════════════════════════════════════════════════════════════
            print("🗺️ OSM - Searching FIRST (FREE, no limits!)...")
            let osmPOIs = await searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
            print("🗺️ OSM - Found \(osmPOIs.count) POIs")
            for poi in osmPOIs {
                if !seenPlaceIds.contains(poi.placeId) {
                    seenPlaceIds.insert(poi.placeId)
                    allResults.append(poi)
                }
            }
            
            // ═══════════════════════════════════════════════════════════════
            // 🍎 PRIORITY 2: Apple Maps FAST MODE (first batch only)
            // Get 40 high-priority queries instantly, background scan continues
            // ═══════════════════════════════════════════════════════════════
            print("🍎 APPLE MAPS - FAST MODE (first 40 queries only)...")
            let applePOIs = await searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
            print("🍎 APPLE MAPS - Found \(applePOIs.count) POIs (fast mode)")
            var appleAdded = 0
            for poi in applePOIs {
                let isDuplicate = allResults.contains { existing in
                    existing.name.lowercased() == poi.name.lowercased() ||
                    distanceBetween(existing.coordinate, poi.coordinate) < 50
                }
                if !isDuplicate {
                    allResults.append(poi)
                    appleAdded += 1
                }
            }
            print("🍎 APPLE MAPS - Added \(appleAdded) unique POIs (after dedup)")
            
            // 🔄 START BACKGROUND SCAN for complete coverage
            // This will update the cache with more POIs for future routes
            let currentPOIs = allResults
            Task.detached { [weak self] in
                guard let self = self else { return }
                print("🍎 📡 BACKGROUND: Starting full Apple Maps scan...")
                let fullApplePOIs = await self.searchAppleMapsForPOIsComplete(location: location, radiusMeters: radiusMeters)
                
                // Merge with current POIs and update cache
                var mergedPOIs = currentPOIs
                var addedInBackground = 0
                for poi in fullApplePOIs {
                    let isDuplicate = mergedPOIs.contains { existing in
                        existing.name.lowercased() == poi.name.lowercased() ||
                        self.distanceBetween(existing.coordinate, poi.coordinate) < 50
                    }
                    if !isDuplicate {
                        mergedPOIs.append(poi)
                        addedInBackground += 1
                    }
                }
                
                if addedInBackground > 0 {
                    POICacheService.shared.cachePOIs(mergedPOIs, for: location)
                    print("🍎 📡 BACKGROUND COMPLETE: Added \(addedInBackground) more POIs (total: \(mergedPOIs.count))")
                } else {
                    print("🍎 📡 BACKGROUND COMPLETE: No new POIs found")
                }
            }
            
            // ═══════════════════════════════════════════════════════════════
            // 🌐 PRIORITY 3: Google Places - SMART DYNAMIC PRIORITIZATION
            // Call Google when OSM+Apple coverage is insufficient:
            // - Low POI count (<50)
            // - No nearby POIs (closest >400m = poor for short routes)
            // - Rural/sparse area detection
            // ═══════════════════════════════════════════════════════════════
            
            // Check if we need Google
            var needsGoogle = false
            var googleReason = ""
            
            // Reason 1: Low POI count
            if allResults.count < 50 {
                needsGoogle = true
                googleReason = "low POI count (\(allResults.count) < 50)"
            }
            
            // Reason 2: No nearby POIs (poor for short routes)
            if !needsGoogle && !allResults.isEmpty {
                let closestDistance = allResults.map { distanceBetween(location, $0.coordinate) }.min() ?? 9999
                if closestDistance > 400 {  // Closest POI is >400m = 5min+ one-way walk
                    needsGoogle = true
                    googleReason = "no nearby POIs (closest: \(Int(closestDistance))m)"
                }
            }
            
            // Reason 3: Check 5-min viability - if no POI within 300m, short routes will fail
            if !needsGoogle && !allResults.isEmpty {
                let poisWithin300m = allResults.filter { distanceBetween(location, $0.coordinate) <= 300 }
                if poisWithin300m.isEmpty {
                    needsGoogle = true
                    googleReason = "no POIs within 300m (5-min routes will fail)"
                }
            }
            
            if !apiKey.isEmpty && needsGoogle {
                print("🌐 GOOGLE - DYNAMIC TRIGGER: \(googleReason)")
                print("🌐 GOOGLE - Calling API to supplement...")
                let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
                var googleAdded = 0
                for poi in googlePOIs {
                    let isDuplicate = allResults.contains { existing in
                        existing.name.lowercased() == poi.name.lowercased() ||
                        distanceBetween(existing.coordinate, poi.coordinate) < 50
                    }
                    if !isDuplicate {
                        allResults.append(poi)
                        googleAdded += 1
                    }
                }
                print("🌐 GOOGLE - Added \(googleAdded) unique POIs (total now: \(allResults.count))")
                
                // Log improvement
                if !allResults.isEmpty {
                    let newClosest = allResults.map { distanceBetween(location, $0.coordinate) }.min() ?? 9999
                    let newWithin300m = allResults.filter { distanceBetween(location, $0.coordinate) <= 300 }.count
                    print("🌐 GOOGLE - Improvement: closest=\(Int(newClosest))m, within 300m=\(newWithin300m)")
                }
            } else if apiKey.isEmpty {
                print("⚠️ GOOGLE SKIPPED - No API key")
            } else {
                print("✅ GOOGLE SKIPPED - OSM+Apple sufficient (\(allResults.count) POIs, good coverage)")
            }
        }
        
        // 💾 Cache combined results for next time
        if !allResults.isEmpty {
            POICacheService.shared.cachePOIs(allResults, for: location)
        }
        
        print("═══════════════════════════════════════════════════════════")
        print("📊 POI FETCH COMPLETE - Total: \(allResults.count) POIs")
        print("   📍 Google: \(allResults.filter { !$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") }.count)")
        print("   🍎 Apple:  \(allResults.filter { $0.placeId.hasPrefix("apple_") }.count)")
        print("   🗺️ OSM:    \(allResults.filter { $0.placeId.hasPrefix("osm_") }.count)")
        print("═══════════════════════════════════════════════════════════")
        
        return allResults
    }
    
    /// Same as findNearbyPlaces but does NOT cache results - used for testing to bypass location limits
    func findNearbyPlacesWithoutCaching(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 2500
    ) async throws -> [PlaceResult] {
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        print("🧪 [TEST MODE] Fetching POIs WITHOUT caching (bypass limit)")
        
        // 1. Check if we already have cached data for this area
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: location), !cachedPOIs.isEmpty {
            print("🧪 Found \(cachedPOIs.count) cached POIs - using those")
            return cachedPOIs
        }
        
        // 2. Google Places API (will fail if quota exceeded, but makes it a TRUE test)
        if !apiKey.isEmpty {
            print("🌐 GOOGLE (test mode) - Calling API...")
            let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
            for poi in googlePOIs {
                if !seenPlaceIds.contains(poi.placeId) {
                    seenPlaceIds.insert(poi.placeId)
                    allResults.append(poi)
                }
            }
            print("🌐 Got \(googlePOIs.count) from Google")
        } else {
            print("⚠️ GOOGLE SKIPPED - No API key")
        }
        
        // 3. Fetch from Apple Maps (FREE, no limits)
        print("🍎 APPLE MAPS (test mode)...")
        let applePOIs = await searchAppleMapsForPOIs(location: location, radiusMeters: radiusMeters)
        for poi in applePOIs {
            let isDuplicate = allResults.contains { existing in
                existing.name.lowercased() == poi.name.lowercased() ||
                distanceBetween(existing.coordinate, poi.coordinate) < 50
            }
            if !isDuplicate {
                allResults.append(poi)
            }
        }
        print("🍎 Got \(applePOIs.count) from Apple")
        
        // 4. Fetch from OpenStreetMap (FREE, no limits)
        print("🗺️ OSM (test mode)...")
        let osmPOIs = await searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
        for poi in osmPOIs {
            let isDuplicate = allResults.contains { existing in
                existing.name.lowercased() == poi.name.lowercased() ||
                distanceBetween(existing.coordinate, poi.coordinate) < 50
            }
            if !isDuplicate {
                allResults.append(poi)
            }
        }
        print("🗺️ Got \(osmPOIs.count) from OSM")
        
        // NOTE: We do NOT cache results to avoid exceeding the free tier limit
        print("🧪 [TEST MODE] Total POIs: \(allResults.count) (not cached)")
        return allResults
    }
    
    // MARK: - On-Demand Google API (when more routes needed)
    
    /// Fetch additional POIs from Google Places API when Apple/OSM didn't find enough variety
    /// Called when route generation only found 1-2 routes and more options are needed
    /// Returns the NEW POIs that weren't already in the cache
    func fetchGooglePOIsOnDemand(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 2500,
        existingPOIs: [PlaceResult]
    ) async -> [PlaceResult] {
        guard !apiKey.isEmpty else {
            print("🌐 GOOGLE ON-DEMAND: No API key, skipping")
            return []
        }
        
        print("🌐 ═══════════════════════════════════════════════════════")
        print("🌐 GOOGLE ON-DEMAND: Fetching additional POIs")
        print("🌐   📍 Location: (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
        print("🌐   📦 Existing POIs: \(existingPOIs.count)")
        print("🌐 ═══════════════════════════════════════════════════════")
        
        let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
        
        // Filter out POIs we already have (by name or proximity)
        var newPOIs: [PlaceResult] = []
        for poi in googlePOIs {
            let isDuplicate = existingPOIs.contains { existing in
                existing.name.lowercased() == poi.name.lowercased() ||
                distanceBetween(existing.coordinate, poi.coordinate) < 50
            }
            if !isDuplicate {
                newPOIs.append(poi)
            }
        }
        
        print("🌐 GOOGLE ON-DEMAND COMPLETE:")
        print("🌐   📊 Fetched: \(googlePOIs.count) POIs")
        print("🌐   ✨ New (after dedup): \(newPOIs.count) POIs")
        
        // Merge with cache for future use
        if !newPOIs.isEmpty {
            let mergedPOIs = existingPOIs + newPOIs
            POICacheService.shared.cachePOIs(mergedPOIs, for: location)
            print("🌐   💾 Cache updated: \(mergedPOIs.count) total POIs")
        }
        
        return newPOIs
    }
    
    /// Fetch POIs from Google Places API (called at most once per 24 hours)
    private func fetchGooglePOIs(
        location: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async -> [PlaceResult] {
        
        // Search multiple specific types in parallel to maximize POI variety
        let placeTypesToSearch = [
            // Retail & Shopping
            "store",              // General retail
            "convenience_store",  // Local corner shops
            "supermarket",        // Supermarkets
            "shopping_mall",      // Shopping centers
            "hardware_store",     // DIY shops
            "florist",            // Flower shops
            "pet_store",          // Pet shops
            "liquor_store",       // Off-licenses
            
            // Food & Drink
            "restaurant",         // Restaurants
            "cafe",               // Coffee shops
            "bar",                // Bars/pubs
            "bakery",             // Bakeries
            "meal_takeaway",      // Takeaways (fish & chips, kebabs)
            
            // Health & Wellness
            "pharmacy",           // Pharmacies
            "doctor",             // GP surgeries
            "dentist",            // Dental practices
            "veterinary_care",    // Vets
            "spa",                // Spas/wellness
            
            // Services
            "bank",               // Banks
            "post_office",        // Post offices
            "hair_care",          // Hairdressers/barbers
            "laundry",            // Launderettes
            "car_wash",           // Car washes
            "gas_station",        // Petrol stations
            
            // Culture & Leisure
            "park",               // Parks
            "museum",             // Museums
            "library",            // Libraries
            "art_gallery",        // Art galleries
            "book_store",         // Book shops
            "gym",                // Gyms
            "church",             // Churches/places of worship
            "movie_theater",      // Cinemas
            "bowling_alley",      // Bowling alleys
            
            // Education & Community
            "school",             // Schools
            "community_center",   // Community centres
            
            // Outdoors & Nature
            "cemetery",           // Cemeteries/churchyards
            "campground",         // Camping/green spaces
            
            // Transport
            "bus_station",        // Bus stations
            "train_station",      // Train stations
            
            // Lodging
            "lodging",            // Hotels, B&Bs
            
            // Government & Landmarks
            "local_government_office",  // Town halls
            "fire_station",       // Fire stations
            "police"              // Police stations
        ]
        
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        print("🌐 GOOGLE NEW PLACES API - Searching \(placeTypesToSearch.count) categories...")
        print("🌐 Categories: \(placeTypesToSearch.joined(separator: ", "))")
        print("🌐 Endpoint: places.googleapis.com/v1/places:searchNearby")
        print("🌐 Field Mask: places.id, displayName, location, formattedAddress, types (Basic only)")
        print("🌐 API Key present: \(!apiKey.isEmpty), key prefix: \(String(apiKey.prefix(10)))...")
        
        // Search each type in parallel using TaskGroup
        await withTaskGroup(of: [PlaceResult].self) { group in
            for placeType in placeTypesToSearch {
                group.addTask {
                    do {
                        return try await self.searchSingleType(
                            location: location,
                            radiusMeters: radiusMeters,
                            type: placeType
                        )
                    } catch {
                        print("   ❌ [\(placeType)] FAILED: \(error.localizedDescription)")
                        return []
                    }
                }
            }
            
            // Collect results from all parallel searches
            for await results in group {
                for place in results {
                    if !seenPlaceIds.contains(place.placeId) {
                        seenPlaceIds.insert(place.placeId)
                        allResults.append(place)
                    }
                }
            }
        }
        
        print("🌐 GOOGLE COMPLETE: \(allResults.count) unique POIs from \(placeTypesToSearch.count) categories")
        return allResults
    }
    
    /// Search for a single place type using New Places API (Essentials tier - much cheaper!)
    /// Cost: ~$5/1k requests vs $32/1k with Legacy API
    private func searchSingleType(
        location: CLLocationCoordinate2D,
        radiusMeters: Int,
        type: String
    ) async throws -> [PlaceResult] {
        // New Places API endpoint
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchNearby") else {
            throw GoogleMapsError.invalidURL
        }
        
        // Build request body
        let requestBody: [String: Any] = [
            "includedTypes": [type],
            "maxResultCount": 20,
            "locationRestriction": [
                "circle": [
                    "center": [
                        "latitude": location.latitude,
                        "longitude": location.longitude
                    ],
                    "radius": Double(radiusMeters)
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // Request only Basic Data fields (FREE tier!) - no rating, no contact info
        request.setValue("places.id,places.displayName,places.location,places.formattedAddress,places.types", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("   ❌ [\(type)] No HTTP response")
            throw GoogleMapsError.serverError
        }
        
        if httpResponse.statusCode != 200 {
            // Try to parse error message
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String,
               let code = error["code"] as? Int {
                print("   ❌ [\(type)] HTTP \(httpResponse.statusCode) - Code \(code): \(message)")
            } else {
                print("   ❌ [\(type)] HTTP \(httpResponse.statusCode) - Unknown error")
            }
            throw GoogleMapsError.serverError
        }
        
        // Parse new API response format
        let newPlacesResponse = try JSONDecoder().decode(NewPlacesResponse.self, from: data)
        let count = newPlacesResponse.places?.count ?? 0
        
        if count > 0 {
            print("   ✓ [\(type)] → \(count) POIs")
        }
        
        // Convert to PlaceResult format
        return newPlacesResponse.places?.map { place in
            PlaceResult(
                placeId: place.id ?? "unknown",
                name: place.displayName?.text ?? "Unknown",
                vicinity: place.formattedAddress,
                geometry: PlaceGeometry(
                    location: PlaceLocation(
                        lat: place.location?.latitude ?? 0,
                        lng: place.location?.longitude ?? 0
                    )
                ),
                types: place.types
            )
        } ?? []
    }
    
    // MARK: - Apple Maps POI Search (FREE - No Limits!)
    
    /// All Apple Maps search categories for UK POIs
    private var allAppleMapsCategories: [String] {
        [
            // ══════════════════════════════════════════════════════════
            // BATCH 1: HIGHEST PRIORITY - Community & Food (40 queries)
            // ══════════════════════════════════════════════════════════
            // Community venues (critical for walking destinations)
            "village hall", "community centre", "town hall", "church", "chapel",
            "mosque", "temple", "gurdwara", "synagogue", "memorial hall",
            "sports club", "social club", "working mens club", "scout hall", "youth club",
            "legion", "rotary", "masonic", "british legion", "community hub",
            
            // Food & Drink (most common POIs - expanded)
            "pub", "restaurant", "cafe", "kitchen", "catering", "deli", "sandwich",
            "coffee", "food", "bakery", "takeaway", "bar", "bistro", "brasserie",
            "tea room", "coffee shop", "pizzeria", "burger", "kebab",
            "fish and chips", "chippy",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 2: RETAIL & SERVICES (40 queries)
            // ══════════════════════════════════════════════════════════
            // Retail (common UK shops)
            "supermarket", "convenience store", "shop", "pharmacy", "newsagent",
            "butcher", "florist", "co-op", "spar", "tesco", "sainsburys", "aldi",
            "lidl", "morrisons", "asda", "charity shop", "bookshop", "gift shop",
            "pet shop", "pound shop", "chemist", "off licence", "grocery",
            
            // Services
            "post office", "bank", "library", "hairdresser", "barber", "nail salon",
            "dry cleaner", "launderette", "optician", "estate agent", "solicitor",
            "accountant", "travel agent", "betting shop", "pawnbroker",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 3: HEALTH, EDUCATION, LEISURE (40 queries)
            // ══════════════════════════════════════════════════════════
            // Health
            "doctor", "dentist", "veterinary", "hospital", "clinic", "health centre",
            "surgery", "medical", "physiotherapy", "osteopath", "chiropractor",
            
            // Education
            "school", "nursery", "preschool", "playcare", "childcare", "academy",
            "primary school", "secondary school", "college", "university",
            
            // Leisure & Recreation
            "park", "gym", "swimming pool", "leisure centre", "playground",
            "recreation ground", "playing field", "nature reserve", "woodland",
            "canal", "golf course", "tennis club", "football club", "cricket club",
            "bowling alley", "sports centre", "fitness", "allotment",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 4: CULTURE, TRANSPORT, LANDMARKS (remaining)
            // ══════════════════════════════════════════════════════════
            // Culture
            "museum", "theatre", "cinema", "art gallery", "historic site", "castle",
            "manor", "stately home", "monument", "statue", "war memorial", "heritage",
            
            // Transport & Auto
            "train station", "petrol station", "car park", "bus station", "taxi",
            "garage", "car wash", "mot", "tyres",
            
            // Accommodation
            "hotel", "bed and breakfast", "guest house", "inn", "hostel",
            
            // Additional UK-specific
            "greggs", "costa", "starbucks", "wetherspoons", "mcdonald",
            "indian restaurant", "chinese restaurant", "thai restaurant",
            "italian restaurant", "mexican restaurant"
        ]
    }
    
    /// FAST MODE: Only first 40 high-priority categories (instant, for first route)
    /// Returns POIs in ~5-10 seconds for immediate route generation
    func searchAppleMapsForPOIsFast(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        var allResults: [PlaceResult] = []
        var seenNames = Set<String>()
        
        // Only use first 40 categories (highest priority: community + food)
        let fastQueries = Array(allAppleMapsCategories.prefix(40))
        
        print("🍎 APPLE MAPS FAST MODE - \(fastQueries.count) priority categories")
        
        var queriesWithResults = 0
        var queriesFailed = 0
        
        for query in fastQueries {
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = MKCoordinateRegion(
                    center: location,
                    latitudinalMeters: Double(radiusMeters * 2),
                    longitudinalMeters: Double(radiusMeters * 2)
                )
                
                let search = MKLocalSearch(request: request)
                let response = try await search.start()
                
                for item in response.mapItems {
                    guard let name = item.name, !seenNames.contains(name) else { continue }
                    
                    let itemCoord = item.placemark.coordinate
                    let distance = distanceBetween(location, itemCoord)
                    guard distance <= Double(radiusMeters) else { continue }
                    
                    seenNames.insert(name)
                    
                    let placeResult = PlaceResult(
                        placeId: "apple_\(name.hashValue)",
                        name: name,
                        vicinity: item.placemark.title,
                        geometry: PlaceGeometry(
                            location: PlaceLocation(
                                lat: item.placemark.coordinate.latitude,
                                lng: item.placemark.coordinate.longitude
                            )
                        ),
                        types: [query]
                    )
                    allResults.append(placeResult)
                }
                if response.mapItems.count > 0 {
                    queriesWithResults += 1
                }
            } catch {
                queriesFailed += 1
                let nsError = error as NSError
                
                // If rate limited, stop immediately
                if nsError.domain == "GEOErrorDomain" && nsError.code == -3 ||
                   nsError.domain == "MKErrorDomain" && nsError.code == 3 {
                    print("🍎 ⚠️ Rate limited during fast mode - returning \(allResults.count) POIs")
                    break
                }
            }
        }
        
        print("🍎 FAST MODE COMPLETE: \(allResults.count) POIs (\(queriesWithResults) queries succeeded)")
        return allResults
    }
    
    /// COMPLETE MODE: All 120+ categories with smart batching (for background scan)
    /// Takes 2-3 minutes but gets maximum POI coverage
    func searchAppleMapsForPOIsComplete(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        var allResults: [PlaceResult] = []
        var seenNames = Set<String>()
        
        let searchQueries = allAppleMapsCategories
        
        print("🍎 📡 BACKGROUND: Starting COMPLETE Apple Maps scan")
        print("🍎 📡   📊 Categories: \(searchQueries.count)")
        print("🍎 📡   📍 Radius: \(radiusMeters)m")
        
        // Smart batching: 40 queries per batch, 65s wait between batches
        let batchSize = 40
        var queriesWithResults = 0
        var queriesFailed = 0
        var queryIndex = 0
        var rateLimitHit = false
        var batchNumber = 0
        
        for batchStart in stride(from: 0, to: searchQueries.count, by: batchSize) {
            if rateLimitHit { break }
            
            batchNumber += 1
            let batchEnd = min(batchStart + batchSize, searchQueries.count)
            let batch = Array(searchQueries[batchStart..<batchEnd])
            
            // Wait between batches (not before first batch)
            if batchStart > 0 {
                print("🍎 📡 Batch \(batchNumber): Waiting 65s for rate limit reset...")
                try? await Task.sleep(nanoseconds: 65_000_000_000)  // 65 seconds
            }
            
            for query in batch {
                if rateLimitHit { break }
                
                queryIndex += 1
                do {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    request.region = MKCoordinateRegion(
                        center: location,
                        latitudinalMeters: Double(radiusMeters * 2),
                        longitudinalMeters: Double(radiusMeters * 2)
                    )
                    
                    let search = MKLocalSearch(request: request)
                    let response = try await search.start()
                    
                    for item in response.mapItems {
                        guard let name = item.name, !seenNames.contains(name) else { continue }
                        
                        let itemCoord = item.placemark.coordinate
                        let distance = distanceBetween(location, itemCoord)
                        guard distance <= Double(radiusMeters) else { continue }
                        
                        seenNames.insert(name)
                        
                        let placeResult = PlaceResult(
                            placeId: "apple_\(name.hashValue)",
                            name: name,
                            vicinity: item.placemark.title,
                            geometry: PlaceGeometry(
                                location: PlaceLocation(
                                    lat: item.placemark.coordinate.latitude,
                                    lng: item.placemark.coordinate.longitude
                                )
                            ),
                            types: [query]
                        )
                        allResults.append(placeResult)
                    }
                    if response.mapItems.count > 0 {
                        queriesWithResults += 1
                    }
                } catch {
                    queriesFailed += 1
                    let nsError = error as NSError
                    
                    if nsError.domain == "GEOErrorDomain" && nsError.code == -3 ||
                       nsError.domain == "MKErrorDomain" && nsError.code == 3 ||
                       nsError.localizedDescription.contains("50 requests") {
                        rateLimitHit = true
                        print("🍎 📡 RATE LIMITED at batch \(batchNumber) - stopping")
                        break
                    }
                }
            }
            
            if !rateLimitHit {
                print("🍎 📡 Batch \(batchNumber) complete: \(allResults.count) POIs")
            }
        }
        
        print("🍎 📡 BACKGROUND COMPLETE: \(allResults.count) unique POIs")
        return allResults
    }
    
    /// Legacy method - redirects to fast mode for backward compatibility
    func searchAppleMapsForPOIs(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        return await searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
    }
    
    // MARK: - Search OpenStreetMap for POIs (Overpass API - FREE!)
    /// Searches OpenStreetMap using the Overpass API for POIs near a location
    /// This is completely FREE with no API key required!
    private func searchOpenStreetMapForPOIs(location: CLLocationCoordinate2D, radiusMeters: Int) async -> [PlaceResult] {
        var allResults: [PlaceResult] = []
        
        // COMPREHENSIVE Overpass API query - maximum POI coverage (FREE!)
        // Includes all major OSM tags that represent walking destinations
        let query = """
        [out:json][timeout:30];
        (
          // Core POI types (nodes)
          node["amenity"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["shop"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["craft"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["office"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["healthcare"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["club"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["community_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Buildings with names (common in UK)
          node["building"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="church"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="chapel"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="pub"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="commercial"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="retail"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="school"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="kindergarten"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Transport nodes
          node["public_transport"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["railway"="station"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["railway"="halt"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Natural features (parks, woods, etc)
          node["natural"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["landuse"="recreation_ground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["landuse"="allotments"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // v1.6.26: GREEN SPACE / LOW-COMMITMENT POIS - Perfect for short walks
          // Parks and recreation
          node["leisure"="park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="playground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="garden"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="nature_reserve"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="dog_park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="pitch"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="common"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Street furniture - great for short walks
          node["amenity"="bench"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"="viewpoint"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"="picnic_site"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="fountain"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="memorial"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="monument"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="wayside_cross"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Community spaces
          node["amenity"="community_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="social_facility"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="village_hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Religious buildings (often open for walks/reflection)
          node["amenity"="place_of_worship"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Sports facilities
          node["leisure"="sports_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="swimming_pool"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="fitness_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Core POI types (ways - for larger buildings/areas)
          way["amenity"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["shop"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["tourism"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["historic"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["craft"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["healthcare"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="church"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="chapel"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="school"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="recreation_ground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // v1.6.26: GREEN SPACE WAYS (larger areas)
          way["leisure"="park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="playground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="garden"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="nature_reserve"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="common"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="grass"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="meadow"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="village_green"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["natural"="wood"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
        );
        out center tags;
        """
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        // Try multiple Overpass API mirrors for reliability
        let mirrors = [
            "https://overpass.kumi.systems/api/interpreter",  // Often more reliable
            "https://lz4.overpass-api.de/api/interpreter",    // Fast mirror
            "https://overpass-api.de/api/interpreter"         // Main server
        ]
        
        for (index, baseUrl) in mirrors.enumerated() {
            let urlString = "\(baseUrl)?data=\(encodedQuery)"
        
        guard let url = URL(string: urlString) else {
                print("🗺️ OSM: Invalid URL for mirror \(index + 1)")
                continue
            }
            
            print("🗺️ Searching OpenStreetMap (mirror \(index + 1)/\(mirrors.count))...")
            
            do {
                // Use a custom URLSession with longer timeout
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 15
                config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    print("🗺️ OSM: Bad response from mirror \(index + 1), trying next...")
                    continue
                }
                
                // Parse Overpass JSON response
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let elements = json["elements"] as? [[String: Any]] {
                    
                    for element in elements {
                        guard let tags = element["tags"] as? [String: String] else { continue }
                        
                        // Get name - skip if no name
                        guard let name = tags["name"] else { continue }
                        
                        // Get coordinates (handle both nodes and ways with center)
                        var lat: Double?
                        var lon: Double?
                        
                        if let nodeLat = element["lat"] as? Double, let nodeLon = element["lon"] as? Double {
                            lat = nodeLat
                            lon = nodeLon
                        } else if let center = element["center"] as? [String: Double] {
                            lat = center["lat"]
                            lon = center["lon"]
                        }
                        
                        guard let finalLat = lat, let finalLon = lon else { continue }
                        
                        // Get type from tags (expanded to match new query)
                        // Use array lookup to avoid Swift compiler complexity issue
                        let typeKeys = ["amenity", "shop", "leisure", "tourism", "historic", "craft", "office", "healthcare", "club", "building", "landuse"]
                        let poiType = typeKeys.compactMap { tags[$0] }.first ?? "place"
                        
                        // Get address if available
                        var address: String? = nil
                        if let street = tags["addr:street"] {
                            let houseNumber = tags["addr:housenumber"] ?? ""
                            address = "\(houseNumber) \(street)".trimmingCharacters(in: .whitespaces)
                        }
                        
                        let osmId = element["id"] as? Int ?? name.hashValue
                        
                        let placeResult = PlaceResult(
                            placeId: "osm_\(osmId)",
                            name: name,
                            vicinity: address,
                            geometry: PlaceGeometry(
                                location: PlaceLocation(lat: finalLat, lng: finalLon)
                            ),
                            types: [poiType]
                        )
                        allResults.append(placeResult)
                    }
                }
                
                print("🗺️ ✓ OpenStreetMap found \(allResults.count) POIs (mirror \(index + 1) succeeded)")
                return allResults  // Success! Return results
                
            } catch {
                print("🗺️ OSM mirror \(index + 1) failed: \(error.localizedDescription)")
                // Continue to next mirror
            }
        }
        
        // All mirrors failed
        print("🗺️ ⚠️ All OSM mirrors failed")
        return allResults
    }
    
    // MARK: - OSRM Walking Directions (OpenStreetMap - FREE, NO LIMITS!)
    /// Gets walking directions using OSRM (Open Source Routing Machine)
    /// Completely FREE with NO rate limits - uses OpenStreetMap data
    /// 
    /// LIMITATIONS & CONSIDERATIONS:
    /// - Public OSRM server only supports CAR routing (we estimate walking time from distance)
    /// - Max ~100 waypoints per request
    /// - No waypoint optimization (we use MapKit's optimization before calling OSRM)
    /// - Polyline may be less detailed than MapKit
    /// - Server may be slow or down (10 second timeout)
    /// - OSM data may be outdated in some areas
    private func getOSRMWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = []
    ) async throws -> (distance: Int, duration: Int, polyline: [CLLocationCoordinate2D]) {
        
        // LIMITATION: OSRM has a max coordinate limit (~100)
        // If we have too many waypoints, throw error to fall back to MapKit
        if waypoints.count > 25 {
            print("🗺️ OSRM: Too many waypoints (\(waypoints.count)), falling back to MapKit")
            throw GoogleMapsError.apiError("Too many waypoints for OSRM")
        }
        
        // Build coordinates string: lon,lat;lon,lat;...
        var coordStrings: [String] = []
        coordStrings.append("\(origin.longitude),\(origin.latitude)")
        for wp in waypoints {
            coordStrings.append("\(wp.longitude),\(wp.latitude)")
        }
        coordStrings.append("\(destination.longitude),\(destination.latitude)")
        
        let coordsPath = coordStrings.joined(separator: ";")
        // Note: Using "driving" profile as public server doesn't support "foot"
        // We estimate walking time from distance afterwards
        let urlString = "https://router.project-osrm.org/route/v1/driving/\(coordsPath)?overview=full&geometries=polyline"
        
        guard let url = URL(string: urlString) else {
            throw GoogleMapsError.invalidURL
        }
        
        // Create request with timeout (public server can be slow)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10  // 10 second timeout
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("🗺️ OSRM: Network error - \(error.localizedDescription)")
            throw GoogleMapsError.apiError("OSRM network error")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleMapsError.apiError("OSRM invalid response")
        }
        
        // Handle HTTP errors
        if httpResponse.statusCode != 200 {
            print("🗺️ OSRM: HTTP error \(httpResponse.statusCode)")
            throw GoogleMapsError.apiError("OSRM HTTP \(httpResponse.statusCode)")
        }
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleMapsError.apiError("OSRM invalid JSON")
        }
        
        // Check OSRM status code (not HTTP, but in JSON)
        if let code = json["code"] as? String, code != "Ok" {
            let message = json["message"] as? String ?? "Unknown error"
            print("🗺️ OSRM: API error - \(code): \(message)")
            throw GoogleMapsError.noRouteFound
        }
        
        guard let routes = json["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let distance = firstRoute["distance"] as? Double,
              let duration = firstRoute["duration"] as? Double,
              let geometry = firstRoute["geometry"] as? String else {
            print("🗺️ OSRM: No route found in response")
            throw GoogleMapsError.noRouteFound
        }
        
        // Validate distance is reasonable
        if distance <= 0 {
            throw GoogleMapsError.noRouteFound
        }
        
        // Decode polyline
        let polylinePoints = decodePolyline(geometry)
        
        // Handle empty polyline
        if polylinePoints.isEmpty {
            print("🗺️ OSRM: Empty polyline returned")
            throw GoogleMapsError.noRouteFound
        }
        
        // IMPORTANT: OSRM public server returns CAR routing times
        // We ALWAYS estimate walking time from distance
        // Walking speed: ~80 m/min (5 km/h) - adjustable based on user's actual speed
        let userWalkingSpeed = Double(adaptiveWalkingSpeed)  // m/min from user's history
        let walkingMinutes = distance / userWalkingSpeed
        let finalDuration = Int(walkingMinutes * 60)  // Convert to seconds
        
        let osrmMinutes = Int(duration / 60)
        let walkingMins = Int(walkingMinutes)
        if osrmMinutes != walkingMins {
            print("🗺️ OSRM: Converted driving time to walking (\(osrmMinutes)min → \(walkingMins)min @ \(Int(userWalkingSpeed))m/min)")
        }
        
        return (distance: Int(distance), duration: finalDuration, polyline: polylinePoints)
    }
    
    /// Check if we should use OSRM instead of MapKit (when approaching rate limit)
    private func shouldUseOSRM() async -> Bool {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        // Use OSRM at 80% of rate limit (40+ requests) for speed
        // OSRM durations are corrected via osrmCalibrationFactor
        return status.currentCount >= 40
    }
    
    /// Check if background pre-generation should pause (to reserve quota for user requests)
    /// Returns true if rate limit is too high for background work
    func shouldPauseBackgroundGeneration() async -> Bool {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        // Pause background work at 80% of limit (40+ requests)
        // This reserves 10 requests for user-initiated actions
        // More generous than before - allows more pre-generation
        let shouldPause = status.currentCount >= 40
        if shouldPause {
            print("⏸️ Background paused briefly (MapKit: \(status.currentCount)/50)")
        }
        return shouldPause
    }
    
    /// Get current MapKit rate limit status (for UI/debugging)
    func getMapKitRateLimitStatus() async -> (current: Int, limit: Int, waitTime: TimeInterval?) {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        return (status.currentCount, 50, status.waitTime)
    }
    
    // MARK: - OSRM Dynamic Calibration
    // OSRM often overestimates distances/durations compared to MapKit
    // We dynamically calibrate by comparing results from both services
    
    private let osrmCalibrationKey = "osrmCalibrationFactor"
    private let osrmCalibrationSamplesKey = "osrmCalibrationSamples"
    private let osrmCalibrationCountKey = "osrmCalibrationCallCount"
    private let maxCalibrationSamples = 15           // Keep last 15 samples for robust average
    private let calibrationInterval = 5              // Calibrate every 5 OSRM calls
    private let minSamplesForConfidence = 3          // Need at least 3 samples before trusting calibration
    private let defaultCalibrationFactor = 0.65      // Default factor (65% of OSRM = MapKit)
    
    /// Get OSRM calibration factor (MapKit duration / OSRM duration)
    /// Values < 1.0 mean OSRM overestimates, so we multiply OSRM result by this
    var osrmCalibrationFactor: Double {
        let stored = UserDefaults.standard.double(forKey: osrmCalibrationKey)
        return stored > 0 ? stored : defaultCalibrationFactor
    }
    
    /// Check if we need to run a calibration (compares MapKit vs OSRM for same route)
    private func shouldCalibrateOSRM() -> Bool {
        let samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        let callCount = UserDefaults.standard.integer(forKey: osrmCalibrationCountKey)
        
        // Always calibrate if we don't have minimum samples
        if samples.count < minSamplesForConfidence {
            return true
        }
        
        // Calibrate every N OSRM calls to keep factor accurate as user moves around
        return callCount % calibrationInterval == 0
    }
    
    /// Increment OSRM call counter
    private func recordOSRMCall() {
        let count = UserDefaults.standard.integer(forKey: osrmCalibrationCountKey)
        UserDefaults.standard.set(count + 1, forKey: osrmCalibrationCountKey)
    }
    
    /// Record a calibration sample comparing MapKit vs OSRM for same route
    func recordOSRMCalibration(mapKitDuration: Int, osrmDuration: Int) {
        guard mapKitDuration > 0 && osrmDuration > 0 else { return }
        
        let ratio = Double(mapKitDuration) / Double(osrmDuration)
        
        // Ignore extreme outliers (data errors)
        guard ratio >= 0.3 && ratio <= 1.5 else {
            print("🔧 Ignoring extreme calibration ratio: \(String(format: "%.2f", ratio)) (MapKit:\(mapKitDuration)s, OSRM:\(osrmDuration)s)")
            return
        }
        
        var samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        samples.append(ratio)
        
        if samples.count > maxCalibrationSamples {
            samples = Array(samples.suffix(maxCalibrationSamples))
        }
        
        // Calculate weighted average (recent samples matter more)
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (index, sample) in samples.enumerated() {
            let weight = Double(index + 1)  // Later samples have higher weight
            weightedSum += sample * weight
            weightTotal += weight
        }
        let weightedAverage = weightedSum / weightTotal
        let clampedAverage = max(0.4, min(1.0, weightedAverage))  // Clamp to reasonable range
        
        UserDefaults.standard.set(samples, forKey: osrmCalibrationSamplesKey)
        UserDefaults.standard.set(clampedAverage, forKey: osrmCalibrationKey)
        
        print("🔧 OSRM calibration: \(String(format: "%.2f", clampedAverage)) (from \(samples.count) samples, MapKit:\(mapKitDuration/60)min vs OSRM:\(osrmDuration/60)min)")
        }
        
    /// Apply calibration factor to OSRM duration
    func calibrateOSRMDuration(_ osrmDuration: Int) -> Int {
        let factor = osrmCalibrationFactor
        let calibrated = Int(Double(osrmDuration) * factor)
        return max(60, calibrated)  // At least 1 minute
    }
    
    /// Perform a calibration check by getting both MapKit and OSRM for the same route
    private func performCalibrationCheck(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) async {
        // Get a simple point-to-point route from both services
        do {
            // Get OSRM result (raw, uncalibrated)
            let osrmResult = try await getOSRMWalkingDirections(
                origin: origin,
                destination: destination,
                waypoints: []
            )
            let osrmDuration = osrmResult.duration  // Raw, uncalibrated
            
            // Get MapKit result (wait for rate limit if needed)
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            let response = try await directions.calculate()
            guard let route = response.routes.first else { return }
            
            let mapKitDuration = Int(route.expectedTravelTime)
            
            // Record the calibration sample
            recordOSRMCalibration(mapKitDuration: mapKitDuration, osrmDuration: osrmDuration)
            
        } catch {
            print("🔧 Calibration check failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Get Walking Directions (Apple MapKit - FREE!)
    /// Gets walking directions between points using Apple MapKit (FREE, unlimited!)
    /// Replaces Google Directions API to eliminate costs
    /// - Parameter preserveWaypointOrder: If true, waypoints are visited in the order provided (no optimization)
    func getWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = [],
        preserveWaypointOrder: Bool = false
    ) async throws -> DirectionsResult {
        
        // Build list of all points: origin → waypoints → destination
        var allPoints = [origin] + waypoints + [destination]
        
        // For circular routes (origin == destination), we need at least one waypoint
        if waypoints.isEmpty && origin.latitude == destination.latitude && origin.longitude == destination.longitude {
            throw GoogleMapsError.noRouteFound
        }
        
        var allLegs: [DirectionsLeg] = []
        var totalDistance: Int = 0
        var totalDuration: Int = 0
        var allPolylinePoints: [CLLocationCoordinate2D] = []
        var optimizedWaypointOrder: [Int]? = nil
        
        // If we have waypoints, try to optimize their order (simple nearest-neighbor)
        // UNLESS preserveWaypointOrder is true (used for enhancement where order is already optimal)
        if waypoints.count > 1 && !preserveWaypointOrder {
            let optimized = optimizeWaypointOrder(from: origin, waypoints: waypoints, to: destination)
            allPoints = [origin] + optimized.waypoints + [destination]
            optimizedWaypointOrder = optimized.order
            print("🍎 MapKit: Optimized waypoint order: \(optimized.order)")
        } else if waypoints.count > 1 && preserveWaypointOrder {
            optimizedWaypointOrder = Array(0..<waypoints.count)
            print("🍎 MapKit: Preserving waypoint order (no optimization)")
        } else if waypoints.count == 1 {
            optimizedWaypointOrder = [0] // Single waypoint, no reordering needed
        }
        
        // Calculate directions for each leg (point to point)
        // Use OSRM when approaching MapKit rate limit to avoid hitting the cap
        let useOSRM = await shouldUseOSRM()
        
        if useOSRM {
            // 🗺️ Use OSRM for all legs at once (more efficient)
            recordOSRMCall()
            let needsCalibration = shouldCalibrateOSRM()
            
            print("🗺️ Using OSRM for directions (MapKit near limit)\(needsCalibration ? " + calibrating" : "")")
            
            do {
                let osrmResult = try await getOSRMWalkingDirections(
                    origin: origin,
                    destination: destination,
                    waypoints: waypoints
                )
                
                // If we need to calibrate, also get MapKit for the first leg and compare
                if needsCalibration && allPoints.count >= 2 {
                    // Do calibration in background - don't block the route result
                    Task {
                        await performCalibrationCheck(
                            origin: allPoints[0],
                            destination: allPoints[min(1, allPoints.count - 1)]
                        )
                    }
                }
                
                // Apply calibration factor to OSRM duration (OSRM often overestimates)
                let rawDuration = osrmResult.duration
                let calibratedDuration = calibrateOSRMDuration(rawDuration)
                
                // Create a single leg with calibrated OSRM results
                let leg = DirectionsLeg(
                    distance: DirectionsValue(text: formatDistance(osrmResult.distance), value: osrmResult.distance),
                    duration: DirectionsValue(text: formatDuration(calibratedDuration), value: calibratedDuration),
                    startAddress: nil,
                    endAddress: nil,
                    steps: nil
                )
                
                // Encode polyline
                let encodedPolyline = encodePolyline(osrmResult.polyline)
                
                // OSRM returns total route, so we only have one "leg"
                let rawMinutes = rawDuration / 60
                let calibratedMinutes = calibratedDuration / 60
                let factor = osrmCalibrationFactor
                let samples = (UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double])?.count ?? 0
                print("🗺️ OSRM: \(allPoints.count - 1) legs, \(osrmResult.distance)m, \(rawMinutes)min → \(calibratedMinutes)min (×\(String(format: "%.2f", factor)) from \(samples) samples)")
                
                return DirectionsResult(
                    legs: [leg],
                    overviewPolyline: OverviewPolyline(points: encodedPolyline),
                    summary: nil,
                    warnings: nil,
                    waypointOrder: optimizedWaypointOrder
                )
            } catch {
                print("🗺️ OSRM failed, falling back to MapKit: \(error.localizedDescription)")
                // Fall through to MapKit
            }
        }
        
        // 🍎 Use MapKit for directions
        // Check if we should do opportunistic calibration on first leg
        let samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        let shouldOpportunisticallyCalibrate = samples.count < minSamplesForConfidence && allPoints.count >= 2
        
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            // Check rate limit before making request
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            
            // Record this request
            recordMapKitRequest()
            
            let response: MKDirections.Response
            do {
                response = try await directions.calculate()
                
                // Opportunistically calibrate on first leg when we need samples
                if i == 0 && shouldOpportunisticallyCalibrate {
                    if let mapKitRoute = response.routes.first {
                        let mapKitDuration = Int(mapKitRoute.expectedTravelTime)
                        // Get OSRM for same leg in background
                        Task {
                            do {
                                let osrmResult = try await getOSRMWalkingDirections(
                                    origin: legOrigin,
                                    destination: legDestination,
                                    waypoints: []
                                )
                                recordOSRMCalibration(mapKitDuration: mapKitDuration, osrmDuration: osrmResult.duration)
                            } catch {
                                // Silently ignore calibration failures
                            }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                print("🍎 MapKit leg \(i+1) failed: \(errorDesc)")
                
                // Check for rate limiting (MapKit returns GEOErrorDomain Code=-3)
                let nsError = error as NSError
                if nsError.domain == "GEOErrorDomain" && nsError.code == -3 {
                    // Extract timeUntilReset from userInfo if available
                    var waitTime = 60 // Default to 60 seconds
                    if let userInfo = nsError.userInfo["timeUntilReset"] as? Int {
                        waitTime = userInfo
                    }
                    print("🚫 MapKit rate limited! Trying OSRM fallback...")
                    
                    // Try OSRM as fallback when rate limited
                    do {
                        let osrmResult = try await getOSRMWalkingDirections(
                            origin: origin,
                            destination: destination,
                            waypoints: waypoints
                        )
                        
                        let leg = DirectionsLeg(
                            distance: DirectionsValue(text: formatDistance(osrmResult.distance), value: osrmResult.distance),
                            duration: DirectionsValue(text: formatDuration(osrmResult.duration), value: osrmResult.duration),
                            startAddress: nil,
                            endAddress: nil,
                            steps: nil
                        )
                        
                        let encodedPolyline = encodePolyline(osrmResult.polyline)
                        let durationMinutes = osrmResult.duration / 60
                        print("🗺️ OSRM fallback success: \(osrmResult.distance)m, \(durationMinutes)min")
                        
                        return DirectionsResult(
                            legs: [leg],
                            overviewPolyline: OverviewPolyline(points: encodedPolyline),
                            summary: nil,
                            warnings: nil,
                            waypointOrder: optimizedWaypointOrder
                        )
                    } catch {
                        print("🗺️ OSRM fallback also failed")
                        throw GoogleMapsError.rateLimited(timeUntilReset: waitTime)
                    }
                }
                
                throw GoogleMapsError.noRouteFound
            }
            
            guard let route = response.routes.first else {
                throw GoogleMapsError.noRouteFound
            }
            
            // Extract polyline points
            let polyline = route.polyline
            let pointCount = polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            
            // Append to overall polyline (skip first point of subsequent legs to avoid duplicates)
            if allPolylinePoints.isEmpty {
                allPolylinePoints.append(contentsOf: coords)
            } else {
                allPolylinePoints.append(contentsOf: coords.dropFirst())
            }
            
            // Extract step-by-step directions from MapKit
            var legSteps: [DirectionsStep] = []
            for step in route.steps {
                // Skip steps with no instructions (usually the first "depart" step)
                guard !step.instructions.isEmpty else { continue }
                
                let stepDistance = Int(step.distance)
                // Estimate duration based on walking speed (~80m/min)
                let stepDuration = max(1, stepDistance / 80) * 60
                
                // Encode step polyline
                let stepPolylineCount = step.polyline.pointCount
                var stepCoords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: stepPolylineCount)
                step.polyline.getCoordinates(&stepCoords, range: NSRange(location: 0, length: stepPolylineCount))
                let stepPolylineEncoded = encodePolyline(stepCoords)
                
                let directionsStep = DirectionsStep(
                    distance: DirectionsValue(text: formatDistance(stepDistance), value: stepDistance),
                    duration: DirectionsValue(text: formatDuration(stepDuration), value: stepDuration),
                    htmlInstructions: step.instructions,
                    polyline: StepPolyline(points: stepPolylineEncoded)
                )
                legSteps.append(directionsStep)
            }
            
            // Create leg data
            let legDistance = Int(route.distance)
            let legDuration = Int(route.expectedTravelTime)
            totalDistance += legDistance
            totalDuration += legDuration
            
            let leg = DirectionsLeg(
                distance: DirectionsValue(text: formatDistance(legDistance), value: legDistance),
                duration: DirectionsValue(text: formatDuration(legDuration), value: legDuration),
                startAddress: nil,
                endAddress: nil,
                steps: legSteps.isEmpty ? nil : legSteps
            )
            allLegs.append(leg)
        }
        
        // ENSURE POLYLINE CONNECTS TO ACTUAL ORIGIN/DESTINATION
        // MapKit may snap to nearest walkable path, so prepend/append actual coordinates
        var finalPolylinePoints = allPolylinePoints
        
        // Prepend origin if polyline doesn't start close enough (within 50m)
        if let firstPoint = finalPolylinePoints.first {
            let distanceToOrigin = distanceBetween(origin, firstPoint)
            if distanceToOrigin > 50 {
                print("🍎 Polyline starts \(Int(distanceToOrigin))m from origin - prepending actual origin")
                finalPolylinePoints.insert(origin, at: 0)
            }
        }
        
        // Append destination if polyline doesn't end close enough (within 50m)
        if let lastPoint = finalPolylinePoints.last {
            let distanceToDestination = distanceBetween(destination, lastPoint)
            if distanceToDestination > 50 {
                print("🍎 Polyline ends \(Int(distanceToDestination))m from destination - appending actual destination")
                finalPolylinePoints.append(destination)
            }
        }
        
        // Encode combined polyline to Google's format (for compatibility)
        let encodedPolyline = encodePolyline(finalPolylinePoints)
        
        print("🍎 MapKit: \(allLegs.count) legs, \(totalDistance)m, \(totalDuration/60)min (FREE!)")
        
        return DirectionsResult(
            legs: allLegs,
            overviewPolyline: OverviewPolyline(points: encodedPolyline),
            summary: nil,
            warnings: nil,
            waypointOrder: optimizedWaypointOrder
        )
    }
    
    // MARK: - v1.6.14: Get MapKit Directions for Existing Route
    /// Gets turn-by-turn directions from Apple MapKit for a route that was generated by OSRM
    /// This ensures ALL routes have directions, regardless of how POIs were selected
    /// - Parameters:
    ///   - origin: Starting point
    ///   - waypoints: Array of waypoint coordinates (POI locations)
    ///   - destination: End point (usually same as origin for round-trips)
    /// - Returns: Array of WalkingDirection for turn-by-turn navigation
    func getMapKitDirectionsForRoute(
        origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D
    ) async -> [WalkingDirection] {
        var allDirections: [WalkingDirection] = []
        
        // Build the list of points: origin → waypoints → destination
        let allPoints = [origin] + waypoints + [destination]
        
        print("🍎 Getting MapKit directions for \(allPoints.count - 1) legs...")
        
        // Get directions for each leg
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            // Check rate limit
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            do {
                let response = try await directions.calculate()
                guard let route = response.routes.first else { continue }
                
                // Extract step-by-step directions
                for step in route.steps {
                    guard !step.instructions.isEmpty else { continue }
                    
                    let stepDistance = Int(step.distance)
                    // Estimate duration based on walking speed (~80m/min)
                    let stepDurationSeconds = max(60, stepDistance / 80 * 60)
                    let durationText = stepDurationSeconds >= 60 ? "\(stepDurationSeconds / 60) min" : "\(stepDurationSeconds) sec"
                    
                    // Extract maneuver type from instructions
                    let maneuver = extractManeuverType(from: step.instructions)
                    
                    let direction = WalkingDirection(
                        instruction: step.instructions,
                        distance: formatDistance(stepDistance),
                        distanceMeters: stepDistance,
                        duration: durationText,
                        maneuver: maneuver
                    )
                    allDirections.append(direction)
                }
            } catch {
                print("🍎 MapKit directions failed for leg \(i): \(error.localizedDescription)")
                // Continue with other legs even if one fails
            }
        }
        
        print("🍎 Got \(allDirections.count) directions from MapKit")
        return allDirections
    }
    
    /// Extract maneuver type from instruction text
    private func extractManeuverType(from instruction: String) -> String {
        let lowercased = instruction.lowercased()
        if lowercased.contains("turn left") { return "turn-left" }
        if lowercased.contains("turn right") { return "turn-right" }
        if lowercased.contains("slight left") { return "turn-slight-left" }
        if lowercased.contains("slight right") { return "turn-slight-right" }
        if lowercased.contains("continue") || lowercased.contains("straight") { return "straight" }
        if lowercased.contains("arrive") || lowercased.contains("destination") { return "arrive" }
        if lowercased.contains("u-turn") { return "uturn" }
        return "straight"
    }
    
    // MARK: - Batch Walking Directions (Parallel MapKit Calls)
    
    /// Result from a batched endpoint route calculation
    struct BatchedEndpointResult {
        let poi: PlaceResult
        let route: GeneratedRoute?
        let durationMinutes: Int
        let error: Error?
    }
    
    /// Get the current MapKit request count (for rate limit awareness) - thread-safe via actor
    var currentMapKitRequestCount: Int {
        get async {
            await rateLimiter.getCurrentCount(window: mapKitRateLimitWindow)
        }
    }
    
    /// Batch get walking directions for multiple endpoint candidates in parallel
    /// - Parameters:
    ///   - origin: Starting point (user's location)
    ///   - candidates: Array of POI candidates to try as endpoints
    ///   - maxConcurrent: Maximum number of concurrent requests (default 5)
    /// - Returns: Array of BatchedEndpointResult with routes for each candidate
    func batchGetWalkingDirectionsForEndpoints(
        origin: CLLocationCoordinate2D,
        candidates: [(poi: PlaceResult, distance: Double, score: Double)],
        maxConcurrent: Int = 5
    ) async -> [BatchedEndpointResult] {
        
        print("🔀 BATCH MODE: Processing \(candidates.count) candidates in parallel (max \(maxConcurrent) concurrent)")
        
        // Use TaskGroup for parallel execution with controlled concurrency
        var results: [BatchedEndpointResult] = []
        
        // Process in chunks to respect rate limits
        let chunks = stride(from: 0, to: candidates.count, by: maxConcurrent).map {
            Array(candidates[$0..<min($0 + maxConcurrent, candidates.count)])
        }
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            print("🔀 Processing batch \(chunkIndex + 1)/\(chunks.count) (\(chunk.count) candidates)")
            
            // Check rate limit before each batch
            await checkMapKitRateLimit()
            
            // Process chunk in parallel
            let chunkResults = await withTaskGroup(of: BatchedEndpointResult.self) { group in
                for candidate in chunk {
                    group.addTask {
                        do {
                            let directions = try await self.getWalkingDirections(
                                origin: origin,
                                destination: origin,
                                waypoints: [candidate.poi.coordinate]
                            )
                            
                            let totalDurationSeconds = directions.legs.reduce(0) { $0 + $1.duration.value }
                            let totalDistanceMeters = directions.legs.reduce(0) { $0 + $1.distance.value }
                            let routeMinutes = totalDurationSeconds / 60
                            
                            let route = GeneratedRoute(
                                places: [candidate.poi],
                                polyline: directions.overviewPolyline.points,
                                distanceMeters: totalDistanceMeters,
                                durationSeconds: totalDurationSeconds,
                                legs: directions.legs
                            )
                            
                            return BatchedEndpointResult(
                                poi: candidate.poi,
                                route: route,
                                durationMinutes: routeMinutes,
                                error: nil
                            )
                        } catch {
                            return BatchedEndpointResult(
                                poi: candidate.poi,
                                route: nil,
                                durationMinutes: 0,
                                error: error
                            )
                        }
                    }
                }
                
                var collected: [BatchedEndpointResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            
            results.append(contentsOf: chunkResults)
        }
        
        // Log results summary
        let successful = results.filter { $0.route != nil }.count
        print("🔀 BATCH COMPLETE: \(successful)/\(candidates.count) routes calculated successfully")
        
        return results
    }
    
    // MARK: - Waypoint Optimization (Nearest Neighbor)
    /// Simple nearest-neighbor algorithm to order waypoints efficiently
    private func optimizeWaypointOrder(
        from origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        to destination: CLLocationCoordinate2D
    ) -> (waypoints: [CLLocationCoordinate2D], order: [Int]) {
        var remaining = Array(waypoints.enumerated())
        var ordered: [CLLocationCoordinate2D] = []
        var orderIndices: [Int] = []
        var currentPoint = origin
        
        while !remaining.isEmpty {
            // Find nearest unvisited waypoint
            let nearest = remaining.min(by: { 
                distanceBetween(currentPoint, $0.element) < distanceBetween(currentPoint, $1.element)
            })!
            
            ordered.append(nearest.element)
            orderIndices.append(nearest.offset)
            currentPoint = nearest.element
            remaining.removeAll { $0.offset == nearest.offset }
        }
        
        return (ordered, orderIndices)
    }
    
    // MARK: - Polyline Encoding (Google format for compatibility)
    /// Encodes coordinates to Google's polyline format
    private func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encodedString = ""
        var prevLat: Int = 0
        var prevLng: Int = 0
        
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            
            encodedString += encodeSignedNumber(lat - prevLat)
            encodedString += encodeSignedNumber(lng - prevLng)
            
            prevLat = lat
            prevLng = lng
        }
        
        return encodedString
    }
    
    private func encodeSignedNumber(_ num: Int) -> String {
        var sgn_num = num << 1
        if num < 0 {
            sgn_num = ~sgn_num
        }
        return encodeNumber(sgn_num)
    }
    
    private func encodeNumber(_ num: Int) -> String {
        var encoded = ""
        var number = num
        
        while number >= 0x20 {
            let nextValue = (0x20 | (number & 0x1f)) + 63
            encoded += String(UnicodeScalar(nextValue)!)
            number >>= 5
        }
        encoded += String(UnicodeScalar(number + 63)!)
        
        return encoded
    }
    
    // MARK: - Formatting Helpers
    private func formatDistance(_ meters: Int) -> String {
        if meters < 1000 {
            return "\(meters) m"
        } else {
            return String(format: "%.1f km", Double(meters) / 1000.0)
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins < 60 {
            return "\(mins) mins"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(hours) hour\(hours > 1 ? "s" : "") \(remainingMins) mins"
        }
    }
    
    // MARK: - Retry Status
    @Published var retryStatus: String?
    
    // MARK: - Generate Route with Auto-Retry
    /// Wrapper that implements multi-stage retry:
    /// 1. Random selection (fast)
    /// 2. If fails: Systematic selection with expanded search
    /// 3. If still fails: Try shorter durations (drop 5 min at a time)
    /// 4. If all fails: Throw no route found
    func generateLocalRouteWithRetry(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║              🚶 ROUTE GENERATION STARTED                     ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ Target Duration: \(targetDurationMinutes) minutes")
        print("║ Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("║ Excluded POIs: \(excludePlaceIds.count)")
        print("║ Prefetched POIs: \(prefetchedPOIs?.count ?? 0)")
        print("╚══════════════════════════════════════════════════════════════╝")
        
        // Stage 1: Random selection (current behavior)
        print("\n📍 STAGE 1: Random Selection")
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                prefetchedPOIs: prefetchedPOIs,
                useSystematicSelection: false
            )
            await MainActor.run { retryStatus = nil }
            print("✅ STAGE 1 SUCCESS: \(route.durationSeconds / 60) min route with \(route.places.count) waypoints")
            return route
        } catch GoogleMapsError.rateLimited(let waitTime) {
            // Rate limited - wait and retry once
            print("🚫 Stage 1 rate limited, waiting \(waitTime)s...")
            await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
            try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
            // Don't retry all stages, just continue to stage 2
        } catch {
            print("🔄 Stage 1 (random) failed, trying systematic...")
        }
        
        // Stage 2: Systematic selection with expanded search
        print("\n📍 STAGE 2: Systematic Selection + Expanded Search")
        await MainActor.run { retryStatus = "Retrying with expanded search..." }
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                prefetchedPOIs: nil,  // Fresh POI fetch with larger radius
                useSystematicSelection: true,
                expandedSearch: true
            )
            await MainActor.run { retryStatus = nil }
            print("✅ STAGE 2 SUCCESS: \(route.durationSeconds / 60) min route with \(route.places.count) waypoints")
            return route
        } catch GoogleMapsError.rateLimited(let waitTime) {
            // Rate limited - wait and continue
            print("🚫 Stage 2 rate limited, waiting \(waitTime)s...")
            await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
            try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
        } catch {
            print("🔄 Stage 2 (systematic) failed, trying shorter durations...")
        }
        
        // Stage 3: Try shorter durations (drop 5 min at a time, but not below 5 min)
        print("\n📍 STAGE 3: Fallback to Shorter Durations")
        for reducedDuration in stride(from: targetDurationMinutes - 5, through: 5, by: -5) {
            let currentDuration = reducedDuration  // Capture for concurrent access
            await MainActor.run { retryStatus = "Trying \(currentDuration) min route..." }
            do {
                let route = try await generateLocalRoute(
                    from: location,
                    targetDurationMinutes: currentDuration,
                    difficulty: difficulty,
                    excludePlaceIds: excludePlaceIds,
                    prefetchedPOIs: nil,
                    useSystematicSelection: true,
                    expandedSearch: true
                )
                await MainActor.run { retryStatus = nil }
                print("🔄 Found route at \(currentDuration) min (originally requested \(targetDurationMinutes) min)")
                return route
            } catch GoogleMapsError.rateLimited(let waitTime) {
                // Rate limited in stage 3 - wait and continue to next duration
                print("🚫 Rate limited at \(currentDuration)min, waiting \(waitTime)s...")
                await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
                try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
            } catch {
                print("🔄 \(currentDuration) min also failed...")
            }
        }
        
        // All stages failed
        await MainActor.run { retryStatus = nil }
        throw GoogleMapsError.noRouteFound
    }
    
    // MARK: - Generate Initial Route with Google Fallback
    /// Generates the INITIAL route for the user. Uses Google Directions as fallback
    /// ONLY if NO valid routes (80-100% of target) are found via MapKit.
    /// This is the only place where Google Directions should be called.
    func generateInitialRouteWithGoogleFallback(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        
        // Step 1: Try MapKit with ENDPOINT-FIRST approach (FREE, simpler, more predictable)
        // This finds a single POI at half the target distance and routes there and back
        let mapKitRoute = try await generateLocalRoute(
            from: location,
            targetDurationMinutes: targetDurationMinutes,
            difficulty: difficulty,
            prefetchedPOIs: prefetchedPOIs,
            useEndpointFirst: true  // NEW: Use simpler endpoint approach for Route 1
        )
        
        // Step 2: Check if route is within 80-100% tolerance
        let mins = mapKitRoute.durationSeconds / 60
        let toleranceMin = Int(Double(targetDurationMinutes) * 0.80)
        let toleranceMax = targetDurationMinutes
        let isWithinTolerance = mins >= toleranceMin && mins <= toleranceMax
        
        // Step 2b: If route is "boring" (1 waypoint), try SHORTER ENDPOINT + WAYPOINTS for variety
        if mapKitRoute.places.count <= 1, let pois = prefetchedPOIs {
            print("🎯 🔄 Route has only \(mapKitRoute.places.count) waypoint(s) - trying SHORTER ENDPOINT + WAYPOINTS for variety...")
            
            // For SHORTER endpoint, target 50-80% of requested time to leave room for waypoints
            // Based on observed data: 222m → 8min, so ~28m per min walking
            // To get 13min base route (middle of 10-16), need ~13 * 28 = 364m
            let shorterTargetMinutes = Int(Double(targetDurationMinutes) * 0.65)  // 65% of target
            let shorterHalfDuration = shorterTargetMinutes / 2
            // Use 0.7 factor - the 0.4 was too aggressive (gave 6-8min routes)
            let shorterIdealDistance = Double(shorterHalfDuration * adaptiveWalkingSpeed) * 0.7
            
            // Exclude the POI already used
            let usedPlaceIds = Set(mapKitRoute.places.map { $0.placeId })
            let shorterCandidates = pois
                .filter { !usedPlaceIds.contains($0.placeId) }
                .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                    let dist = distanceBetween(location, poi.coordinate)
                    let score = abs(dist - shorterIdealDistance)
                    return (poi, dist, score)
                }
                .filter { $0.distance >= shorterIdealDistance * 0.3 && $0.distance <= shorterIdealDistance * 2.0 }
                .sorted { $0.score < $1.score }
            
            print("🎯 🔄 Found \(shorterCandidates.count) shorter endpoint candidates (ideal: \(Int(shorterIdealDistance))m)")
            
            for candidate in shorterCandidates.prefix(3) {
                print("🎯 🔄 Trying shorter endpoint: '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                
                do {
                    let directions = try await getWalkingDirections(
                        origin: location,
                        destination: location,
                        waypoints: [candidate.poi.coordinate]
                    )
                    
                    let routeDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                    let routeDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                    let routeMinutes = routeDuration / 60
                    
                    // Must be 50-80% of target (room for waypoints)
                    let minShorter = Int(Double(targetDurationMinutes) * 0.50)
                    let maxShorter = Int(Double(targetDurationMinutes) * 0.80)
                    
                    if routeMinutes >= minShorter && routeMinutes <= maxShorter {
                        print("🎯 🔄 Shorter route: \(routeMinutes)min (\(minShorter)-\(maxShorter) target) - enhancing...")
                        
                        let shorterRoute = GeneratedRoute(
                            places: [candidate.poi],
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: routeDistance,
                            durationSeconds: routeDuration,
                            legs: directions.legs
                        )
                        
                        let enhanced = try await enhanceRouteWithWaypoints(
                            existingRoute: shorterRoute,
                            origin: location,
                            targetDurationMinutes: targetDurationMinutes,
                            prefetchedPOIs: pois
                        )
                        
                        let enhancedMins = enhanced.durationSeconds / 60
                        if enhanced.places.count > 1 && enhancedMins >= toleranceMin && enhancedMins <= toleranceMax {
                            print("🎯 ✨ ENHANCED shorter route: \(enhanced.places.count) waypoints, \(enhancedMins)min - adding as alternative!")
                            alternativeEndpointRoutes.append(enhanced)
                            break  // Found one good enhanced route
                        } else {
                            print("🎯 🔄 Enhanced not valid: \(enhanced.places.count) wp, \(enhancedMins)min (need \(toleranceMin)-\(toleranceMax))")
                        }
                    } else {
                        print("🎯 🔄 Route \(routeMinutes)min outside \(minShorter)-\(maxShorter) range")
                    }
                } catch {
                    print("🎯 🔄 Failed: \(error.localizedDescription)")
                }
            }
            
            if alternativeEndpointRoutes.isEmpty {
                print("🎯 🔄 No valid shorter+enhanced route found")
            } else {
                print("🎯 📦 Added \(alternativeEndpointRoutes.count) alternative route(s) to pool")
            }
        }
        
        if isWithinTolerance {
            print("🗺️ ✅ Initial route within 80-100%: \(mins)min - no Google needed")
            return mapKitRoute
        }
        
        // Step 3: MapKit route is outside tolerance - try Google (PAID, 1 attempt only)
        print("🗺️ ⚠️ Initial route outside 80-100%: \(mins)min - trying Google fallback...")
        
        if let googleRoute = await getGoogleDirectionsRoute(
            origin: location,
            waypoints: mapKitRoute.places,
            targetDurationMinutes: targetDurationMinutes
        ) {
            let googleMins = googleRoute.durationSeconds / 60
            let googleWithinTolerance = googleMins >= toleranceMin && googleMins <= toleranceMax
            
            if googleWithinTolerance {
                print("🌐 ✅ Google route within tolerance: \(googleMins)min - using Google")
                return googleRoute
            } else if abs(googleMins - targetDurationMinutes) < abs(mins - targetDurationMinutes) {
                print("🌐 ✓ Google route closer to target: \(googleMins)min vs MapKit \(mins)min")
                return googleRoute
            } else {
                print("🌐 ✗ Google not better, using MapKit: \(mins)min")
            }
        } else {
            print("🌐 ✗ Google fallback failed, using MapKit: \(mins)min")
        }
        
        // Return MapKit route as fallback
        return mapKitRoute
    }
    
    // MARK: - Enhance Route with More Waypoints
    /// Takes an existing route (often with 1-2 waypoints) and adds more POIs along the path
    /// This creates a more interesting walk without significantly changing the route duration
    /// - Parameter existingRoute: The quick-generated route to enhance
    /// - Parameter targetDurationMinutes: Original target duration (to calculate ideal waypoint count)
    /// - Parameter prefetchedPOIs: POIs to choose from (should include all nearby POIs)
    /// - Returns: Enhanced route with more waypoints, or original if enhancement fails
    @Published var enhancementStatus: String? = nil
    
    func enhanceRouteWithWaypoints(
        existingRoute: GeneratedRoute,
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        prefetchedPOIs: [PlaceResult]
    ) async throws -> GeneratedRoute {
        let currentWaypoints = existingRoute.places.count
        let maxDurationSeconds = targetDurationMinutes * 60  // Hard limit - never exceed
        let currentDurationMins = existingRoute.durationSeconds / 60
        
        // SKIP if already at or near target time (within 2 minutes)
        let timeBuffer = 2
        if currentDurationMins >= targetDurationMinutes - timeBuffer {
            print("🗺️ 📍 Route already at target time (\(currentDurationMins)min / \(targetDurationMinutes)min) - no enhancement needed")
            return existingRoute
        }
        
        print("🗺️ 📍 PROGRESSIVE ENHANCEMENT: \(currentDurationMins)min → target \(targetDurationMinutes)min, \(currentWaypoints) waypoints")
        await MainActor.run { enhancementStatus = "Adding waypoints..." }
        
        // Decode existing polyline to find points along the route
        let routePoints = decodePolyline(existingRoute.polyline)
        guard routePoints.count >= 2 else {
            print("🗺️ 📍 Cannot enhance - not enough route points")
            await MainActor.run { enhancementStatus = nil }
            return existingRoute
        }
        
        // Get existing waypoint IDs to exclude
        let existingIds = Set(existingRoute.places.map { $0.placeId })
        let availablePOIs = prefetchedPOIs.filter { !existingIds.contains($0.placeId) }
        
        guard !availablePOIs.isEmpty else {
            print("🗺️ 📍 No additional POIs available for enhancement")
            await MainActor.run { enhancementStatus = nil }
            return existingRoute
        }
        
        // Find POIs that are NEAR the route path (within 150m of route line)
        var poisNearRoute: [(poi: PlaceResult, routeIndex: Int, distanceFromRoute: Double)] = []
        
        for poi in availablePOIs {
            var closestDistance = Double.infinity
            var closestRouteIndex = 0
            
            for (index, routePoint) in routePoints.enumerated() {
                let dist = distanceBetween(poi.coordinate, routePoint)
                if dist < closestDistance {
                    closestDistance = dist
                    closestRouteIndex = index
                }
            }
            
            // Only include POIs within 150m of the route path
            if closestDistance < 150 {
                poisNearRoute.append((poi: poi, routeIndex: closestRouteIndex, distanceFromRoute: closestDistance))
            }
        }
        
        guard !poisNearRoute.isEmpty else {
            print("🗺️ 📍 No POIs found near route path (within 150m)")
            await MainActor.run { enhancementStatus = nil }
            return existingRoute
        }
        
        print("🗺️ 📍 Found \(poisNearRoute.count) POIs near route path")
        
        // Sort by distance from route (closest first - these add least time)
        poisNearRoute.sort { $0.distanceFromRoute < $1.distanceFromRoute }
        
        // MINIMUM DISTANCE: Waypoints should be spaced ~3-4 min of walking apart
        // At ~80m/min walking speed, 3 min = 240m minimum spacing
        // Lowered from 350m to allow more POI options
        let minWaypointDistance: Double = 200  // ~2.5 min walking, more flexible
        
        // Start with the existing route and add waypoints ONE AT A TIME
        var currentRoute = existingRoute
        var currentWaypointsList = Array(existingRoute.places)
        var addedCount = 0
        let maxWaypointsToAdd = 5  // Cap at 5 additional waypoints
        
        for candidateInfo in poisNearRoute {
            // Check if we've added enough
            if addedCount >= maxWaypointsToAdd {
                print("🗺️ 📍 Reached max waypoints to add (\(maxWaypointsToAdd))")
                break
            }
            
            let candidate = candidateInfo.poi
            
            // Skip if already in list
            if currentWaypointsList.contains(where: { $0.placeId == candidate.placeId }) {
                continue
            }
            
            // Skip if too close to any existing waypoint
            let currentCoordinates = currentWaypointsList.map { $0.coordinate }
            let tooClose = currentCoordinates.contains { coord in
                distanceBetween(candidate.coordinate, coord) < minWaypointDistance
            }
            if tooClose {
                print("🗺️ 📍 Skipping \(candidate.name) - too close to existing waypoint")
                continue
            }
            
            // Try adding this waypoint and calculate new route time
            var testWaypoints = currentWaypointsList
            testWaypoints.append(candidate)
            
            // Sort waypoints by ANGLE from origin to form a smooth loop
            // This creates a clockwise/counter-clockwise circuit instead of back-and-forth
            let waypointsWithAngle: [(poi: PlaceResult, angle: Double)] = testWaypoints.map { poi in
                let bearing = bearingBetween(origin, poi.coordinate)
                return (poi: poi, angle: bearing)
            }
            
            // Find the farthest waypoint (the endpoint) - this determines the direction
            let farthestWaypoint = testWaypoints.max { distanceBetween(origin, $0.coordinate) < distanceBetween(origin, $1.coordinate) }
            let endpointAngle = farthestWaypoint.map { bearingBetween(origin, $0.coordinate) } ?? 0
            
            // Sort waypoints in a loop: start from origin direction, go to endpoint, return
            // Use angular distance from the "out" direction (origin to endpoint)
            let sortedByLoop = waypointsWithAngle.sorted { wp1, wp2 in
                // Calculate angular distance from endpoint direction
                let angDist1 = abs(wp1.angle - endpointAngle)
                let angDist2 = abs(wp2.angle - endpointAngle)
                
                // Also consider distance from origin for tiebreaking
                let dist1 = distanceBetween(origin, wp1.poi.coordinate)
                let dist2 = distanceBetween(origin, wp2.poi.coordinate)
                
                // Waypoints closer to the endpoint angle go first (outbound), then others (return)
                if abs(angDist1 - angDist2) > 30 {
                    return angDist1 < angDist2  // Closer to endpoint direction first
                } else {
                    return dist1 > dist2  // Farther waypoints first when similar angle
                }
            }
            let sortedWaypoints = sortedByLoop.map { $0.poi }
            
            print("🗺️ 📍 Testing: + \(candidate.name) (\(Int(candidateInfo.distanceFromRoute))m from route)")
            
            do {
                // Check rate limit
                await checkMapKitRateLimit()
                recordMapKitRequest()
                
                let testDirections = try await getWalkingDirections(
                    origin: origin,
                    destination: origin,
                    waypoints: sortedWaypoints.map { $0.coordinate },
                    preserveWaypointOrder: true
                )
                
                let testDuration = testDirections.legs.reduce(0) { $0 + $1.duration.value }
                let testMins = testDuration / 60
                
                // CHECK: Would adding this waypoint exceed the time limit?
                if testDuration > maxDurationSeconds {
                    print("🗺️ 📍 ✗ \(candidate.name) would make route \(testMins)min (over \(targetDurationMinutes)min limit) - SKIPPING")
                    continue  // Try next candidate instead of stopping
                }
                
                // SUCCESS: Adding this waypoint keeps us within limits
                let testDistance = testDirections.legs.reduce(0) { $0 + $1.distance.value }
                let polylinePoints = testDirections.overviewPolyline.points
                
                currentRoute = GeneratedRoute(
                    places: sortedWaypoints,
                    polyline: polylinePoints,
                    distanceMeters: testDistance,
                    durationSeconds: testDuration,
                    legs: testDirections.legs
                )
                currentWaypointsList = sortedWaypoints
                addedCount += 1
                
                print("🗺️ 📍 ✅ Added \(candidate.name) → now \(currentWaypointsList.count) waypoints, \(testMins)min")
                
            } catch {
                print("🗺️ 📍 ⚠️ Failed to test \(candidate.name): \(error.localizedDescription)")
                continue
            }
        }
        
        // Report results
        let originalMins = existingRoute.durationSeconds / 60
        let finalMins = currentRoute.durationSeconds / 60
        
        if addedCount > 0 {
            print("🗺️ 📍 🎉 ENHANCED! \(existingRoute.places.count) → \(currentWaypointsList.count) waypoints, \(originalMins)min → \(finalMins)min")
        } else {
            print("🗺️ 📍 Could not add any waypoints without exceeding \(targetDurationMinutes)min limit")
        }
        
        await MainActor.run { enhancementStatus = nil }
        return currentRoute
    }
    
    // MARK: - Generate Local Walking Route
    /// Generates a circular walking route from user's location using nearby POIs
    /// DYNAMICALLY adjusts number of waypoints to match target duration
    /// Keeps trying different combinations until within ±3 minutes of target
    /// - Parameter prefetchedPOIs: Optional pre-fetched POIs to skip the Places API call (faster generation)
    /// - Parameter useSystematicSelection: If true, tries POI combinations in order of likelihood to succeed
    /// - Parameter expandedSearch: If true, uses larger search radius
    
    /// Route generation method based on duration
    enum RouteMethod {
        case endpointOnly           // 10-25 min: endpoint-first, no loop fallback
        case endpointWithEnhancement // 26-45 min: endpoint + enhancement
        case loopFallback           // 50-60 min: can use loop-based as fallback
    }
    
    /// Direction quadrant for route generation variety
    enum RouteDirection: Int, CaseIterable {
        case north = 0      // 315° to 45°
        case east = 1       // 45° to 135°
        case south = 2      // 135° to 225°
        case west = 3       // 225° to 315°
        
        var angleRange: ClosedRange<Double> {
            switch self {
            case .north: return -45...45
            case .east: return 45...135
            case .south: return 135...225  // Note: will need to handle wrap
            case .west: return -135...(-45)  // Note: will need to handle wrap
            }
        }
        
        func contains(angle: Double) -> Bool {
            // Normalize angle to -180 to 180
            var normalized = angle
            while normalized > 180 { normalized -= 360 }
            while normalized < -180 { normalized += 360 }
            
            switch self {
            case .north: return normalized >= -45 && normalized <= 45
            case .east: return normalized > 45 && normalized <= 135
            case .south: return normalized > 135 || normalized < -135
            case .west: return normalized >= -135 && normalized < -45
            }
        }
    }
    
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        prefetchedPOIs: [PlaceResult]? = nil,
        useSystematicSelection: Bool = false,
        expandedSearch: Bool = false,
        preferredDirection: RouteDirection? = nil,  // Try to generate route in this direction
        useEndpointFirst: Bool = false  // NEW: Use single endpoint approach (better for Route 1)
    ) async throws -> GeneratedRoute {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        // ADAPTIVE TIMING: More flexible for short routes in dense urban areas
        // Short routes (≤15 min): 50-100% acceptable (dense areas have clustered POIs)
        // Medium routes (16-30 min): 65-100% acceptable
        // Quick mode (initial generation): 70-100% for fast, accurate results
        // Retry modes: more flexible to find any route
        let isQuickMode = !useSystematicSelection && !expandedSearch
        
        // Tolerance matches RouteCacheService: 80-120% (or 75-125% for edge cases)
        let isEdgeCase = targetDurationMinutes <= 10 || targetDurationMinutes >= 55
        let minPercent: Double
        let maxPercent: Double
        
        if isQuickMode {
            // QUICK mode: 70-130% to catch more routes on first try
            // Better to show a slightly off route than keep searching
            if isEdgeCase {
                minPercent = 0.65  // Edge cases: more flexible (65-140%)
                maxPercent = 1.40
            } else {
                minPercent = 0.70  // Standard: 70-130%
                maxPercent = 1.30
            }
        } else if expandedSearch {
            minPercent = 0.40  // Very flexible during retry
            maxPercent = 1.60  // Allow longer routes
        } else {
            minPercent = 0.50  // Systematic retry
            maxPercent = 1.40
        }
        
        let minAcceptableMinutes = max(1, Int(Double(targetDurationMinutes) * minPercent))
        let maxAcceptableMinutes = Int(Double(targetDurationMinutes) * maxPercent)
        let minAcceptableDuration = minAcceptableMinutes * 60
        let maxAcceptableDuration = maxAcceptableMinutes * 60
        
        let modeLabel = isQuickMode ? "⚡ QUICK" : (expandedSearch ? "EXPANDED" : "SYSTEMATIC")
        print("🗺️ \(modeLabel): \(minAcceptableMinutes)min to \(maxAcceptableMinutes)min (\(Int(minPercent * 100))-\(Int(maxPercent * 100))% of \(targetDurationMinutes)min)")
        
        // Walking speed ~80m/min, but actual routes are 2-4x longer than straight-line
        // Use ADAPTIVE walking speed (learned from user's completed walks)
        // Defaults to 80m/min, adjusts to 65-90m/min based on actual pace
        let walkingSpeedMeterPerMin = adaptiveWalkingSpeed
        
        // v1.6.10: DUAL-MULTIPLIER + DENSITY-AWARE (for 5-min routes)
        // - estimationMultiplier: Aggressive - used for POI selection, aims shorter
        // - validationMultiplier: Original - used for accepting routes, realistic
        // For ≤5 min routes: use POI density as proxy for street grid density
        let estimationMultiplier: Double
        let validationMultiplier: Double
        
        // Determine POI density for adaptive 5-min estimation
        let poiDensity = prefetchedPOIs?.count ?? 100  // Default to medium if unknown
        
        if targetDurationMinutes <= 5 {
            // DENSITY-AWARE 5-MIN ESTIMATION (v1.6.10)
            // Explains the 60%-180% split between locations
            if poiDensity > 300 {
                estimationMultiplier = 0.55   // Dense street grids (Ecclesall) - aim much shorter
            } else if poiDensity < 80 {
                estimationMultiplier = 0.75   // Sparse / park-heavy (Chapeltown) - less aggressive
            } else {
                estimationMultiplier = 0.65   // Default
            }
            validationMultiplier = 0.85
            print("🎯 5-min density-aware: \(poiDensity) POIs → estimation=\(estimationMultiplier)")
        } else if targetDurationMinutes <= 10 {
            estimationMultiplier = 0.65
            validationMultiplier = 0.85
        } else if targetDurationMinutes <= 15 {
            estimationMultiplier = 0.70
            validationMultiplier = 0.85
        } else if targetDurationMinutes <= 20 {
            estimationMultiplier = 0.75
            validationMultiplier = 0.88
        } else if targetDurationMinutes <= 35 {
            estimationMultiplier = 0.82
            validationMultiplier = 0.90
        } else {
            estimationMultiplier = 0.85
            validationMultiplier = 0.92
        }
        
        // Use estimation multiplier for distance targeting (aims shorter)
        let totalDistanceTarget = Int(Double(targetDurationMinutes * walkingSpeedMeterPerMin) * estimationMultiplier)
        print("🗺️ Distance target: \(totalDistanceTarget)m (estimation: \(estimationMultiplier), validation: \(validationMultiplier))")
        
        // Search radius - LARGER for short routes to find POIs at better distances
        // In dense areas, nearby POIs are too close for a proper loop
        // Expanded search uses 2x radius to find more options
        // Long routes need larger radius to find distant POIs
        let baseRadius = max(600, totalDistanceTarget / 2)
        let searchRadius: Int
        if expandedSearch {
            searchRadius = baseRadius * 2  // Double radius for retry
        } else if targetDurationMinutes >= 30 {
            searchRadius = max(1500, baseRadius * 2)  // 30+ min: largest radius
            print("🗺️ 🔍 Extended search radius for \(targetDurationMinutes)min route (30+ tier)")
        } else if targetDurationMinutes >= 20 {
            searchRadius = max(1200, baseRadius * 2)  // 20-29 min: large radius
            print("🗺️ 🔍 Extended search radius for \(targetDurationMinutes)min route (20+ tier)")
        } else if targetDurationMinutes <= 15 {
            searchRadius = max(800, baseRadius * 3 / 2)  // Short routes need wider search
        } else {
            searchRadius = baseRadius  // 16-19 min: standard
        }
        
        let searchMode = expandedSearch ? "EXPANDED" : (useSystematicSelection ? "SYSTEMATIC" : "RANDOM")
        print("🗺️ Target: \(targetDurationMinutes)min [\(searchMode)]")
        print("🗺️ Search radius: \(searchRadius)m")
        
        // DURATION-BASED METHOD SELECTION
        // Short routes: endpoint-first only (skip loops - they're too unpredictable)
        // Medium routes: endpoint-first + enhancement
        // Long routes: can fall back to loop-based if needed
        let routeMethod: RouteMethod
        var dynamicMaxWaypoints: Int  // var: can be increased as fallback for short routes
        
        // FLEXIBLE WAYPOINT TIERS: Allow fewer waypoints, ensure routes are achievable
        // The algorithm tries more waypoints first, falls back to fewer if needed
        var minWaypointsForTier: Int
        
        switch targetDurationMinutes {
        case 5...10:
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 2
            minWaypointsForTier = 1
            print("🗺️ 📋 Tier 5-10min: 1-\(dynamicMaxWaypoints) waypoints")
        case 11...20:
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 3
            minWaypointsForTier = 1  // Lowered: allow 1 waypoint if needed
            print("🗺️ 📋 Tier 11-20min: 1-\(dynamicMaxWaypoints) waypoints")
        case 21...30:
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 4
            minWaypointsForTier = 2
            print("🗺️ 📋 Tier 21-30min: 2-\(dynamicMaxWaypoints) waypoints")
        case 31...45:
            routeMethod = .endpointWithEnhancement
            dynamicMaxWaypoints = 6
            minWaypointsForTier = 2  // Lowered from 4
            print("🗺️ 📋 Tier 31-45min: 2-\(dynamicMaxWaypoints) waypoints")
        default:  // 46-60+ min
            routeMethod = .endpointWithEnhancement
            dynamicMaxWaypoints = 8
            minWaypointsForTier = 3  // Lowered from 7-10
            print("🗺️ 📋 Tier 46+min: 3-\(dynamicMaxWaypoints) waypoints")
        }
        
        // Step 1: Find nearby POIs - use pre-fetched if available (faster!)
        // Waypoints spaced 5 min apart: N waypoints = N+1 segments
        // desiredSpots = (duration / 5) - 1, but minimum 2 for variety
        let desiredSpots = max(2, (targetDurationMinutes / 5) - 1)
        var places: [PlaceResult]
        
        if let prefetched = prefetchedPOIs, !prefetched.isEmpty {
            // Use pre-fetched POIs - skip API call!
            places = prefetched
            print("🗺️ ⚡ Using \(places.count) pre-fetched POIs (faster!)")
        } else {
            // Fetch POIs now
            places = try await findNearbyPlaces(
                location: location,
                radiusMeters: searchRadius
            )
            print("🗺️ Found \(places.count) POIs (need \(desiredSpots) for route)")
        }
        
        // ════════════════════════════════════════════════════════════════
        // 📊 POI FUNNEL TELEMETRY - Track filtering stages for debugging
        // ════════════════════════════════════════════════════════════════
        let fetchedPOICount = places.count
        
        // Filter out previously shown places to ensure variety
        if !excludePlaceIds.isEmpty {
            let beforeCount = places.count
            let excludedPOIs = places.filter { excludePlaceIds.contains($0.placeId) }
            places = places.filter { !excludePlaceIds.contains($0.placeId) }
            print("🗺️ Excluded \(beforeCount - places.count) previously shown POIs, \(places.count) remaining")
            if !excludedPOIs.isEmpty {
                print("🚫 Excluded POIs: \(excludedPOIs.map { $0.name }.joined(separator: ", "))")
            }
        }
        let afterExclusionCount = places.count
        
        // 🎯 PRE-FILTER: Remove POIs that would create routes WAY outside target duration
        // This prevents "Springwood Cott" (30min round-trip) from being tried for 5min routes
        let preFilteredPlaces = preFilterPOIsByDuration(places, origin: location, targetDurationMinutes: targetDurationMinutes)
        places = preFilteredPlaces
        let prefilterPassedCount = places.count
        
        // ⚠️ WARNING: Pre-filter too aggressive?
        let prefilterPassRate = fetchedPOICount > 0 ? Double(prefilterPassedCount) / Double(fetchedPOICount) * 100 : 0
        if prefilterPassRate < 5.0 && fetchedPOICount > 50 {
            print("⚠️ 🚨 POI FUNNEL WARNING: Pre-filter too aggressive!")
            print("   📊 Fetched: \(fetchedPOICount) → Pre-filter passed: \(prefilterPassedCount) (\(String(format: "%.1f", prefilterPassRate))%)")
            print("   💡 Consider widening filter range for \(targetDurationMinutes)min routes")
        }
        
        // 📊 DYNAMIC POI CAP (v1.6.12): More aggressive density-adaptive cap
        // Batch test showed: more POIs ≠ better accuracy
        // 127 POIs (Chapeltown) → 72% valid, 296 POIs (Firth Park) → 42% valid
        // Root cause: too many candidates = selection noise dominates
        let rawPOICount = places.count
        let maxPOIs: Int
        if rawPOICount > 300 {
            maxPOIs = 50    // Very dense - aggressive reduction
        } else if rawPOICount > 200 {
            maxPOIs = 75    // Dense (e.g., Firth Park, Ecclesall)
        } else {
            maxPOIs = 150   // Normal / suburban / rural (working well)
        }
        
        var cappedPOICount = places.count
        if places.count > maxPOIs {
            print("📊 POI CAP: \(rawPOICount) raw → \(maxPOIs) (density tier: \(rawPOICount > 500 ? "ultra-dense" : rawPOICount > 200 ? "dense" : "normal"))")
            
            // v1.6.33: Count Google POIs to determine if we should prioritize them
            let googlePOICount = places.filter { isGooglePOI($0) }.count
            
            // Score POIs by: walkability + distance fit + source quality (prefer Google when plentiful)
            let targetDistance = Double(targetDurationMinutes) * 80 / 2  // Ideal one-way distance
            let scoredPlaces = places.map { poi -> (poi: PlaceResult, score: Double) in
                let distance = distanceBetween(location, poi.coordinate)
                let distanceFit = 1.0 - min(1.0, abs(distance - targetDistance) / targetDistance)
                let walkScore = walkabilityScore(for: poi)
                let sourceScore = sourceQualityScore(for: poi, googlePOICount: googlePOICount)
                return (poi, distanceFit * 10 + walkScore + sourceScore)
            }.sorted { $0.score > $1.score }
            
            places = Array(scoredPlaces.prefix(maxPOIs).map { $0.poi })
            cappedPOICount = places.count
            
            // Log source breakdown
            let keptGoogleCount = places.filter { isGooglePOI($0) }.count
            print("📊 Kept top \(places.count) POIs by score (Google: \(keptGoogleCount), OSM/Apple: \(places.count - keptGoogleCount))")
        }
        
        // 📊 FINAL FUNNEL SUMMARY
        print("📊 ═══════════════════════════════════════════════════")
        print("📊 POI FUNNEL for \(targetDurationMinutes)min route:")
        print("📊   Fetched:        \(fetchedPOICount)")
        print("📊   After exclusion: \(afterExclusionCount)")
        print("📊   Pre-filter pass: \(prefilterPassedCount) (\(String(format: "%.0f", prefilterPassRate))%)")
        print("📊   After cap:       \(cappedPOICount)")
        print("📊 ═══════════════════════════════════════════════════")
        
        // For longer routes OR short routes with few POIs, do additional searches at different points
        // Short routes in dense areas need POIs at BETTER distances, not just more nearby ones
        let needsMorePOIs = places.count < desiredSpots * 2 || 
                           (targetDurationMinutes <= 15 && places.count < 10)
        if needsMorePOIs {
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
        
        // ════════════════════════════════════════════════════════════════
        // 🚦 v1.6.21: VIABILITY GATE FOR SHORT ROUTES
        // Prevents forced bad routes in sparse areas
        // ════════════════════════════════════════════════════════════════
        let nearestPOIDistance = places.map { distanceBetween(location, $0.coordinate) }.min() ?? 9999
        
        // For 5-7 min routes: nearest POI must be within ~300m (3.75 min one-way @ 80m/min)
        // If nearest is >300m, a 5-min round trip is physically impossible
        if targetDurationMinutes <= 7 && nearestPOIDistance > 300 {
            print("🚦 VIABILITY GATE: 5-7min route not possible")
            print("   📏 Nearest POI: \(Int(nearestPOIDistance))m (need ≤300m for round-trip)")
            print("   💡 Recommending 10-min minimum for this location")
            
            // Set flag so UI can show appropriate message
            await MainActor.run {
                shortRouteNotViable = true
                minimumViableMinutes = 10
            }
        } else {
            await MainActor.run {
                shortRouteNotViable = false
                minimumViableMinutes = 5
            }
        }
        
        // v1.6.10: Track POI count for low-POI warning
        let finalPOICount = places.count
        await MainActor.run {
            lastPOICount = finalPOICount
            hasLimitedPOIs = finalPOICount < GoogleMapsService.limitedPOIThreshold
            if hasLimitedPOIs {
                print("⚠️ LIMITED POIs: Only \(finalPOICount) POIs available (threshold: \(GoogleMapsService.limitedPOIThreshold))")
            }
        }
        
        print("🗺️ Have \(places.count) POIs to select from")
        
        // 🔍 DIAGNOSTIC: Show all available POIs with distances, directions, and source
        print("🔍 === POI DIAGNOSTIC ===")
        for (index, poi) in places.prefix(15).enumerated() {
            let dist = Int(distanceBetween(location, poi.coordinate))
            let angle = Int(bearingBetween(location, poi.coordinate))
            let direction: String
            if angle >= -45 && angle <= 45 { direction = "N" }
            else if angle > 45 && angle <= 135 { direction = "E" }
            else if angle > 135 || angle < -135 { direction = "S" }
            else { direction = "W" }
            
            // Determine source from placeId prefix
            let source: String
            if poi.placeId.hasPrefix("apple_") {
                source = "🍎"  // Apple Maps
            } else if poi.placeId.hasPrefix("osm_") {
                source = "🗺️"  // OpenStreetMap
            } else {
                source = "📍"  // Google
            }
            
            print("🔍 \(index+1). \(source) '\(poi.name)' - \(dist)m \(direction) (\(angle)°)")
        }
        if places.count > 15 {
            print("🔍 ... and \(places.count - 15) more POIs")
        }
        print("🔍 ======================")
        
        // ========================================
        // ENDPOINT-FIRST APPROACH (for Route 1)
        // ========================================
        // Find a single endpoint at half the target distance, route there and back
        // This is simpler and more predictable than loop-based routing
        if useEndpointFirst {
            print("🎯 ENDPOINT-FIRST: Looking for POI at ~\(targetDurationMinutes/2) min distance")
            
            // Calculate ideal endpoint distance (half of total loop)
            // Use ADAPTIVE walking speed for better accuracy
            // FIX: Use ceiling division for short routes (5min/2 = 3, not 2)
            let halfDurationMinutes: Int
            if targetDurationMinutes <= 10 {
                // For very short walks, round UP to avoid being too restrictive
                halfDurationMinutes = (targetDurationMinutes + 1) / 2  // 5→3, 10→5
            } else {
                halfDurationMinutes = targetDurationMinutes / 2
            }
            let idealEndpointDistance = Double(halfDurationMinutes * walkingSpeedMeterPerMin) * 0.9
            
            // ADAPTIVE RANGE: Wider for short routes (high road overhead makes close POIs too long)
            // Short routes need more flexibility to find ANY valid endpoint
            let minMultiplier: Double
            let maxMultiplier: Double
            if targetDurationMinutes <= 10 {
                minMultiplier = 0.1  // Very short: accept VERY close POIs (even 20m away)
                maxMultiplier = 3.0  // And much farther ones too (school at 240m)
            } else if targetDurationMinutes <= 15 {
                minMultiplier = 0.2
                maxMultiplier = 2.5
            } else if targetDurationMinutes <= 25 {
                minMultiplier = 0.3
                maxMultiplier = 2.0
            } else {
                minMultiplier = 0.4
                maxMultiplier = 1.8
            }
            let minEndpointDistance = idealEndpointDistance * minMultiplier
            let maxEndpointDistance = idealEndpointDistance * maxMultiplier
            let targetTotalMeters = Double(targetDurationMinutes * walkingSpeedMeterPerMin)
            
            print("🎯 Ideal endpoint: \(Int(idealEndpointDistance))m (range: \(Int(minEndpointDistance))-\(Int(maxEndpointDistance))m) [speed: \(walkingSpeedMeterPerMin)m/min]")
            
            // v1.6.15: CLOSEST-FIRST with SHUFFLE for variety
            // For short routes, prefer closer POIs but shuffle top candidates
            // This ensures variety when generating multiple routes
            let useClosestFirst = targetDurationMinutes <= 10
            
            // Find POIs at the right distance, with CORRIDOR PENALTY scoring
            // Score = 0.7 * |distance - ideal| + 0.3 * (2×distance / targetTotal) * 100
            // This penalizes POIs that would create overly long out-and-backs
            var endpointCandidates = places
                .filter { !excludePlaceIds.contains($0.placeId) }
                .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                    let dist = distanceBetween(location, poi.coordinate)
                    let distanceScore = abs(dist - idealEndpointDistance)
                    // Corridor penalty: penalize if 2×distance significantly exceeds target
                    let twoLegDistance = dist * 2
                    let distanceRatio = twoLegDistance / targetTotalMeters
                    let corridorPenalty = max(0, distanceRatio - 1.0) * 100  // Penalty if ratio > 1.0
                    let score = 0.7 * distanceScore + 0.3 * corridorPenalty
                    return (poi, dist, score)
                }
                .filter { $0.distance >= minEndpointDistance && $0.distance <= maxEndpointDistance }
                .sorted { 
                    if useClosestFirst {
                        // For short routes, sort by DISTANCE (closest first)
                        return $0.distance < $1.distance
                    } else {
                        // For longer routes, use score-based sorting
                        return $0.score < $1.score
                    }
                }
            
            // v1.6.15: SHUFFLE top candidates for variety when generating multiple routes
            // Without this, we always pick the same "closest" POI
            if useClosestFirst && endpointCandidates.count > 3 {
                let topCount = min(8, endpointCandidates.count)  // Shuffle top 8
                var topCandidates = Array(endpointCandidates.prefix(topCount))
                topCandidates.shuffle()
                endpointCandidates = topCandidates + Array(endpointCandidates.dropFirst(topCount))
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (SHUFFLED top \(topCount) for variety)")
                // Debug: Show first 5 candidates after shuffle
                print("🎯 📋 Top 5 after shuffle: \(endpointCandidates.prefix(5).map { "\($0.poi.name) (\(Int($0.distance))m)" }.joined(separator: ", "))")
            } else if useClosestFirst {
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (closest-first, not enough to shuffle)")
                // Debug: Show what few candidates we have
                if !endpointCandidates.isEmpty {
                    print("🎯 📋 Candidates: \(endpointCandidates.map { "\($0.poi.name) (\(Int($0.distance))m)" }.joined(separator: ", "))")
                }
            } else {
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (score-sorted)")
            }
            
            // PRE-CHECK POI DENSITY: If fewer than 3 candidates, skip endpoint-first entirely
            // Go straight to loop approach which handles sparse areas better
            if endpointCandidates.count < 3 && targetDurationMinutes <= 15 {
                print("🎯 ⚠️ Only \(endpointCandidates.count) endpoint candidates - too sparse for short route, using loop fallback")
                // Skip to loop approach
            } else {
            
            // PRE-FILTER: Check one-way time before attempting full route
            // This saves MapKit calls by rejecting POIs that are clearly too far
            // FIX: More generous buffer for short walks (need to find POIs!)
            let oneWayBuffer = targetDurationMinutes <= 10 ? 2 : 1  // +2 min for very short, +1 otherwise
            let maxOneWayMinutes = halfDurationMinutes + oneWayBuffer
            var filteredCandidates: [(poi: PlaceResult, distance: Double, score: Double)] = []
            
            for candidate in endpointCandidates.prefix(10) {
                // Check cached one-way time first
                if let cached = getCachedLegTime(from: location, to: candidate.poi) {
                    if cached.minutes > maxOneWayMinutes {
                        print("🎯 ⏱️ Skipping '\(candidate.poi.name)' - cached one-way: \(cached.minutes)min > \(maxOneWayMinutes)min max")
                        continue
                    }
                }
                // Estimate based on distance (80m/min walking speed)
                let estimatedOneWayMins = Int(candidate.distance / Double(walkingSpeedMeterPerMin))
                if estimatedOneWayMins > maxOneWayMinutes + 3 {  // Extra buffer since estimate is rough
                    print("🎯 ⏱️ Skipping '\(candidate.poi.name)' - estimated one-way: \(estimatedOneWayMins)min too long")
                    continue
                }
                filteredCandidates.append(candidate)
            }
            
            print("🎯 \(filteredCandidates.count) candidates after time pre-filter (max one-way: \(maxOneWayMinutes)min)")
            
            // Track valid endpoint routes to find one with enhancement potential
            var validEndpointRoutes: [(route: GeneratedRoute, enhanceable: Bool, poisNearby: Int)] = []
            
            // FALLBACK: Track best route even if outside tolerance (for sparse areas)
            var bestEndpointFallback: GeneratedRoute?
            var bestEndpointFallbackDiff = Int.max
            
            // Clear previous alternative routes
            alternativeEndpointRoutes = []
            
            // BATCH vs SEQUENTIAL DECISION:
            // - Use BATCH for short routes (10-20 min) where tolerance is tight and failures are common
            // - Use SEQUENTIAL for longer routes where first candidate usually works
            // - Rate-limit aware: fall back to sequential if already near limit
            let currentRateLimitCount = await currentMapKitRequestCount
            let useBatchMode = targetDurationMinutes <= 20 && currentRateLimitCount < 35 && filteredCandidates.count >= 3
            
            if useBatchMode {
                // ========================================
                // BATCH MODE: Process multiple candidates in parallel
                // ========================================
                let batchSize = min(6, filteredCandidates.count)  // Process up to 6 at once
                let candidatesToBatch = Array(filteredCandidates.prefix(batchSize))
                
                print("🔀 BATCH MODE: Processing \(candidatesToBatch.count) candidates in parallel (rate limit: \(currentRateLimitCount)/50)")
                
                let batchResults = await batchGetWalkingDirectionsForEndpoints(
                    origin: location,
                    candidates: candidatesToBatch,
                    maxConcurrent: 3  // 3 concurrent to stay well under rate limit
                )
                
                // Process batch results - find best routes
                for result in batchResults {
                    guard let route = result.route else {
                        print("🔀 ✗ '\(result.poi.name)' failed: \(result.error?.localizedDescription ?? "unknown")")
                        continue
                    }
                    
                    let routeMinutes = result.durationMinutes
                    print("🔀 '\(result.poi.name)': \(routeMinutes)min (target: \(targetDurationMinutes)min)")
                    
                    // Check if within tolerance
                    if routeMinutes >= minAcceptableMinutes && routeMinutes <= maxAcceptableMinutes {
                        print("🔀 ✅ VALID: \(routeMinutes)min to '\(result.poi.name)'")
                        
                        // CHECK ENHANCEMENT POTENTIAL
                        let timeHeadroom = targetDurationMinutes - routeMinutes
                        let routePoints = decodePolyline(route.polyline)
                        
                        let poisNearRoute = places.filter { poi in
                            guard poi.placeId != result.poi.placeId else { return false }
                            return routePoints.contains { routePoint in
                                distanceBetween(poi.coordinate, routePoint) < 150
                            }
                        }
                        
                        let hasEnhancementPotential = timeHeadroom >= 2 && poisNearRoute.count >= 1
                        validEndpointRoutes.append((route: route, enhanceable: hasEnhancementPotential, poisNearby: poisNearRoute.count))
                        
                        if hasEnhancementPotential {
                            print("🔀 ✨ Has enhancement potential: \(timeHeadroom)min headroom, \(poisNearRoute.count) POIs nearby")
                        }
                    } else {
                        // Track as fallback
                        let diff = abs(routeMinutes - targetDurationMinutes)
                        if diff < bestEndpointFallbackDiff {
                            bestEndpointFallbackDiff = diff
                            bestEndpointFallback = route
                            print("🔀 📌 Best fallback: \(routeMinutes)min (diff: \(diff)min)")
                        }
                    }
                }
                
                // Sort valid routes: enhanceable first, then by time closest to target
                validEndpointRoutes.sort { a, b in
                    if a.enhanceable != b.enhanceable { return a.enhanceable }
                    let aDiff = abs(a.route.durationMinutes - targetDurationMinutes)
                    let bDiff = abs(b.route.durationMinutes - targetDurationMinutes)
                    return aDiff < bDiff
                }
                
                print("🔀 BATCH RESULT: \(validEndpointRoutes.count) valid routes, \(validEndpointRoutes.filter { $0.enhanceable }.count) enhanceable")
                
            } else {
                // ========================================
                // SEQUENTIAL MODE: Try candidates one by one (original logic)
                // ========================================
                print("🎯 SEQUENTIAL MODE: Processing candidates one by one")
                
                for (index, candidate) in filteredCandidates.prefix(8).enumerated() {
                    print("🎯 Trying endpoint \(index+1): '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                    
                    do {
                        let directions = try await getWalkingDirections(
                            origin: location,
                            destination: location,
                            waypoints: [candidate.poi.coordinate]
                        )
                        
                        let totalDurationSeconds = directions.legs.reduce(0) { $0 + ($1.duration.value) }
                        let totalDistanceMeters = directions.legs.reduce(0) { $0 + ($1.distance.value) }
                        let routeMinutes = totalDurationSeconds / 60
                        
                        print("🎯 Route duration: \(routeMinutes)min (target: \(targetDurationMinutes)min)")
                        
                        if routeMinutes >= minAcceptableMinutes && routeMinutes <= maxAcceptableMinutes {
                            print("🎯 ✅ VALID endpoint route! \(routeMinutes)min to '\(candidate.poi.name)'")
                            
                            let route = GeneratedRoute(
                                places: [candidate.poi],
                                polyline: directions.overviewPolyline.points,
                                distanceMeters: totalDistanceMeters,
                                durationSeconds: totalDurationSeconds,
                                legs: directions.legs
                            )
                            
                            let timeHeadroom = targetDurationMinutes - routeMinutes
                            let routePoints = decodePolyline(route.polyline)
                            
                            let poisNearRoute = places.filter { poi in
                                guard poi.placeId != candidate.poi.placeId else { return false }
                                return routePoints.contains { routePoint in
                                    distanceBetween(poi.coordinate, routePoint) < 150
                                }
                            }
                            
                            let hasEnhancementPotential = timeHeadroom >= 2 && poisNearRoute.count >= 1
                            
                            if hasEnhancementPotential {
                                print("🎯 ✨ Route has enhancement potential: \(timeHeadroom)min headroom, \(poisNearRoute.count) POIs nearby")
                                validEndpointRoutes.append((route: route, enhanceable: true, poisNearby: poisNearRoute.count))
                                break  // Found an enhanceable route
                            } else {
                                print("🎯 ⚠️ Route may be boring: only 1 waypoint")
                                validEndpointRoutes.append((route: route, enhanceable: false, poisNearby: poisNearRoute.count))
                            }
                        } else {
                            print("🎯 ✗ Outside tolerance: \(routeMinutes)min")
                            
                            let diff = abs(routeMinutes - targetDurationMinutes)
                            if diff < bestEndpointFallbackDiff {
                                bestEndpointFallbackDiff = diff
                                bestEndpointFallback = GeneratedRoute(
                                    places: [candidate.poi],
                                    polyline: directions.overviewPolyline.points,
                                    distanceMeters: totalDistanceMeters,
                                    durationSeconds: totalDurationSeconds,
                                    legs: directions.legs
                                )
                                print("🎯 📌 Saved as best fallback: \(routeMinutes)min (diff: \(diff)min)")
                            }
                        }
                    } catch {
                        print("🎯 ✗ Route failed: \(error.localizedDescription)")
                    }
                }
            }
            
            // Return best endpoint route (prefer enhanceable, otherwise first valid)
            // Store ALL other valid routes as alternatives for the caller to use
            // ALSO try shorter endpoint + waypoints strategy for variety
            
            // Helper function to try shorter endpoint strategy
            func tryShorterEndpointStrategy() async {
                print("🎯 🔄 Trying SHORTER ENDPOINT + WAYPOINTS for variety...")
                
                let shorterTargetMinutes = Int(Double(targetDurationMinutes) * 0.75)
                let shorterHalfDuration = shorterTargetMinutes / 2
                let shorterIdealDistance = Double(shorterHalfDuration * walkingSpeedMeterPerMin) * 0.9
                
                // Exclude already-found endpoints
                let usedPlaceIds = Set(validEndpointRoutes.compactMap { $0.route.places.first?.placeId })
                let shorterCandidates = places
                    .filter { !excludePlaceIds.contains($0.placeId) && !usedPlaceIds.contains($0.placeId) }
                    .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                        let dist = distanceBetween(location, poi.coordinate)
                        let score = abs(dist - shorterIdealDistance)
                        return (poi, dist, score)
                    }
                    .filter { $0.distance >= shorterIdealDistance * 0.4 && $0.distance <= shorterIdealDistance * 1.6 }
                    .sorted { $0.score < $1.score }
                
                for candidate in shorterCandidates.prefix(3) {
                    print("🎯 🔄 Trying shorter endpoint: '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                    
                    do {
                        let directions = try await getWalkingDirections(
                            origin: location,
                            destination: location,
                            waypoints: [candidate.poi.coordinate]
                        )
                        
                        let routeDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let routeDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        let routeMinutes = routeDuration / 60
                        
                        // Must be 50-80% of target (room for waypoints)
                        let minShorter = Int(Double(targetDurationMinutes) * 0.50)
                        let maxShorter = Int(Double(targetDurationMinutes) * 0.80)
                        
                        if routeMinutes >= minShorter && routeMinutes <= maxShorter {
                            print("🎯 🔄 Shorter route: \(routeMinutes)min (\(minShorter)-\(maxShorter) target) - enhancing...")
                            
                            let shorterRoute = GeneratedRoute(
                                places: [candidate.poi],
                                polyline: directions.overviewPolyline.points,
                                distanceMeters: routeDistance,
                                durationSeconds: routeDuration,
                                legs: directions.legs
                            )
                            
                            let enhanced = try await enhanceRouteWithWaypoints(
                                existingRoute: shorterRoute,
                                origin: location,
                                targetDurationMinutes: targetDurationMinutes,
                                prefetchedPOIs: places
                            )
                            
                            let enhancedMins = enhanced.durationSeconds / 60
                            if enhanced.places.count > 1 && enhancedMins >= minAcceptableMinutes && enhancedMins <= maxAcceptableMinutes {
                                print("🎯 ✨ ENHANCED shorter route: \(enhanced.places.count) waypoints, \(enhancedMins)min - adding as alternative")
                                alternativeEndpointRoutes.append(enhanced)
                                return  // Found one good enhanced route
                            } else {
                                print("🎯 🔄 Enhanced not valid: \(enhanced.places.count) wp, \(enhancedMins)min (need \(minAcceptableMinutes)-\(maxAcceptableMinutes))")
                            }
                        } else {
                            print("🎯 🔄 Route \(routeMinutes)min outside \(minShorter)-\(maxShorter) range")
                        }
                    } catch {
                        print("🎯 🔄 Failed: \(error.localizedDescription)")
                    }
                }
                print("🎯 🔄 No valid shorter+enhanced route found")
            }
            
            if let bestEnhanceable = validEndpointRoutes.first(where: { $0.enhanceable }) {
                print("🎯 ✅ Found enhanceable endpoint route")
                
                // ALSO try shorter endpoint strategy for variety (adds as alternative)
                await tryShorterEndpointStrategy()
                
                // Store other routes as alternatives
                for otherRoute in validEndpointRoutes where otherRoute.route.polyline != bestEnhanceable.route.polyline {
                    alternativeEndpointRoutes.append(otherRoute.route)
                }
                if !alternativeEndpointRoutes.isEmpty {
                    print("🎯 📦 Stored \(alternativeEndpointRoutes.count) alternative route(s) for pool")
                }
                return bestEnhanceable.route
            } else if let firstValid = validEndpointRoutes.first {
                print("🎯 ⚠️ Only boring routes found")
                
                // Try shorter endpoint + waypoints strategy for variety
                await tryShorterEndpointStrategy()
                
                // Store other valid routes as alternatives
                for otherRoute in validEndpointRoutes.dropFirst() {
                    alternativeEndpointRoutes.append(otherRoute.route)
                }
                if !alternativeEndpointRoutes.isEmpty {
                    print("🎯 📦 Stored \(alternativeEndpointRoutes.count) alternative route(s) for pool")
                }
                return firstValid.route
            }
            
            // If no valid routes but we have a fallback, use it (better than nothing)
            if let fallback = bestEndpointFallback {
                let fallbackMins = fallback.durationSeconds / 60
                print("🎯 ⚠️ No routes in tolerance, using best fallback: \(fallbackMins)min (target: \(targetDurationMinutes)min)")
                print("🎯 💡 Note: This area has high road overhead - closest route is \(fallbackMins)min")
                return fallback
            }
            
            print("🎯 No valid endpoint routes found, falling back to loop approach...")
            }  // End of POI density else block
        }
        
        // ========================================
        // LOOP APPROACH (for Routes 2+ or fallback)
        // ========================================
        
        // For short routes (10-25 min), use MINIMAL loop attempts as last resort
        // Don't skip entirely - high road overhead areas need fallback options
        let loopAttemptsLimit: Int
        if routeMethod == .endpointOnly {
            loopAttemptsLimit = 4  // Quick fallback with minimal attempts
            print("🗺️ ⚡ Using minimal loop fallback for \(targetDurationMinutes)min route (endpoint-only tier)")
        } else {
            loopAttemptsLimit = 8  // Standard attempts for longer routes
        }
        
        // Step 3: MAXIMIZE POIs while staying within time limit
        var validRoutes: [GeneratedRoute] = []
        var bestFallbackRoute: GeneratedRoute?
        var bestFallbackDiff = Int.max
        
        // PRIORITY: 1) Timing within tolerance  2) Maximum POIs
        let quickMode = !useSystematicSelection && !expandedSearch
        
        // Calculate appropriate waypoint counts based on target duration
        // Waypoints should be SPACED ~5 mins of walking apart (user spends ~2 min at each, not counted in route time)
        // For circular route: Start → WP1 → WP2 → ... → Start
        // With N waypoints, there are N+1 walking segments
        // If segments are ~5 mins each: totalWalkingTime = 5 * (N+1)
        // So: N = (walkingTime / 5) - 1
        // Example: 20min route → (20/5) - 1 = 3 waypoints (4 segments of 5 mins each)
        let idealWaypoints = max(1, (targetDurationMinutes / 5) - 1)
        let standardMaxWaypoints = min(dynamicMaxWaypoints, idealWaypoints + 1, places.count)
        
        // FALLBACK: Allow extra waypoints if routes are too short
        // Can reduce spacing to ~4 mins between waypoints as fallback
        // Example: 20min route fallback → (20/4) - 1 = 4 waypoints (5 segments of 4 mins each)
        let fallbackMaxWaypoints = max(1, (targetDurationMinutes / 4) - 1)
        let extendedMaxWaypoints = min(max(standardMaxWaypoints, fallbackMaxWaypoints), places.count)
        
        // ENFORCE MINIMUM WAYPOINTS per tier to ensure distinct routes
        // This prevents 15min routes from using the same 1-waypoint as 10min
        // SAFETY: Never let minWaypoints exceed standardMaxWaypoints (prevents crash with few POIs)
        let idealMinWaypoints = max(minWaypointsForTier, quickMode ? max(1, idealWaypoints / 2) : max(1, idealWaypoints - 2))
        let minWaypoints = min(idealMinWaypoints, standardMaxWaypoints)  // Clamp to available max
        print("🗺️ Waypoint range: \(minWaypoints) to \(standardMaxWaypoints) (extended: \(extendedMaxWaypoints))")
        
        // QUICK MODE: Try ASCENDING order (fewest waypoints first) for faster matching
        // This gets a valid route quickly, even if it has fewer POIs
        // Retry modes: Try DESCENDING to maximize POIs
        var waypointCountsToTry: [Int]
        if quickMode {
            // Start small for fast matching: [1, 2, 3] for 10-min route
            // Include extra waypoints at the end as fallback if routes are too short
            waypointCountsToTry = Array(minWaypoints...standardMaxWaypoints)
            if extendedMaxWaypoints > standardMaxWaypoints {
                waypointCountsToTry += Array((standardMaxWaypoints + 1)...extendedMaxWaypoints)
                print("🗺️ 📋 Including fallback waypoints: \(standardMaxWaypoints + 1)-\(extendedMaxWaypoints) if routes too short")
            }
        } else {
            // Start big to maximize POIs: [5, 4, 3, 2, 1]
            // Include extra waypoints at the START for retry modes (try most first)
            if extendedMaxWaypoints > standardMaxWaypoints {
                waypointCountsToTry = Array((minWaypoints...extendedMaxWaypoints).reversed())
                print("🗺️ 📋 Extended waypoint range: up to \(extendedMaxWaypoints) (fallback for short routes)")
            } else {
                waypointCountsToTry = Array((minWaypoints...standardMaxWaypoints).reversed())
            }
        }
        _ = extendedMaxWaypoints  // Extended max available for fallback waypoint counts
        
        var totalAttempts = 0
        let maxTotalAttempts: Int
        if quickMode {
            maxTotalAttempts = loopAttemptsLimit  // Use duration-based limit
            print("🗺️ ⚡ QUICK MODE: Trying \(waypointCountsToTry) waypoints (max \(loopAttemptsLimit) attempts)")
        } else if expandedSearch || useSystematicSelection {
            maxTotalAttempts = 20  // Retry mode: more thorough
            print("🗺️ Will try waypoint counts: \(waypointCountsToTry) (most first for max POIs)")
        } else {
            maxTotalAttempts = 10
            print("🗺️ Will try waypoint counts: \(waypointCountsToTry)")
        }
        
        for waypointCount in waypointCountsToTry {
            print("🗺️ 🔄 OUTER LOOP: waypointCount=\(waypointCount), totalAttempts=\(totalAttempts)/\(maxTotalAttempts)")
            guard totalAttempts < maxTotalAttempts else {
                print("🗺️ ⛔ Stopping: reached max attempts (\(maxTotalAttempts))")
                break
            }
            
            // In quick mode, return immediately if we have a valid route that meets minimum threshold
            // If route is too short (< 75% of target), continue trying more waypoints
            if quickMode && !validRoutes.isEmpty {
                let bestRouteMinutes = validRoutes.first!.durationSeconds / 60
                let minimumAcceptable = Int(Double(targetDurationMinutes) * 0.75)  // 75% minimum
                if bestRouteMinutes >= minimumAcceptable {
                    print("🗺️ ⚡ Quick mode: returning valid route (\(bestRouteMinutes)min >= \(minimumAcceptable)min threshold)")
                    break
                } else if waypointCount <= standardMaxWaypoints {
                    // Route too short, but we have fallback waypoint counts to try
                    print("🗺️ ⚡ Quick mode: route too short (\(bestRouteMinutes)min < \(minimumAcceptable)min), trying more waypoints...")
                } else {
                    // Tried fallback waypoints, return what we have
                    print("🗺️ ⚡ Quick mode: returning best available route (\(bestRouteMinutes)min)")
                    break
                }
            }
            
            guard validRoutes.count < 3 else { break } // Stop if we have enough valid routes
            
            // IMPORTANT: Scale ideal distance based on waypoint count
            // Walking routes are ~1.5-2x longer than straight-line distance due to streets/turns
            // For longer routes, we need to target farther POIs to hit the target duration
            // Segment distance factor - keep POIs closer for more predictable routes
            // Rural areas especially need closer POIs to avoid very long indirect routes
            let routeOverheadFactor: Double = 0.8  // Use 80% of ideal distance for all routes
            let segmentsInRoute = waypointCount + 1
            let idealSegmentDistance = Int(Double(totalDistanceTarget) * routeOverheadFactor) / segmentsInRoute
            
            // Re-select candidates with appropriate distance for this waypoint count
            var candidatesForCount = selectCandidateWaypoints(
                from: places,
                origin: location,
                idealWaypointDistance: idealSegmentDistance,
                difficulty: difficulty,
                targetDurationMinutes: targetDurationMinutes
            )
            
            // TIME-BASED PRE-FILTER: Remove candidates whose one-way time exceeds half target + 1 min
            // This prevents attempting routes that are clearly too long
            let maxOneWayForLoop = (targetDurationMinutes / 2) + 1
            let timeFilteredCandidates = candidatesForCount.filter { poi in
                // Check cached time first
                if let cached = getCachedLegTime(from: location, to: poi) {
                    if cached.minutes > maxOneWayForLoop {
                        return false  // Cached time too long
                    }
                    return true
                }
                // Estimate based on distance
                let dist = distanceBetween(location, poi.coordinate)
                let estimatedMins = Int(dist / Double(adaptiveWalkingSpeed))
                return estimatedMins <= maxOneWayForLoop + 2  // +2 buffer since estimate is rough
            }
            
            if timeFilteredCandidates.count < candidatesForCount.count {
                print("🎯 ⏱️ Time filter: \(candidatesForCount.count) → \(timeFilteredCandidates.count) candidates (max one-way: \(maxOneWayForLoop)min)")
                candidatesForCount = timeFilteredCandidates
            }
            
            // DIRECTIONAL PREFERENCE: If a direction is specified, prefer POIs in that quadrant
            if let direction = preferredDirection {
                let directedCandidates = candidatesForCount.filter { poi in
                    let angle = bearingBetween(location, poi.coordinate)
                    return direction.contains(angle: angle)
                }
                
                if directedCandidates.count >= waypointCount {
                    candidatesForCount = directedCandidates
                    print("🧭 Filtered to \(directedCandidates.count) POIs in \(direction) direction")
                } else {
                    print("🧭 Not enough POIs in \(direction) direction (\(directedCandidates.count)), using all candidates")
                }
            }
            
            print("🗺️ --- Trying \(waypointCount) waypoint(s) (ideal segment: \(idealSegmentDistance)m) ---")
            
            guard candidatesForCount.count >= waypointCount else {
                print("🗺️ Not enough candidates (\(candidatesForCount.count)) for \(waypointCount) waypoints")
                continue
            }
            
            // Try multiple combinations with this waypoint count
            // Quick mode: just try 1 combination for speed
            let combinationsToTry = quickMode ? 1 : min(8, candidatesForCount.count)
            var triedCombinations = Set<String>()
            
            for comboIndex in 0..<combinationsToTry {
                guard totalAttempts < maxTotalAttempts else { break }
                
                var selectedWaypoints: [PlaceResult] = []
                
                if comboIndex == 0 {
                    // FIRST ATTEMPT: Select angularly diverse waypoints for better loops
                    selectedWaypoints = selectAngularlyDiverseWaypoints(
                        from: candidatesForCount,
                        origin: location,
                        count: waypointCount
                    )
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
                do {
                    if let route = try await tryRouteAndEvaluate(
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
                        // If route is too long, break and try fewer waypoints
                        if routeMins > maxAcceptableMinutes + 5 {
                            print("🗺️ Route too long (\(routeMins)min vs max \(maxAcceptableMinutes)min), breaking to try fewer waypoints...")
                            break  // Exit this waypoint count loop, try fewer waypoints
                        }
                    }
                } catch GoogleMapsError.rateLimited(let waitTime) {
                    // Rate limited - wait for cooldown then return best route so far
                    print("🚫 Rate limited! Waiting \(waitTime) seconds before continuing...")
                    
                    // Return best valid route if we have one
                    if !validRoutes.isEmpty {
                        let best = validRoutes.max(by: { $0.places.count < $1.places.count })!
                        print("🗺️ ⚠️ Returning best route found before rate limit: \(best.durationSeconds/60)min, \(best.places.count) POIs")
                        return best
                    }
                    
                    // Return fallback if we have one
                    if let fallback = bestFallbackRoute {
                        print("🗺️ ⚠️ Returning fallback route before rate limit: \(fallback.durationSeconds/60)min, \(fallback.places.count) POIs")
                        return fallback
                    }
                    
                    // No routes found yet - propagate the error
                    throw GoogleMapsError.rateLimited(timeUntilReset: waitTime)
                } catch {
                    // Other errors - just continue trying
                    print("🗺️ Route generation error: \(error.localizedDescription)")
                }
            }
            print("🗺️ 🔄 END of waypointCount=\(waypointCount) loop, totalAttempts=\(totalAttempts)")
        }
        print("🗺️ 🏁 OUTER LOOP COMPLETE. validRoutes=\(validRoutes.count), hasFallback=\(bestFallbackRoute != nil)")
        
        // Return best valid route (50-100% of target, never exceeds)
        // PRIORITY: 1) Most waypoints  2) Less backtracking  3) Closest to target time
        if !validRoutes.isEmpty {
            // Calculate composite scores for all valid routes
            // Includes backtracking score AND soft cap overrun penalty
            let routesWithScores = validRoutes.map { route -> (route: GeneratedRoute, backtrackScore: Double, overrunPenalty: Double) in
                let backtrack = calculateBacktrackingScore(polyline: route.polyline)
                
                // SOFT CAP OVERRUN PENALTY: Routes >115% get penalized
                // 115% is "this better be really good" threshold
                // 130% loses 7.5 points, 150% loses 17.5 points
                let accuracy = Double(route.durationSeconds / 60) / Double(targetDurationMinutes)
                var overrunPenalty = 0.0
                if accuracy > 1.15 {
                    overrunPenalty = (accuracy - 1.15) * 50  // Steep penalty after 115%
                }
                
                return (route, backtrack, overrunPenalty)
            }
            
            // Sort by: least overrun penalty, then most waypoints, then least backtracking, then closest to target
            let sorted = routesWithScores.sorted { r1, r2 in
                // FIRST: Lower overrun penalty is better (kills 150%+ routes)
                if abs(r1.overrunPenalty - r2.overrunPenalty) > 1.0 {
                    return r1.overrunPenalty < r2.overrunPenalty
                }
                // Second: more waypoints is better
                if r1.route.places.count != r2.route.places.count {
                    return r1.route.places.count > r2.route.places.count
                }
                // Third: less backtracking is better (lower score = more loop-like)
                if abs(r1.backtrackScore - r2.backtrackScore) > 0.1 {
                    return r1.backtrackScore < r2.backtrackScore
                }
                // Fourth: closer to target is better
                let diff1 = abs(targetDurationMinutes - r1.route.durationSeconds / 60)
                let diff2 = abs(targetDurationMinutes - r2.route.durationSeconds / 60)
                return diff1 < diff2  // Prefer routes closer to target
            }
            
            var selected = sorted.first!.route
            let selectedScore = sorted.first!.backtrackScore
            print("🗺️ Route backtracking score: \(String(format: "%.0f", selectedScore * 100))% (lower = more loop-like)")
            
            // Remove waypoints that are too close together (should be ~5 min / 300m+ apart)
            selected = removeCloseWaypoints(from: selected, minDistance: 250)
            
            let finalMins = selected.durationSeconds / 60
            print("🗺️ ✓ SUCCESS! Selected: \(finalMins)min, \(selected.places.count) POIs (target: \(targetDurationMinutes)min)")
            
            // Mark POIs as recently used for variety in future routes
            for place in selected.places {
                markPOIAsUsed(place.placeId)
            }
            
            return selected
        }
        
        // Return BEST fallback route we found - better to show something than nothing
        if var best = bestFallbackRoute {
            let mins = best.durationSeconds / 60
            
                // Remove waypoints that are too close together (should be ~5 min / 300m+ apart)
                best = removeCloseWaypoints(from: best, minDistance: 250)
            
            // Check if route is within 80-100% tolerance
            let toleranceMin = Int(Double(targetDurationMinutes) * 0.80)
            let toleranceMax = targetDurationMinutes
            let isWithinTolerance = mins >= toleranceMin && mins <= toleranceMax
            
            if isWithinTolerance {
                print("🗺️ ✓ Fallback route within 80-100%: \(mins)min (target: \(targetDurationMinutes)min)")
            } else if mins < toleranceMin {
                print("🗺️ ⚠️ Returning shorter route: \(mins)min (target: \(targetDurationMinutes)min)")
            } else {
                print("🗺️ ⚠️ Returning longer route: \(mins)min (target: \(targetDurationMinutes)min)")
            }
            
            // Mark POIs as recently used for variety
            for place in best.places {
                markPOIAsUsed(place.placeId)
            }
            
            // Note: Google fallback is handled separately in generateLocalRouteWithGoogleFallback
            // This function just returns the best MapKit route
            return best
        }
        
        // GUARANTEED FALLBACK: Create a simple out-and-back route if all else fails
        // This ensures we ALWAYS return something rather than leaving the user waiting
        print("🗺️ 🆘 Creating guaranteed fallback route...")
        print("🗺️ 🆘 Available POIs for fallback: \(places.count)")
        if places.count < 5 {
            print("🗺️ 🆘 Available POI names: \(places.prefix(5).map { $0.name }.joined(separator: ", "))")
        }
        if let guaranteedRoute = try? await createGuaranteedFallbackRoute(
            from: location,
            targetDurationMinutes: targetDurationMinutes,
            availablePOIs: places
        ) {
            let mins = guaranteedRoute.durationSeconds / 60
            print("🗺️ ✓ Guaranteed fallback created: \(mins)min (target: \(targetDurationMinutes)min)")
            
            // Mark POIs as recently used for variety
            for place in guaranteedRoute.places {
                markPOIAsUsed(place.placeId)
            }
            
            return guaranteedRoute
        }
        
        throw GoogleMapsError.noRouteFound
    }
    
    /// Creates a guaranteed simple route when complex generation fails
    /// Uses the closest POI at roughly half the target walking distance
    private func createGuaranteedFallbackRoute(
        from origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        availablePOIs: [PlaceResult]
    ) async throws -> GeneratedRoute? {
        guard !availablePOIs.isEmpty else {
            print("🗺️ 🆘 No POIs available for fallback")
            return nil
        }
        
        // Target distance: half the walking distance (out and back)
        // Walking ~80m/min, so 20min = 1600m total = 800m out
        let targetOutDistance = Double(targetDurationMinutes) * 80.0 / 2.0
        
        print("🗺️ 🆘 Looking for POI ~\(Int(targetOutDistance))m away for out-and-back")
        
        // Find POI closest to target distance
        let poisWithDistance = availablePOIs.map { poi -> (poi: PlaceResult, distance: Double, diff: Double) in
            let dist = distanceBetween(origin, poi.coordinate)
            let diff = abs(dist - targetOutDistance)
            return (poi, dist, diff)
        }
        
        let sorted = poisWithDistance.sorted { $0.diff < $1.diff }
        
        // Try POIs in order of how close they are to ideal distance
        for candidate in sorted.prefix(5) {
            let poi = candidate.poi
            let poiDist = candidate.distance
            
            // Skip if too close (need some walking distance)
            if poiDist < 50 {
                continue
            }
            
            print("🗺️ 🆘 Trying \(poi.name) at \(Int(poiDist))m...")
            
            do {
                // Get actual route directions (simple out-and-back: origin → POI → origin)
                let directions = try await getWalkingDirections(
                    origin: origin,
                    destination: origin,
                    waypoints: [poi.coordinate]
                )
                
                // Calculate total duration from legs
                let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let durationMinutes = totalDuration / 60
                
                // Accept if within 40-160% of target (very flexible for fallback)
                let minAccept = max(2, targetDurationMinutes * 4 / 10)  // 40%
                let maxAccept = targetDurationMinutes * 16 / 10  // 160%
                
                if durationMinutes >= minAccept && durationMinutes <= maxAccept {
                    print("🗺️ 🆘 ✓ Found viable out-and-back: \(durationMinutes)min")
                    
                    return GeneratedRoute(
                        places: [poi],
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: totalDistance,
                        durationSeconds: totalDuration,
                        legs: directions.legs
                    )
                } else {
                    print("🗺️ 🆘 ✗ \(poi.name): \(durationMinutes)min not in \(minAccept)-\(maxAccept)min range")
                }
            } catch {
                print("🗺️ 🆘 ✗ Route to \(poi.name) failed: \(error.localizedDescription)")
                continue
            }
        }
        
        // Last resort: return a reachable POI but cap at 130% of target
        // Tightened from 150% to reduce outliers
        let absoluteMaxDuration = targetDurationMinutes * 130 / 100  // 130% cap
        var bestLastResort: GeneratedRoute? = nil
        var bestLastResortDiff = Int.max
        
        for candidate in sorted.prefix(10) {
            let poi = candidate.poi
            print("🗺️ 🆘 Last resort: trying \(poi.name)")
            
            do {
                let directions = try await getWalkingDirections(
                    origin: origin,
                    destination: origin,
                    waypoints: [poi.coordinate]
                )
                
                let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let durationMinutes = totalDuration / 60
                
                // Skip if over 150% of target - never return absurdly long routes
                if durationMinutes > absoluteMaxDuration {
                    print("🗺️ 🆘 ✗ \(poi.name): \(durationMinutes)min exceeds \(absoluteMaxDuration)min cap")
                    continue
                }
                
                let diff = abs(durationMinutes - targetDurationMinutes)
                print("🗺️ 🆘 ✓ \(poi.name): \(durationMinutes)min (diff: \(diff)min)")
                
                // Keep the one closest to target
                if diff < bestLastResortDiff {
                    bestLastResortDiff = diff
                    bestLastResort = GeneratedRoute(
                        places: [poi],
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: totalDistance,
                        durationSeconds: totalDuration,
                        legs: directions.legs
                    )
                }
            } catch {
                continue  // Try next POI
            }
        }
        
        if let route = bestLastResort {
            print("🗺️ 🆘 ✓ Best last resort: \(route.durationSeconds/60)min")
            return route
        }
        
        return nil
    }
    
    /// Calculate how much a route backtracks on itself (0.0 = perfect loop, 1.0 = complete out-and-back)
    /// Compares outbound path to return path - if they overlap significantly, score is high
    private func calculateBacktrackingScore(polyline: String) -> Double {
        let points = decodePolyline(polyline)
        guard points.count >= 4 else { return 0.5 }  // Not enough points to analyze
        
        // Split route at midpoint
        let midIndex = points.count / 2
        let outbound = Array(points.prefix(midIndex))
        let returnPath = Array(points.suffix(from: midIndex))
        
        guard !outbound.isEmpty && !returnPath.isEmpty else { return 0.5 }
        
        // Sample points from return path and check how close they are to outbound path
        let sampleCount = min(10, returnPath.count)
        let sampleInterval = max(1, returnPath.count / sampleCount)
        
        var closePointCount = 0
        let closeThresholdMeters: Double = 30  // Points within 30m are considered "same path"
        
        for i in stride(from: 0, to: returnPath.count, by: sampleInterval) {
            let returnPoint = returnPath[i]
            
            // Check if this return point is close to any outbound point
            let isCloseToOutbound = outbound.contains { outboundPoint in
                distanceBetween(outboundPoint, returnPoint) < closeThresholdMeters
            }
            
            if isCloseToOutbound {
                closePointCount += 1
            }
        }
        
        let sampledPoints = (returnPath.count + sampleInterval - 1) / sampleInterval
        let backtrackRatio = Double(closePointCount) / Double(max(1, sampledPoints))
        
        return backtrackRatio  // 0.0 = no overlap (good loop), 1.0 = full overlap (out-and-back)
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
    ) async throws -> GeneratedRoute? {
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
            let decodedCount = decodePolyline(polylinePoints).count
            
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
                
                // TRIM FARTHEST WAYPOINT: If route too long and has 2+ waypoints, try trimming
                if totalDuration > maxAcceptable && orderedWaypoints.count > 1 {
                    print("🗺️ ✂️ Route too long, trying to trim farthest waypoint...")
                    
                    // Find farthest waypoint from origin
                    if let farthestIndex = orderedWaypoints.enumerated().max(by: { 
                        distanceBetween(origin, $0.element.coordinate) < distanceBetween(origin, $1.element.coordinate)
                    })?.offset {
                        let farthestPOI = orderedWaypoints[farthestIndex]
                        print("🗺️ ✂️ Removing '\(farthestPOI.name)' (farthest at \(Int(distanceBetween(origin, farthestPOI.coordinate)))m)")
                        
                        var trimmedWaypoints = orderedWaypoints
                        trimmedWaypoints.remove(at: farthestIndex)
                        
                        // Recalculate route with trimmed waypoints
                        if let trimmedDirections = try? await getWalkingDirections(
                            origin: origin,
                            destination: origin,
                            waypoints: trimmedWaypoints.map { $0.coordinate }
                        ) {
                            let trimmedDuration = trimmedDirections.legs.reduce(0) { $0 + $1.duration.value }
                            let trimmedDistance = trimmedDirections.legs.reduce(0) { $0 + $1.distance.value }
                            let trimmedMins = trimmedDuration / 60
                            
                            if trimmedDuration >= minAcceptable && trimmedDuration <= maxAcceptable {
                                print("🗺️ ✂️ ✅ Trimmed route is valid: \(trimmedMins)min (was \(durationMin)min)")
                                
                                let trimmedRoute = GeneratedRoute(
                                    places: trimmedWaypoints,
                                    polyline: trimmedDirections.overviewPolyline.points,
                                    distanceMeters: trimmedDistance,
                                    durationSeconds: trimmedDuration,
                                    legs: trimmedDirections.legs
                                )
                                validRoutes.append(trimmedRoute)
                                return trimmedRoute
                            } else {
                                print("🗺️ ✂️ ✗ Trimmed route still outside tolerance: \(trimmedMins)min")
                            }
                        }
                    }
                }
            }
            
            // Track best fallback - save ANY route as fallback, preferring closest to target
            // This ensures we always have SOMETHING to show rather than leaving user waiting
            let shouldUpdate = bestFallback == nil || diff < bestFallbackDiff
                
                if shouldUpdate {
                    bestFallbackDiff = diff
                    bestFallback = route
                print("🗺️ 📌 Best fallback so far: \(durationMin)min (diff: \(diff)min)")
            }
            
            return route
        } catch let error as GoogleMapsError {
            // Propagate rate limit errors so caller can handle them
            if case .rateLimited = error {
                throw error
            }
            print("🗺️ Route failed: \(error.localizedDescription)")
            return nil
        } catch {
            print("🗺️ Route failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Select candidate waypoints sorted by preference
    /// Difficulty affects order: easy prefers closer, hard prefers further (within reasonable range)
    /// Uses ELASTIC windows: expands range if not enough candidates found
    /// Now includes walkability scoring and recent-use penalty
    private func selectCandidateWaypoints(from places: [PlaceResult], origin: CLLocationCoordinate2D, idealWaypointDistance: Int, difficulty: RouteDifficulty?, targetDurationMinutes: Int = 20, minRequired: Int = 3) -> [PlaceResult] {
        let idealDistance = Double(idealWaypointDistance)
        
        // Excluded types
        let excludedTypes = Set(["transit_station", "locality", "political", "sublocality"])
        
        // ELASTIC WINDOWS: Start with default range, expand if needed
        var expansionFactor: Double = 1.0
        let maxExpansions = 3  // Up to 3x expansion
        var filtered: [PlaceResult] = []
        var minDistance: Double = 0
        var maxDistance: Double = 0
        
        for attempt in 0..<maxExpansions {
            // Calculate range with current expansion
            minDistance = max(50, idealDistance * 0.3 / expansionFactor)  // Shrink min
            maxDistance = max(400, idealDistance * 2.5 * expansionFactor)  // Grow max
            
            if attempt == 0 {
                print("🎯 Candidate selection: ideal=\(Int(idealDistance))m, range=\(Int(minDistance))-\(Int(maxDistance))m")
            } else {
                print("🎯 📈 ELASTIC EXPANSION \(attempt): range=\(Int(minDistance))-\(Int(maxDistance))m (factor: \(expansionFactor)x)")
            }
        
        // Filter places within acceptable range
            var tooClose: [(String, Int)] = []
            var tooFar: [(String, Int)] = []
            
            filtered = places.filter { place in
            let distance = distanceBetween(origin, place.coordinate)
            let types = Set(place.types ?? [])
            let hasExcludedType = !types.isDisjoint(with: excludedTypes)
                
                if hasExcludedType { return false }
                if distance < minDistance {
                    tooClose.append((place.name, Int(distance)))
                    return false
                }
                if distance > maxDistance {
                    tooFar.append((place.name, Int(distance)))
                    return false
                }
                return true
            }
            
            // Log what was filtered out (only on first attempt)
            if attempt == 0 {
                if !tooClose.isEmpty {
                    print("🎯 ❌ Too close (<\(Int(minDistance))m): \(tooClose.prefix(5).map { "\($0.0) (\($0.1)m)" }.joined(separator: ", "))")
                }
                if !tooFar.isEmpty {
                    print("🎯 ❌ Too far (>\(Int(maxDistance))m): \(tooFar.prefix(5).map { "\($0.0) (\($0.1)m)" }.joined(separator: ", "))")
                }
            }
            
            // Check if we have enough candidates
            if filtered.count >= minRequired {
                print("🎯 ✓ \(filtered.count) candidates in range")
                break
            } else {
                print("🎯 ⚠️ Only \(filtered.count) candidates (need \(minRequired)) - expanding range...")
                expansionFactor *= 1.5  // 1x → 1.5x → 2.25x
            }
        }
        
        // Final fallback: if still not enough, include "too far" POIs
        if filtered.count < minRequired {
            print("🎯 🆘 FALLBACK: Including all non-excluded POIs")
            filtered = places.filter { place in
                let types = Set(place.types ?? [])
                return types.isDisjoint(with: excludedTypes)
            }
            print("🎯 ✓ \(filtered.count) candidates after fallback")
        }
        
        // Calculate bearing (angle) from origin for each POI
        let placesWithAngles = filtered.map { place -> (place: PlaceResult, distance: Double, angle: Double) in
            let distance = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            return (place, distance, angle)
        }
        
        // Sort based on difficulty preference, but also consider angular diversity
        let sorted: [PlaceResult]
        switch difficulty {
        case .easy:
            // Easy: prefer closer POIs
            sorted = placesWithAngles.sorted { p1, p2 in
                let score1 = p1.distance < idealDistance * 0.5 ? p1.distance + 100 : p1.distance
                let score2 = p2.distance < idealDistance * 0.5 ? p2.distance + 100 : p2.distance
                return score1 < score2
            }.map { $0.place }
            print("🗺️ Sorting: EASY - preferring closer POIs")
            
        case .challenging:
            // Hard: prefer further POIs
            sorted = placesWithAngles.sorted { $0.distance > $1.distance }.map { $0.place }
            print("🗺️ Sorting: HARD - preferring further POIs")
            
        case .moderate, .none:
            // Moderate/None: Use combined scoring with walkability + angular diversity
            // Score each POI: distance fit + walkability bonus - recent use penalty
            let scoredPOIs = placesWithAngles.map { item -> (place: PlaceResult, score: Double, angle: Double) in
                let combinedScore = calculatePOIScore(
                    poi: item.place,
                    origin: origin,
                    idealDistance: idealDistance,
                    targetDurationMinutes: targetDurationMinutes
                )
                return (item.place, combinedScore, item.angle)
            }
            
            // Group by 8 sectors for angular diversity
            var sectors: [[(place: PlaceResult, score: Double)]] = Array(repeating: [], count: 8)
            for item in scoredPOIs {
                let sectorIndex = Int((item.angle + 180) / 45) % 8
                sectors[sectorIndex].append((item.place, item.score))
            }
            
            // Pick BEST SCORED POI from each sector (not just closest)
            var diverseSelection: [PlaceResult] = []
            for sector in sectors {
                if let best = sector.max(by: { $0.score < $1.score }) {
                    diverseSelection.append(best.place)
                }
            }
            
            // Then add remaining POIs sorted by score
            let diverseIds = Set(diverseSelection.map { $0.placeId })
            let remaining = scoredPOIs
                .filter { !diverseIds.contains($0.place.placeId) }
                .sorted { $0.score > $1.score }
                .map { $0.place }
            
            sorted = diverseSelection + remaining
            
            // Log top picks with their scores
            let topPicks = scoredPOIs.sorted { $0.score > $1.score }.prefix(3)
            let pickLog = topPicks.map { "\($0.place.name) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
            print("🗺️ Sorting: SMART - walkability + variety scoring (\(diverseSelection.count) sectors)")
            print("🗺️ Top picks: \(pickLog)")
        }
        
        print("🗺️ Candidate waypoints: \(sorted.count) (ideal: \(Int(idealDistance))m, range: \(Int(minDistance))-\(Int(maxDistance))m)")
        for (i, place) in sorted.prefix(5).enumerated() {
            let dist = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            print("🗺️   \(i+1). '\(place.name)' at \(Int(dist))m, \(Int(angle))°")
        }
        
        return sorted
    }
    
    /// Calculate bearing (angle) from one coordinate to another in degrees (-180 to 180)
    private func bearingBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let lat1 = c1.latitude * .pi / 180
        let lat2 = c2.latitude * .pi / 180
        let dLon = (c2.longitude - c1.longitude) * .pi / 180
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        
        let bearing = atan2(y, x) * 180 / .pi
        return bearing  // -180 to 180 degrees
    }
    
    /// Select waypoints that are angularly spread around the origin to form better loops
    /// This avoids selecting multiple POIs in the same direction (which causes backtracking)
    private func selectAngularlyDiverseWaypoints(from places: [PlaceResult], origin: CLLocationCoordinate2D, count: Int) -> [PlaceResult] {
        guard count > 0, !places.isEmpty else { return [] }
        guard count > 1 else { return Array(places.prefix(1)) }  // Single waypoint - just use first
        
        // Calculate angle for each place
        let placesWithAngles = places.map { place -> (place: PlaceResult, angle: Double) in
            let angle = bearingBetween(origin, place.coordinate)
            return (place, angle)
        }
        
        // Target angular spread for N waypoints: 360/N degrees apart
        let targetSpread = 360.0 / Double(count)
        let minAngularDistance = targetSpread * 0.4  // At least 40% of ideal spread
        
        var selected: [PlaceResult] = []
        var selectedAngles: [Double] = []
        
        for (place, angle) in placesWithAngles {
            // Check if this angle is far enough from already selected angles
            let isAngularlyDistinct = selectedAngles.allSatisfy { existingAngle in
                let diff = abs(angle - existingAngle)
                let angularDistance = min(diff, 360 - diff)  // Handle wrap-around
                return angularDistance >= minAngularDistance
            }
            
            if isAngularlyDistinct || selected.isEmpty {
                selected.append(place)
                selectedAngles.append(angle)
                
                if selected.count >= count {
                    break
                }
            }
        }
        
        // If we couldn't find enough angularly diverse POIs, fill with remaining
        if selected.count < count {
            let selectedIds = Set(selected.map { $0.placeId })
            for place in places where !selectedIds.contains(place.placeId) {
                selected.append(place)
                if selected.count >= count {
                    break
                }
            }
        }
        
        if selected.count > 1 {
            let angles = selected.map { Int(bearingBetween(origin, $0.coordinate)) }
            print("🗺️ Selected \(selected.count) angularly diverse waypoints: \(angles)°")
        }
        
        return selected
    }
    
    /// Add additional discovery spots along the route polyline without affecting timing
    /// These are display-only POIs that weren't used in the Directions API call
    private func addDiscoverySpotsAlongRoute(
        route: GeneratedRoute,
        allPlaces: [PlaceResult],
        desiredCount: Int,
        origin: CLLocationCoordinate2D
    ) async -> GeneratedRoute {
        let routePath = decodePolyline(route.polyline)
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
    
    /// Decode a Google Maps encoded polyline string into coordinates
    private func decodePolyline(_ encodedPath: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encodedPath.startIndex
        var lat: Int32 = 0
        var lng: Int32 = 0
        
        while index < encodedPath.endIndex {
            // Decode latitude
            var shift: Int32 = 0
            var result: Int32 = 0
            var byte: Int32
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += deltaLat
            
            // Decode longitude
            shift = 0
            result = 0
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += deltaLng
            
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            )
            coordinates.append(coordinate)
        }
        
        return coordinates
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
    
    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }
    
    // MARK: - Google Directions API Fallback (PAID - Use Sparingly!)
    
    /// Uses Google Directions API as fallback when MapKit route is outside tolerance
    /// This is a PAID API - only use when MapKit fails to find acceptable route
    /// Returns nil if Google also fails or API key is missing
    func getGoogleDirectionsRoute(
        origin: CLLocationCoordinate2D,
        waypoints: [PlaceResult],
        targetDurationMinutes: Int
    ) async -> GeneratedRoute? {
        guard !apiKey.isEmpty else {
            print("🌐 Google Directions: No API key available")
            return nil
        }
        
        print("🌐 Google Directions: Attempting fallback route (PAID API)...")
        
        // Build waypoints string for Google API using coordinate property
        let waypointCoords = waypoints.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }
        let waypointsParam = waypointCoords.joined(separator: "|")
        
        // Google Directions API URL
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(origin.latitude),\(origin.longitude)"
        urlString += "&destination=\(origin.latitude),\(origin.longitude)"  // Round trip
        urlString += "&waypoints=optimize:true|\(waypointsParam)"
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            print("🌐 Google Directions: Invalid URL")
            return nil
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🌐 Google Directions: HTTP error")
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "OK",
                  let routes = json["routes"] as? [[String: Any]],
                  let firstRoute = routes.first,
                  let legs = firstRoute["legs"] as? [[String: Any]],
                  let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
                  let polylinePoints = overviewPolyline["points"] as? String else {
                let errorStatus = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String ?? "unknown"
                print("🌐 Google Directions: Failed - status: \(errorStatus)")
                return nil
            }
            
            // Calculate total distance and duration
            var totalDistance = 0
            var totalDuration = 0
            var directionsLegs: [DirectionsLeg] = []
            
            for leg in legs {
                guard let distance = leg["distance"] as? [String: Any],
                      let distanceValue = distance["value"] as? Int,
                      let distanceText = distance["text"] as? String,
                      let duration = leg["duration"] as? [String: Any],
                      let durationValue = duration["value"] as? Int,
                      let durationText = duration["text"] as? String else {
                    continue
                }
                
                totalDistance += distanceValue
                totalDuration += durationValue
                
                // Extract steps for directions
                var steps: [DirectionsStep] = []
                if let stepsData = leg["steps"] as? [[String: Any]] {
                    for step in stepsData {
                        let instruction = step["html_instructions"] as? String
                        let stepDistanceVal = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                        let stepDistanceText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                        let stepDurationVal = (step["duration"] as? [String: Any])?["value"] as? Int ?? 0
                        let stepDurationText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                        let stepPolyline = (step["polyline"] as? [String: Any])?["points"] as? String
                        
                        steps.append(DirectionsStep(
                            distance: DirectionsValue(text: stepDistanceText, value: stepDistanceVal),
                            duration: DirectionsValue(text: stepDurationText, value: stepDurationVal),
                            htmlInstructions: instruction,
                            polyline: stepPolyline != nil ? StepPolyline(points: stepPolyline!) : nil
                        ))
                    }
                }
                
                let startAddress = leg["start_address"] as? String
                let endAddress = leg["end_address"] as? String
                
                directionsLegs.append(DirectionsLeg(
                    distance: DirectionsValue(text: distanceText, value: distanceValue),
                    duration: DirectionsValue(text: durationText, value: durationValue),
                    startAddress: startAddress,
                    endAddress: endAddress,
                    steps: steps
                ))
            }
            
            let durationMinutes = totalDuration / 60
            let targetMin = Int(Double(targetDurationMinutes) * 0.80)
            let targetMax = targetDurationMinutes
            
            print("🌐 Google Directions: Route found - \(durationMinutes)min, \(totalDistance)m")
            
            // Check if Google route is within 80-100% tolerance
            if durationMinutes >= targetMin && durationMinutes <= targetMax {
                print("🌐 ✓ Google route within tolerance (80-100%): \(durationMinutes)min")
            } else {
                print("🌐 ⚠️ Google route outside tolerance: \(durationMinutes)min (target: \(targetMin)-\(targetMax)min)")
            }
            
            // Get optimized waypoint order from Google
            var orderedPlaces = waypoints
            if let waypointOrder = firstRoute["waypoint_order"] as? [Int] {
                orderedPlaces = waypointOrder.map { waypoints[$0] }
                print("🌐 Google optimized waypoint order: \(waypointOrder)")
            }
            
            return GeneratedRoute(
                places: orderedPlaces,
                polyline: polylinePoints,
                distanceMeters: totalDistance,
                durationSeconds: totalDuration,
                legs: directionsLegs
            )
            
        } catch {
            print("🌐 Google Directions: Error - \(error.localizedDescription)")
            return nil
        }
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
    case rateLimited(timeUntilReset: Int)  // MapKit rate limit hit
    
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
        case .rateLimited(let seconds):
            return "Rate limited, please wait \(seconds) seconds"
        }
    }
}

// MARK: - API Response Models

// Legacy Places API Response (kept for backwards compatibility)
struct PlacesResponse: Codable {
    let status: String
    let results: [PlaceResult]
}

// New Places API Response (Essentials tier - much cheaper!)
struct NewPlacesResponse: Codable {
    let places: [NewPlace]?
}

struct NewPlace: Codable {
    let id: String?
    let displayName: DisplayName?
    let location: NewPlaceLocation?
    let formattedAddress: String?
    let types: [String]?
}

struct DisplayName: Codable {
    let text: String?
    let languageCode: String?
}

struct NewPlaceLocation: Codable {
    let latitude: Double?
    let longitude: Double?
}

struct PlaceResult: Codable, Identifiable {
    let placeId: String
    let name: String
    let vicinity: String?
    let geometry: PlaceGeometry
    let types: [String]?
    
    var id: String { placeId }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: geometry.location.lat,
            longitude: geometry.location.lng
        )
    }
    
    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, vicinity, geometry, types
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
    
    // v1.6.10: Low POI warning - shown when route options are limited
    var hasLimitedPOIs: Bool = false
    var poiCount: Int = 0
    
    // Threshold for "limited" POIs (below this, variety is reduced)
    static let limitedPOIThreshold = 50
    
    var limitedPOIWarning: String? {
        guard hasLimitedPOIs else { return nil }
        return "Limited route options in this area. Try again later for more variety."
    }
    
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


