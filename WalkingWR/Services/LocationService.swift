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
    
    // Direction monitoring
    @Published var currentDirectionIndex: Int = 0
    @Published var isMonitoringDirections: Bool = false
    @Published var isSignificantlyOffRoute: Bool = false  // v1.9.15: Track if user has deviated significantly
    private var directionWaypoints: [(coordinate: CLLocationCoordinate2D, instruction: String, distance: String)] = []
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
        guard isAuthorized else {
            requestPermission()
            return
        }
        
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
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: Date())
        
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("✅ HEADING UPDATES STARTED")
        print("═══════════════════════════════════════════════════════════")
        print("Time: \(timeString)")
        print("isTracking: \(isTracking)")
        print("═══════════════════════════════════════════════════════════")
        print("")
        
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
        
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("⛔ HEADING UPDATES STOPPED")
        print("═══════════════════════════════════════════════════════════")
        print("Time: \(timeString)")
        print("isTracking: \(isTracking)")
        print("═══════════════════════════════════════════════════════════")
        print("")
        
        stopHeadingUpdateMonitoring()
        stopDirectionMonitoring()
    }
    
    // MARK: - Direction Monitoring
    
    /// Start monitoring for direction waypoints to send turn-by-turn notifications
    func startDirectionMonitoring(directions: [WalkingDirection], routePath: [CLLocationCoordinate2D]) {
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
                distance: direction.distance
            ))
            
            cumulativeDistance += Double(direction.distanceMeters)
        }
        
        isMonitoringDirections = true
        print("📍 Started direction monitoring with \(directionWaypoints.count) waypoints")
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
    private func checkDirectionWaypoints(currentLocation: CLLocation) {
        guard isMonitoringDirections, !directionWaypoints.isEmpty else { return }
        
        // Check upcoming waypoints (current and next few)
        let checkRange = currentDirectionIndex..<min(currentDirectionIndex + 3, directionWaypoints.count)
        
        for index in checkRange {
            // Skip if already notified for this waypoint
            guard !notifiedDirectionIndices.contains(index) else { continue }
            
            let waypoint = directionWaypoints[index]
            let waypointLocation = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
            let distance = currentLocation.distance(from: waypointLocation)
            
            // If within notification radius, send notification
            if distance <= directionNotificationRadius {
                NotificationService.shared.sendDirectionNotification(
                    instruction: waypoint.instruction,
                    distance: waypoint.distance,
                    stepNumber: index + 1,
                    totalSteps: directionWaypoints.count
                )
                
                notifiedDirectionIndices.insert(index)
                
                // Update current direction index
                if index >= currentDirectionIndex {
                    DispatchQueue.main.async {
                        // v1.9.15: Ensure index doesn't go out of bounds
                        let newIndex = min(index + 1, self.directionWaypoints.count - 1)
                        self.currentDirectionIndex = newIndex
                    }
                }
                
                print("📍 Direction notification sent for step \(index + 1): \(waypoint.instruction)")
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
        if !isAuthorized {
            requestPermission()
            return
        }
        
        // Show fetching state
        isFetchingLocation = true
        
        // Use requestLocation() for faster one-shot location
        locationManager.requestLocation()
        
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
        guard let newLocation = locations.last else { return }
        
        DispatchQueue.main.async {
            // Mark fetching complete and cancel retry timer
            self.locationObtained()
            
            // Set start location on first update
            if self.startLocation == nil {
                self.startLocation = newLocation
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
            print("========================================")
            print("⚠️ HEADING UPDATE RESUMED")
            print("Time: \(timeString)")
            print("Gap: \(String(format: "%.1f", timeSince))s")
            print("========================================")
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📍 HEADING UPDATE RECEIVED")
        print("Time: \(timeString)")
        print("trueHeading: \(trueHeading >= 0 ? "\(trueHeading)°" : "INVALID (\(trueHeading))")")
        print("magneticHeading: \(magneticHeading)°")
        print("using: \(finalHeading)°")
        print("accuracy: \(newHeading.headingAccuracy >= 0 ? "\(newHeading.headingAccuracy)°" : "INVALID")")
        print("timeSinceLastUpdate: \(timeSinceLastUpdate != nil ? String(format: "%.2f", timeSinceLastUpdate!) + "s" : "N/A")")
        
        // Log if heading is invalid
        if trueHeading < 0 && magneticHeading < 0 {
            print("⚠️ WARNING: Both headings invalid!")
            print("trueHeading: \(trueHeading)")
            print("magneticHeading: \(magneticHeading)")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        DispatchQueue.main.async {
            let previousHeading = self.headingDegrees
            self.heading = newHeading
            self.headingDegrees = finalHeading
            
            // Log if heading changed significantly or stopped updating
            let headingDiff = abs(finalHeading - previousHeading)
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("🔄 HEADING DEGREES UPDATED")
            print("Time: \(timeString)")
            print("Previous: \(previousHeading)°")
            print("New: \(finalHeading)°")
            print("Difference: \(String(format: "%.2f", headingDiff))°")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
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
            
            if let lastUpdate = self.lastHeadingUpdateTime {
                let timeSince = Date().timeIntervalSince(lastUpdate)
                if timeSince > 3.0 {
                    print("")
                    print("═══════════════════════════════════════════════════════════")
                    print("⚠️⚠️⚠️ HEADING UPDATES HAVE STOPPED ⚠️⚠️⚠️")
                    print("═══════════════════════════════════════════════════════════")
                    print("Time: \(timeString)")
                    print("Last update: \(String(format: "%.1f", timeSince))s ago")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("STATE CHECK:")
                    print("  isTracking: \(self.isTracking)")
                    print("  current headingDegrees: \(self.headingDegrees)°")
                    print("  heading object: \(self.heading != nil ? "EXISTS" : "NIL")")
                    if let heading = self.heading {
                        print("  heading.trueHeading: \(heading.trueHeading >= 0 ? "\(heading.trueHeading)°" : "INVALID")")
                        print("  heading.magneticHeading: \(heading.magneticHeading)°")
                        print("  heading.headingAccuracy: \(heading.headingAccuracy >= 0 ? "\(heading.headingAccuracy)°" : "INVALID")")
                    }
                    print("═══════════════════════════════════════════════════════════")
                    print("")
                }
            } else {
                print("")
                print("═══════════════════════════════════════════════════════════")
                print("⚠️⚠️⚠️ HEADING UPDATES NEVER STARTED ⚠️⚠️⚠️")
                print("═══════════════════════════════════════════════════════════")
                print("Time: \(timeString)")
                print("No updates received yet")
                print("isTracking: \(self.isTracking)")
                print("═══════════════════════════════════════════════════════════")
                print("")
            }
        }
    }
    
    private func stopHeadingUpdateMonitoring() {
        headingUpdateTimer?.invalidate()
        headingUpdateTimer = nil
    }
}

