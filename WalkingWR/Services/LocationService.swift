//
//  LocationService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import CoreLocation
import Combine

class LocationService: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var distanceWalked: Double = 0 // in meters
    @Published var routeLocations: [CLLocation] = []
    @Published var heading: CLHeading?
    @Published var headingDegrees: Double = 0
    @Published var isFetchingLocation: Bool = false
    @Published var locationRetryCount: Int = 0
    @Published var isRetrying: Bool = false
    
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
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    func stopTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
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
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
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
        DispatchQueue.main.async {
            self.heading = newHeading
            self.headingDegrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }
}

