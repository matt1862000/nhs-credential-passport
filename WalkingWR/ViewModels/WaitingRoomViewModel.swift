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
    @Published var showReturnNowAlert: Bool = false  // 80% - time to head back
    @Published var showWalkCompleteAlert: Bool = false  // 100% - walk finished
    @Published var showClinicianReadyAlert: Bool = false
    @Published var showWaitTimeIncreasedAlert: Bool = false
    @Published var showWaitTimeDecreasedAlert: Bool = false
    @Published var waitTimeChangeInfo: (oldMinutes: Int, newMinutes: Int, isIncrease: Bool)?
    @Published var showDelayChangeOverlay: Bool = false  // v1.6.11: In-map overlay when walking
    @Published var showPreWalkWellbeing: Bool = false
    @Published var showPostWalkWellbeing: Bool = false
    
    // v1.6.28: Post-walk HealthKit sync offer (only shown if Motion was granted)
    @Published var showHealthKitSyncOffer: Bool = false
    @Published var stepTrackingWasEnabled: Bool = false  // Track if user opted into steps during walk
    
    // Location-based marker detection
    @Published var showMarkerArrivalPrompt: Bool = false
    @Published var currentMarker: QRMarker? = nil
    @Published var visitedMarkerIds: Set<UUID> = []
    
    // Clinician selection
    @Published var availableClinicians: [Clinician] = []
    @Published var selectedClinician: Clinician?
    @Published var notificationsEnabled: Bool = true
    
    // Push notification dialog
    @Published var showPushNotificationDialog: Bool = false
    @Published var pushNotificationTitle: String = ""
    @Published var pushNotificationBody: String = ""
    @Published var pushNotificationTopic: String = ""
    private var suppressInAppAlerts: Bool = false  // Prevents duplicate alerts when opened from push
    @Published var showClinicianSelection: Bool = false
    @Published var hasSkippedClinicianSelection: Bool = false  // User chose to explore without selecting clinician
    private let allClinicians: [Clinician] = Clinician.sampleClinicians
    
    // Data loading state
    @Published var isDataReady: Bool = false
    
    // Clinic availability state
    @Published var isClinicEnded: Bool = false        // Selected clinician no longer in Firebase
    @Published var hasNoClinicsAvailable: Bool = false // Firebase returned no clinicians
    
    // Simulated EPR updates
    @Published var isSimulatingUpdates: Bool = true
    
    private var cancellables = Set<AnyCancellable>()
    private var walkTimer: Timer?
    private var updateTimer: Timer?
    private var isFirstFirebaseUpdate = true  // Skip alert on first sync
    
    let healthKitService = HealthKitService()
    let notificationService = NotificationService.shared
    let locationService = LocationService()
    let firebaseService = FirebaseService()
    
    // MARK: - Initialization
    init() {
        // Check if notifications should auto-reset (new day = new appointment)
        let savedNotificationDate = UserDefaults.standard.object(forKey: "notificationsEnabledDate") as? Date
        let isNewDay = !Calendar.current.isDateInToday(savedNotificationDate ?? Date.distantPast)
        
        // Load saved notification preference (defaults to true if clinician was selected)
        // But reset to false if it's a new day
        var savedNotificationPref = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool
        if isNewDay && savedNotificationPref == true {
            print("📅 New day detected - auto-disabling notifications")
            savedNotificationPref = false
            UserDefaults.standard.set(false, forKey: "notificationsEnabled")
        }
        
        // Load saved clinician name (more reliable than UUID which changes)
        let savedClinicianName = UserDefaults.standard.string(forKey: "selectedClinicianName")
        
        // Try to find clinician by name first in sampleClinicians (for immediate availability)
        var foundClinician: Clinician? = nil
        
        if let name = savedClinicianName {
            foundClinician = Clinician.sampleClinicians.first(where: { 
                $0.fullTitle.lowercased() == name.lowercased() ||
                $0.name.lowercased() == name.lowercased()
            })
        }
        
        // Fallback to UUID lookup
        if foundClinician == nil,
           let savedClinicianId = UserDefaults.standard.string(forKey: "selectedClinicianId"),
           let uuid = UUID(uuidString: savedClinicianId) {
            foundClinician = Clinician.sampleClinicians.first(where: { $0.id == uuid })
        }
        
        if let clinician = foundClinician {
            self.selectedClinician = clinician
            self.waitTimeInfo = WaitTimeInfo(from: clinician)
            
            // Default to notifications enabled unless explicitly disabled
            self.notificationsEnabled = savedNotificationPref ?? true
            
            // Re-subscribe to this clinician's topic if notifications are enabled
            let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            
            if notificationsEnabled {
                print("📱 Attempting to subscribe to topic: \(topic)")
                Messaging.messaging().subscribe(toTopic: topic) { error in
                    if let error = error {
                        print("❌ Error re-subscribing to topic: \(error)")
                    } else {
                        print("🔔 Re-subscribed to topic on launch: \(topic)")
                    }
                }
            } else {
                // Notifications disabled - ensure we're unsubscribed (in case previous unsubscription didn't complete)
                print("🔕 Notifications disabled - ensuring unsubscribed from: \(topic)")
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    if error == nil {
                        print("✅ Confirmed unsubscribed on launch: \(topic)")
                    }
                }
            }
            print("📱 Restored clinician from sampleClinicians: \(clinician.fullTitle)")
            
            // Data is ready - clinician found in sampleClinicians
            self.isDataReady = true
        } else if savedClinicianName != nil {
            // Clinician not in sampleClinicians - will be restored when Firebase loads
            // Keep notification preference for when Firebase restores the clinician
            self.notificationsEnabled = savedNotificationPref ?? true
            
            // Temporary wait time info until Firebase loads
            self.waitTimeInfo = WaitTimeInfo(
                estimatedMinutes: 20,
                lastUpdated: Date(),
                clinicianName: savedClinicianName ?? "Loading...",
                queuePosition: 0
            )
            print("📱 Clinician '\(savedClinicianName!)' not in sampleClinicians - waiting for Firebase to restore")
        } else {
            // No clinician selected - default to notifications disabled
            self.notificationsEnabled = false
            
            // Default wait time info (no clinician selected yet)
            self.waitTimeInfo = WaitTimeInfo(
                estimatedMinutes: 20,
                lastUpdated: Date(),
                clinicianName: "Select your clinician",
                queuePosition: 0
            )
            print("📱 No saved clinician found")
            
            // Data is ready - no saved clinician, user needs to select one
            self.isDataReady = true
        }
        
        // Listen to Firebase for real wait times
        setupFirebaseListener()
        
        // Notification permission is now requested AFTER clinician selection
        // This follows the new flow: Location → Clinician Selection → Notifications
        // (See selectClinician method)
        
        // Listen for notifications disabled via push notification action
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NotificationsDisabled"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.notificationsEnabled = false
                print("🔕 UI updated: notifications disabled via push action")
            }
        }
        
        // Listen for walk notification taps to reset in-app alerts
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ResetWalkAlerts"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showHalfwayAlert = false
                self?.showReturnNowAlert = false
                self?.showWalkCompleteAlert = false
                print("📱 Reset walk alerts - user came from push notification")
            }
        }
        
        // Record app usage for streak tracking
        userProgress.recordAppUsage()
        
        // Clean up old topic subscriptions (do this after init is complete)
        DispatchQueue.main.async { [weak self] in
            self?.cleanupOldSubscriptions()
        }
    }
    
    private func cleanupOldSubscriptions() {
        // Unsubscribe from all clinician topics EXCEPT the selected one
        guard let selected = selectedClinician else {
            // No clinician selected - unsubscribe from all
            unsubscribeFromAllClinicianTopics()
            return
        }
        
        let selectedTopic = "clinician_" + selected.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        
        // Unsubscribe from all except selected
        let allPossibleClinicians = Clinician.sampleClinicians
        for clinician in allPossibleClinicians {
            let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            
            // Skip the selected clinician
            if topic == selectedTopic { continue }
            
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if error == nil {
                    print("🧹 Cleaned up old subscription: \(topic)")
                }
            }
        }
    }
    
    func checkForPendingNotification() {
        // Check and show pending notification dialog
        guard let pending = AppDelegate.pendingNotification else {
            return
        }
        
        // Clear immediately to prevent duplicate checks
        AppDelegate.pendingNotification = nil
        
        print("📱 Found pending notification, showing dialog")
        
        // Suppress in-app alerts
        suppressInAppAlerts = true
        
        // Dismiss any existing alerts
        showWaitTimeIncreasedAlert = false
        showWaitTimeDecreasedAlert = false
        
        // Set dialog content
        pushNotificationTitle = pending["title"] ?? "Clinic Update"
        pushNotificationBody = pending["body"] ?? ""
        pushNotificationTopic = pending["topic"] ?? ""
        showPushNotificationDialog = true
        
        // Reset suppression after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.suppressInAppAlerts = false
            AppDelegate.suppressInAppAlertsFlag = false
        }
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
            // No clinicians in Firebase - show empty list
            availableClinicians = []
            hasNoClinicsAvailable = true
            
            // If user had a clinician selected, their clinic has ended
            if selectedClinician != nil {
                isClinicEnded = true
                print("📋 Selected clinician's clinic has ended (Firebase empty)")
            }
            
            print("⏳ No clinicians in Firebase - clinic not active")
            
            // Data is ready - Firebase responded (even if empty)
            if !isDataReady {
                isDataReady = true
                print("✅ Data ready - Firebase empty but responded")
            }
            return
        }
        
        // Firebase has clinicians - reset the "no clinics" flag
        hasNoClinicsAvailable = false
        
        // If user skipped clinician selection because none were available,
        // but now there are clinicians, prompt them to select one
        if hasSkippedClinicianSelection && selectedClinician == nil {
            hasSkippedClinicianSelection = false
            print("📋 Clinicians now available - prompting user to select")
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
        
        // Data is ready - Firebase has loaded (even if empty)
        if !isDataReady {
            isDataReady = true
            print("✅ Data ready - Firebase loaded")
        }
        
        // If selectedClinician is nil but we have a saved name, try to restore from Firebase
        // This handles clinicians added via Google Sheets that aren't in sampleClinicians
        if selectedClinician == nil,
           let savedName = UserDefaults.standard.string(forKey: "selectedClinicianName") {
            if let matchingData = firebaseClinicians.first(where: {
                $0.fullName.lowercased() == savedName.lowercased() ||
                $0.name.lowercased() == savedName.replacingOccurrences(of: "Dr. ", with: "").replacingOccurrences(of: "Mr. ", with: "").lowercased()
            }) {
                let restoredClinician = createClinicianFromFirebase(matchingData)
                selectedClinician = restoredClinician
                waitTimeInfo = WaitTimeInfo(from: restoredClinician)
                
                // Re-subscribe if notifications are enabled
                if notificationsEnabled {
                    let topic = "clinician_" + restoredClinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                    Messaging.messaging().subscribe(toTopic: topic) { error in
                        if error == nil {
                            print("🔔 Re-subscribed to restored clinician: \(topic)")
                        }
                    }
                }
                
                print("📱 Restored clinician from Firebase: \(restoredClinician.fullTitle)")
                isFirstFirebaseUpdate = false  // Don't show alert for restoration
            } else {
                // Clinician was saved but not found in Firebase - clinic has ended
                isClinicEnded = true
                print("📋 Saved clinician '\(savedName)' not found in Firebase - clinic ended")
            }
        }
        
        // Update selected clinician if they exist in new data
        if let selected = selectedClinician {
            if let updatedData = firebaseClinicians.first(where: { 
                $0.name.lowercased() == selected.name.lowercased() ||
                $0.fullName.lowercased() == selected.fullTitle.lowercased()
            }) {
                // Clinician found - clinic is active
                isClinicEnded = false
                let previousDelay = waitTimeInfo.estimatedMinutes
                let newDelay = updatedData.delay
                let isWalking = walkSession.isActive
                
                // Check for delay changes and notify
                print("🔍 Firebase update: previous=\(previousDelay), new=\(newDelay), isFirst=\(isFirstFirebaseUpdate), suppress=\(AppDelegate.suppressInAppAlertsFlag), pending=\(AppDelegate.pendingNotification != nil)")
                
                // Skip first Firebase update (it's just syncing on app launch, not a real-time change)
                if isFirstFirebaseUpdate {
                    isFirstFirebaseUpdate = false
                    print("🔄 First Firebase sync - skipping alert (this is expected)")
                } else if newDelay == 0 && previousDelay == 0 {
                    // Was already on time, still on time - no notification needed
                    print("✅ Clinic still on time (delay = 0) - no notification needed")
                } else if newDelay != previousDelay {
                    // Delay changed (including 0 → positive, positive → 0, or any change)
                    if !notificationsEnabled {
                        print("🔕 Notifications disabled - skipping delay alert (data will still update)")
                    } else {
                        // Only skip if there's a pending push notification waiting to be shown
                        let hasPendingPush = AppDelegate.pendingNotification != nil
                        
                        if hasPendingPush {
                            print("⏸️ Skipping in-app alert - pending push notification will show instead")
                        } else if !notificationsEnabled {
                            // Alerts are disabled - don't show in-app alerts
                            print("🔕 Skipping in-app alert - notifications disabled")
                        } else {
                            // Clear any stale suppress flag - we need to show this alert
                            AppDelegate.suppressInAppAlertsFlag = false
                            
                            let isAppInForeground = UIApplication.shared.applicationState == .active
                            
                            if newDelay > previousDelay {
                                // Delay increased
                                if isAppInForeground {
                                    notificationService.sendWaitTimeIncreasedNotification(
                                        oldMinutes: previousDelay,
                                        newMinutes: newDelay,
                                        isWalking: isWalking
                                    )
                                }
                                waitTimeChangeInfo = (oldMinutes: previousDelay, newMinutes: newDelay, isIncrease: true)
                                
                                // v1.6.11: Show in-map overlay if walking, otherwise standard alert
                                if isWalking {
                                    showDelayChangeOverlay = true
                                    print("🗺️ SHOWING MAP OVERLAY: Delay increased \(previousDelay) → \(newDelay) min (walking)")
                                } else {
                                    showWaitTimeIncreasedAlert = true
                                    print("⚠️ SHOWING ALERT: Delay increased \(previousDelay) → \(newDelay) min")
                                }
                            } else if newDelay < previousDelay {
                                // Delay decreased (any amount)
                                if isAppInForeground {
                                    notificationService.sendWaitTimeDecreasedNotification(
                                        oldMinutes: previousDelay,
                                        newMinutes: newDelay,
                                        isWalking: isWalking
                                    )
                                }
                                waitTimeChangeInfo = (oldMinutes: previousDelay, newMinutes: newDelay, isIncrease: false)
                                
                                // v1.6.11: Show in-map overlay if walking, otherwise standard alert
                                if isWalking {
                                    showDelayChangeOverlay = true
                                    print("🗺️ SHOWING MAP OVERLAY: Delay decreased \(previousDelay) → \(newDelay) min (walking)")
                                } else {
                                    showWaitTimeDecreasedAlert = true
                                    print("✅ SHOWING ALERT: Delay decreased \(previousDelay) → \(newDelay) min")
                                }
                            }
                        }
                    }
                }
                
                // Update selected clinician with ALL new data
                selectedClinician = createClinicianFromFirebase(updatedData)
                
                // Update waitTimeInfo
                waitTimeInfo.estimatedMinutes = newDelay
                waitTimeInfo.lastUpdated = Date()
                waitTimeInfo.clinicianName = updatedData.fullName
                
                // Ensure we're subscribed to this clinician's topic
                if notificationsEnabled {
                    let topic = "clinician_" + updatedData.fullName.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                    Messaging.messaging().subscribe(toTopic: topic) { error in
                        if error == nil {
                            print("🔔 Confirmed subscription to: \(topic)")
                        }
                    }
                }
                
                print("🔄 Updated selected clinician: \(updatedData.fullName) - all fields refreshed")
            } else {
                // Selected clinician is NOT in Firebase anymore - clinic has ended
                isClinicEnded = true
                print("📋 Selected clinician '\(selected.fullTitle)' no longer in Firebase - clinic ended")
                
                // Unsubscribe from notifications since clinic is over
                let topic = "clinician_" + selected.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    if error == nil {
                        print("🔕 Unsubscribed from ended clinic: \(topic)")
                    }
                }
            }
        }
    }
    
    /// Create a Clinician from Firebase/Google Sheets data
    private func createClinicianFromFirebase(_ data: FirebaseClinicianData) -> Clinician {
        return Clinician(
            name: data.name,
            location: data.location,           // Clinic location from Google Sheets
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
    /// Permissions are requested in sequence to avoid iOS dismissing dialogs
    private func requestWalkPermissions() {
        Task {
            // Step 1: Location permission (if not already authorized)
            if !locationService.isAuthorized {
                locationService.requestPermission()
                // Wait for user to respond to location dialog
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
            
            // Step 2: Wait a moment for any motion permission that might be triggered
            // Motion permission is triggered automatically by startObservingSteps
            // so we don't request it explicitly here
            
            // Step 3: HealthKit permission (after other dialogs have settled)
            // Delay to ensure motion dialog has finished
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            _ = await healthKitService.requestAuthorization()
        }
    }
    
    // MARK: - Walk Session Management
    func startWalk() {
        guard let route = selectedRoute else { return }
        
        // v1.6.29: Removed requestWalkPermissions() - no longer request HealthKit here
        // Step tracking is now fully opt-in via the Steps card during the walk
        // HealthKit sync offer is shown AFTER the post-walk check (if Motion was granted)
        
        walkSession.isActive = true
        walkSession.startTime = Date()
        walkSession.currentRoute = route
        walkSession.startLocation = locationService.currentLocation?.coordinate  // v1.6.48: Snap Start/End to user's actual GPS position
        walkSession.halfwayAlertSent = false
        walkSession.returnNowAlertSent = false
        walkSession.walkCompleteAlertSent = false
        walkSession.stepsThisSession = 0
        walkSession.markersScanned = []
        
        // v1.6.28: Reset step tracking flag for new walk
        stepTrackingWasEnabled = false
        
        // Calculate return time (halfway point of route duration)
        let halfwaySeconds = Double(route.durationMinutes * 60) / 2
        walkSession.estimatedReturnTime = Date().addingTimeInterval(halfwaySeconds)
        
        // v1.6.30: Step tracking is now opt-in via the Steps card during walk
        // Auto-start if user has previously opted in (trust UserDefaults flag)
        let autoEnabled = UserDefaults.standard.bool(forKey: "stepTrackingAutoEnabled")
        print("🚶 startWalk - stepTrackingAutoEnabled: \(autoEnabled)")
        if autoEnabled {
            print("🚶 Auto-starting step observation, setting stepTrackingWasEnabled = true")
            healthKitService.startObservingSteps(from: Date())
            stepTrackingWasEnabled = true
        }
        // Otherwise, step tracking will start when user taps the Steps card
        
        // Start location tracking (requests permission if needed)
        locationService.startTracking()
        
        // Start direction monitoring for turn-by-turn notifications (non-indoor routes only)
        if !route.isIndoor && !route.walkingDirections.isEmpty {
            locationService.startDirectionMonitoring(
                directions: route.walkingDirections,
                routePath: route.routePath
            )
        }
        
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
        
        // v1.6.28: Reset step tracking flag for next walk
        // (stepTrackingWasEnabled is used to determine if HealthKit offer should be shown)
        // Note: We don't reset it here because we need it for the post-walk flow
        // It will be reset at the start of the next walk
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
        
        // Check for halfway point (50%)
        if !walkSession.halfwayAlertSent,
           let returnTime = walkSession.estimatedReturnTime,
           Date() >= returnTime {
            walkSession.halfwayAlertSent = true
            
            // Only show in-app alert if NOT coming from a push notification tap
            if !AppDelegate.cameFromWalkNotification {
                showHalfwayAlert = true
            } else {
                print("📱 Skipping halfway in-app alert - user came from push notification")
            }
        }
        
        // Check for return now point (80%)
        if !walkSession.returnNowAlertSent && walkSession.progress >= 0.8 && walkSession.progress < 1.0 {
            walkSession.returnNowAlertSent = true
            
            if !AppDelegate.cameFromWalkNotification {
                showReturnNowAlert = true
            } else {
                print("📱 Skipping return now in-app alert - user came from push notification")
            }
        }
        
        // Check if walk is complete (100%)
        if !walkSession.walkCompleteAlertSent && walkSession.progress >= 1.0 {
            walkSession.walkCompleteAlertSent = true
            
            if !AppDelegate.cameFromWalkNotification {
                showWalkCompleteAlert = true
            } else {
                print("📱 Skipping walk complete in-app alert - user came from push notification")
            }
        }
    }
    
    // MARK: - Location-Based Marker Detection
    private func checkMarkerProximity() {
        guard let route = selectedRoute,
              let userLocation = locationService.currentLocation else { return }
        
        // Get route path for dynamic radius calculation
        let routePath = route.routePath
        
        // Check each marker on the route
        for marker in route.qrMarkers {
            // Skip already visited markers
            guard !visitedMarkerIds.contains(marker.id) else { continue }
            
            // Calculate distance to marker (in meters)
            let markerLocation = CLLocation(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
            let userDistanceToMarker = userLocation.distance(from: markerLocation)
            
            // v1.7.2: Dynamic activation radius based on POI distance from route
            // POIs close to the road get tight radius, set-back buildings get generous radius
            let activationRadius = calculateDynamicActivationRadius(
                markerCoordinate: marker.coordinate,
                routePath: routePath
            )
            
            if userDistanceToMarker < activationRadius {
                print("📍 Waypoint activated: \(marker.name) (distance: \(Int(userDistanceToMarker))m, radius: \(Int(activationRadius))m)")
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
    
    /// Calculates a dynamic activation radius based on how far the POI is from the walking route.
    /// - POIs on the roadside (cafes, bus stops): ~25m radius
    /// - POIs set back from road (schools, parks): up to 75m radius
    private func calculateDynamicActivationRadius(
        markerCoordinate: CLLocationCoordinate2D,
        routePath: [CLLocationCoordinate2D]
    ) -> Double {
        // Find minimum distance from marker to any point on the route
        let markerLocation = CLLocation(latitude: markerCoordinate.latitude, longitude: markerCoordinate.longitude)
        
        var minDistanceToRoute: Double = .greatestFiniteMagnitude
        
        for routePoint in routePath {
            let routeLocation = CLLocation(latitude: routePoint.latitude, longitude: routePoint.longitude)
            let distance = markerLocation.distance(from: routeLocation)
            minDistanceToRoute = min(minDistanceToRoute, distance)
        }
        
        // If route is empty, use default radius
        guard minDistanceToRoute != .greatestFiniteMagnitude else {
            return 50.0 // Default fallback
        }
        
        // Dynamic radius formula:
        // Base: 20m (minimum for GPS accuracy)
        // + Distance from route (accounts for set-back buildings)
        // + Buffer: 15m (walking on opposite side of street, GPS drift)
        // Capped at 75m to prevent false activations
        let baseRadius: Double = 20.0
        let buffer: Double = 15.0
        let maxRadius: Double = 75.0
        
        let dynamicRadius = min(baseRadius + minDistanceToRoute + buffer, maxRadius)
        
        return dynamicRadius
    }
    
    func dismissMarkerPrompt() {
        showMarkerArrivalPrompt = false
        currentMarker = nil
    }
    
    // MARK: - Notifications
    private func scheduleWalkNotifications(routeDuration: Int) {
        // Halfway at 50%
        let halfwaySeconds = Double(routeDuration * 60) / 2
        notificationService.scheduleHalfwayNotification(in: halfwaySeconds, walkDuration: routeDuration)
        
        // Return Now at 80%
        let returnSeconds = Double(routeDuration * 60) * 0.8
        notificationService.scheduleReturnNowNotification(in: returnSeconds, walkDuration: routeDuration)
        
        // Walk Complete at 100%
        let completeSeconds = Double(routeDuration * 60)
        notificationService.scheduleWalkCompleteNotification(in: completeSeconds, walkDuration: routeDuration)
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
        // Check if selecting the same clinician - preserve notification settings
        // Compare by name since UUIDs are regenerated each time clinicians are rebuilt from Firebase
        let isSameClinician = selectedClinician?.fullTitle == clinician.fullTitle
        
        // Unsubscribe from old clinician topic (only if different)
        if let old = selectedClinician, !isSameClinician {
            let oldTopic = "clinician_" + old.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            Messaging.messaging().unsubscribe(fromTopic: oldTopic) { error in
                if let error = error {
                    print("Error unsubscribing from topic: \(error)")
                } else {
                    print("Unsubscribed from topic: \(oldTopic)")
                }
            }
        }
        
        // Subscribe to new clinician topic - but only if:
        // 1. It's a different clinician, OR
        // 2. Notifications are still enabled (user hasn't disabled them)
        let newTopic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        
        if !isSameClinician || notificationsEnabled {
            print("🔔 Subscribing to topic: \(newTopic)")
            Messaging.messaging().subscribe(toTopic: newTopic) { error in
                if let error = error {
                    print("❌ Subscription failed: \(error)")
                } else {
                    print("✅ Subscription success: \(newTopic)")
                }
            }
        } else {
            print("🔕 Skipping subscription - same clinician and notifications disabled")
        }
        
        selectedClinician = clinician
        waitTimeInfo = WaitTimeInfo(from: clinician)
        
        // Reset clinic ended flag - user selected an active clinician
        isClinicEnded = false
        
        // Only enable notifications if selecting a DIFFERENT clinician
        // This preserves the user's "Stop Alerts" preference when re-selecting same clinician
        if !isSameClinician {
            notificationsEnabled = true  // Enable notifications for new clinician
            UserDefaults.standard.set(true, forKey: "notificationsEnabled")
            UserDefaults.standard.set(Date(), forKey: "notificationsEnabledDate")
            print("📱 Saved clinician: \(clinician.fullTitle), notifications enabled for today")
        } else {
            print("📱 Same clinician selected, preserving notification preference: \(notificationsEnabled)")
        }
        
        // Save selection
        UserDefaults.standard.set(clinician.id.uuidString, forKey: "selectedClinicianId")
        UserDefaults.standard.set(clinician.fullTitle, forKey: "selectedClinicianName")
        
        // Request notification permission AFTER clinician is selected
        // This follows the flow: Location → Clinician Selection → Notifications
        // Only request if not already authorized and selecting a new clinician
        if !isSameClinician && !notificationService.isAuthorized {
            Task {
                // Small delay to let the clinician selection UI dismiss first
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                _ = await notificationService.requestAuthorization()
            }
        }
    }
    
    // MARK: - Notification Management
    
    private func unsubscribeFromAllClinicianTopics() {
        // Unsubscribe from all possible clinician topics to ensure clean state
        // This prevents receiving notifications for previously selected clinicians
        let allPossibleClinicians = Clinician.sampleClinicians + availableClinicians
        var seenTopics = Set<String>()
        
        for clinician in allPossibleClinicians {
            let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            
            // Avoid duplicate unsubscribe calls
            guard !seenTopics.contains(topic) else { continue }
            seenTopics.insert(topic)
            
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if error == nil {
                    print("🔕 Unsubscribed from topic: \(topic)")
                }
            }
        }
        print("🧹 Cleaned up all clinician topic subscriptions")
    }
    
    /// Disable notifications only - used by "Stop Alerts" button
    /// This will NOT re-enable if already disabled (safe to call multiple times)
    func disableNotifications() {
        guard let clinician = selectedClinician else { return }
        
        // If already disabled, do nothing (prevents old alerts from re-enabling)
        guard notificationsEnabled else {
            print("🔕 Notifications already disabled, ignoring Stop Alerts tap")
            return
        }
        
        let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        
        // IMMEDIATELY set preference (before async call) so it's saved even if app closes
        notificationsEnabled = false
        UserDefaults.standard.set(false, forKey: "notificationsEnabled")
        print("🔕 Notifications disabled for: \(topic)")
        
        // Then unsubscribe in background
        Messaging.messaging().unsubscribe(fromTopic: topic) { error in
            if let error = error {
                print("❌ Error unsubscribing (preference already saved): \(error)")
            } else {
                print("✅ Unsubscription confirmed for: \(topic)")
            }
        }
    }
    
    /// Enable notifications - used by UI toggle or re-enable button
    func enableNotifications() {
        guard let clinician = selectedClinician else { return }
        
        let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        
        // IMMEDIATELY set preference
        notificationsEnabled = true
        UserDefaults.standard.set(true, forKey: "notificationsEnabled")
        UserDefaults.standard.set(Date(), forKey: "notificationsEnabledDate")
        print("🔔 Notifications enabled for: \(topic)")
        
        // Then subscribe in background
        Messaging.messaging().subscribe(toTopic: topic) { error in
            if let error = error {
                print("❌ Error subscribing: \(error)")
            } else {
                print("✅ Subscription confirmed for: \(topic)")
            }
        }
    }
    
    /// Toggle notifications on/off - used by settings UI
    func toggleNotifications() {
        if notificationsEnabled {
            disableNotifications()
        } else {
            enableNotifications()
        }
    }
    
    func stopNotificationsFromDialog() {
        // Use the topic from the push notification
        let topic = pushNotificationTopic
        
        guard !topic.isEmpty else {
            print("❌ No topic to unsubscribe from")
            return
        }
        
        Messaging.messaging().unsubscribe(fromTopic: topic) { [weak self] error in
            if let error = error {
                print("❌ Error unsubscribing: \(error)")
            } else {
                print("🔕 Notifications stopped via dialog for: \(topic)")
                DispatchQueue.main.async {
                    self?.notificationsEnabled = false
                }
            }
        }
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
            showWalkCompleteAlert = true
        }
    }
    
    func simulateDelayIncrease() {
        waitTimeInfo.estimatedMinutes += 10
        waitTimeInfo.lastUpdated = Date()
        notificationService.scheduleDelayUpdateNotification(newWaitMinutes: waitTimeInfo.estimatedMinutes)
    }
}


