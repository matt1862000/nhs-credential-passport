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
import Network

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
    
    // v1.9.74: Network monitoring for WiFi/cellular transitions
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "NetworkMonitor")
    private var currentNetworkType: String = "Unknown"
    private var lastNetworkChangeTime: Date?
    
    // v1.9.74: File-based debug logging
    private let debugLogger = DebugLogger.shared
    
    // Direction monitoring
    @Published var currentDirectionIndex: Int = 0 {
        didSet {
            // v1.9.78: Log every time direction index changes
            if currentDirectionIndex != oldValue {
                let logMsg = "🔄 Direction index changed: \(oldValue) → \(currentDirectionIndex) (total: \(directionWaypoints.count))"
                print("📍 [DIRECTION INDEX] \(logMsg)")
                debugLogger.log(logMsg, category: "DIRECTION_INDEX")
                
                // Log what instruction is now being shown
                if currentDirectionIndex < directionWaypoints.count {
                    let currentWaypoint = directionWaypoints[currentDirectionIndex]
                    let instructionLog = "📋 Now showing instruction: '\(currentWaypoint.instruction)' (index \(currentDirectionIndex))"
                    print("📍 [DIRECTION INDEX] \(instructionLog)")
                    debugLogger.log(instructionLog, category: "DIRECTION_INDEX")
                }
            }
        }
    }
    @Published var isMonitoringDirections: Bool = false
    @Published var isSignificantlyOffRoute: Bool = false  // v1.9.15: Track if user has deviated significantly
    private var directionWaypoints: [(coordinate: CLLocationCoordinate2D, instruction: String, distance: String, polylineIndex: Int)] = []
    private var notifiedDirectionIndices: Set<Int> = []
    private var cachedRoutePath: [CLLocationCoordinate2D] = []  // v1.9.15: Cache route path for deviation detection
    private let directionNotificationRadius: Double = 30 // meters - notify when within 30m of turn
    private let deviationThreshold: Double = 50.0  // v1.9.15: Consider off-route if >50m from route
    
    // v1.9.71: GPS stability tracking to prevent jitter from advancing waypoints
    private var recentProjectedPositions: [(segmentIndex: Int, t: Double, timestamp: Date)] = []
    private let maxGPSAccuracy: Double = 40.0 // Reject GPS readings with accuracy worse than 40m (balanced: allows 35m readings while still filtering poor GPS)
    private let minMovementAlongRoute: Double = 15.0 // Require 15m of actual movement along route before advancing (balanced: prevents jitter but allows progression)
    private let positionHistoryWindow: TimeInterval = 30.0 // Keep last 30 seconds of positions (3x longer)
    private let minConsistentReadings: Int = 3 // Require at least 3 consistent readings
    private let consistencyThreshold: Double = 0.6 // 60% of readings must show forward progress
    private let minDistanceToCountAsWalked: Double = 5.0 // Ignore movements smaller than this (GPS jitter when stationary)
    private let minDistancePastWaypointToSkipOnStart: Double = 25.0 // When skipping passed waypoints on start, user must be at least this far past the waypoint (prevents single noisy reading from jumping ahead)
    
    // v1.9.90: Track last marker to prevent advancing to return journey before destination is reached
    private var lastMarkerPolylineIndex: Int? = nil
    private var returnJourneyStartIndex: Int? = nil  // v1.9.93: Direction index where return journey starts
    private var isLastMarkerVisited: (() -> Bool)? = nil
    
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
    
    /// Distance in meters along the polyline from (fromSegment, fromT) to (toSegment, toT). Assumes "to" is ahead of "from".
    private func distanceAlongRoute(
        fromSegment segA: Int, fromT tA: Double,
        toSegment segB: Int, toT tB: Double,
        polyline: [CLLocationCoordinate2D]
    ) -> Double {
        guard polyline.count >= 2, segA >= 0, segB >= 0 else { return 0 }
        var totalDistance: Double = 0
        if segA == segB {
            let segmentStart = polyline[segA]
            let segmentEnd = polyline[min(segA + 1, polyline.count - 1)]
            let segmentLength = CLLocation(latitude: segmentStart.latitude, longitude: segmentStart.longitude)
                .distance(from: CLLocation(latitude: segmentEnd.latitude, longitude: segmentEnd.longitude))
            totalDistance = abs(tB - tA) * segmentLength
        } else {
            let minSeg = min(segA, segB)
            let maxSeg = max(segA, segB)
            if segA < polyline.count - 1 {
                let segStart = polyline[segA]
                let segEnd = polyline[segA + 1]
                let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                    .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                totalDistance += (1.0 - tA) * segLength
            }
            for i in (minSeg + 1)..<maxSeg {
                if i < polyline.count - 1 {
                    let segStart = polyline[i]
                    let segEnd = polyline[i + 1]
                    let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                        .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                    totalDistance += segLength
                }
            }
            if segB < polyline.count - 1 {
                let segStart = polyline[segB]
                let segEnd = polyline[segB + 1]
                let segLength = CLLocation(latitude: segStart.latitude, longitude: segStart.longitude)
                    .distance(from: CLLocation(latitude: segEnd.latitude, longitude: segEnd.longitude))
                totalDistance += tB * segLength
            }
        }
        return totalDistance
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
        
        // v1.9.74: Start network monitoring
        startNetworkMonitoring()
        
        // v1.9.80: Log initialization with app session info
        debugLogger.log("LocationService initialized", category: "INIT")
        debugLogger.log("App session started - Log file: \(DebugLogger.shared.logFile.lastPathComponent)", category: "INIT")
        
        // v1.9.80: Check if previous walk was active (crash detection)
        let hadActiveWalk = UserDefaults.standard.bool(forKey: "hasActiveWalk")
        if hadActiveWalk {
            debugLogger.log("⚠️ Detected previous walk was active - app may have crashed", category: "INIT")
        }
        
        debugLogger.log("GPS Settings: maxAccuracy=\(maxGPSAccuracy)m, minMovement=\(minMovementAlongRoute)m, historyWindow=\(positionHistoryWindow)s", category: "CONFIG")
        debugLogger.log("GPS Settings: minConsistentReadings=\(minConsistentReadings), consistencyThreshold=\(consistencyThreshold)", category: "CONFIG")
        
        // Listen for app returning to foreground to re-check permissions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Listen for app going to background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    // v1.9.74: Network monitoring for debugging WiFi/cellular transitions
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeString = formatter.string(from: timestamp)
            
            var networkType = "Unknown"
            if path.usesInterfaceType(.wifi) {
                networkType = "WiFi"
            } else if path.usesInterfaceType(.cellular) {
                networkType = "Cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                networkType = "Ethernet"
            } else if path.usesInterfaceType(.loopback) {
                networkType = "Loopback"
            }
            
            let isExpensive = path.isExpensive
            let isConstrained = path.isConstrained
            let status = path.status
            
            let previousType = self.currentNetworkType
            self.currentNetworkType = networkType
            self.lastNetworkChangeTime = timestamp
            
            let networkLog = "Network changed: \(previousType) → \(networkType), Status: \(status == .satisfied ? "Connected" : "Unsatisfied"), Expensive: \(isExpensive), Tracking: \(self.isTracking), Monitoring: \(self.isMonitoringDirections)"
            print("🌐 [NETWORK] [\(timeString)] \(networkLog)")
            self.debugLogger.log(networkLog, category: "NETWORK")
            
            // Log if transitioning during active walk
            if self.isTracking {
                let warning = "⚠️ Network transition during active walk! \(previousType) → \(networkType)"
                print("🌐 [NETWORK] [\(timeString)] \(warning)")
                self.debugLogger.log(warning, category: "NETWORK")
            }
        }
        networkMonitor.start(queue: networkQueue)
        
        // Log initial network state
        let initialPath = networkMonitor.currentPath
        if initialPath.usesInterfaceType(.wifi) {
            currentNetworkType = "WiFi"
        } else if initialPath.usesInterfaceType(.cellular) {
            currentNetworkType = "Cellular"
        }
        print("🌐 [NETWORK] Initial network type: \(currentNetworkType)")
    }
    
    @objc private func appDidEnterBackground() {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        print("📱 [APP STATE] [\(timeString)] App entered background")
        print("📱 [APP STATE] [\(timeString)]   Tracking: \(isTracking), Monitoring: \(isMonitoringDirections)")
        print("📱 [APP STATE] [\(timeString)]   Network: \(currentNetworkType)")
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
    ///   - lastMarkerPolylineIndex: Optional polyline index of the last marker (destination). If provided, prevents advancing to return journey until marker is visited.
    ///   - returnJourneyStartIndex: Optional direction index where return journey starts (after arrival instruction is filtered). More reliable than polyline index alone.
    ///   - isLastMarkerVisited: Optional closure that returns true if the last marker has been visited. Required if lastMarkerPolylineIndex is provided.
    func startDirectionMonitoring(
        directions: [WalkingDirection],
        routePath: [CLLocationCoordinate2D],
        skipPassedWaypoints: Bool = false,
        lastMarkerPolylineIndex: Int? = nil,
        returnJourneyStartIndex: Int? = nil,
        isLastMarkerVisited: (() -> Bool)? = nil
    ) {
        // Build waypoints from directions
        // Each direction corresponds to a step - we'll use approximate positions along the route
        directionWaypoints = []
        notifiedDirectionIndices = []
        currentDirectionIndex = 0
        cachedRoutePath = routePath  // v1.9.15: Cache route path for deviation detection
        isSignificantlyOffRoute = false  // Reset deviation flag
        
        // v1.9.90: Store last marker info to prevent advancing to return journey before destination is reached
        self.lastMarkerPolylineIndex = lastMarkerPolylineIndex
        self.returnJourneyStartIndex = returnJourneyStartIndex  // v1.9.93: Store return journey start index
        self.isLastMarkerVisited = isLastMarkerVisited
        
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
                    let waypointSegment = max(0, waypoint.polylineIndex - 1)  // Segment index (waypoint is at end of this segment)
                    
                    // User is past this waypoint if:
                    // 1. User's projected position is ahead on the polyline, AND
                    // 2. User is at least minDistancePastWaypointToSkipOnStart (25m) past the waypoint (avoids single noisy GPS reading jumping ahead)
                    let isAheadOnPolyline = isAhead(
                        segmentIndex1: userProjection.segmentIndex,
                        t1: userProjection.t,
                        segmentIndex2: waypointSegment,
                        t2: 0.5  // Consider waypoint at midpoint of its segment
                    )
                    let distancePastWaypoint = isAheadOnPolyline
                        ? distanceAlongRoute(fromSegment: waypointSegment, fromT: 0.5, toSegment: userProjection.segmentIndex, toT: userProjection.t, polyline: routePath)
                        : 0
                    let isPast = isAheadOnPolyline && distancePastWaypoint >= minDistancePastWaypointToSkipOnStart
                    
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
        
        // v1.9.78: Log all directions for debugging
        var allDirectionsLog = "📋 All directions (\(directionWaypoints.count) total):\n"
        for (idx, waypoint) in directionWaypoints.enumerated() {
            let marker = idx == currentDirectionIndex ? "👉" : "  "
            allDirectionsLog += "\(marker) [\(idx)] \(waypoint.instruction) (polylineIndex: \(waypoint.polylineIndex))\n"
        }
        print("📍 [DIRECTION_MONITORING] \(allDirectionsLog)")
        debugLogger.log(allDirectionsLog, category: "DIRECTION_MONITORING")
        
        let monitoringLog = "Started direction monitoring with \(directionWaypoints.count) waypoints, starting at index \(currentDirectionIndex), routePath points: \(cachedRoutePath.count)"
        print("📍 \(monitoringLog)")
        debugLogger.log(monitoringLog, category: "DIRECTION_MONITORING")
    }
    
    /// Stop monitoring for directions
    func stopDirectionMonitoring() {
        isMonitoringDirections = false
        directionWaypoints = []
        notifiedDirectionIndices = []
        currentDirectionIndex = 0
        recentProjectedPositions = []  // v1.9.71: Clear position history
        lastMarkerPolylineIndex = nil  // v1.9.90: Clear last marker tracking
        returnJourneyStartIndex = nil  // v1.9.93: Clear return journey start index
        isLastMarkerVisited = nil
        NotificationService.shared.cancelDirectionNotifications()
    }
    
    /// v2.1.1: Update directions while walk is in progress (e.g., after background refresh)
    /// Preserves current progress and only updates directions that haven't been shown yet
    func updateDirections(_ directions: [WalkingDirection], routePath: [CLLocationCoordinate2D]) {
        guard isMonitoringDirections else {
            print("📍 [DIRECTION UPDATE] Not currently monitoring - starting fresh")
            startDirectionMonitoring(directions: directions, routePath: routePath, skipPassedWaypoints: true)
            return
        }
        
        // Preserve current progress
        let previousIndex = currentDirectionIndex
        let previousNotified = notifiedDirectionIndices
        
        // Rebuild waypoints with new directions
        var newWaypoints: [(coordinate: CLLocationCoordinate2D, instruction: String, distance: String, polylineIndex: Int)] = []
        var cumulativeDistance: Double = 0
        var routeIndex = 0
        let totalRoutePoints = routePath.count
        
        for direction in directions {
            let targetDistance = cumulativeDistance + Double(direction.distanceMeters) / 2
            var accumulatedDistance: Double = 0
            
            while routeIndex < totalRoutePoints - 1 {
                let start = routePath[routeIndex]
                let end = routePath[routeIndex + 1]
                let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
                
                if accumulatedDistance + segmentDistance >= targetDistance {
                    break
                }
                accumulatedDistance += segmentDistance
                routeIndex += 1
            }
            
            let waypointPolylineIndex = routeIndex
            let waypointCoord = routeIndex < routePath.count ? routePath[routeIndex] : (routePath.last ?? CLLocationCoordinate2D())
            
            newWaypoints.append((
                coordinate: waypointCoord,
                instruction: direction.instruction,
                distance: direction.distance,
                polylineIndex: waypointPolylineIndex
            ))
            
            cumulativeDistance += Double(direction.distanceMeters)
        }
        
        // Update waypoints and route path
        directionWaypoints = newWaypoints
        cachedRoutePath = routePath
        
        // Restore progress (clamp to valid range)
        currentDirectionIndex = min(previousIndex, max(0, directionWaypoints.count - 1))
        notifiedDirectionIndices = previousNotified.filter { $0 < directionWaypoints.count }
        
        print("📍 [DIRECTION UPDATE] Updated directions: \(directionWaypoints.count) waypoints, preserved index \(currentDirectionIndex), routePath: \(cachedRoutePath.count) points")
    }
    
    /// Check if user is approaching any direction waypoint and send notification
    /// v1.9.71: Adds GPS accuracy filtering and movement confirmation to prevent jitter from advancing waypoints
    private func checkDirectionWaypoints(currentLocation: CLLocation) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        guard isMonitoringDirections, !directionWaypoints.isEmpty, !cachedRoutePath.isEmpty else {
            let skipLog = "Skipping waypoint check - Monitoring: \(isMonitoringDirections), Waypoints: \(directionWaypoints.count), Route: \(cachedRoutePath.count)"
            print("📍 [WAYPOINT CHECK] [\(timeString)] \(skipLog)")
            debugLogger.log(skipLog, category: "WAYPOINT")
            return
        }
        
        // v1.9.71: Filter out poor GPS readings
        // Reject readings with accuracy worse than maxGPSAccuracy (default 20m)
        if currentLocation.horizontalAccuracy > maxGPSAccuracy || currentLocation.horizontalAccuracy < 0 {
            let rejectLog = "Rejecting location: accuracy=\(String(format: "%.1f", currentLocation.horizontalAccuracy))m (max: \(maxGPSAccuracy)m), Network: \(currentNetworkType)"
            print("📍 [GPS Filter] [\(timeString)] \(rejectLog)")
            debugLogger.log(rejectLog, category: "GPS_FILTER")
            return
        }
        
        // v1.9.78: Enhanced GPS location logging
        let gpsLog = "📍 GPS: (\(String(format: "%.6f", currentLocation.coordinate.latitude)), \(String(format: "%.6f", currentLocation.coordinate.longitude))), Accuracy: \(String(format: "%.1f", currentLocation.horizontalAccuracy))m, Speed: \(String(format: "%.2f", currentLocation.speed))m/s, Network: \(currentNetworkType)"
        print("📍 [GPS] [\(timeString)] \(gpsLog)")
        debugLogger.log(gpsLog, category: "GPS")
        
        // v1.9.78: Log current direction being shown
        if currentDirectionIndex < directionWaypoints.count {
            let currentWaypoint = directionWaypoints[currentDirectionIndex]
            let directionLog = "📋 Current direction shown: Index \(currentDirectionIndex)/\(directionWaypoints.count) - '\(currentWaypoint.instruction)'"
            print("📍 [CURRENT DIRECTION] [\(timeString)] \(directionLog)")
            debugLogger.log(directionLog, category: "CURRENT_DIRECTION")
        }
        
        let checkLog = "Checking waypoints (index: \(currentDirectionIndex)/\(directionWaypoints.count)), Network: \(currentNetworkType), Accuracy: \(String(format: "%.1f", currentLocation.horizontalAccuracy))m"
        print("📍 [WAYPOINT CHECK] [\(timeString)] \(checkLog)")
        debugLogger.log(checkLog, category: "WAYPOINT")
        
        // Project user's current position onto the polyline
        guard let userProjection = projectOntoPolyline(coordinate: currentLocation.coordinate, polyline: cachedRoutePath) else {
            let projectionFailLog = "⚠️ Failed to project location onto polyline"
            print("📍 [WAYPOINT CHECK] [\(timeString)] \(projectionFailLog)")
            debugLogger.log(projectionFailLog, category: "WAYPOINT")
            return
        }
        
        // v1.9.78: Enhanced projection logging with route segment info
        let segmentInfo: String
        if userProjection.segmentIndex < cachedRoutePath.count - 1 {
            let segmentStart = cachedRoutePath[userProjection.segmentIndex]
            let segmentEnd = cachedRoutePath[min(userProjection.segmentIndex + 1, cachedRoutePath.count - 1)]
            segmentInfo = "Segment \(userProjection.segmentIndex): (\(String(format: "%.6f", segmentStart.latitude)), \(String(format: "%.6f", segmentStart.longitude))) → (\(String(format: "%.6f", segmentEnd.latitude)), \(String(format: "%.6f", segmentEnd.longitude)))"
        } else {
            segmentInfo = "Segment \(userProjection.segmentIndex): (last segment)"
        }
        
        let projectionLog = "Projected position: segment=\(userProjection.segmentIndex), t=\(String(format: "%.3f", userProjection.t)), distanceToPolyline=\(String(format: "%.1f", userProjection.distanceToPolyline))m | \(segmentInfo)"
        debugLogger.log(projectionLog, category: "WAYPOINT")
        
        // v1.9.71: Add to position history for movement tracking
        let now = Date()
        recentProjectedPositions.append((userProjection.segmentIndex, userProjection.t, now))
        
        // Clean up old positions (keep last 30 seconds)
        recentProjectedPositions = recentProjectedPositions.filter { now.timeIntervalSince($0.timestamp) <= positionHistoryWindow }
        
        debugLogger.log("Position history: \(recentProjectedPositions.count) positions in last \(positionHistoryWindow)s", category: "WAYPOINT")
        
        // v1.9.71: Calculate distance moved along route (not straight-line, but along the polyline)
        let distanceMovedAlongRoute = calculateDistanceMovedAlongRoute(
            currentProjection: userProjection,
            recentPositions: recentProjectedPositions
        )
        
        debugLogger.log("Distance moved along route: \(String(format: "%.1f", distanceMovedAlongRoute))m (required: \(minMovementAlongRoute)m)", category: "WAYPOINT")
        
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
            // 1. Within 20m straight-line distance, AND
            // 2. User's polyline position is past the waypoint's position (stricter: > instead of >=)
            let userIsAtOrPastOnPolyline = isAhead(
                segmentIndex1: userProjection.segmentIndex,
                t1: userProjection.t,
                segmentIndex2: waypointSegment,
                t2: 0.6  // User should be at least 60% into the waypoint's segment (stricter)
            ) || userProjection.segmentIndex > waypoint.polylineIndex  // Stricter: > instead of >=
            
            // v1.9.71: Require actual movement along route before advancing (prevents GPS jitter)
            let hasMovedEnough = distanceMovedAlongRoute >= minMovementAlongRoute
            
            // v1.9.72: Check for consistent forward movement
            let hasConsistentMovement = hasConsistentForwardMovement(recentPositions: recentProjectedPositions)
            
            // v1.9.72: Check GPS accuracy for this reading
            let hasGoodAccuracy = currentLocation.horizontalAccuracy > 0 && currentLocation.horizontalAccuracy <= maxGPSAccuracy
            
            // v1.9.93: Check if we're trying to advance to a return journey waypoint
            // Use direction index (more reliable) OR polyline index as fallback
            let isReturnJourneyWaypoint: Bool
            if let returnStartIndex = returnJourneyStartIndex {
                // Use direction index - most reliable method
                isReturnJourneyWaypoint = index >= returnStartIndex
            } else if let lastMarkerIndex = lastMarkerPolylineIndex {
                // Fallback to polyline index check (use >= to catch waypoints at same index)
                isReturnJourneyWaypoint = waypoint.polylineIndex >= lastMarkerIndex
            } else {
                isReturnJourneyWaypoint = false
            }
            
            let canAdvanceToReturnJourney: Bool
            if isReturnJourneyWaypoint {
                // This is a return journey waypoint - check if last marker has been visited
                if let checkVisited = isLastMarkerVisited {
                    canAdvanceToReturnJourney = checkVisited()
                    if !canAdvanceToReturnJourney {
                        let blockLog: String
                        if let returnStartIndex = returnJourneyStartIndex {
                            blockLog = "🚫 BLOCKED: Trying to advance to return journey waypoint \(index + 1) ('\(waypoint.instruction)') but last marker not yet visited (waypoint index: \(index) >= return journey start: \(returnStartIndex))"
                        } else {
                            blockLog = "🚫 BLOCKED: Trying to advance to return journey waypoint \(index + 1) ('\(waypoint.instruction)') but last marker not yet visited (waypoint polylineIndex: \(waypoint.polylineIndex) >= last marker: \(lastMarkerPolylineIndex ?? -1))"
                        }
                        print("📍 [WAYPOINT CHECK] [\(timeString)] \(blockLog)")
                        debugLogger.log(blockLog, category: "DIRECTION_ADVANCE")
                    }
                } else {
                    // No check function provided - allow advancement (backward compatibility)
                    canAdvanceToReturnJourney = true
                }
            } else {
                // Not a return journey waypoint - allow advancement
                canAdvanceToReturnJourney = true
            }
            
            // Trigger notification if ALL conditions are met (stricter AND logic):
            // - Within 20m distance (stricter radius)
            // - Past on polyline
            // - Has moved enough along route
            // - Has consistent forward movement
            // - Has good GPS accuracy
            // - Can advance to return journey (if applicable)
            // OR failsafe: if very close (<8m), always trigger (stricter failsafe)
            let shouldTrigger = (distance <= 20 && userIsAtOrPastOnPolyline && hasMovedEnough && hasConsistentMovement && hasGoodAccuracy && canAdvanceToReturnJourney) ||
                                (distance <= 8 && canAdvanceToReturnJourney)  // Failsafe: if very close, always trigger (stricter failsafe)
            
            // v1.9.74: Comprehensive logging for direction advancement debugging
            let waypointLog = """
            Waypoint \(index + 1)/\(directionWaypoints.count): "\(waypoint.instruction)"
            - Distance: \(String(format: "%.1f", distance))m (threshold: 20m, failsafe: 8m)
            - User segment: \(userProjection.segmentIndex), t: \(String(format: "%.3f", userProjection.t))
            - Waypoint segment: \(waypointSegment), polylineIndex: \(waypoint.polylineIndex)
            - Conditions:
              * atOrPastOnPolyline: \(userIsAtOrPastOnPolyline) (user segment > waypoint OR t > 0.6)
              * hasMovedEnough: \(hasMovedEnough) (moved \(String(format: "%.1f", distanceMovedAlongRoute))m >= \(minMovementAlongRoute)m)
              * hasConsistentMovement: \(hasConsistentMovement) (needs \(minConsistentReadings) readings, \(consistencyThreshold*100)% forward)
              * hasGoodAccuracy: \(hasGoodAccuracy) (accuracy: \(String(format: "%.1f", currentLocation.horizontalAccuracy))m <= \(maxGPSAccuracy)m)
            - Network: \(currentNetworkType)
            - shouldTrigger: \(shouldTrigger)
            """
            
            // Always log when checking waypoints within range
            if distance <= 30 {  // Log for waypoints within 30m
                print("📍 [WAYPOINT CHECK] [\(timeString)] \(waypointLog)")
                debugLogger.log(waypointLog, category: "DIRECTION_ADVANCE")
                
                // Log why it's NOT triggering if it should be close
                if !shouldTrigger && distance <= 20 {
                    var failureReasons: [String] = []
                    if distance > 20 { failureReasons.append("Distance too far (\(String(format: "%.1f", distance))m > 20m)") }
                    if !userIsAtOrPastOnPolyline { failureReasons.append("Not past waypoint on polyline (user segment \(userProjection.segmentIndex) vs waypoint \(waypointSegment), t=\(String(format: "%.3f", userProjection.t)) < 0.6)") }
                    if !hasMovedEnough { failureReasons.append("Not moved enough (\(String(format: "%.1f", distanceMovedAlongRoute))m < \(minMovementAlongRoute)m)") }
                    if !hasConsistentMovement { failureReasons.append("No consistent forward movement") }
                    if !hasGoodAccuracy { failureReasons.append("Poor GPS accuracy (\(String(format: "%.1f", currentLocation.horizontalAccuracy))m > \(maxGPSAccuracy)m)") }
                    
                    let failureLog = "❌ NOT TRIGGERING waypoint \(index + 1) - Reasons: \(failureReasons.joined(separator: ", "))"
                    print("📍 [WAYPOINT CHECK] [\(timeString)] \(failureLog)")
                    debugLogger.log(failureLog, category: "DIRECTION_ADVANCE")
                }
            }
            
            if shouldTrigger {
                let triggerLog = "✅ TRIGGERED waypoint \(index + 1): '\(waypoint.instruction)' - Advancing from index \(currentDirectionIndex) to \(min(index + 1, directionWaypoints.count - 1))"
                print("📍 [WAYPOINT TRIGGER] [\(timeString)] \(triggerLog)")
                debugLogger.log(triggerLog, category: "DIRECTION_ADVANCE")
                NotificationService.shared.sendDirectionNotification(
                    instruction: waypoint.instruction,
                    distance: waypoint.distance,
                    stepNumber: index + 1,
                    totalSteps: directionWaypoints.count
                )
                
                notifiedDirectionIndices.insert(index)
                
                // Update current direction index
                // v1.9.90: Don't advance if current index is beyond directionWaypoints (e.g., showing arrival instruction)
                // The arrival instruction is added to cachedOriginalDirections but not to directionWaypoints
                if index >= currentDirectionIndex && currentDirectionIndex < directionWaypoints.count {
                    let newIndex = min(index + 1, directionWaypoints.count - 1)
                    let oldIndex = currentDirectionIndex
                    currentDirectionIndex = newIndex
                    debugLogger.log("Direction index updated: \(oldIndex) → \(newIndex)", category: "DIRECTION_ADVANCE")
                } else if currentDirectionIndex >= directionWaypoints.count {
                    // v1.9.90: Currently showing arrival instruction (index beyond directionWaypoints) - don't override
                    debugLogger.log("⚠️ Waypoint advancement blocked - currently showing arrival instruction (index \(currentDirectionIndex) >= \(directionWaypoints.count))", category: "DIRECTION_ADVANCE")
                }
                
                // v1.9.76: Keep position history for next waypoint (don't clear)
                // This allows movement tracking to continue across waypoint advances
                // Old positions will naturally expire via the time window filter
                // Only keep recent positions (last 10 seconds) to prevent stale data from affecting next waypoint
                let cutoffTime = now.addingTimeInterval(-10.0) // Keep last 10 seconds of positions
                recentProjectedPositions = recentProjectedPositions.filter { $0.timestamp >= cutoffTime }
                debugLogger.log("Kept \(recentProjectedPositions.count) recent positions for next waypoint tracking", category: "DIRECTION_ADVANCE")
                
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
    
    /// v1.9.72: Check if recent positions show consistent forward movement along route
    /// Returns true if at least 60% of readings show forward progress
    private func hasConsistentForwardMovement(recentPositions: [(segmentIndex: Int, t: Double, timestamp: Date)]) -> Bool {
        guard recentPositions.count >= minConsistentReadings else {
            return false  // Need at least minConsistentReadings to check consistency
        }
        
        // Sort by timestamp (oldest first)
        let sorted = recentPositions.sorted { $0.timestamp < $1.timestamp }
        
        // Count how many positions show forward progress compared to the previous one
        var forwardCount = 0
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            
            // Check if current position is ahead of previous
            if isAhead(
                segmentIndex1: curr.segmentIndex,
                t1: curr.t,
                segmentIndex2: prev.segmentIndex,
                t2: prev.t
            ) {
                forwardCount += 1
            }
        }
        
        // Require at least consistencyThreshold percentage of readings to show forward progress
        let forwardPercentage = Double(forwardCount) / Double(sorted.count - 1)
        return forwardPercentage >= consistencyThreshold
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
        
        // v1.9.74: Enhanced logging for network transitions
        let accuracy = newLocation.horizontalAccuracy
        let speed = newLocation.speed
        let course = newLocation.course
        let altitude = newLocation.altitude
        let timeSinceLastUpdate: TimeInterval
        if let lastLocation = currentLocation {
            timeSinceLastUpdate = newLocation.timestamp.timeIntervalSince(lastLocation.timestamp)
        } else {
            timeSinceLastUpdate = 0
        }
        
        // v1.9.78: Enhanced location logging with direction context
        var locationLog = "Location: (\(String(format: "%.6f", newLocation.coordinate.latitude)), \(String(format: "%.6f", newLocation.coordinate.longitude))), Accuracy: \(String(format: "%.1f", accuracy))m, Speed: \(String(format: "%.2f", speed))m/s, Course: \(String(format: "%.1f", course))°, Network: \(currentNetworkType), TimeSinceLast: \(String(format: "%.2f", timeSinceLastUpdate))s"
        
        // Add current direction info if monitoring
        if isMonitoringDirections && currentDirectionIndex < directionWaypoints.count {
            let currentWaypoint = directionWaypoints[currentDirectionIndex]
            locationLog += " | Current direction: [\(currentDirectionIndex)] '\(currentWaypoint.instruction)'"
        }
        
        print("📍 [LOCATION UPDATE] [\(timeString)] \(locationLog)")
        debugLogger.log(locationLog, category: "LOCATION")
        
        // Log if accuracy is poor (might indicate network transition issue)
        if accuracy > maxGPSAccuracy {
            let poorAccuracyLog = "⚠️ POOR ACCURACY - Rejecting: \(String(format: "%.1f", accuracy))m > max \(maxGPSAccuracy)m, Network: \(currentNetworkType)"
            print("📍 [LOCATION UPDATE] [\(timeString)] \(poorAccuracyLog)")
            debugLogger.log(poorAccuracyLog, category: "GPS_FILTER")
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
            
            // Calculate distance walked (ignore small movements to avoid GPS jitter when stationary)
            if let lastLocation = self.routeLocations.last {
                let distance = newLocation.distance(from: lastLocation)
                if distance >= self.minDistanceToCountAsWalked {
                    self.distanceWalked += distance
                }
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
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        print("❌ [LOCATION ERROR] [\(timeString)] Location manager failed with error")
        print("❌ [LOCATION ERROR] [\(timeString)]   Error: \(error.localizedDescription)")
        print("❌ [LOCATION ERROR] [\(timeString)]   Network: \(currentNetworkType)")
        print("❌ [LOCATION ERROR] [\(timeString)]   Tracking: \(isTracking), Monitoring: \(isMonitoringDirections)")
        print("❌ [LOCATION ERROR] [\(timeString)]   Current location: \(currentLocation != nil ? "Yes" : "No")")
        
        if let clError = error as? CLError {
            print("❌ [LOCATION ERROR] [\(timeString)]   CLError code: \(clError.code.rawValue)")
            switch clError.code {
            case .locationUnknown:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: locationUnknown - Location could not be determined")
            case .denied:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: denied - Location services denied")
            case .network:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: network - Network unavailable or bad")
            case .headingFailure:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: headingFailure - Heading could not be determined")
            case .regionMonitoringDenied:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: regionMonitoringDenied")
            case .regionMonitoringFailure:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: regionMonitoringFailure")
            case .regionMonitoringSetupDelayed:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: regionMonitoringSetupDelayed")
            case .regionMonitoringResponseDelayed:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: regionMonitoringResponseDelayed")
            case .geocodeFoundNoResult:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: geocodeFoundNoResult")
            case .geocodeFoundPartialResult:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: geocodeFoundPartialResult")
            case .geocodeCanceled:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: geocodeCanceled")
            default:
                print("❌ [LOCATION ERROR] [\(timeString)]   Code: unknown")
            }
        }
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

