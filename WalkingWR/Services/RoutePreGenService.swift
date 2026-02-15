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

            for duration in sortedDurations {
                if Task.isCancelled { break }

                let mapKitCount = await mapsService.currentMapKitRequestCount
                if mapKitCount >= mapKitQuotaCap {
                    print("\(tag) MapKit count \(mapKitCount) >= \(mapKitQuotaCap) — stopping to preserve quota")
                    break
                }

                // Skip if already cached
                if RouteCacheService.shared.getCachedRoutes(near: coord, durationMinutes: duration, consumeSessionCrossBucket: false) != nil {
                    print("\(tag) Already have cached routes for \(duration)min — skipping")
                    completedDurations.insert(duration)
                    continue
                }

                do {
                    let result = try await mapsService.generateRouteTopologySafe(
                        from: coord,
                        targetDurationMinutes: duration,
                        difficulty: nil,
                        excludePlaceIds: [],
                        excludePOIs: [],
                        prefetchedPOIs: poisSnapshot
                    )

                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        print("\(tag) Empty result for \(duration)min — skipping")
                        continue
                    }
                    if Task.isCancelled { break }

                    let filteredResult = mapsService.filterCloseWaypointsSync(from: result, durationMinutes: duration, origin: coord)

                    let markers = RouteConversionHelper.markersFromPlaces(filteredResult.places, origin: coord)
                    guard !markers.isEmpty else { continue }

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

                    if Task.isCancelled { break }

                    let routeDifficulty: RouteDifficulty = filteredResult.durationMinutes <= 10 ? .easy : (filteredResult.durationMinutes <= 20 ? .moderate : .challenging)

                    // Use Gemini for the focused/first duration; template for others (saves API calls)
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
                    RouteCacheService.shared.setSessionRoutes([meta], at: coord, durationMinutes: duration)
                    completedDurations.insert(duration)
                    print("\(tag) Stored route for \(duration)min: '\(route.name)' (\(route.durationMinutes)min, \(route.distanceMeters)m)")

                    // Generate a second route for the focused duration
                    if isFocused && !Task.isCancelled {
                        let mapKitCount2 = await mapsService.currentMapKitRequestCount
                        if mapKitCount2 < mapKitQuotaCap {
                            let excludeIds = Set(result.places.map { $0.placeId })
                            if let secondResult = try? await mapsService.generateRouteTopologySafe(
                                from: coord,
                                targetDurationMinutes: duration,
                                difficulty: nil,
                                excludePlaceIds: excludeIds,
                                excludePOIs: result.places,
                                prefetchedPOIs: poisSnapshot
                            ), !secondResult.places.isEmpty, secondResult.distanceMeters > 0, secondResult.durationSeconds > 0 {
                                let filteredSecond = mapsService.filterCloseWaypointsSync(from: secondResult, durationMinutes: duration, origin: coord)
                                let markers2 = RouteConversionHelper.markersFromPlaces(filteredSecond.places, origin: coord)
                                if !markers2.isEmpty {
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
                                    // Gemini name for 2nd route too (so it doesn't show "8 min walk" template)
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
                                    RouteCacheService.shared.setSessionRoutes([meta, meta2], at: coord, durationMinutes: duration)
                                    print("\(tag) Stored 2nd route for focused \(duration)min: '\(route2.name)'")
                                }
                            }
                        }
                    }

                } catch {
                    print("\(tag) Error for \(duration)min: \(error.localizedDescription)")
                }

                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms between durations
            }

            await MainActor.run {
                isPreGenerating = false
                print("\(tag) Complete — pre-generated for durations: \(completedDurations.sorted())")
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
}
