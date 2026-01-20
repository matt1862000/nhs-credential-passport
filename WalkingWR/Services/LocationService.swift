//
//  LocationService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import CoreLocation
import Combine
import UIKit

class LocationService: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var distanceWalked: Double = 0 // in meters
    @Published var routeLocations: [CLLocation] = []
    @Published var heading: CLHeading?
    @Published var headingDegrees: Double = 0
    private var lastHeadingUpdateTime: Date?
    private var headingUpdateTimer: Timer?
    @Published var isFetchingLocation: Bool = false
    @Published var locationRetryCount: Int = 0
    @Published var isRetrying: Bool = false
    private var locationRequestStartTime: Date?
    
    // Direction monitoring
    @Published var currentDirectionIndex: Int = 0
    @Published var isMonitoringDirections: Bool = false
    @Published var isSignificantlyOffRoute: Bool = false  // v1.9.15: Track if user has deviated significantly
    private var directionWaypoints: [(coordinate: CLLocationCoordinate2D, instruction: String, distance: String, polylineIndex: Int)] = []
    private var notifiedDirectionIndices: Set<Int> = []
    private var cachedRoutePath: [CLLocationCoordinate2D] = []  // v1.9.15: Cache route path for deviation detection
    private let directionNotificationRadius: Double = 30 // meters - notify when within 30m of turn
    private let deviationThreshold: Double = 50.0  // v1.9.15: Consider off-route if >50m from route
    
    // v1.9.71: GPS stability tracking to prevent jitter from advancing waypoints
    private var recentProjectedPositions: [(segmentIndex: Int, t: Double, timestamp: Date)] = []
    private let maxGPSAccuracy: Double = 20.0 // Reject GPS readings with accuracy worse than 20m
    private let minMovementAlongRoute: Double = 15.0 // Require 15m of actual movement along route before advancing
    private let positionHistoryWindow: TimeInterval = 10.0 // Keep last 10 seconds of positions
    
    // MARK: - Polyline Projection Helpers (v1.9.70)
    
    /// Project a point onto a polyline segment and return the closest point
    private func closestPointOnSegment(
        point: CLLocationCoordinate2D,
        segmentStart: CLLocationCoordinate2D,
        segmentEnd: CLLocationCoordinate2D
    ) -> (closestPoint: CLLocationCoordinate2D, t: Double) {
        // Vector from start to end
        let dx = segmentEnd.longitude - segmentStart.longitude
        let dy = segmentEnd.latitude - segmentStart.latitude
        
        // Handle zero-length segment
        let segmentLengthSq = dx * dx + dy * dy
        if segmentLengthSq < 1e-12 {
            return (segmentStart, 0.0)
        }
        
        // Vector from start to point
        let px = point.longitude - segmentStart.longitude
        let py = point.latitude - segmentStart.latitude
        
        // Project point onto line, clamped to [0, 1]
        let t = max(0, min(1, (px * dx + py * dy) / segmentLengthSq))
        
        // Return the closest point on the segment
        let closestPoint = CLLocationCoordinate2D(
            latitude: segmentStart.latitude + t * dy,
            longitude: segmentStart.longitude + t * dx
        )
        
        return (closestPoint, t)
    }
    
    /// Project a coordinate onto the cached route polyline
    /// Returns: (segmentIndex, fractionalPosition along that segment, distance to polyline)
    private func projectOntoPolyline(
        coordinate: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> (segmentIndex: Int, t: Double, distanceToPolyline: Double)? {
        guard polyline.count >= 2 else { return nil }
        
        var bestSegmentIndex = 0
        var bestT: Double = 0
        var bestDistance: Double = .greatestFiniteMagnitude
        
        for i in 0..<(polyline.count - 1) {
            let (closestPoint, t) = closestPointOnSegment(
                point: coordinate,
                segmentStart: polyline[i],
                segmentEnd: polyline[i + 1]
            )
            
            let closestLocation = CLLocation(latitude: closestPoint.latitude, longitude: closestPoint.longitude)
            let pointLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = pointLocation.distance(from: closestLocation)
            
            if distance < bestDistance {
                bestDistance = distance
                bestSegmentIndex = i
                bestT = t
            }
        }
        
        return (bestSegmentIndex, bestT, bestDistance)
    }
    
    /// Compare two positions along the polyline
    /// Returns true if position1 is AHEAD of position2 (further along the route)
    private func isAhead(
        segmentIndex1: Int, t1: Double,
        segmentIndex2: Int, t2: Double
    ) -> Bool {
        if segmentIndex1 > segmentIndex2 {
            return true
        } else if segmentIndex1 == segmentIndex2 {
            return t1 > t2
        }
        return false
    }
    
    // Starting point for walk
    private var startLocation: CLLocation?
    private var retryTimer: Timer?
    private let maxRetries = 3
    private let retryAfterSeconds: TimeInterval = 30
    
    // Clinic location (Longley Centre, Sheffield - S5 7JT)
    let clinicLocation = CLLocation(latitude: 53.4148, longitude: -1.4685)
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // Update every 10 meters
        authorizationStatus = locationManager.authorizationStatus
        
        // Listen for app returning to foreground to re-check permissions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopHeadingUpdateMonitoring()
    }
    
    @objc private func appDidBecomeActive() {
        // Re-check authorization status when app returns from Settings
        let newStatus = locationManager.authorizationStatus
        
        DispatchQueue.main.async {
            let previousStatus = self.authorizationStatus
            self.authorizationStatus = newStatus
            
            // If status changed from denied to notDetermined ("Ask Next Time"), prompt again
            if previousStatus == .denied && newStatus == .notDetermined {
                print("📍 User selected 'Ask Next Time' - requesting permission")
                self.requestPermission()
            }
            // If we're now authorized but no location yet, request one
            else if self.isAuthorized && self.currentLocation == nil {
                print("📍 App became active - requesting fresh location")
                self.requestFreshLocation()
            }
        }
    }
    
    // MARK: - Authorization
    
    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }
    
    // MARK: - Tracking
    
    func startTracking() {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [LOCATION] [\(timeString)] 🚶 startTracking() called")
        
        guard isAuthorized else {
            print("⏱️ [LOCATION] [\(timeString)] ❌ Not authorized - requesting permission")
            requestPermission()
            return
        }
        
        print("⏱️ [LOCATION] [\(timeString)] ✅ Starting location tracking...")
        
        isTracking = true
        distanceWalked = 0
        routeLocations = []
        startLocation = nil
        
        // Enable background location updates for turn-by-turn notifications
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        
        print("⏱️ [LOCATION] [\(timeString)] 📡 startUpdatingLocation() and startUpdatingHeading() called")
        
        // Start monitoring for heading update stops
        startHeadingUpdateMonitoring()
    }
    
    func stopTracking() {
        isTracking = false
        
        // Disable background location updates to save battery
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: Date())
        
        
        stopHeadingUpdateMonitoring()
        stopDirectionMonitoring()
    }
    
    // MARK: - Direction Monitoring
    
    /// Start monitoring for direction waypoints to send turn-by-turn notifications
    /// v1.9.70: Uses polyline projection to correctly determine which waypoints are ahead/behind
    /// - Parameters:
    ///   - directions: Walking directions
    ///   - routePath: Full route polyline
    ///   - skipPassedWaypoints: If true, check current location and skip already-passed waypoints.
    ///                          Use false for fresh walk start (index 0), true for mid-walk direction changes.
    func startDirectionMonitoring(directions: [WalkingDirection], routePath: [CLLocationCoordinate2D], skipPassedWaypoints: Bool = false) {
        // Build waypoints from directions
        // Each direction corresponds to a step - we'll use approximate positions along the route
        directionWaypoints = []
        notifiedDirectionIndices = []
        currentDirectionIndex = 0
        cachedRoutePath = routePath  // v1.9.15: Cache route path for deviation detection
        isSignificantlyOffRoute = false  // Reset deviation flag
        
        // Calculate cumulative distance for each step to find approximate positions
        var cumulativeDistance: Double = 0
        var routeIndex = 0
        let totalRoutePoints = routePath.count
        
        for direction in directions {
            // Find the approximate point along the route for this direction
            let targetDistance = cumulativeDistance + Double(direction.distanceMeters) / 2 // Midpoint of step
            
            // Walk through route points until we reach the target distance
            var accumulatedDist: Double = 0
            var waypointCoord = routePath.first ?? CLLocationCoordinate2D()
            var waypointPolylineIndex = 0
            
            for i in routeIndex..<(totalRoutePoints - 1) {
                let from = CLLocation(latitude: routePath[i].latitude, longitude: routePath[i].longitude)
                let to = CLLocation(latitude: routePath[i + 1].latitude, longitude: routePath[i + 1].longitude)
                let segmentDist = from.distance(from: to)
                
                if accumulatedDist + segmentDist >= targetDistance - cumulativeDistance {
                    // This segment contains our waypoint
                    waypointCoord = routePath[i + 1]
                    waypointPolylineIndex = i + 1  // v1.9.70: Store polyline index
                    routeIndex = i + 1
                    break
                }
                accumulatedDist += segmentDist
            }
            
            // v1.9.70: Store polyline index for each waypoint
            directionWaypoints.append((
                coordinate: waypointCoord,
                instruction: direction.instruction,
                distance: direction.distance,
                polylineIndex: waypointPolylineIndex
            ))
            
            cumulativeDistance += Double(direction.distanceMeters)
        }
        
        // v1.9.70: Use polyline projection to determine which waypoints are ahead/behind
        // This handles cached routes where start position may differ from user's actual position
        if skipPassedWaypoints, let currentLoc = currentLocation, !directionWaypoints.isEmpty, !routePath.isEmpty {
            // Project user's current position onto the polyline
            if let userProjection = projectOntoPolyline(coordinate: currentLoc.coordinate, polyline: routePath) {
                var skippedCount = 0
                
                for (index, waypoint) in directionWaypoints.enumerated() {
                    // Check if this waypoint is BEHIND the user on the polyline
                    // Waypoint is behind if its polyline index is less than or equal to user's projected position
                    let waypointSegment = max(0, waypoint.polylineIndex - 1)  // Segment index (waypoint is at end of this segment)
                    
                    // User is past this waypoint if:
                    // 1. User's segment index is greater than waypoint's segment, OR
                    // 2. User is on the same segment but further along (t > 0.5)
                    let isPast = isAhead(
                        segmentIndex1: userProjection.segmentIndex,
                        t1: userProjection.t,
                        segmentIndex2: waypointSegment,
                        t2: 0.5  // Consider waypoint at midpoint of its segment
                    )
                    
                    if isPast {
                        skippedCount = index + 1
                        notifiedDirectionIndices.insert(index)
                    } else {
                        break  // Stop at first waypoint that's still ahead
                    }
                }
                
                if skippedCount > 0 {
                    currentDirectionIndex = min(skippedCount, directionWaypoints.count - 1)
                    print("📍 [Polyline] Skipped \(skippedCount) waypoint(s) - user already past (segment \(userProjection.segmentIndex), t=\(String(format: "%.2f", userProjection.t))). Starting at index \(currentDirectionIndex)")
                } else {
                    print("📍 [Polyline] User at segment \(userProjection.segmentIndex) - no waypoints to skip")
                }
            } else {
                print("📍 [Polyline] Could not project user position - starting at index 0")
            }
        }
        
        isMonitoringDirections = true
        print("📍 Started direction monitoring with \(directionWaypoints.count) waypoints, starting at index \(currentDirectionIndex)")
    }
    
    /// Stop monitoring for directions
    func stopDirectionMonitoring() {
        isMonitoringDirections = false
        directionWaypoints = []
        notifiedDirectionIndices = []
        currentDirectionIndex = 0
        recentProjectedPositions = []  // v1.9.71: Clear position history
        NotificationService.shared.cancelDirectionNotifications()
    }
    
    /// Check if user is approaching any direction waypoint and send notification
    /// v1.9.71: Adds GPS accuracy filtering and movement confirmation to prevent jitter from advancing waypoints
    private func checkDirectionWaypoints(currentLocation: CLLocation) {
        guard isMonitoringDirections, !directionWaypoints.isEmpty, !cachedRoutePath.isEmpty else { return }
        
        // v1.9.71: Filter out poor GPS readings
        // Reject readings with accuracy worse than maxGPSAccuracy (default 20m)
        if currentLocation.horizontalAccuracy > maxGPSAccuracy || currentLocation.horizontalAccuracy < 0 {
            print("📍 [GPS Filter] Rejecting location: accuracy=\(String(format: "%.1f", currentLocation.horizontalAccuracy))m (max: \(maxGPSAccuracy)m)")
            return
        }
        
        // Project user's current position onto the polyline
        guard let userProjection = projectOntoPolyline(coordinate: currentLocation.coordinate, polyline: cachedRoutePath) else {
            return
        }
        
        // v1.9.71: Add to position history for movement tracking
        let now = Date()
        recentProjectedPositions.append((userProjection.segmentIndex, userProjection.t, now))
        
        // Clean up old positions (keep last 10 seconds)
        recentProjectedPositions = recentProjectedPositions.filter { now.timeIntervalSince($0.timestamp) <= positionHistoryWindow }
        
        // v1.9.71: Calculate distance moved along route (not straight-line, but along the polyline)
        let distanceMovedAlongRoute = calculateDistanceMovedAlongRoute(
            currentProjection: userProjection,
            recentPositions: recentProjectedPositions
        )
        
        // Check upcoming waypoints (current and next few)
        let checkRange = currentDirectionIndex..<min(currentDirectionIndex + 3, directionWaypoints.count)
        
        for index in checkRange {
            // Skip if already notified for this waypoint
            guard !notifiedDirectionIndices.contains(index) else { continue }
            
            let waypoint = directionWaypoints[index]
            let waypointLocation = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
            let distance = currentLocation.distance(from: waypointLocation)
            
            // v1.9.70: Determine waypoint's position on the polyline
            let waypointSegment = max(0, waypoint.polylineIndex - 1)
            
            // Check if user has reached/passed this waypoint using polyline position
            // User is at/past waypoint if:
            // 1. Within 30m straight-line distance, AND
            // 2. User's polyline position is at or past the waypoint's position
            let userIsAtOrPastOnPolyline = isAhead(
                segmentIndex1: userProjection.segmentIndex,
                t1: userProjection.t,
                segmentIndex2: waypointSegment,
                t2: 0.3  // User should be at least 30% into the waypoint's segment
            ) || userProjection.segmentIndex >= waypoint.polylineIndex
            
            // v1.9.71: Require actual movement along route before advancing (prevents GPS jitter)
            // Exception: if very close (<15m), always trigger (user is definitely there)
            let hasMovedEnough = distanceMovedAlongRoute >= minMovementAlongRoute || distance <= 15
            
            // Trigger notification if:
            // - Within 30m distance AND past on polyline AND has moved enough, OR
            // - Within 15m distance (very close, definitely there regardless of movement)
            let shouldTrigger = (distance <= directionNotificationRadius && userIsAtOrPastOnPolyline && hasMovedEnough) ||
                                (distance <= 15)  // Failsafe: if very close, always trigger
            
            if shouldTrigger {
                NotificationService.shared.sendDirectionNotification(
                    instruction: waypoint.instruction,
                    distance: waypoint.distance,
                    stepNumber: index + 1,
                    totalSteps: directionWaypoints.count
                )
                
                notifiedDirectionIndices.insert(index)
                
                // Update current direction index
                if index >= currentDirectionIndex {
                    let newIndex = min(index + 1, directionWaypoints.count - 1)
                    currentDirectionIndex = newIndex
                }
                
                // Clear position history after advancing (fresh start for next waypoint)
                recentProjectedPositions.removeAll()
                
                print("📍 Direction: step \(index + 1)/\(directionWaypoints.count) - \(waypoint.instruction) (segment \(userProjection.segmentIndex), dist \(Int(distance))m, moved \(String(format: "%.1f", distanceMovedAlongRoute))m)")
                break // Only send one notification at a time
            }
        }
    }
    
    /// v1.9.71: Calculate distance moved along the route polyline (not straight-line)
    /// This helps distinguish real movement from GPS jitter
    private func calculateDistanceMovedAlongRoute(
        currentProjection: (segmentIndex: Int, t: Double, distanceToPolyline: Double),
        recentPositions: [(segmentIndex: Int, t: Double, timestamp: Date)]
    ) -> Double {
        guard recentPositions.count >= 2 else { return 0 }
        
        // Get the oldest position in history
        guard let oldestPosition = recentPositions.first else { return 0 }
        
        // Calculate distance along polyline from oldest to current
        var totalDistance: Double = 0
        
        let startSegment = oldestPosition.segmentIndex
        let startT = oldestPosition.t
        let endSegment = currentProjection.segmentIndex
        let endT = currentProjection.t
        
        if startSegment == endSegment {
            // Same segment - calculate fractional distance
            let segmentStart = cachedRoutePath[startSegment]
            let segmentEnd = cachedRoutePath[min(startSegment + 1, cachedRoutePath.count - 1)]
            let segmentLength = CLLocation(latitude: segmentStart.latitude, longitude: segmentStart.longitude)
                .distance(from: CLLocation(latitude: segmentEnd.latitude, longitude: segmentEnd.longitude))
            totalDistance = abs(endT - startT) * segmentLength
        } else {
            // Different segments - sum up intermediate segments
            let minSegment = min(startSegment, endSegment)
            let maxSegment = max(startSegment, endSegment)
            
            // Distance from start position to end of its segment
            if startSegment < cachedRoutePath.count - 1 {
                let segStart = cachedRoutePath[startSegment]
                let segEnd = cachedRoutePath[startSegment + 1]
                let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                    .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                totalDistance += (1.0 - startT) * segLength
            }
            
            // Distance through intermediate segments
            for i in (minSegment + 1)..<maxSegment {
                if i < cachedRoutePath.count - 1 {
                    let segStart = cachedRoutePath[i]
                    let segEnd = cachedRoutePath[i + 1]
                    let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                        .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                    totalDistance += segLength
                }
            }
            
            // Distance from start of end segment to end position
            if endSegment < cachedRoutePath.count - 1 {
                let segStart = cachedRoutePath[endSegment]
                let segEnd = cachedRoutePath[endSegment + 1]
                let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                    .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                totalDistance += endT * segLength
            }
        }
        
        return totalDistance
    }
    
    // v1.9.0: Get next turn coordinate for map annotation
    var nextTurnCoordinate: CLLocationCoordinate2D? {
        guard isMonitoringDirections, 
              currentDirectionIndex < directionWaypoints.count else { return nil }
        return directionWaypoints[currentDirectionIndex].coordinate
    }
    
    // v1.9.1: Get next ambiguous turn coordinate and index (where arrow should appear)
    // Shows arrow only at the turn currently displayed in the banner, but only if it's in the uncertainty zone (50-150m)
    // This ensures the arrow appears when the directions change to that turn (e.g., "Turn right onto Brandy Carr Road")
    func nextAmbiguousTurn(from currentLocation: CLLocation?) -> (coordinate: CLLocationCoordinate2D, directionIndex: Int)? {
        guard isMonitoringDirections, 
              let location = currentLocation,
              currentDirectionIndex < directionWaypoints.count else { return nil }
        
        // Get the turn that's currently displayed in the banner (currentDirectionIndex)
        let currentTurn = directionWaypoints[currentDirectionIndex]
        let turnLocation = CLLocation(latitude: currentTurn.coordinate.latitude, longitude: currentTurn.coordinate.longitude)
        let distance = location.distance(from: turnLocation)
        
        // Only show arrow if the current turn (shown in banner) is in the uncertainty zone (50-150m)
        // This way the arrow appears when the banner changes to show that turn
        if distance >= 50 && distance <= 150 {
            return (currentTurn.coordinate, currentDirectionIndex)
        }
        
        // Don't show arrow if too close (<50m) or too far (>150m)
        // The arrow will appear when the banner updates to the next turn that's in the uncertainty zone
        return nil
    }
    
    // v1.9.0: Get distance to next turn for auto-zoom
    func distanceToNextTurn(from location: CLLocation) -> Double? {
        guard let nextTurn = nextTurnCoordinate else { return nil }
        let turnLocation = CLLocation(latitude: nextTurn.latitude, longitude: nextTurn.longitude)
        return location.distance(from: turnLocation)
    }
    
    // v1.9.15: Check if user has deviated significantly from the route
    private func checkRouteDeviation(currentLocation: CLLocation) {
        guard !cachedRoutePath.isEmpty else { return }
        
        // Find minimum distance from current location to any point on the route
        var minDistanceToRoute: Double = .greatestFiniteMagnitude
        
        for routePoint in cachedRoutePath {
            let routeLocation = CLLocation(latitude: routePoint.latitude, longitude: routePoint.longitude)
            let distance = currentLocation.distance(from: routeLocation)
            minDistanceToRoute = min(minDistanceToRoute, distance)
        }
        
        // Update deviation flag
        let wasOffRoute = isSignificantlyOffRoute
        isSignificantlyOffRoute = minDistanceToRoute > deviationThreshold
        
        // Log significant deviations (but don't block directions - they're cached)
        if isSignificantlyOffRoute && !wasOffRoute {
            print("⚠️ User has deviated from route: \(Int(minDistanceToRoute))m away (threshold: \(Int(deviationThreshold))m)")
            print("   Directions will continue using cached data. Re-route would require internet connection.")
        } else if !isSignificantlyOffRoute && wasOffRoute {
            print("✅ User is back on route (within \(Int(deviationThreshold))m)")
        }
    }
    
    /// Request a FRESH location (clears cached location first)
    func requestFreshLocation() {
        // Clear cached location to force fresh GPS fix
        currentLocation = nil
        locationRetryCount = 0
        isRetrying = false
        cancelRetryTimer()
        requestCurrentLocation()
    }
    
    func requestCurrentLocation() {
        let startTime = Date()
        locationRequestStartTime = startTime
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [LOCATION] [\(timeString)] requestCurrentLocation() called")
        
        if !isAuthorized {
            print("⏱️ [LOCATION] [\(timeString)] ❌ Not authorized - requesting permission")
            requestPermission()
            return
        }
        
        print("⏱️ [LOCATION] [\(timeString)] ✅ Authorized - requesting location...")
        
        // Show fetching state
        isFetchingLocation = true
        
        // Use requestLocation() for faster one-shot location
        locationManager.requestLocation()
        
        print("⏱️ [LOCATION] [\(timeString)] 📡 locationManager.requestLocation() called")
        
        // Start retry timer - if no location after 30 seconds, retry automatically
        startRetryTimer()
    }
    
    private func startRetryTimer() {
        cancelRetryTimer()
        
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryAfterSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Only retry if we still don't have a location and haven't exceeded max retries
                if self.currentLocation == nil && self.locationRetryCount < self.maxRetries {
                    self.locationRetryCount += 1
                    self.isRetrying = true
                    print("Location retry attempt \(self.locationRetryCount) of \(self.maxRetries)")
                    
                    // Request location again
                    self.locationManager.requestLocation()
                    
                    // Start another retry timer
                    self.startRetryTimer()
                } else {
                    // Give up after max retries
                    self.isFetchingLocation = false
                    self.isRetrying = false
                }
            }
        }
    }
    
    private func cancelRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    /// Call this when location is successfully obtained
    private func locationObtained() {
        cancelRetryTimer()
        isFetchingLocation = false
        isRetrying = false
        locationRequestStartTime = nil
    }
    
    // MARK: - Distance Calculations
    
    func distanceFromClinic() -> Double? {
        guard let current = currentLocation else { return nil }
        return current.distance(from: clinicLocation)
    }
    
    func isNearClinic(withinMeters meters: Double = 100) -> Bool {
        guard let distance = distanceFromClinic() else { return false }
        return distance <= meters
    }
    
    /// Estimates if user should start heading back based on:
    /// - Current distance from clinic
    /// - Walking speed (average 1.4 m/s or 5 km/h)
    /// - Remaining time until appointment
    func shouldReturnNow(remainingMinutes: Int) -> Bool {
        guard let distance = distanceFromClinic() else { return false }
        
        let walkingSpeedMPS: Double = 1.4 // meters per second
        let timeToReturnSeconds = distance / walkingSpeedMPS
        let timeToReturnMinutes = timeToReturnSeconds / 60
        
        // Add 2 minute buffer
        return timeToReturnMinutes + 2 >= Double(remainingMinutes)
    }
    
    // MARK: - Route Suggestions
    
    /// Suggests maximum safe walking distance based on wait time
    func maxSafeDistance(forWaitMinutes minutes: Int) -> Double {
        let walkingSpeedMPS: Double = 1.4
        // Use half the time for outbound journey (other half for return)
        let outboundTimeSeconds = Double(minutes * 60) / 2
        // Subtract 2 minute buffer
        let safeTimeSeconds = max(0, outboundTimeSeconds - 120)
        return safeTimeSeconds * walkingSpeedMPS
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let previousStatus = authorizationStatus
        let newStatus = manager.authorizationStatus
        
        DispatchQueue.main.async {
            self.authorizationStatus = newStatus
            
            // If we just became authorized (from denied/notDetermined), request location
            let wasNotAuthorized = previousStatus == .denied || previousStatus == .notDetermined || previousStatus == .restricted
            let isNowAuthorized = newStatus == .authorizedWhenInUse || newStatus == .authorizedAlways
            
            if wasNotAuthorized && isNowAuthorized && self.currentLocation == nil {
                print("📍 Location permission granted - requesting fresh location")
                self.requestFreshLocation()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let updateTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: updateTime)
        
        guard let newLocation = locations.last else {
            print("⏱️ [LOCATION] [\(timeString)] ⚠️ didUpdateLocations called but locations array is empty")
            return
        }
        
        let isFirstLocation = currentLocation == nil
        
        print("⏱️ [LOCATION] [\(timeString)] 📍 didUpdateLocations: lat=\(String(format: "%.5f", newLocation.coordinate.latitude)), lon=\(String(format: "%.5f", newLocation.coordinate.longitude)), accuracy=\(String(format: "%.1f", newLocation.horizontalAccuracy))m\(isFirstLocation ? " (FIRST LOCATION)" : "")")
        
        DispatchQueue.main.async {
            // Mark fetching complete and cancel retry timer
            let wasFetching = self.isFetchingLocation
            let requestStartTime = self.locationRequestStartTime
            self.locationObtained()
            
            if wasFetching, let startTime = requestStartTime {
                let elapsed = updateTime.timeIntervalSince(startTime)
                print("⏱️ [LOCATION] [\(timeString)] ✅ Location obtained in \(String(format: "%.2f", elapsed))s")
                self.locationRequestStartTime = nil
            }
            
            // Set start location on first update
            if self.startLocation == nil {
                self.startLocation = newLocation
                print("⏱️ [LOCATION] [\(timeString)] 🎯 Start location set")
            }
            
            // Calculate distance walked
            if let lastLocation = self.routeLocations.last {
                let distance = newLocation.distance(from: lastLocation)
                self.distanceWalked += distance
            }
            
            self.routeLocations.append(newLocation)
            self.currentLocation = newLocation
            
            // v1.9.15: Check if user has deviated significantly from route
            self.checkRouteDeviation(currentLocation: newLocation)
            
            // Check if approaching any direction waypoints
            self.checkDirectionWaypoints(currentLocation: newLocation)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            // On error, trigger immediate retry if we haven't exceeded max
            if self.locationRetryCount < self.maxRetries {
                self.locationRetryCount += 1
                self.isRetrying = true
                print("Location failed, retry attempt \(self.locationRetryCount) of \(self.maxRetries)")
                
                // Wait 2 seconds then retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.locationManager.requestLocation()
                }
            } else {
                self.isFetchingLocation = false
                self.isRetrying = false
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let trueHeading = newHeading.trueHeading
        let magneticHeading = newHeading.magneticHeading
        let finalHeading = trueHeading >= 0 ? trueHeading : magneticHeading
        
        let timestamp = Date()
        let timeSinceLastUpdate = lastHeadingUpdateTime.map { timestamp.timeIntervalSince($0) }
        lastHeadingUpdateTime = timestamp
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        if let timeSince = timeSinceLastUpdate, timeSince > 2.0 {
        }
        
        // Log if heading is invalid
        if trueHeading < 0 && magneticHeading < 0 {
            print("⚠️ WARNING: Both headings invalid!")
        }
        
        DispatchQueue.main.async {
            let previousHeading = self.headingDegrees
            self.heading = newHeading
            self.headingDegrees = finalHeading
            
        }
    }
    
    // Monitor for heading update stops
    private func startHeadingUpdateMonitoring() {
        stopHeadingUpdateMonitoring()
        headingUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isTracking else { return }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeString = formatter.string(from: Date())
            
            // Monitor for heading update stops (silent monitoring)
            if let lastUpdate = self.lastHeadingUpdateTime {
                let timeSince = Date().timeIntervalSince(lastUpdate)
                if timeSince > 3.0 {
                    // Heading updates may have stopped - silently monitor
                }
            }
        }
    }
    
    private func stopHeadingUpdateMonitoring() {
        headingUpdateTimer?.invalidate()
        headingUpdateTimer = nil
    }
}

