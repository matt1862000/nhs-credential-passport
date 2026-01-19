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
    private var directionWaypoints: [(coordinate: CLLocationCoordinate2D, instruction: String, distance: String, routeIndex: Int)] = []  // v1.9.68: Store route index for accurate advancement
    private var notifiedDirectionIndices: Set<Int> = []
    private var cachedRoutePath: [CLLocationCoordinate2D] = []  // v1.9.15: Cache route path for deviation detection
    private let directionNotificationRadius: Double = 30 // meters - notify when within 30m of turn
    private let deviationThreshold: Double = 50.0  // v1.9.15: Consider off-route if >50m from route
    
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
    /// Start monitoring for direction waypoints to send turn-by-turn notifications
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
            
            for i in routeIndex..<(totalRoutePoints - 1) {
                let from = CLLocation(latitude: routePath[i].latitude, longitude: routePath[i].longitude)
                let to = CLLocation(latitude: routePath[i + 1].latitude, longitude: routePath[i + 1].longitude)
                let segmentDist = from.distance(from: to)
                
                if accumulatedDist + segmentDist >= targetDistance - cumulativeDistance {
                    // This segment contains our waypoint
                    waypointCoord = routePath[i + 1]
                    routeIndex = i + 1
                    break
                }
                accumulatedDist += segmentDist
            }
            
            directionWaypoints.append((
                coordinate: waypointCoord,
                instruction: direction.instruction,
                distance: direction.distance,
                routeIndex: routeIndex  // v1.9.68: Store route index for accurate advancement
            ))
            
            cumulativeDistance += Double(direction.distanceMeters)
        }
        
        // v1.9.63/v1.9.65/v1.9.66: Check if user has already passed the first waypoint(s)
        // Only do this for mid-walk direction changes, NOT for fresh walk starts
        // This handles cases where return directions are switched and user is partway through
        if skipPassedWaypoints, let currentLoc = currentLocation, !directionWaypoints.isEmpty, !routePath.isEmpty {
            // Find closest point on route path to user's current location
            var closestRouteIndex = 0
            var closestRouteDistance = Double.greatestFiniteMagnitude
            for (index, routePoint) in routePath.enumerated() {
                let routeLocation = CLLocation(latitude: routePoint.latitude, longitude: routePoint.longitude)
                let distance = currentLoc.distance(from: routeLocation)
                if distance < closestRouteDistance {
                    closestRouteDistance = distance
                    closestRouteIndex = index
                }
            }
            
            // v1.9.66: Only skip if user is significantly along the route (past 10% of route points)
            // This prevents skipping when user is at the START of return directions
            let minRouteProgressToSkip = max(5, routePath.count / 10)  // At least 5 points or 10%
            
            // Check each waypoint in order - skip any that are already behind the user along the route
            var skippedCount = 0
            for (index, waypoint) in directionWaypoints.enumerated() {
                // v1.9.68: Use stored route index instead of recalculating
                let waypointRouteIndex = waypoint.routeIndex
                
                // v1.9.66: Only skip if:
                // 1. User is past this waypoint along the route path AND
                // 2. User has made significant progress (not just at the start)
                let isPastWaypointOnRoute = closestRouteIndex > waypointRouteIndex
                let hasSignificantProgress = closestRouteIndex >= minRouteProgressToSkip
                
                if isPastWaypointOnRoute && hasSignificantProgress {
                    skippedCount = index + 1
                    notifiedDirectionIndices.insert(index) // Mark as already notified
                } else {
                    // User hasn't made enough progress or hasn't passed this waypoint
                    break
                }
            }
            
            if skippedCount > 0 {
                currentDirectionIndex = min(skippedCount, directionWaypoints.count - 1)
                print("📍 Skipped \(skippedCount) waypoint(s) - user already past. Starting at index \(currentDirectionIndex)")
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
        NotificationService.shared.cancelDirectionNotifications()
    }
    
    /// Check if user is approaching any direction waypoint and send notification
    /// v1.9.67: Fixed to use route-position-based advancement, not just distance
    private func checkDirectionWaypoints(currentLocation: CLLocation) {
        guard isMonitoringDirections, !directionWaypoints.isEmpty, !cachedRoutePath.isEmpty else { return }
        
        // v1.9.67: Find user's position along the route path
        var userRouteIndex = 0
        var closestDistanceToRoute = Double.greatestFiniteMagnitude
        for (index, routePoint) in cachedRoutePath.enumerated() {
            let routeLocation = CLLocation(latitude: routePoint.latitude, longitude: routePoint.longitude)
            let distance = currentLocation.distance(from: routeLocation)
            if distance < closestDistanceToRoute {
                closestDistanceToRoute = distance
                userRouteIndex = index
            }
        }
        
        // Check upcoming waypoints (current and next few)
        let checkRange = currentDirectionIndex..<min(currentDirectionIndex + 3, directionWaypoints.count)
        
        for index in checkRange {
            // Skip if already notified for this waypoint
            guard !notifiedDirectionIndices.contains(index) else { continue }
            
            let waypoint = directionWaypoints[index]
            let waypointLocation = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
            let distance = currentLocation.distance(from: waypointLocation)
            let waypointRouteIndex = waypoint.routeIndex  // v1.9.68: Use stored route index
            
            // v1.9.68: Advancement logic - more lenient for far-apart waypoints
            // Advance if:
            // 1. User has PASSED the waypoint on the route (userRouteIndex > waypointRouteIndex)
            //    AND user is reasonably close (< 100m) - prevents skipping when way off route
            // 2. OR user is very close (< 30m) - for immediate turns
            // 3. OR it's the first waypoint (index 0) at the start
            let hasPassedWaypoint = userRouteIndex > waypointRouteIndex
            let isCloseEnough = distance < 100  // More lenient for far waypoints
            let isVeryClose = distance <= directionNotificationRadius  // 30m for immediate turns
            let isFirstWaypointAtStart = (index == 0 && waypointRouteIndex <= 3)
            
            let shouldAdvance = (hasPassedWaypoint && isCloseEnough) || isVeryClose || isFirstWaypointAtStart
            
            if shouldAdvance {
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
                
                print("📍 Direction notification sent for step \(index + 1): \(waypoint.instruction) (userRouteIdx=\(userRouteIndex), waypointRouteIdx=\(waypointRouteIndex))")
                break // Only send one notification at a time
            }
        }
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

