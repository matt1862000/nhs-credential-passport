//
//  RouteConversionHelper.swift
//  WalkingWR
//
//  Shared conversion from GeneratedRoute to WalkingRoute for delay-change route refresh.
//

import Foundation
import SwiftUI
import CoreLocation

enum RouteConversionHelper {

    /// Build a WalkingRoute from a GeneratedRoute (e.g. for delay-change new route). Uses same semantics as RouteSelectionView marker/direction creation.
    static func walkingRoute(
        from generated: GeneratedRoute,
        origin: CLLocationCoordinate2D,
        name: String = "Updated route",
        description: String = "Route updated for new delay"
    ) -> WalkingRoute {
        let markers = markersFromPlaces(generated.places, origin: origin)
        let directions = walkingDirections(from: generated.legs, waypoints: generated.places)
        let difficulty: RouteDifficulty = generated.durationMinutes <= 10 ? .easy : (generated.durationMinutes <= 20 ? .moderate : .challenging)
        return WalkingRoute(
            name: name,
            description: description,
            durationMinutes: max(1, generated.durationMinutes),
            distanceMeters: generated.distanceMeters,
            difficulty: difficulty,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Start"] + generated.places.map { $0.name } + ["Return"],
            icon: "location.fill",
            color: .tealAccent,
            qrMarkers: markers,
            routeType: .local,
            trimmed: generated.polyline,
            walkingDirections: directions,
            usedOSRMRouting: generated.usedOSRM,
            isFromPrePopulatedDatabase: false
        )
    }

    static func markersFromPlaces(_ places: [PlaceResult], origin: CLLocationCoordinate2D) -> [QRMarker] {
        let realPlaces = places.filter { $0.name != "Route Point" && !GoogleMapsService.isJunkPOIName($0.name) }
        return realPlaces.enumerated().map { index, place in
            let content = WellbeingContent.breathingExercises.randomElement() ?? WellbeingContent.breathingExercises[0]
            return QRMarker(
                code: "POI\(index + 1)",
                name: place.displayName,
                location: place.vicinity ?? "Local POI",
                coordinate: place.coordinate,
                contentType: .breathingExercise,
                content: content,
                pointsValue: 20 + (index * 5)
            )
        }
    }

    static func walkingDirections(from legs: [DirectionsLeg], waypoints: [PlaceResult]) -> [WalkingDirection] {
        var directions: [WalkingDirection] = []
        for (legIndex, leg) in legs.enumerated() {
            guard let steps = leg.steps else { continue }
            let isLastLeg = legIndex == legs.count - 1
            let isReturnLeg = legIndex == legs.count - 1 && !waypoints.isEmpty
            for (stepIndex, step) in steps.enumerated() {
                guard let html = step.htmlInstructions else { continue }
                let maneuver = extractManeuver(from: html)
                var direction = WalkingDirection.fromHTML(
                    html,
                    distance: step.distance.text,
                    distanceMeters: step.distance.value,
                    duration: step.duration.text,
                    maneuver: maneuver
                )
                let isLastStepOfLeg = stepIndex == steps.count - 1
                // v2.2: Always replace last step of waypoint leg so Waypoint 1 always appears (API often omits arrival phrasing)
                if isLastStepOfLeg {
                    if isReturnLeg {
                        direction = WalkingDirection(
                            instruction: "Return to starting point",
                            distance: step.distance.text,
                            distanceMeters: step.distance.value,
                            duration: step.duration.text,
                            maneuver: "arrive"
                        )
                    } else if legIndex < waypoints.count {
                        let waypointIndex = legIndex + 1
                        let waypoint = waypoints[legIndex]
                        let waypointName = waypoint.name
                        direction = WalkingDirection(
                            instruction: "Arrive at Waypoint \(waypointIndex) (\(waypointName))",
                            distance: step.distance.text,
                            distanceMeters: step.distance.value,
                            duration: step.duration.text,
                            maneuver: "arrive"
                        )
                    }
                }
                directions.append(direction)
            }
        }
        return filterContradictoryDirections(directions)
    }

    private static func extractManeuver(from html: String) -> String? {
        let lowercased = html.lowercased()
        if lowercased.contains("turn <b>left") || lowercased.contains("turn left") { return "turn-left" }
        if lowercased.contains("turn <b>right") || lowercased.contains("turn right") { return "turn-right" }
        if lowercased.contains("slight <b>left") || lowercased.contains("slight left") { return "turn-slight-left" }
        if lowercased.contains("slight <b>right") || lowercased.contains("slight right") { return "turn-slight-right" }
        if lowercased.contains("sharp <b>left") || lowercased.contains("sharp left") { return "turn-sharp-left" }
        if lowercased.contains("sharp <b>right") || lowercased.contains("sharp right") { return "turn-sharp-right" }
        if lowercased.contains("u-turn") || lowercased.contains("uturn") { return "uturn-left" }
        if lowercased.contains("roundabout") { return "roundabout-left" }
        if lowercased.contains("continue") || lowercased.contains("straight") || lowercased.contains("head ") { return "straight" }
        return nil
    }

    private static func filterContradictoryDirections(_ directions: [WalkingDirection]) -> [WalkingDirection] {
        var filtered: [WalkingDirection] = []
        for (index, direction) in directions.enumerated() {
            let instructionLower = direction.instruction.lowercased()
            let isStartOn = instructionLower.hasPrefix("start on") || instructionLower.contains("start on")
            let distanceIsZero = direction.distanceMeters == 0 || direction.distanceMeters < 5
            if isStartOn && distanceIsZero {
                var shouldSkip = false
                if index + 1 < directions.count {
                    let next = directions[index + 1]
                    let extractRoadName: (String) -> String? = { text in
                        let lower = text.lowercased()
                        if let onIndex = lower.range(of: " on ")?.upperBound ?? lower.range(of: " onto ")?.upperBound {
                            let afterOn = String(lower[onIndex...]).trimmingCharacters(in: .whitespaces)
                            let words = afterOn.components(separatedBy: .whitespaces).prefix(3)
                            return words.isEmpty ? nil : words.joined(separator: " ")
                        }
                        return nil
                    }
                    let currentRoad = extractRoadName(direction.instruction)
                    let nextRoad = extractRoadName(next.instruction)
                    if let c = currentRoad, let n = nextRoad, c == n { shouldSkip = true }
                } else {
                    shouldSkip = true
                }
                if shouldSkip { continue }
            }
            filtered.append(direction)
        }
        return filtered
    }
}
