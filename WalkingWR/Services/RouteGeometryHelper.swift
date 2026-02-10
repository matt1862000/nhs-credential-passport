//
//  RouteGeometryHelper.swift
//  WalkingWR
//
//  Shared geometry for route path: project coordinates onto polyline, select on-route POIs with min spacing.
//

import Foundation
import CoreLocation

enum RouteGeometryHelper {

    /// Distance in meters between two coordinates (Haversine approximation).
    static func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }

    /// Closest point on a segment and fractional position t in [0,1].
    private static func closestPointOnSegment(
        point: CLLocationCoordinate2D,
        segmentStart: CLLocationCoordinate2D,
        segmentEnd: CLLocationCoordinate2D
    ) -> (closestPoint: CLLocationCoordinate2D, t: Double) {
        let dx = segmentEnd.longitude - segmentStart.longitude
        let dy = segmentEnd.latitude - segmentStart.latitude
        let lengthSq = dx * dx + dy * dy
        if lengthSq < 1e-12 {
            return (segmentStart, 0.0)
        }
        let px = point.longitude - segmentStart.longitude
        let py = point.latitude - segmentStart.latitude
        let t = max(0, min(1, (px * dx + py * dy) / lengthSq))
        let closest = CLLocationCoordinate2D(
            latitude: segmentStart.latitude + t * dy,
            longitude: segmentStart.longitude + t * dx
        )
        return (closest, t)
    }

    /// Project a coordinate onto the polyline.
    /// Returns: (segmentIndex, t, distanceToPolyline in meters), or nil if polyline has < 2 points.
    static func projectOntoPolyline(
        coordinate: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> (segmentIndex: Int, t: Double, distanceToPolyline: Double)? {
        guard polyline.count >= 2 else { return nil }
        var bestSegment = 0
        var bestT: Double = 0
        var bestDistance = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let (closest, t) = closestPointOnSegment(
                point: coordinate,
                segmentStart: polyline[i],
                segmentEnd: polyline[i + 1]
            )
            let d = distanceBetween(coordinate, closest)
            if d < bestDistance {
                bestDistance = d
                bestSegment = i
                bestT = t
            }
        }
        return (bestSegment, bestT, bestDistance)
    }

    /// Cumulative distance along polyline from start up to (segmentIndex, t). In meters.
    static func distanceAlongPolyline(
        polyline: [CLLocationCoordinate2D],
        segmentIndex: Int,
        t: Double
    ) -> Double {
        guard polyline.count >= 2, segmentIndex >= 0, segmentIndex < polyline.count - 1 else { return 0 }
        var total: Double = 0
        for i in 0..<segmentIndex {
            total += distanceBetween(polyline[i], polyline[i + 1])
        }
        let segStart = polyline[segmentIndex]
        let segEnd = polyline[segmentIndex + 1]
        total += distanceBetween(segStart, segEnd) * t
        return total
    }

    /// Total length of the polyline in meters.
    static func polylineLength(_ polyline: [CLLocationCoordinate2D]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 0..<(polyline.count - 1) {
            total += distanceBetween(polyline[i], polyline[i + 1])
        }
        return total
    }

    /// Candidate for on-route selection: an identifier and coordinate.
    struct Candidate {
        let id: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Result of on-route selection: candidate and its progress along the route (0...1).
    struct OnRouteResult {
        let candidate: Candidate
        let progress: Double
    }

    /// Select POIs that lie on the route path (within onRouteThresholdMeters of the polyline),
    /// ordered by progress along the route, with at least minDistanceBetweenWaypoints between them and from existing waypoints.
    /// - Parameters:
    ///   - polyline: Decoded route polyline (e.g. start → waypoints → end).
    ///   - candidates: Candidate POIs (e.g. from area) with id and coordinate.
    ///   - origin: User start coordinate.
    ///   - existingWaypointCoords: Current waypoint coordinates (for min spacing).
    ///   - minDistanceBetweenWaypoints: Minimum spacing in meters (e.g. 200 for prepop).
    ///   - onRouteThresholdMeters: Max distance from polyline to consider "on route" (e.g. 50).
    ///   - maxToAdd: Cap on how many to return (e.g. 2–3).
    /// - Returns: Ordered list of (candidate, progress) to insert, respecting spacing.
    static func selectOnRoutePOIs(
        polyline: [CLLocationCoordinate2D],
        candidates: [Candidate],
        origin: CLLocationCoordinate2D,
        existingWaypointCoords: [CLLocationCoordinate2D],
        minDistanceBetweenWaypoints: Double,
        onRouteThresholdMeters: Double,
        maxToAdd: Int
    ) -> [OnRouteResult] {
        guard polyline.count >= 2, maxToAdd > 0 else { return [] }
        let totalLength = polylineLength(polyline)
        guard totalLength > 0 else { return [] }

        typealias WithProgress = (candidate: Candidate, progress: Double, distanceToLine: Double, segmentIndex: Int, t: Double)
        var withProgress: [WithProgress] = []
        for c in candidates {
            guard let proj = projectOntoPolyline(coordinate: c.coordinate, polyline: polyline) else { continue }
            if proj.distanceToPolyline >= onRouteThresholdMeters { continue }
            let distAlong = distanceAlongPolyline(polyline: polyline, segmentIndex: proj.segmentIndex, t: proj.t)
            let progress = distAlong / totalLength
            withProgress.append((c, progress, proj.distanceToPolyline, proj.segmentIndex, proj.t))
        }
        withProgress.sort { $0.progress < $1.progress }

        let allExistingCoords = [origin] + existingWaypointCoords
        var kept: [WithProgress] = []
        for item in withProgress {
            guard kept.count < maxToAdd else { break }
            let coord = item.candidate.coordinate
            let tooCloseToExisting = allExistingCoords.contains { distanceBetween(coord, $0) < minDistanceBetweenWaypoints }
            if tooCloseToExisting { continue }
            let tooCloseToKept = kept.contains { distanceBetween(coord, $0.candidate.coordinate) < minDistanceBetweenWaypoints }
            if tooCloseToKept { continue }
            kept.append(item)
        }
        return kept.map { OnRouteResult(candidate: $0.candidate, progress: $0.progress) }
    }
}
