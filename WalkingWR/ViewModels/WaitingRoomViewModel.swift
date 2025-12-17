//
//  WaitingRoomViewModel.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import SwiftUI
import Combine
import CoreLocation
import FirebaseMessaging

@MainActor
class WaitingRoomViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var waitTimeInfo: WaitTimeInfo
    @Published var availableRoutes: [WalkingRoute] = WalkingRoute.sampleRoutes
    @Published var selectedRoute: WalkingRoute?
    @Published var walkSession: WalkSession = WalkSession()
    @Published var userProgress: UserProgress = UserProgress()
    
    @Published var showHalfwayAlert: Bool = false
    @Published var showReturnAlert: Bool = false
    @Published var showClinicianReadyAlert: Bool = false
    @Published var showWaitTimeIncreasedAlert: Bool = false
    @Published var showWaitTimeDecreasedAlert: Bool = false
    @Published var waitTimeChangeInfo: (oldMinutes: Int, newMinutes: Int, isIncrease: Bool)?
    @Published var showPreWalkWellbeing: Bool = false
    @Published var showPostWalkWellbeing: Bool = false
    
    // Location-based marker detection
    @Published var showMarkerArrivalPrompt: Bool = false
    @Published var currentMarker: QRMarker? = nil
    @Published var visitedMarkerIds: Set<UUID> = []
    
    // Clinician selection
    @Published var availableClinicians: [Clinician] = []
    @Published var selectedClinician: Clinician?
    @Published var showClinicianSelection: Bool = false
    private let allClinicians: [Clinician] = Clinician.sampleClinicians
    
    // Simulated EPR updates
    @Published var isSimulatingUpdates: Bool = true
    
    private var cancellables = Set<AnyCancellable>()
    private var walkTimer: Timer?
    private var updateTimer: Timer?
    
    let healthKitService = HealthKitService()
    let notificationService = NotificationService.shared
    let locationService = LocationService()
    let firebaseService = FirebaseService()
    
    // MARK: - Initialization
    init() {
        // Load saved clinician or use default
        if let savedClinicianId = UserDefaults.standard.string(forKey: "selectedClinicianId"),
           let uuid = UUID(uuidString: savedClinicianId),
           let clinician = Clinician.sampleClinicians.first(where: { $0.id == uuid }) {
            self.selectedClinician = clinician
            self.waitTimeInfo = WaitTimeInfo(from: clinician)
        } else {
            // Default wait time info (no clinician selected yet)
            self.waitTimeInfo = WaitTimeInfo(
                estimatedMinutes: 20,
                lastUpdated: Date(),
                clinicianName: "Select your clinician",
                queuePosition: 0
            )
        }
        
        // Listen to Firebase for real wait times
        setupFirebaseListener()
        
        // Request notification permission on startup (needed for delay change alerts)
        // Location and HealthKit permissions are requested when starting a walk
        // This provides a better user experience (just-in-time permissions)
        Task {
            await notificationService.requestAuthorization()
        }
        
        // Record app usage for streak tracking
        userProgress.recordAppUsage()
    }
    
    // MARK: - Firebase Real-Time Updates
    private func setupFirebaseListener() {
        // Subscribe to full clinician data changes (bio, photo, delay, etc.)
        firebaseService.$clinicians
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clinicians in
                self?.rebuildCliniciansFromFirebase(clinicians)
            }
            .store(in: &cancellables)
    }
    
    private func rebuildCliniciansFromFirebase(_ firebaseClinicians: [FirebaseClinicianData]) {
        guard !firebaseClinicians.isEmpty else {
            // If Firebase has no data yet, show all clinicians as fallback
            availableClinicians = allClinicians
            print("⏳ No Firebase data yet, using fallback clinicians")
            return
        }
        
        // Build clinicians entirely from Firebase data
        var result: [Clinician] = []
        
        for firebaseData in firebaseClinicians {
            let clinician = createClinicianFromFirebase(firebaseData)
            result.append(clinician)
            print("✅ Built clinician from Firebase: \(clinician.fullTitle) - \(clinician.currentWaitMinutes)min")
        }
        
        availableClinicians = result
        print("👥 Total clinicians from Firebase: \(availableClinicians.count)")
        
        // Update selected clinician if they exist in new data
        if let selected = selectedClinician {
            if let updatedData = firebaseClinicians.first(where: { 
                $0.name.lowercased() == selected.name.lowercased() ||
                $0.fullName.lowercased() == selected.fullTitle.lowercased()
            }) {
                let previousDelay = waitTimeInfo.estimatedMinutes
                let newDelay = updatedData.delay
                let isWalking = walkSession.isActive
                
                // Check for delay changes and notify
                if previousDelay > 0 && newDelay != previousDelay {
                    if newDelay > previousDelay {
                        // Delay increased
                        notificationService.sendWaitTimeIncreasedNotification(
                            oldMinutes: previousDelay,
                            newMinutes: newDelay,
                            isWalking: isWalking
                        )
                        waitTimeChangeInfo = (oldMinutes: previousDelay, newMinutes: newDelay, isIncrease: true)
                        showWaitTimeIncreasedAlert = true
                        print("⚠️ Delay increased: \(previousDelay) → \(newDelay) min")
                    } else if previousDelay - newDelay >= 2 {
                        // Delay decreased by 2+ minutes
                        notificationService.sendWaitTimeDecreasedNotification(
                            oldMinutes: previousDelay,
                            newMinutes: newDelay,
                            isWalking: isWalking
                        )
                        waitTimeChangeInfo = (oldMinutes: previousDelay, newMinutes: newDelay, isIncrease: false)
                        showWaitTimeDecreasedAlert = true
                        print("✅ Delay decreased: \(previousDelay) → \(newDelay) min")
                    }
                }
                
                // Update selected clinician with ALL new data
                selectedClinician = createClinicianFromFirebase(updatedData)
                
                // Update waitTimeInfo
                waitTimeInfo.estimatedMinutes = newDelay
                waitTimeInfo.lastUpdated = Date()
                waitTimeInfo.clinicianName = updatedData.fullName
                
                print("🔄 Updated selected clinician: \(updatedData.fullName) - all fields refreshed")
            }
        }
    }
    
    /// Create a Clinician from Firebase/Google Sheets data
    private func createClinicianFromFirebase(_ data: FirebaseClinicianData) -> Clinician {
        return Clinician(
            name: data.name,
            title: data.title,
            specialty: data.specialty,
            photoName: nil,                    // No local asset
            photoURL: data.photoURL,           // Remote URL from Google Sheets
            bio: data.bio,
            expertiseDescription: data.expertise ?? "Clinical details available on request.",
            expertiseTags: data.expertiseTags,
            achievements: data.achievements ?? "",
            publicationsIntro: data.publications ?? "",
            publicationTitle: nil,
            publicationSubtitle: nil,
            publicationsOutro: "",
            interests: parseInterests(data.interests),
            interestsDescription: data.interests ?? "",
            currentWaitMinutes: data.delay,
            queuePosition: 0
        )
    }
    
    /// Parse interests string into ClinicianInterest array
    private func parseInterests(_ interestsString: String?) -> [Clinician.ClinicianInterest] {
        guard let interests = interestsString, !interests.isEmpty else { return [] }
        
        // Simple parsing: comma-separated interests with default icons
        let defaultIcons = ["heart.fill", "star.fill", "leaf.fill", "book.fill", "figure.walk"]
        return interests.components(separatedBy: ",").enumerated().map { index, interest in
            let iconIndex = index % defaultIcons.count
            return Clinician.ClinicianInterest(
                icon: defaultIcons[iconIndex],
                text: interest.trimmingCharacters(in: .whitespaces)
            )
        }
    }
    
    
    // MARK: - Route Selection
    func suggestedRoutes(for waitMinutes: Int) -> [WalkingRoute] {
        // Filter routes that can be completed within the wait time
        // Leave a 5-minute buffer for return
        let maxDuration = waitMinutes - 5
        
        return availableRoutes
            .filter { $0.durationMinutes <= maxDuration }
            .sorted { $0.durationMinutes > $1.durationMinutes } // Prefer longer routes
    }
    
    func selectRoute(_ route: WalkingRoute) {
        selectedRoute = route
    }
    
    // MARK: - Permission Requests (Just-in-Time)
    
    /// Request permissions needed for walking - called when user starts a walk
    private func requestWalkPermissions() {
        // Request location permission if not already authorized
        if !locationService.isAuthorized {
            locationService.requestPermission()
        }
        
        // Request HealthKit permission for step counting
        Task {
            await healthKitService.requestAuthorization()
        }
    }
    
    // MARK: - Walk Session Management
    func startWalk() {
        guard let route = selectedRoute else { return }
        
        // Request permissions just-in-time when starting a walk
        requestWalkPermissions()
        
        walkSession.isActive = true
        walkSession.startTime = Date()
        walkSession.currentRoute = route
        walkSession.halfwayAlertSent = false
        walkSession.stepsThisSession = 0
        walkSession.markersScanned = []
        
        // Calculate return time (halfway point of route duration)
        let halfwaySeconds = Double(route.durationMinutes * 60) / 2
        walkSession.estimatedReturnTime = Date().addingTimeInterval(halfwaySeconds)
        
        // Start health tracking
        healthKitService.startObservingSteps(from: Date())
        
        // Start location tracking (requests permission if needed)
        locationService.startTracking()
        
        // Schedule notifications
        notificationService.sendWalkStartedNotification(routeName: route.name, duration: route.durationMinutes)
        scheduleWalkNotifications(routeDuration: route.durationMinutes)
        
        // Start session timer
        startSessionTimer()
        
        // Prompt for pre-walk wellbeing score if not already done
        if userProgress.anxietyLevelBefore == nil {
            showPreWalkWellbeing = true
        }
    }
    
    func endWalk(completed: Bool) {
        walkSession.isActive = false
        
        // Record progress
        if completed {
            userProgress.routesCompleted += 1
            userProgress.todayRoutesCompleted += 1
            userProgress.addPoints(50 + walkSession.stepsThisSession / 10)
        }
        
        // Transfer steps
        userProgress.recordSteps(walkSession.stepsThisSession)
        
        // Stop tracking
        healthKitService.stopObserving()
        locationService.stopTracking()
        notificationService.cancelAllWalkingNotifications()
        stopSessionTimer()
        
        // Prompt for post-walk wellbeing score
        if completed && userProgress.anxietyLevelBefore != nil {
            showPostWalkWellbeing = true
        }
        
        // Reset session
        walkSession.startTime = nil
        walkSession.currentRoute = nil
        selectedRoute = nil
        visitedMarkerIds = []
        currentMarker = nil
    }
    
    private func startSessionTimer() {
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSession()
            }
        }
        // Ensure timer runs even when scrolling
        if let timer = walkTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopSessionTimer() {
        walkTimer?.invalidate()
        walkTimer = nil
    }
    
    private func updateSession() {
        guard walkSession.isActive else { return }
        
        // Update elapsed time
        walkSession.updateElapsedTime()
        
        // Update steps from pedometer/HealthKit (real-time)
        walkSession.stepsThisSession = healthKitService.stepCount
        
        // Use pedometer distance if available, otherwise use GPS
        if healthKitService.distance > 0 {
            locationService.distanceWalked = healthKitService.distance
        }
        
        #if targetEnvironment(simulator)
        // Only simulate on simulator (no real sensors)
        if walkSession.elapsedSeconds > 3 {
            let elapsedMinutes = Double(walkSession.elapsedSeconds) / 60.0
            walkSession.stepsThisSession = Int(elapsedMinutes * 100)
            locationService.distanceWalked = elapsedMinutes * 80
        }
        #endif
        
        // Check for marker proximity (location-based triggers)
        checkMarkerProximity()
        
        // Force view update for nested observable
        objectWillChange.send()
        
        // Check for halfway point
        if !walkSession.halfwayAlertSent,
           let returnTime = walkSession.estimatedReturnTime,
           Date() >= returnTime {
            walkSession.halfwayAlertSent = true
            showHalfwayAlert = true
        }
        
        // Check if walk should be complete
        if walkSession.progress >= 1.0 {
            showReturnAlert = true
        }
    }
    
    // MARK: - Location-Based Marker Detection
    private func checkMarkerProximity() {
        guard let route = selectedRoute,
              let userLocation = locationService.currentLocation else { return }
        
        // Check each marker on the route
        for marker in route.qrMarkers {
            // Skip already visited markers
            guard !visitedMarkerIds.contains(marker.id) else { continue }
            
            // Calculate distance to marker (in meters)
            let markerLocation = CLLocation(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
            let distance = userLocation.distance(from: markerLocation)
            
            // Trigger when within 20 meters of marker
            if distance < 20 {
                currentMarker = marker
                visitedMarkerIds.insert(marker.id)
                walkSession.markersScanned.append(marker)
                userProgress.qrScansCompleted += 1
                userProgress.todayQRScansCompleted += 1
                userProgress.addPoints(marker.pointsValue)
                
                // Show the photo prompt
                showMarkerArrivalPrompt = true
                
                // Send notification
                notificationService.sendMarkerArrivalNotification(markerName: marker.name)
                break
            }
        }
    }
    
    func dismissMarkerPrompt() {
        showMarkerArrivalPrompt = false
        currentMarker = nil
    }
    
    // MARK: - Notifications
    private func scheduleWalkNotifications(routeDuration: Int) {
        let halfwaySeconds = Double(routeDuration * 60) / 2
        notificationService.scheduleHalfwayNotification(in: halfwaySeconds)
        
        // Return notification at 80% of route
        let returnSeconds = Double(routeDuration * 60) * 0.8
        notificationService.scheduleReturnNowNotification(in: returnSeconds)
    }
    
    // MARK: - Simulated EPR Updates (Disabled - using Firebase)
    private func startSimulatedUpdates() {
        // Disabled - now using Firebase real-time updates
        // Keep for fallback if Firebase is unavailable
        guard isSimulatingUpdates && firebaseService.clinicianDelays.isEmpty else { return }
        
        // Simulate EPR updates every 30-60 seconds (fallback only)
        updateTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 30...60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Only simulate if Firebase has no data
                if self?.firebaseService.clinicianDelays.isEmpty == true {
                    self?.simulateEPRUpdate()
                }
            }
        }
    }
    
    private func simulateEPRUpdate() {
        guard waitTimeInfo.estimatedMinutes > 5 else { return }
        
        // Random delay change (-3 to +5 minutes)
        let change = Int.random(in: -3...2)
        let newWait = max(5, waitTimeInfo.estimatedMinutes + change)
        
        waitTimeInfo.estimatedMinutes = newWait
        waitTimeInfo.lastUpdated = Date()
        
        // Update selected clinician's wait time too
        if var clinician = selectedClinician {
            clinician.currentWaitMinutes = newWait
            clinician.lastUpdated = Date()
            selectedClinician = clinician
        }
        
        // Queue position might decrease
        if change < 0 && waitTimeInfo.queuePosition > 1 {
            waitTimeInfo.queuePosition -= 1
        }
        
        // Update notifications if on a walk
        if walkSession.isActive, let route = walkSession.currentRoute {
            recalculateReturnTime(for: route)
        }
    }
    
    // MARK: - Clinician Selection
    func selectClinician(_ clinician: Clinician) {
        // Unsubscribe from old clinician topic
        if let old = selectedClinician {
            let oldTopic = "clinician_" + old.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            Messaging.messaging().unsubscribe(fromTopic: oldTopic) { error in
                if let error = error {
                    print("Error unsubscribing from topic: \(error)")
                } else {
                    print("Unsubscribed from topic: \(oldTopic)")
                }
            }
        }
        
        // Subscribe to new clinician topic
        let newTopic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        Messaging.messaging().subscribe(toTopic: newTopic) { error in
            if let error = error {
                print("Error subscribing to topic: \(error)")
            } else {
                print("Subscribed to topic: \(newTopic)")
            }
        }
        
        selectedClinician = clinician
        waitTimeInfo = WaitTimeInfo(from: clinician)
        
        // Save selection
        UserDefaults.standard.set(clinician.id.uuidString, forKey: "selectedClinicianId")
    }
    
    func clearClinicianSelection() {
        selectedClinician = nil
        UserDefaults.standard.removeObject(forKey: "selectedClinicianId")
        waitTimeInfo = WaitTimeInfo(
            estimatedMinutes: 20,
            lastUpdated: Date(),
            clinicianName: "Select your clinician",
            queuePosition: 0
        )
    }
    
    var hasSelectedClinician: Bool {
        selectedClinician != nil
    }
    
    private func recalculateReturnTime(for route: WalkingRoute) {
        // Adjust return time based on updated wait
        let remainingWait = Double(waitTimeInfo.estimatedMinutes * 60)
        let halfwayTime = remainingWait / 2
        
        walkSession.estimatedReturnTime = Date().addingTimeInterval(halfwayTime)
    }
    
    func stopSimulation() {
        updateTimer?.invalidate()
        updateTimer = nil
        isSimulatingUpdates = false
    }
    
    // MARK: - QR Scanning
    func processQRCode(_ code: String) -> QRMarker? {
        // First check if marker exists in the selected route
        if let route = selectedRoute,
           let existingMarker = route.qrMarkers.first(where: { $0.code == code }) {
            walkSession.markersScanned.append(existingMarker)
            userProgress.qrScansCompleted += 1
            userProgress.todayQRScansCompleted += 1
            userProgress.addPoints(existingMarker.pointsValue)
            return existingMarker
        }
        
        // For unknown codes, create a sample marker
        let currentLocation = locationService.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 53.4084, longitude: -1.4350)
        let marker = QRMarker(
            code: code,
            name: "Discovered Marker",
            location: "Along your route",
            coordinate: currentLocation,
            contentType: .breathingExercise,
            content: WellbeingContent.breathingExercises.randomElement()!,
            pointsValue: 10
        )
        
        walkSession.markersScanned.append(marker)
        userProgress.qrScansCompleted += 1
        userProgress.todayQRScansCompleted += 1
        userProgress.addPoints(marker.pointsValue)
        
        return marker
    }
    
    // MARK: - Anxiety Tracking
    func recordAnxietyBefore(_ level: Int) {
        userProgress.anxietyLevelBefore = level
        objectWillChange.send() // Force UI refresh
    }
    
    func recordAnxietyAfter(_ level: Int) {
        userProgress.anxietyLevelAfter = level
        objectWillChange.send() // Force UI refresh
    }
    
    func recordAnxietyAfterWalk(_ level: Int) {
        userProgress.anxietyLevelAfter = level
        userProgress.anxietyLevelAfterWalk = level
        objectWillChange.send() // Force UI refresh
    }
    
    var anxietyReduction: Int? {
        guard let before = userProgress.anxietyLevelBefore,
              let after = userProgress.anxietyLevelAfter else { return nil }
        return before - after
    }
    
    // MARK: - Digital Skills
    func markDigitalSkillCompleted(_ skillId: String) {
        userProgress.markDigitalSkillComplete(skillId)
    }
}

// MARK: - Simulated Demo Actions
extension WaitingRoomViewModel {
    func simulateClinicianReady() {
        showClinicianReadyAlert = true
        notificationService.scheduleClinicianReadyNotification()
        
        if walkSession.isActive {
            showReturnAlert = true
        }
    }
    
    func simulateDelayIncrease() {
        waitTimeInfo.estimatedMinutes += 10
        waitTimeInfo.lastUpdated = Date()
        notificationService.scheduleDelayUpdateNotification(newWaitMinutes: waitTimeInfo.estimatedMinutes)
    }
}


