//
//  RoutePreGenService.swift
//  WalkingWR
//
//  Pre-generates routes as soon as POIs are available, using all clinicians'
//  delay times (e.g. Park 30min→25min, MacLeod 55min→50min).
//  When a clinician is selected, focusOnDuration() reprioritises the queue.
//

import Foundation
import CoreLocation
import SwiftUI

@MainActor
final class RoutePreGenService: ObservableObject {
    static let shared = RoutePreGenService()

    // MARK: - Published state (observable by views if needed)
    @Published private(set) var isPreGenerating = false
    @Published private(set) var completedDurations: Set<Int> = []

    // MARK: - Internal state
    private var preGenTask: Task<Void, Never>?
    private(set) var preGeneratedAtLocation: CLLocationCoordinate2D?
    private var focusedDuration: Int?

    /// MapKit quota cap for background pre-gen (lower than the 30 used at Generate-tap time)
    private let mapKitQuotaCap = 20

    private let tag = "[PRE-GEN-SVC]"

    private init() {}

    // MARK: - Public API

    /// Start pre-generating routes for every unique clinician duration.
    /// Safe to call multiple times — guards against duplicate runs.
    func startPreGenForAllClinicians(
        pois: [PlaceResult],
        clinicians: [Clinician],
        location: CLLocationCoordinate2D
    ) {
        guard !isPreGenerating else {
            print("\(tag) Already pre-generating — skipping")
            return
        }
        guard pois.count >= 15 else {
            print("\(tag) Only \(pois.count) POIs — need ≥15, skipping")
            return
        }
        // Need at least one clinician with a delay > 0
        let activeClinicians = clinicians.filter { $0.currentWaitMinutes > 0 }
        guard !activeClinicians.isEmpty else {
            print("\(tag) No clinicians with active delay — skipping")
            return
        }

        // Build unique durations from all clinician delays
        var durationSet = Set<Int>()
        for clinician in activeClinicians {
            let rec = Self.recommendedDuration(forDelay: clinician.currentWaitMinutes)
            durationSet.insert(rec)
        }

        // Sort: focused duration first (if set), then ascending
        let focused = focusedDuration
        let sortedDurations = Array(durationSet).sorted { a, b in
            if let f = focused {
                if a == f { return true }
                if b == f { return false }
            }
            return a < b
        }

        isPreGenerating = true
        completedDurations.removeAll()
        preGeneratedAtLocation = location

        let poisSnapshot = pois
        let coord = location

        print("\(tag) Starting route pre-generation for durations \(sortedDurations) (\(activeClinicians.count) active clinicians)")

        preGenTask = Task {
            let mapsService = GoogleMapsService.shared
            var failedPOIsByDuration: [Int: Set<String>] = [:]
            var didWaitForQuotaRefresh = false

            // MARK: First pass — generate routes for each duration
            for duration in sortedDurations {
                if Task.isCancelled { break }

                // Strategy (ii) + (iii): Wait for MapKit quota refresh, then use free APIs if still capped
                let mapKitCount = await mapsService.currentMapKitRequestCount
                var usesFreeAPIsOnly = false
                if mapKitCount >= mapKitQuotaCap {
                    if !didWaitForQuotaRefresh {
                        didWaitForQuotaRefresh = true
                        print("\(tag) MapKit count \(mapKitCount) >= \(mapKitQuotaCap) — waiting 65s for quota refresh")
                        try? await Task.sleep(nanoseconds: 65_000_000_000)
                        if Task.isCancelled { break }
                        let refreshedCount = await mapsService.currentMapKitRequestCount
                        if refreshedCount >= mapKitQuotaCap {
                            print("\(tag) MapKit still at \(refreshedCount) after wait — will use free APIs only")
                            usesFreeAPIsOnly = true
                        } else {
                            print("\(tag) MapKit quota refreshed to \(refreshedCount) — continuing with MapKit")
                        }
                    } else {
                        usesFreeAPIsOnly = true
                        print("\(tag) MapKit still capped — using free APIs for \(duration)min")
                    }
                }

                // Skip if already cached
                if RouteCacheService.shared.getCachedRoutes(near: coord, durationMinutes: duration, consumeSessionCrossBucket: false) != nil {
                    print("\(tag) Already have cached routes for \(duration)min — skipping")
                    completedDurations.insert(duration)
                    continue
                }

                // Strategy (iii): Force free APIs when MapKit is capped
                if usesFreeAPIsOnly { mapsService.forceSkipMapKit = true }
                defer { mapsService.forceSkipMapKit = false }

                await self.generateAndStoreRoute(
                    duration: duration,
                    coord: coord,
                    poisSnapshot: poisSnapshot,
                    excludePlaceIds: [],
                    excludePOIs: [],
                    focused: focused,
                    sortedDurations: sortedDurations,
                    mapsService: mapsService,
                    failedPOIsByDuration: &failedPOIsByDuration,
                    isRetry: false
                )

                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            // MARK: Retry pass — re-attempt incomplete durations (focused first)
            let incompleteDurations = sortedDurations.filter { !completedDurations.contains($0) }
            if !incompleteDurations.isEmpty && !Task.isCancelled {
                let sortedRetries = incompleteDurations.sorted { a, b in
                    if let f = focused {
                        if a == f { return true }
                        if b == f { return false }
                    }
                    return a < b
                }
                print("\(tag) Retry pass for \(sortedRetries.count) incomplete duration(s): \(sortedRetries) (focused: \(focused ?? -1))")

                for duration in sortedRetries {
                    if Task.isCancelled { break }

                    let mapKitCount = await mapsService.currentMapKitRequestCount
                    if mapKitCount >= mapKitQuotaCap {
                        mapsService.forceSkipMapKit = true
                    }
                    defer { mapsService.forceSkipMapKit = false }

                    let excludeIds = failedPOIsByDuration[duration] ?? []
                    await self.generateAndStoreRoute(
                        duration: duration,
                        coord: coord,
                        poisSnapshot: poisSnapshot,
                        excludePlaceIds: excludeIds,
                        excludePOIs: [],
                        focused: focused,
                        sortedDurations: sortedDurations,
                        mapsService: mapsService,
                        failedPOIsByDuration: &failedPOIsByDuration,
                        isRetry: true
                    )

                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }

            await MainActor.run {
                isPreGenerating = false
                print("\(tag) Complete — pre-generated for durations: \(completedDurations.sorted())")
                let missed = sortedDurations.filter { !completedDurations.contains($0) }
                if !missed.isEmpty {
                    print("\(tag) ⚠️ Still incomplete after retry: \(missed) — live gen will handle at display time")
                }
            }
        }
    }

    /// Prioritise a specific duration (e.g. user selected Dr. MacLeod → 50 min).
    /// If pre-gen is already running for a different duration, cancel and restart
    /// with the focused duration first.
    func focusOnDuration(_ duration: Int, pois: [PlaceResult]? = nil, clinicians: [Clinician]? = nil, location: CLLocationCoordinate2D? = nil) {
        focusedDuration = duration
        print("\(tag) Focus set to \(duration)min")

        // If already completed for this duration, nothing to do
        if completedDurations.contains(duration) {
            print("\(tag) Duration \(duration)min already pre-generated — no restart needed")
            return
        }

        // If we have all the context, restart with priority
        if let pois = pois, let clinicians = clinicians, let loc = location {
            cancelAll()
            startPreGenForAllClinicians(pois: pois, clinicians: clinicians, location: loc)
        } else if isPreGenerating {
            // Cancel current and restart if we have a stored location
            // The caller should provide full context for a proper restart
            print("\(tag) Focus changed but no context to restart — will take effect on next start")
        }
    }

    /// Cancel all in-flight pre-generation.
    func cancelAll() {
        preGenTask?.cancel()
        preGenTask = nil
        isPreGenerating = false
        print("\(tag) Cancelled all pre-generation")
    }

    /// Cancel and clear everything (e.g. user moved significantly).
    func cancelAndClear() {
        cancelAll()
        completedDurations.removeAll()
        preGeneratedAtLocation = nil
        focusedDuration = nil
        print("\(tag) Cleared all pre-gen state (user moved)")
    }

    // MARK: - Route generation + in-band storage

    /// Generate a route for a duration, Google re-measure it, and store it in the correct bucket.
    /// If in-band: session cache for that duration. If out-of-band: cross-bucket pool at actual duration.
    private func generateAndStoreRoute(
        duration: Int,
        coord: CLLocationCoordinate2D,
        poisSnapshot: [PlaceResult],
        excludePlaceIds: Set<String>,
        excludePOIs: [PlaceResult],
        focused: Int?,
        sortedDurations: [Int],
        mapsService: GoogleMapsService,
        failedPOIsByDuration: inout [Int: Set<String>],
        isRetry: Bool
    ) async {
        let passLabel = isRetry ? "RETRY" : "FIRST"

        do {
            let result = try await mapsService.generateRouteTopologySafe(
                from: coord,
                targetDurationMinutes: duration,
                difficulty: nil,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,
                prefetchedPOIs: poisSnapshot
            )

            guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                print("\(tag) [\(passLabel)] Empty result for \(duration)min — skipping")
                return
            }
            if Task.isCancelled { return }

            let filteredResult = mapsService.filterCloseWaypointsSync(from: result, durationMinutes: duration, origin: coord)

            let markers = RouteConversionHelper.markersFromPlaces(filteredResult.places, origin: coord)
            guard !markers.isEmpty else { return }

            var directions = RouteConversionHelper.walkingDirections(from: filteredResult.legs, waypoints: filteredResult.places)
            if directions.isEmpty && !filteredResult.places.isEmpty {
                let waypointCoords = filteredResult.places.map { $0.coordinate }
                let waypointNames = filteredResult.places.map { $0.name }
                directions = await mapsService.getMapKitDirectionsForRoute(
                    origin: coord,
                    waypoints: waypointCoords,
                    destination: coord,
                    waypointNames: waypointNames
                )
            }

            if Task.isCancelled { return }

            let routeDifficulty: RouteDifficulty = filteredResult.durationMinutes <= 10 ? .easy : (filteredResult.durationMinutes <= 20 ? .moderate : .challenging)

            let isFocused = (duration == focused) || (duration == sortedDurations.first)
            let routeName: String
            let routeDescription: String

            if isFocused {
                let waypointInfos = filteredResult.places.map { place in
                    GeminiService.WaypointInfo(name: place.name, types: place.types ?? [], vicinity: place.vicinity)
                }
                let aiContent = await GeminiService.shared.generateRouteContent(
                    waypoints: waypointInfos,
                    durationMinutes: filteredResult.durationMinutes,
                    distanceMeters: filteredResult.distanceMeters,
                    difficulty: routeDifficulty
                )
                routeName = aiContent.name
                routeDescription = aiContent.description
            } else {
                routeName = "\(filteredResult.durationMinutes) min walk"
                routeDescription = "A short walk from start and back."
            }

            var route = WalkingRoute(
                name: routeName,
                description: routeDescription,
                durationMinutes: max(1, filteredResult.durationMinutes),
                distanceMeters: filteredResult.distanceMeters,
                difficulty: routeDifficulty,
                isIndoor: false,
                isAccessible: true,
                landmarks: ["Start"] + filteredResult.places.map { $0.name } + ["Return"],
                icon: "location.fill",
                color: .tealAccent,
                qrMarkers: markers,
                routeType: .local,
                trimmed: filteredResult.polyline,
                walkingDirections: directions,
                usedOSRMRouting: filteredResult.usedOSRM
            )

            if let snappedRoute = await mapsService.refreshRouteWithGoogleOnly(route: route, userLocation: coord) {
                route = snappedRoute
            }
            route = route.withDurationSanityCap(targetDurationMinutes: duration)

            let deduplicatedResult = mapsService.finalizeRouteDedupForView(filteredResult)

            let meta = RouteCacheService.CachedRouteWithMetadata(
                route: deduplicatedResult,
                name: route.name,
                description: route.description,
                directions: directions.isEmpty ? nil : directions,
                isDeadZoneFallback: false,
                isFromPrePopulatedDatabase: false
            )

            // Strategy (i): Check if route is in-band after Google re-measure
            if Self.isRouteInBand(route, targetDuration: duration) {
                RouteCacheService.shared.setSessionRoutes([meta], at: coord, durationMinutes: duration)
                completedDurations.insert(duration)
                print("\(tag) [\(passLabel)] ✅ Stored route for \(duration)min: '\(route.name)' (\(route.durationMinutes)min, \(route.distanceMeters)m)")

                // Generate a second route for the focused duration
                if isFocused && !isRetry && !Task.isCancelled {
                    await self.generateSecondFocusedRoute(
                        duration: duration,
                        coord: coord,
                        poisSnapshot: poisSnapshot,
                        firstResult: result,
                        firstMeta: meta,
                        mapsService: mapsService
                    )
                }
            } else {
                let currentBucket = RouteCacheService.roundToNearest5Minutes(duration)
                RouteCacheService.shared.addToSessionCrossBucket(route: route, data: deduplicatedResult, isFromGoogle: true, currentBucket: currentBucket)
                failedPOIsByDuration[duration, default: []].formUnion(result.places.map { $0.placeId })
                print("\(tag) [\(passLabel)] ⚠️ Pre-gen route for \(duration)min re-measured to \(route.durationMinutes)min (out-of-band) — stored in cross-bucket pool")
            }

        } catch {
            print("\(tag) [\(passLabel)] Error for \(duration)min: \(error.localizedDescription)")
        }
    }

    /// Generate and store a second route for the focused duration (called when first route was in-band).
    private func generateSecondFocusedRoute(
        duration: Int,
        coord: CLLocationCoordinate2D,
        poisSnapshot: [PlaceResult],
        firstResult: GeneratedRoute,
        firstMeta: RouteCacheService.CachedRouteWithMetadata,
        mapsService: GoogleMapsService
    ) async {
        let mapKitCount2 = await mapsService.currentMapKitRequestCount
        if mapKitCount2 >= mapKitQuotaCap {
            mapsService.forceSkipMapKit = true
        }
        defer { mapsService.forceSkipMapKit = false }

        let excludeIds = Set(firstResult.places.map { $0.placeId })
        guard let secondResult = try? await mapsService.generateRouteTopologySafe(
            from: coord,
            targetDurationMinutes: duration,
            difficulty: nil,
            excludePlaceIds: excludeIds,
            excludePOIs: firstResult.places,
            prefetchedPOIs: poisSnapshot
        ), !secondResult.places.isEmpty, secondResult.distanceMeters > 0, secondResult.durationSeconds > 0 else {
            return
        }

        let filteredSecond = mapsService.filterCloseWaypointsSync(from: secondResult, durationMinutes: duration, origin: coord)
        let markers2 = RouteConversionHelper.markersFromPlaces(filteredSecond.places, origin: coord)
        guard !markers2.isEmpty else { return }

        var dirs2 = RouteConversionHelper.walkingDirections(from: filteredSecond.legs, waypoints: filteredSecond.places)
        if dirs2.isEmpty && !filteredSecond.places.isEmpty {
            dirs2 = await mapsService.getMapKitDirectionsForRoute(
                origin: coord,
                waypoints: filteredSecond.places.map { $0.coordinate },
                destination: coord,
                waypointNames: filteredSecond.places.map { $0.name }
            )
        }

        let diff2: RouteDifficulty = filteredSecond.durationMinutes <= 10 ? .easy : (filteredSecond.durationMinutes <= 20 ? .moderate : .challenging)
        let waypointInfos2 = filteredSecond.places.map { place in
            GeminiService.WaypointInfo(name: place.name, types: place.types ?? [], vicinity: place.vicinity)
        }
        let aiContent2 = await GeminiService.shared.generateRouteContent(
            waypoints: waypointInfos2,
            durationMinutes: filteredSecond.durationMinutes,
            distanceMeters: filteredSecond.distanceMeters,
            difficulty: diff2
        )

        var route2 = WalkingRoute(
            name: aiContent2.name,
            description: aiContent2.description,
            durationMinutes: max(1, filteredSecond.durationMinutes),
            distanceMeters: filteredSecond.distanceMeters,
            difficulty: diff2,
            isIndoor: false, isAccessible: true,
            landmarks: ["Start"] + filteredSecond.places.map { $0.name } + ["Return"],
            icon: "location.fill", color: .tealAccent,
            qrMarkers: markers2, routeType: .local,
            trimmed: filteredSecond.polyline,
            walkingDirections: dirs2,
            usedOSRMRouting: filteredSecond.usedOSRM
        )

        if let snapped2 = await mapsService.refreshRouteWithGoogleOnly(route: route2, userLocation: coord) {
            route2 = snapped2
        }
        route2 = route2.withDurationSanityCap(targetDurationMinutes: duration)

        let dedup2 = mapsService.finalizeRouteDedupForView(filteredSecond)
        let meta2 = RouteCacheService.CachedRouteWithMetadata(
            route: dedup2,
            name: route2.name,
            description: route2.description,
            directions: dirs2.isEmpty ? nil : dirs2,
            isDeadZoneFallback: false,
            isFromPrePopulatedDatabase: false
        )

        // Check if 2nd route is also in-band
        if Self.isRouteInBand(route2, targetDuration: duration) {
            RouteCacheService.shared.setSessionRoutes([firstMeta, meta2], at: coord, durationMinutes: duration)
            print("\(tag) ✅ Stored 2nd route for focused \(duration)min: '\(route2.name)' (\(route2.durationMinutes)min)")
        } else {
            // 2nd route out-of-band — keep first route only, send 2nd to cross-bucket
            let currentBucket = RouteCacheService.roundToNearest5Minutes(duration)
            RouteCacheService.shared.addToSessionCrossBucket(route: route2, data: dedup2, isFromGoogle: true, currentBucket: currentBucket)
            print("\(tag) ⚠️ 2nd route for \(duration)min re-measured to \(route2.durationMinutes)min (out-of-band) — cross-bucket; keeping 1st route only")
        }
    }

    // MARK: - Helpers

    /// Compute recommended walk duration from a clinic delay (delay − 5, snapped to presets, min 10).
    /// Supports durations up to 60 min (not capped at 30).
    static func recommendedDuration(forDelay delay: Int) -> Int {
        let availableTime = delay - 5
        let presetOptions = [10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]
        if availableTime < 10 { return 10 }
        if let best = presetOptions.reversed().first(where: { $0 <= availableTime }) {
            return best
        }
        return 10
    }

    // MARK: - In-band check (mirrors RouteSelectionView logic)

    /// True if route is in-band for the target duration: duration within 80–120% (75–125% for edge buckets)
    /// and distance at least 50 m/min implied. Same logic as RouteSelectionView.isRouteInBand.
    static func isRouteInBand(_ route: WalkingRoute, targetDuration: Int) -> Bool {
        let rounded = RouteCacheService.roundToNearest5Minutes(targetDuration)
        let isEdge = rounded <= 10 || rounded >= 55
        let minPct = isEdge ? 0.75 : 0.80
        let maxPct = isEdge ? 1.25 : 1.20
        let minAcc = Int(Double(rounded) * minPct)
        let maxAcc = Int(Double(rounded) * maxPct)
        let durationOk = route.durationMinutes >= minAcc && route.durationMinutes <= maxAcc
        let minDist = max(200, rounded * 50)
        let distanceOk = route.distanceMeters >= minDist
        return durationOk && distanceOk
    }
}
