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
import MapKit
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
    /// Don't show delay-change overlay for this many seconds after walk start (route loading + intro animation).
    private let delayOverlayGracePeriodSeconds: Int = 20
    @Published var showPreWalkWellbeing: Bool = false
    @Published var showPostWalkWellbeing: Bool = false
    
    // v1.6.28: Post-walk HealthKit sync offer (only shown if Motion was granted)
    @Published var showHealthKitSyncOffer: Bool = false
    @Published var stepTrackingWasEnabled: Bool = false  // Track if user opted into steps during walk
    @Published var motionWasAuthorizedAtWalkStart: Bool = false  // v1.9.33: Track if Motion was authorized when walk started
    @Published var pendingActiveWalk: Bool = false  // v1.9.36: Delays map until after pre-walk anxiety check (iOS 17 compatible)
    
    // Location-based marker detection
    @Published var showMarkerArrivalPrompt: Bool = false
    @Published var currentMarker: QRMarker? = nil
    @Published var visitedMarkerIds: Set<UUID> = []
    
    /// v2.1.x: Explicit duration for "mins left" pill so it doesn't revert after Google refresh (avoids stale currentRoute reads on re-render).
    @Published var displayDurationMinutesForPill: Int? = nil
    /// Google lock: once true (set in updateCurrentRoute when first refresh runs), must never be set back to false except in endWalk().
    /// startWalk() must never unlock; only endWalk() resets it so the next walk can start with a fresh pill.
    @Published var hasReceivedGoogleRefreshForPill: Bool = false
    /// When lock is set, fallback so pill never reverts to currentRoute if displayDurationMinutesForPill is ever nil (e.g. binding glitch).
    private var lastKnownPillMinutes: Int? = nil
    
    /// Pre-pop duration adjust: when we dropped waypoints (over target), offer user to switch to shorter route.
    @Published var pendingAdjustedRoute: WalkingRoute? = nil
    @Published var showAdjustRouteAlert: Bool = false
    
    /// When true, map stays centered on route with padding and does not auto-snap to user location (Let's Go flow).
    @Published var mapStayCenteredOnRoute: Bool = false
    
    /// Delay-change route refresh: loading and error state for "Extend my walk" / "Get shorter route".
    @Published var isLoadingDelayChangeRoute: Bool = false
    @Published var delayChangeRouteError: String? = nil
    
    private static let pillDisplayMinutesKey = "pillDisplayDurationMinutes"
    private static let pillLockKey = "pillHasReceivedGoogleRefresh"
    
    private static func persistPillState(minutes: Int, locked: Bool) {
        UserDefaults.standard.set(minutes, forKey: pillDisplayMinutesKey)
        UserDefaults.standard.set(locked, forKey: pillLockKey)
    }
    
    /// Call when walk ends or when hasActiveWalk is cleared (crash/background) so next session starts fresh.
    static func clearPersistedPillState() {
        UserDefaults.standard.removeObject(forKey: pillDisplayMinutesKey)
        UserDefaults.standard.removeObject(forKey: pillLockKey)
        print("PILL | clearPersistedPillState: persisted pill cleared (walk ended or crash/background)")
    }
    
    /// Value the pill should show: once locked, never fall back to currentRoute so 73→77 never reverts to 73.
    var effectiveDisplayDurationMinutesForPill: Int? {
        if let v = displayDurationMinutesForPill { return v }
        if hasReceivedGoogleRefreshForPill, let v = lastKnownPillMinutes { return v }
        return nil
    }

    // v2.1.7: Track last waypoint activation time to prevent rapid multiple activations
    private var lastWaypointActivationTime: Date?
    
    // v1.9.13: Home arrival detection
    @Published var showHomeArrivalPrompt: Bool = false
    @Published var hasReachedHome: Bool = false
    
    // v1.9.15: Cached directions for offline use
    @Published var cachedOriginalDirections: [WalkingDirection] = []
    @Published var cachedReturnDirections: [WalkingDirection] = []
    @Published var isUsingReturnDirections: Bool = false
    
    // v1.9.83: Store arrival instruction to show when close to destination
    private var arrivalInstruction: WalkingDirection? = nil
    /// Map direction index -> marker ID for waypoint steps (so we only advance to next step when that waypoint is activated). Cleared in endWalk.
    private var directionIndexToMarkerId: [Int: UUID] = [:]
    
    // v1.9.16: Cached return route for offline fallback
    @Published var cachedReturnRoutePolyline: [CLLocationCoordinate2D] = []
    @Published var hasCachedReturnRoute: Bool = false
    /// When true, user tapped "Head back" and we switched to return route; skip 80% and 100% overlays. Reset in endWalk.
    private(set) var isHeadingBack: Bool = false
    
    // v1.9.17: Walking alerts control
    @Published var walkingAlertsEnabled: Bool = true
    private var alertAutoDismissTimer: Timer?
    
    /// Freeze diagnostic: logs every 10s during a walk so we can see last activity if the app freezes (no crash).
    private var walkHeartbeatTimer: Timer?
    
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
    /// Optional; when nil, delay-change route refresh uses GoogleMapsService.shared.
    private var mapsService: GoogleMapsService?
    
    // MARK: - Initialization
    init(mapsService: GoogleMapsService? = nil) {
        self.mapsService = mapsService
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
            // Create waitTimeInfo first, appointment time will be restored after init
            self.waitTimeInfo = WaitTimeInfo(from: clinician)
            
            // Default to notifications enabled unless explicitly disabled
            self.notificationsEnabled = savedNotificationPref ?? true
            
            // Re-subscribe to this clinician's topic if notifications are enabled
            let topic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            
            if notificationsEnabled {
                print("📱 Attempting to subscribe to topic: \(topic)")
                // v1.7.12: Run on background thread to avoid main thread blocking
                DispatchQueue.global(qos: .utility).async {
                    Messaging.messaging().subscribe(toTopic: topic) { error in
                        if let error = error {
                            print("❌ Error re-subscribing to topic: \(error.localizedDescription)")
                        } else {
                            print("🔔 ✅ Re-subscribed to topic on launch: \(topic)")
                            print("🔔 Topic subscription confirmed - background notifications should work")
                        }
                    }
                }
            } else {
                // Notifications disabled - ensure we're unsubscribed (in case previous unsubscription didn't complete)
                // v1.7.12: Run on background thread to avoid main thread blocking
                print("🔕 Notifications disabled - ensuring unsubscribed from: \(topic)")
                DispatchQueue.global(qos: .utility).async {
                    Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                        if error == nil {
                            print("✅ Confirmed unsubscribed on launch: \(topic)")
                        }
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
        
        // v1.9.56: Restore appointment time from UserDefaults
        restoreAppointmentTime()
        
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
            
            // v1.7.12: Run on background thread
            DispatchQueue.global(qos: .utility).async {
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    if error == nil {
                        print("🧹 Cleaned up old subscription: \(topic)")
                    }
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
                // Preserve appointment time when updating waitTimeInfo from Firebase
                let preservedAppointmentTime = waitTimeInfo.appointmentTime
                // Create WaitTimeInfo with appointment time already set to avoid publishing during view updates
                waitTimeInfo = WaitTimeInfo(
                    estimatedMinutes: restoredClinician.currentWaitMinutes,
                    lastUpdated: restoredClinician.lastUpdated,
                    clinicianName: restoredClinician.fullTitle,
                    queuePosition: restoredClinician.queuePosition,
                    appointmentTime: preservedAppointmentTime
                )
                
                // Re-subscribe if notifications are enabled
                // v1.7.12: Run on background thread to avoid main thread blocking
                if notificationsEnabled {
                    let topic = "clinician_" + restoredClinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                    DispatchQueue.global(qos: .utility).async {
                        Messaging.messaging().subscribe(toTopic: topic) { error in
                            if error == nil {
                                print("🔔 Re-subscribed to restored clinician: \(topic)")
                            }
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
                                
                                // v1.6.11: Show in-map overlay if walking, otherwise standard alert. Defer until after route/animations (grace period).
                                if isWalking {
                                    if walkSession.elapsedSeconds >= delayOverlayGracePeriodSeconds {
                                        showDelayChangeOverlay = true
                                        print("🗺️ SHOWING MAP OVERLAY: Delay increased \(previousDelay) → \(newDelay) min (walking)")
                                    } else {
                                        print("🗺️ DEFERRING delay overlay (elapsed \(walkSession.elapsedSeconds)s < \(delayOverlayGracePeriodSeconds)s grace)")
                                    }
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
                                
                                // v1.6.11: Show in-map overlay if walking, otherwise standard alert. Defer until after route/animations (grace period).
                                if isWalking {
                                    if walkSession.elapsedSeconds >= delayOverlayGracePeriodSeconds {
                                        showDelayChangeOverlay = true
                                        print("🗺️ SHOWING MAP OVERLAY: Delay decreased \(previousDelay) → \(newDelay) min (walking)")
                                    } else {
                                        print("🗺️ DEFERRING delay overlay (elapsed \(walkSession.elapsedSeconds)s < \(delayOverlayGracePeriodSeconds)s grace)")
                                    }
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
                // v1.7.12: Run on background thread to avoid any main thread blocking
                if notificationsEnabled {
                    let topic = "clinician_" + updatedData.fullName.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                    DispatchQueue.global(qos: .utility).async {
                        Messaging.messaging().subscribe(toTopic: topic) { error in
                            if error == nil {
                                print("🔔 Confirmed subscription to: \(topic)")
                            }
                        }
                    }
                }
                
                print("🔄 Updated selected clinician: \(updatedData.fullName) - all fields refreshed")
            } else {
                // Selected clinician is NOT in Firebase anymore - clinic has ended
                isClinicEnded = true
                print("📋 Selected clinician '\(selected.fullTitle)' no longer in Firebase - clinic ended")
                
                // Unsubscribe from notifications since clinic is over
                // v1.7.12: Run on background thread
                let topic = "clinician_" + selected.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
                DispatchQueue.global(qos: .utility).async {
                    Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                        if error == nil {
                            print("🔕 Unsubscribed from ended clinic: \(topic)")
                        }
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
    
    /// v2.1.1: Update current route with refreshed data (e.g., after background Google/MapKit fetch)
    /// Updates both selectedRoute and walkSession.currentRoute so map refreshes automatically.
    /// When resetDirectionIndex is true (e.g. Head back), directions start from step 0.
    func updateCurrentRoute(_ route: WalkingRoute, sourceIsGoogle: Bool = false, resetDirectionIndex: Bool = false) {
        let incomingMin = route.durationMinutes
        print("PILL | updateCurrentRoute ENTRY isActive=\(walkSession.isActive) incoming=\(incomingMin)min display=\(displayDurationMinutesForPill ?? -1) lastKnown=\(lastKnownPillMinutes ?? -1) lock=\(hasReceivedGoogleRefreshForPill) sourceIsGoogle=\(sourceIsGoogle) route.name=\(route.name)")
        selectedRoute = route
        if walkSession.isActive {
            walkSession.currentRoute = route
            let currentPill = displayDurationMinutesForPill
            let alreadyLocked = hasReceivedGoogleRefreshForPill
            let shouldUpdatePill = sourceIsGoogle || !alreadyLocked
            if shouldUpdatePill {
                displayDurationMinutesForPill = incomingMin
                hasReceivedGoogleRefreshForPill = true
                lastKnownPillMinutes = incomingMin
                Self.persistPillState(minutes: incomingMin, locked: true)
                print("PILL | updateCurrentRoute: pill SET display=\(incomingMin) lastKnown=\(incomingMin) lock=true (\(sourceIsGoogle ? "Google source of truth" : "first refresh"))")
            } else {
                print("PILL | updateCurrentRoute: pill LOCKED display=\(currentPill ?? -1) lastKnown=\(lastKnownPillMinutes ?? -1) — IGNORING incoming \(incomingMin)min (MapKit, waiting for Google)")
            }
            // v2.1.1: Update direction monitoring with new directions
            if !route.walkingDirections.isEmpty {
                // Safeguard: for single-waypoint routes (e.g. extend), ensure arrival step shows "Waypoint 1 (Name)" not "Arrive at the destination"
                var directionsToUse = route.walkingDirections
                if route.qrMarkers.count == 1,
                   let name = route.qrMarkers.first?.name,
                   let idx = directionsToUse.firstIndex(where: { d in
                       let l = d.instruction.lowercased()
                       return (l.contains("arrive") || l.contains("destination")) && !d.instruction.contains("Waypoint")
                   }) {
                    let orig = directionsToUse[idx].instruction
                    let side = orig.lowercased().contains("right") ? "right" : "left"
                    directionsToUse[idx] = WalkingDirection(
                        instruction: "Waypoint 1 (\(name)) is on your \(side)",
                        distance: directionsToUse[idx].distance,
                        distanceMeters: directionsToUse[idx].distanceMeters,
                        duration: directionsToUse[idx].duration,
                        maneuver: "arrive"
                    )
                    print("REFRESH_FALLBACK | Single-waypoint safeguard: replaced '\(orig.prefix(40))...' with Waypoint 1 (\(name))")
                }
                if resetDirectionIndex {
                    locationService.startDirectionMonitoring(directions: directionsToUse, routePath: route.routePath, skipPassedWaypoints: false)
                } else {
                    locationService.updateDirections(directionsToUse, routePath: route.routePath)
                }
                // Keep cached directions in sync so banner and expanded list show the new instructions (e.g. after delay-change route refresh).
                cachedOriginalDirections = directionsToUse
                // #region agent log — waypoint directions diagnostic (filter Xcode by WAYPOINT_DIAG)
                let wpCountUpdate = directionsToUse.filter { $0.instruction.contains("Waypoint") && $0.instruction.contains("is on your") }.count
                print("WAYPOINT_DIAG updateCurrentRoute | route='\(route.name)' waypoints=\(route.qrMarkers.count) names=[\(route.qrMarkers.map { $0.name }.joined(separator: ", "))] | directions=\(directionsToUse.count) waypointLines=\(wpCountUpdate)")
                let updatePayload: [String: Any] = ["location": "WaitingRoomViewModel:updateCurrentRoute:diag", "message": "route update waypoint diagnostic", "data": ["routeName": route.name, "expectedWaypoints": route.qrMarkers.count, "waypointNames": route.qrMarkers.map { $0.name }, "directionCount": directionsToUse.count, "waypointLineCount": wpCountUpdate], "timestamp": Int(Date().timeIntervalSince1970 * 1000), "hypothesisId": "A"]
                if let updateData = try? JSONSerialization.data(withJSONObject: updatePayload), let updateLine = String(data: updateData, encoding: .utf8) { updateLine.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log") }
                // #endregion
            }
            objectWillChange.send()
        } else {
            print("PILL | updateCurrentRoute: walk not active — route/selectedRoute updated but pill NOT touched (display=\(displayDurationMinutesForPill ?? -1) lock=\(hasReceivedGoogleRefreshForPill))")
        }
        print("🔄 [ROUTE UPDATE] Route updated: '\(route.name)' with \(route.walkingDirections.count) directions, \(route.routePath.count) polyline points, \(route.durationMinutes)min")
    }
    
    /// Pre-pop duration adjust: offer user to switch to shorter route when we dropped waypoints (over target).
    func offerAdjustedRoute(_ route: WalkingRoute) {
        pendingAdjustedRoute = route
        showAdjustRouteAlert = true
    }
    
    /// Apply an adjusted route (shorter or longer) and update "mins left" pill to match. Use when user accepts shortened route or when we auto-apply a longer adjusted route.
    func applyAdjustedRouteAndUpdatePill(_ route: WalkingRoute) {
        displayDurationMinutesForPill = route.durationMinutes
        lastKnownPillMinutes = route.durationMinutes
        Self.persistPillState(minutes: route.durationMinutes, locked: true)
        updateCurrentRoute(route)
    }
    
    func acceptAdjustedRoute() {
        if let r = pendingAdjustedRoute {
            applyAdjustedRouteAndUpdatePill(r)
        }
        pendingAdjustedRoute = nil
        showAdjustRouteAlert = false
    }
    
    func declineAdjustedRoute() {
        pendingAdjustedRoute = nil
        showAdjustRouteAlert = false
    }
    
    // MARK: - Delay-change route refresh
    
    /// Request a new route from current location with duration derived from new delay (extend or shorten). Updates pill and directions on success. Call when user taps "Extend my walk" or "Get shorter route" on the delay overlay.
    /// When extending: preserves current route's waypoints and refreshes directions/polyline (so all waypoint names stay). When shortening or no current route: generates a new route.
    func requestNewRouteForDelayChange() {
        guard walkSession.isActive else { return }
        let service = mapsService ?? GoogleMapsService.shared
        guard let location = locationService.currentLocation?.coordinate else {
            delayChangeRouteError = "Location unavailable. Keep walking your current route."
            return
        }
        let isIncrease = waitTimeChangeInfo?.isIncrease ?? true
        let newMinutes = waitTimeChangeInfo?.newMinutes ?? waitTimeInfo.estimatedMinutes
        let buffer = isIncrease ? 5 : 8
        let targetDurationMinutes = max(10, min(45, newMinutes - buffer))
        
        isLoadingDelayChangeRoute = true
        delayChangeRouteError = nil
        showDelayChangeOverlay = false
        
        Task {
            do {
                print("REFRESH_FALLBACK | Delay-change: targetDuration=\(targetDurationMinutes)min (newMinutes=\(newMinutes), buffer=\(buffer), isIncrease=\(isIncrease))")
                
                // When extending: preserve current waypoints only if current route is already close to target duration; otherwise generate a longer route so the suggested walk matches the extended time.
                let walkingRoute: WalkingRoute
                let currentRoute = walkSession.currentRoute
                let currentMin = currentRoute?.durationMinutes ?? 0
                let minRatioToPreserve: Double = 0.5  // Preserve waypoints only if current >= 50% of target
                let shouldPreserve = isIncrease && currentRoute != nil && !currentRoute!.qrMarkers.isEmpty && (Double(currentMin) / Double(targetDurationMinutes)) >= minRatioToPreserve
                
                if shouldPreserve {
                    print("REFRESH_FALLBACK | Delay-change: extending — preserving current \(currentRoute!.qrMarkers.count) waypoints (current=\(currentMin)min ~= target=\(targetDurationMinutes)min) [\(currentRoute!.qrMarkers.map { $0.name }.joined(separator: ", "))]")
                    walkingRoute = WalkingRoute(
                        name: "Extended route",
                        description: "Route extended for extra time.",
                        durationMinutes: targetDurationMinutes,
                        distanceMeters: currentRoute!.distanceMeters,
                        difficulty: currentRoute!.difficulty,
                        isIndoor: currentRoute!.isIndoor,
                        isAccessible: currentRoute!.isAccessible,
                        landmarks: ["Start"] + currentRoute!.qrMarkers.map { $0.name } + ["Return"],
                        icon: currentRoute!.icon,
                        color: currentRoute!.color,
                        qrMarkers: currentRoute!.qrMarkers,
                        routeType: currentRoute!.routeType,
                        trimmed: currentRoute!.trimmed,
                        walkingDirections: currentRoute!.walkingDirections,
                        usedOSRMRouting: currentRoute!.usedOSRMRouting,
                        isFromPrePopulatedDatabase: currentRoute!.isFromPrePopulatedDatabase
                    )
                } else {
                    if isIncrease, currentRoute != nil, !currentRoute!.qrMarkers.isEmpty {
                        print("REFRESH_FALLBACK | Delay-change: current route short (\(currentMin)min) vs target (\(targetDurationMinutes)min) — generating new longer route with more waypoints")
                    }
                    // Shorten, or extend with a short current route: generate a new route for target duration
                    let generated = try await service.generateRouteTopologySafe(
                        from: location,
                        targetDurationMinutes: targetDurationMinutes,
                        difficulty: nil,
                        excludePlaceIds: [],
                        excludePOIs: []
                    )
                    print("REFRESH_FALLBACK | Delay-change: generator returned places=\(generated.places.count) [\(generated.places.map { $0.name }.joined(separator: ", "))]")
                    walkingRoute = RouteConversionHelper.walkingRoute(
                        from: generated,
                        origin: location,
                        name: isIncrease ? "Extended route" : "Shorter route",
                        description: isIncrease ? "Route extended for extra time." : "Shorter route to head back sooner."
                    )
                }
                
                print("REFRESH_FALLBACK | Delay-change: requesting route refresh (Google prioritised, then MapKit if quota/denied) — waypoints=\(walkingRoute.qrMarkers.count)")
                guard let refreshed = await service.refreshRouteWithGoogleOnly(route: walkingRoute, userLocation: location) else {
                    await MainActor.run {
                        delayChangeRouteError = "Couldn't update route. Keep walking your current route."
                        isLoadingDelayChangeRoute = false
                    }
                    return
                }
                await MainActor.run {
                    updateCurrentRoute(refreshed, sourceIsGoogle: true, resetDirectionIndex: true)
                    isLoadingDelayChangeRoute = false
                    delayChangeRouteError = nil
                }
            } catch {
                await MainActor.run {
                    delayChangeRouteError = "Couldn't find a new route. Keep walking your current route."
                    isLoadingDelayChangeRoute = false
                }
            }
        }
    }
    
    /// Clear delay-change route error (e.g. when user dismisses the message).
    func clearDelayChangeRouteError() {
        delayChangeRouteError = nil
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
        let routeMin = route.durationMinutes
        print("PILL | startWalk ENTRY selectedRoute.duration=\(routeMin)min display=\(displayDurationMinutesForPill ?? -1) lastKnown=\(lastKnownPillMinutes ?? -1) lock=\(hasReceivedGoogleRefreshForPill) isActive=\(walkSession.isActive)")
        
        // If already on a walk, do nothing — prevents overwriting Google-refreshed route/pill when startWalk is triggered again (e.g. re-render)
        if walkSession.isActive {
            print("PILL | startWalk: SKIPPED (already active) — pill stays display=\(displayDurationMinutesForPill ?? -1) lock=\(hasReceivedGoogleRefreshForPill)")
            return
        }
        
        // v1.6.29: Removed requestWalkPermissions() - no longer request HealthKit here
        // Step tracking is now fully opt-in via the Steps card during the walk
        // HealthKit sync offer is shown AFTER the post-walk check (if Motion was granted)
        
        walkSession.isActive = true
        walkSession.startTime = Date()
        walkSession.currentRoute = route
        // When route has 0 duration (bug/race), use pill/display so "10 min" choice is respected for pill and halfway
        let effectiveMinutes = route.durationMinutes > 0 ? route.durationMinutes : (displayDurationMinutesForPill ?? lastKnownPillMinutes ?? 10)
        let startMin = route.durationMinutes > 0 ? route.durationMinutes : effectiveMinutes
        if route.durationMinutes <= 0 {
            print("PILL | startWalk: route.durationMinutes=\(route.durationMinutes), using effectiveMinutes=\(effectiveMinutes) for pill and halfway")
        }
        // Only set pill when starting fresh (no refresh yet). Never unlock: hasReceivedGoogleRefreshForPill is only set to false in endWalk().
        if !hasReceivedGoogleRefreshForPill {
            displayDurationMinutesForPill = startMin
            lastKnownPillMinutes = startMin
            Self.persistPillState(minutes: startMin, locked: false)
            print("PILL | startWalk: pill SET display=\(startMin) lastKnown=\(startMin) lock=false (OSM/cache; lock will be set when first refresh runs)")
        } else {
            print("PILL | startWalk: pill LOCKED — NOT overwriting display=\(displayDurationMinutesForPill ?? -1) with route \(startMin)min (Google lock never cleared here)")
        }
        walkSession.startLocation = locationService.currentLocation?.coordinate  // v1.6.48: Snap Start/End to user's actual GPS position
        walkSession.halfwayAlertSent = false
        print("[HALFWAY] startWalk cameFromWalkNotification=\(AppDelegate.cameFromWalkNotification)")
        walkSession.returnNowAlertSent = false
        walkSession.walkCompleteAlertSent = false
        walkSession.stepsThisSession = 0
        walkSession.markersScanned = []
        
        // v1.7.5: Set flag so app knows walk is active (used to cancel notifications on app close)
        UserDefaults.standard.set(true, forKey: "hasActiveWalk")
        
        // v1.6.28: Reset step tracking flag for new walk
        stepTrackingWasEnabled = false
        
        // v1.9.33: Track if Motion was authorized at walk start (for HealthKit offer logic)
        motionWasAuthorizedAtWalkStart = healthKitService.isMotionAuthorized
        print("🚶 startWalk - motionWasAuthorizedAtWalkStart: \(motionWasAuthorizedAtWalkStart)")
        
        // v1.9.17: Reset walking alerts for new walk
        walkingAlertsEnabled = true
        
        // Calculate return time (halfway point of route duration). Use effectiveMinutes (route or pill fallback) so "10 min" choice is respected.
        let rawHalfway = Double(effectiveMinutes * 60) / 2
        let halfwaySeconds = max(60.0, rawHalfway)
        walkSession.estimatedReturnTime = Date().addingTimeInterval(halfwaySeconds)
        
        // v1.6.30: Step tracking is now opt-in via the Steps card during walk
        // Auto-start if (1) user has previously opted in, or (2) Motion is already authorized at walk start
        // so steps count without requiring a tap (avoids "Motion enabled but 0 steps" when user expected counting)
        let autoEnabled = UserDefaults.standard.bool(forKey: "stepTrackingAutoEnabled")
        print("🚶 startWalk - stepTrackingAutoEnabled: \(autoEnabled)")
        if autoEnabled || motionWasAuthorizedAtWalkStart {
            if !autoEnabled {
                print("🚶 Motion already authorized at walk start - auto-starting step observation")
            } else {
                print("🚶 Auto-starting step observation, setting stepTrackingWasEnabled = true")
            }
            healthKitService.startObservingSteps(from: Date())
            stepTrackingWasEnabled = true
        }
        // Otherwise, step tracking will start when user taps the Steps card
        
        // v1.9.79: Log walk start
        DebugLogger.shared.log("🚶🚶🚶 WALK STARTED 🚶🚶🚶", category: "WALK_LIFECYCLE")
        DebugLogger.shared.log("Route: \(route.name), Duration: \(route.durationMinutes) min, Waypoints: \(route.qrMarkers.count)", category: "WALK_LIFECYCLE")
        
        // Freeze diagnostic: heartbeat every 10s so we can see last activity if app freezes (logs to DebugLogs in Documents)
        walkHeartbeatTimer?.invalidate()
        walkHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self, self.walkSession.isActive else { return }
            let dist = Int(self.locationService.distanceWalked)
            let name = self.walkSession.currentRoute?.name ?? "?"
            DebugLogger.shared.log("walk_heartbeat route=\(name) distanceWalked=\(dist)m", category: "FREEZE_DIAG")
            print("[WALKED_DIST] heartbeat route=\(name) distanceWalked=\(dist)m")
        }
        if let t = walkHeartbeatTimer { RunLoop.main.add(t, forMode: .common) }
        
        // Map opens centered on route with padding; no auto-follow (Let's Go flow)
        mapStayCenteredOnRoute = true
        
        // Start location tracking (requests permission if needed)
        locationService.startTracking()
        
        // v1.9.15: Cache original directions for offline use
        cachedOriginalDirections = route.walkingDirections
        // #region agent log
        let dirs = route.walkingDirections
        let destinationOrWaypoint = dirs.filter { $0.instruction.lowercased().contains("destination") || $0.instruction.contains("Waypoint") }
        let payload: [String: Any] = [
            "location": "WaitingRoomViewModel:startWalk:cachedDirs",
            "message": "directions cached for display",
            "data": [
                "count": dirs.count,
                "samples": destinationOrWaypoint.prefix(5).map { String($0.instruction.prefix(70)) }
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "hypothesisId": "E"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: data, encoding: .utf8) {
            line.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
        }
        print("WAYPOINT_DIR WaitingRoomViewModel:startWalk:cachedDirs | directions cached for display | count=\(dirs.count) samples=\(destinationOrWaypoint.prefix(5).map { String($0.instruction.prefix(70)) })")
        // #endregion
        // #region agent log — waypoint directions diagnostic (filter Xcode by WAYPOINT_DIAG)
        let waypointNames = route.qrMarkers.map { $0.name }
        let waypointLineCount = dirs.filter { $0.instruction.contains("Waypoint") && $0.instruction.contains("is on your") }.count
        print("WAYPOINT_DIAG startWalk | expected waypoints=\(route.qrMarkers.count) names=[\(waypointNames.joined(separator: ", "))] | directions=\(dirs.count) waypointLines=\(waypointLineCount)")
        let diagPayload: [String: Any] = ["location": "WaitingRoomViewModel:startWalk:diag", "message": "waypoint diagnostic", "data": ["expectedWaypoints": route.qrMarkers.count, "waypointNames": waypointNames, "directionCount": dirs.count, "waypointLineCount": waypointLineCount], "timestamp": Int(Date().timeIntervalSince1970 * 1000), "hypothesisId": "E"]
        if let diagData = try? JSONSerialization.data(withJSONObject: diagPayload), let diagLine = String(data: diagData, encoding: .utf8) { diagLine.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log") }
        // #endregion
        cachedReturnDirections = []
        isUsingReturnDirections = false
        
        // v1.9.16: Pre-calculate return route from last waypoint to start (for offline fallback)
        preCalculateReturnRoute(route: route)
        
        // Start direction monitoring for turn-by-turn notifications (non-indoor routes only)
        if !route.isIndoor && !route.walkingDirections.isEmpty {
            // v1.9.83: Filter out ALL arrival instructions, but store the first one to show when close
            // This prevents showing "The destination is on your right" during navigation
            // Arrival instructions can appear in the middle of the list (end of outbound route)
            let originalCount = route.walkingDirections.count
            arrivalInstruction = nil  // Reset for new walk
            
            let filteredDirections = route.walkingDirections.compactMap { direction -> WalkingDirection? in
                let lowercased = direction.instruction.lowercased()
                
                // Check if this is an arrival instruction
                let isArrivalInstruction = lowercased.contains("the destination is on your right") ||
                   lowercased.contains("the destination is on your left") ||
                   lowercased.contains("destination is on your right") ||
                   lowercased.contains("destination is on your left") ||
                   (lowercased.contains("destination") && (lowercased.contains("on your right") || lowercased.contains("on your left"))) ||
                   (lowercased.contains("arrive") && lowercased.contains("destination"))
                
                if isArrivalInstruction {
                    // Store the first arrival instruction to show when close to destination
                    if arrivalInstruction == nil {
                        arrivalInstruction = direction
                        DebugLogger.shared.log("💾 Stored arrival instruction for later: '\(direction.instruction)'", category: "DIRECTION_FILTER")
                    }
                    DebugLogger.shared.log("🚫 Filtered out arrival instruction: '\(direction.instruction)'", category: "DIRECTION_FILTER")
                    return nil
                }
                return direction
            }
            
            if filteredDirections.count < originalCount {
                DebugLogger.shared.log("✅ Filtered \(originalCount - filteredDirections.count) arrival instruction(s). Passing \(filteredDirections.count) directions to monitoring", category: "DIRECTION_FILTER")
            }
            
            // v1.9.90: Find polyline index of last marker to prevent advancing to return journey before destination is reached
            var lastMarkerPolylineIndex: Int? = nil
            if let lastMarker = route.qrMarkers.last {
                // Find the closest point on the route polyline to the last marker
                var closestIndex = 0
                var closestDistance = Double.greatestFiniteMagnitude
                let markerLocation = CLLocation(latitude: lastMarker.coordinate.latitude, longitude: lastMarker.coordinate.longitude)
                
                for (index, routePoint) in route.routePath.enumerated() {
                    let routeLocation = CLLocation(latitude: routePoint.latitude, longitude: routePoint.longitude)
                    let distance = markerLocation.distance(from: routeLocation)
                    if distance < closestDistance {
                        closestDistance = distance
                        closestIndex = index
                    }
                }
                lastMarkerPolylineIndex = closestIndex
                DebugLogger.shared.log("📍 Last marker polyline index: \(closestIndex) (distance: \(String(format: "%.1f", closestDistance))m from marker)", category: "DIRECTION_MONITORING")
            }
            
            // v1.9.93: Find the return journey start index in filtered directions
            // The return journey starts at the direction that comes after the arrival instruction
            var returnJourneyStartIndex: Int? = nil
            if let arrivalInst = arrivalInstruction,
               let arrivalIndexInOriginal = route.walkingDirections.firstIndex(where: { $0.id == arrivalInst.id }) {
                // Count how many directions before the arrival instruction were filtered out
                var filteredBeforeArrival = 0
                for i in 0..<arrivalIndexInOriginal {
                    let direction = route.walkingDirections[i]
                    let lowercased = direction.instruction.lowercased()
                    let isArrival = lowercased.contains("the destination is on your right") ||
                                   lowercased.contains("the destination is on your left") ||
                                   lowercased.contains("destination is on your right") ||
                                   lowercased.contains("destination is on your left") ||
                                   (lowercased.contains("destination") && (lowercased.contains("on your right") || lowercased.contains("on your left"))) ||
                                   (lowercased.contains("arrive") && lowercased.contains("destination"))
                    if isArrival {
                        filteredBeforeArrival += 1
                    }
                }
                // The return journey starts at (arrivalIndexInOriginal - filteredBeforeArrival) in the filtered list
                returnJourneyStartIndex = arrivalIndexInOriginal - filteredBeforeArrival
                DebugLogger.shared.log("📍 Return journey starts at filtered direction index: \(returnJourneyStartIndex!) (original arrival index: \(arrivalIndexInOriginal))", category: "DIRECTION_MONITORING")
            }
            
            // Build mapping: direction index -> marker ID for waypoint steps (first Waypoint = first marker, etc.)
            directionIndexToMarkerId = [:]
            var waypointCount = 0
            for (index, dir) in filteredDirections.enumerated() {
                if dir.instruction.contains("Waypoint") && dir.instruction.contains("is on your"),
                   waypointCount < route.qrMarkers.count {
                    directionIndexToMarkerId[index] = route.qrMarkers[waypointCount].id
                    waypointCount += 1
                }
            }
            
            locationService.startDirectionMonitoring(
                directions: filteredDirections,
                routePath: route.routePath,
                lastMarkerPolylineIndex: lastMarkerPolylineIndex,
                returnJourneyStartIndex: returnJourneyStartIndex,
                isLastMarkerVisited: { [weak self] in
                    guard let self = self,
                          let lastMarker = route.qrMarkers.last else { return false }
                    return self.visitedMarkerIds.contains(lastMarker.id)
                },
                canAdvanceFromDirectionIndex: { [weak self] index in
                    guard let self = self else { return true }
                    if let markerId = self.directionIndexToMarkerId[index] {
                        return self.visitedMarkerIds.contains(markerId)
                    }
                    return true
                }
            )
        }
        
        // Schedule notifications
        notificationService.sendWalkStartedNotification(routeName: route.name, duration: effectiveMinutes)
        scheduleWalkNotifications(routeDuration: effectiveMinutes)
        
        // Start session timer
        startSessionTimer()
        
        // Prompt for pre-walk wellbeing score if not already done
        if userProgress.anxietyLevelBefore == nil {
            showPreWalkWellbeing = true
        }
    }
    
    func endWalk(completed: Bool) {
        // Log immediately so we can see order vs home arrival / sheet (search for [HOME] and [WALK_LIFECYCLE])
        DebugLogger.shared.log("endWalk(completed: \(completed)) CALLED - showHomeArrivalPrompt=\(showHomeArrivalPrompt) hasReachedHome=\(hasReachedHome)", category: "HOME")
        // v1.9.79: Log walk end
        DebugLogger.shared.log("WALK ENDED - Completed: \(completed)", category: "WALK_LIFECYCLE")
        if let route = walkSession.currentRoute {
            DebugLogger.shared.log("Final stats - Distance: \(Int(locationService.distanceWalked))m, Duration: \(walkSession.elapsedTime) seconds", category: "WALK_LIFECYCLE")
            print("[WALKED_DIST] endWalk completed=\(completed) finalDistance=\(Int(locationService.distanceWalked))m duration=\(walkSession.elapsedTime)s")
        }
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        print("🔍 [MOTION DEBUG] [\(timeString)] 🏁 endWalk(completed: \(completed)) CALLED")
        print("🔍 [MOTION DEBUG] [\(timeString)]   stepTrackingWasEnabled: \(stepTrackingWasEnabled)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Current Motion auth status: \(healthKitService.isMotionAuthorized ? "authorized" : "not authorized")")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Call stack:")
        Thread.callStackSymbols.prefix(10).enumerated().forEach { index, symbol in
            print("🔍 [MOTION DEBUG] [\(timeString)]     [\(index)] \(symbol)")
        }
        
        walkSession.isActive = false
        
        // Prevent "reached home" sheet from appearing after user has already ended the walk
        showHomeArrivalPrompt = false
        hasReachedHome = true  // so checkHomeArrival won't fire again
        
        walkHeartbeatTimer?.invalidate()
        walkHeartbeatTimer = nil
        
        // v1.7.5: Clear flag so app knows walk has ended
        UserDefaults.standard.set(false, forKey: "hasActiveWalk")
        
        // Record progress
        if completed {
            userProgress.routesCompleted += 1
            userProgress.todayRoutesCompleted += 1
            userProgress.addPoints(50 + walkSession.stepsThisSession / 10)
        }
        
        // Transfer steps
        userProgress.recordSteps(walkSession.stepsThisSession)
        
        // Stop tracking
        print("🔍 [MOTION DEBUG] [\(timeString)]   🛑 About to call healthKitService.stopObserving()")
        healthKitService.stopObserving()
        locationService.stopTracking()
        notificationService.cancelAllWalkingNotifications()
        stopSessionTimer()
        
        // Prompt for post-walk wellbeing score
        // v1.9.34: Motion permission is now requested AFTER anxiety check dismisses (in RouteSelectionView onDismiss)
        if completed && userProgress.anxietyLevelBefore != nil {
            print("🔍 [MOTION DEBUG] [\(timeString)]   📋 Setting showPostWalkWellbeing = true")
            showPostWalkWellbeing = true
        } else {
            print("🔍 [MOTION DEBUG] [\(timeString)]   📋 NOT showing post-walk wellbeing (completed: \(completed), anxietyLevelBefore: \(userProgress.anxietyLevelBefore != nil))")
        }
        
        // Reset session
        walkSession.startTime = nil
        walkSession.currentRoute = nil
        print("PILL | endWalk: clearing pill (was display=\(displayDurationMinutesForPill ?? -1) lastKnown=\(lastKnownPillMinutes ?? -1) lock=\(hasReceivedGoogleRefreshForPill))")
        displayDurationMinutesForPill = nil
        hasReceivedGoogleRefreshForPill = false
        lastKnownPillMinutes = nil
        Self.clearPersistedPillState()
        selectedRoute = nil
        visitedMarkerIds = []
        currentMarker = nil
        lastWaypointActivationTime = nil // v2.1.7: Reset activation timer
        
        // v1.9.15: Reset cached directions
        cachedOriginalDirections = []
        cachedReturnDirections = []
        isUsingReturnDirections = false
        
        // v1.9.85: Reset arrival instruction
        arrivalInstruction = nil
        
        // v1.9.16: Reset cached return route
        cachedReturnRoutePolyline = []
        hasCachedReturnRoute = false
        isHeadingBack = false
        directionIndexToMarkerId = [:]
        
        mapStayCenteredOnRoute = false
        
        // v1.6.28: Reset step tracking flag for next walk
        // (stepTrackingWasEnabled is used to determine if HealthKit offer should be shown)
        // Note: We don't reset it here because we need it for the post-walk flow
        // It will be reset at the start of the next walk
        
        print("🔍 [MOTION DEBUG] [\(timeString)]   ✅ endWalk() completed")
    }
    
    // v2.1.0: Pre-calculation of return route DISABLED for ToS compliance
    // MapKit directions cannot be cached. Return directions will be fetched live
    // from Google Directions API when user reaches the last waypoint.
    private func preCalculateReturnRoute(route: WalkingRoute) {
        // v2.1.0: DISABLED - no MapKit caching for ToS compliance
        // Return directions will be fetched live when user reaches last waypoint
        print("📍 Return route will be fetched live via Google when needed (ToS compliance)")
        hasCachedReturnRoute = false
    }
    
    /// Called when user taps "Head back" on 50% or 80% overlay. Switches to return route (current → origin) and skips 80%/100% overlays.
    func userTappedHeadBack() {
        print("🏠 [HEAD HOME] userTappedHeadBack() — setting isHeadingBack=true, fetching return route")
        isHeadingBack = true
        didSwitchToReturnDirections()
        fetchAndSwitchToReturnRoute()
    }
    
    /// Call when switching to return leg (directions or route). Dismisses 50%/80% overlays and cancels pending progress notifications so user doesn't see "head back" while already heading back.
    func didSwitchToReturnDirections() {
        showHalfwayAlert = false
        showReturnNowAlert = false
        cancelAlertAutoDismissTimer()
        notificationService.cancelProgressNotifications()
    }
    
    /// Fetch route from current location → origin and switch map/directions to it.
    /// Uses Google Directions API first (street-following route); falls back to MapKit if Google fails.
    private func fetchAndSwitchToReturnRoute() {
        guard let currentCoord = locationService.currentLocation?.coordinate,
              let originCoord = walkSession.startLocation,
              let currentRoute = walkSession.currentRoute else {
            print("🏠 [HEAD HOME] fetchAndSwitchToReturnRoute — SKIP: missing location or route")
            return
        }
        let distanceToStart = CLLocation(latitude: currentCoord.latitude, longitude: currentCoord.longitude)
            .distance(from: CLLocation(latitude: originCoord.latitude, longitude: originCoord.longitude))
        print("🏠 [HEAD HOME] fetchAndSwitchToReturnRoute — current=(\(String(format: "%.5f", currentCoord.latitude)), \(String(format: "%.5f", currentCoord.longitude))), start=(\(String(format: "%.5f", originCoord.latitude)), \(String(format: "%.5f", originCoord.longitude))), distanceToStart=\(Int(distanceToStart))m")
        
        Task { @MainActor in
            // If already at start, use a minimal route so the line is short (not to the first waypoint)
            if distanceToStart < 25 {
                let minimalPolyline = [currentCoord, originCoord]
                let encodedPolyline = encodePolylineForReturnRoute(minimalPolyline)
                let returnRoute = WalkingRoute(
                    name: currentRoute.name,
                    description: currentRoute.description,
                    durationMinutes: 1,
                    distanceMeters: Int(distanceToStart),
                    difficulty: currentRoute.difficulty,
                    isIndoor: currentRoute.isIndoor,
                    isAccessible: currentRoute.isAccessible,
                    landmarks: currentRoute.landmarks,
                    icon: currentRoute.icon,
                    color: currentRoute.color,
                    qrMarkers: currentRoute.qrMarkers,
                    routeType: currentRoute.routeType,
                    encodedPolyline: encodedPolyline,
                    walkingDirections: [WalkingDirection(instruction: "You're at the start", distance: "0m", distanceMeters: 0, duration: "", maneuver: "arrive")],
                    usedOSRMRouting: false,
                    isFromPrePopulatedDatabase: currentRoute.isFromPrePopulatedDatabase
                )
                updateCurrentRoute(returnRoute, resetDirectionIndex: true)
                print("🏠 [HEAD HOME] Route updated: MINIMAL (already at start) — polyline points=2, from current to start")
                return
            }
            
            // Try Google Directions first for a street-following return route
            print("🏠 [HEAD HOME] Requesting return route from Google Directions...")
            if let result = await GoogleMapsService.shared.getReturnDirectionsLive(from: currentCoord, to: originCoord) {
                let encodedPolyline = encodePolylineForReturnRoute(result.polyline)
                let returnRoute = WalkingRoute(
                    name: currentRoute.name,
                    description: currentRoute.description,
                    durationMinutes: max(1, result.totalDurationSeconds / 60),
                    distanceMeters: result.totalDistanceMeters,
                    difficulty: currentRoute.difficulty,
                    isIndoor: currentRoute.isIndoor,
                    isAccessible: currentRoute.isAccessible,
                    landmarks: currentRoute.landmarks,
                    icon: currentRoute.icon,
                    color: currentRoute.color,
                    qrMarkers: currentRoute.qrMarkers,
                    routeType: currentRoute.routeType,
                    encodedPolyline: encodedPolyline,
                    walkingDirections: result.directions.isEmpty ? currentRoute.walkingDirections : result.directions,
                    usedOSRMRouting: false,
                    isFromPrePopulatedDatabase: currentRoute.isFromPrePopulatedDatabase
                )
                updateCurrentRoute(returnRoute, resetDirectionIndex: true)
                let first = result.polyline.first.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "nil"
                let last = result.polyline.last.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "nil"
                print("🏠 [HEAD HOME] Route updated: GOOGLE — polyline points=\(result.polyline.count), first=(\(first)), last=(\(last))")
                return
            }
            
            // Fallback to MapKit if Google fails (e.g. no API key, quota, or network)
            print("🏠 [HEAD HOME] Google failed or unavailable — using MapKit fallback")
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentCoord))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: originCoord))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            directions.calculate { [weak self] response, error in
                guard let self = self else { return }
                if let error = error {
                    print("🚶 [HEAD BACK] MapKit return route failed: \(error.localizedDescription)")
                    return
                }
                guard let mkRoute = response?.routes.first else {
                    print("🚶 [HEAD BACK] MapKit returned no route")
                    return
                }
                let polylineCoords = self.polylineCoordinates(from: mkRoute.polyline)
                guard !polylineCoords.isEmpty else {
                    print("🚶 [HEAD BACK] No polyline coordinates")
                    return
                }
                let encodedPolyline = self.encodePolylineForReturnRoute(polylineCoords)
                let walkingDirs = self.extractDirectionsFromMKRoute(mkRoute)
                let returnRoute = WalkingRoute(
                    name: currentRoute.name,
                    description: currentRoute.description,
                    durationMinutes: max(1, Int(mkRoute.expectedTravelTime / 60)),
                    distanceMeters: Int(mkRoute.distance),
                    difficulty: currentRoute.difficulty,
                    isIndoor: currentRoute.isIndoor,
                    isAccessible: currentRoute.isAccessible,
                    landmarks: currentRoute.landmarks,
                    icon: currentRoute.icon,
                    color: currentRoute.color,
                    qrMarkers: currentRoute.qrMarkers,
                    routeType: currentRoute.routeType,
                    encodedPolyline: encodedPolyline,
                    walkingDirections: walkingDirs.isEmpty ? currentRoute.walkingDirections : walkingDirs,
                    usedOSRMRouting: false,
                    isFromPrePopulatedDatabase: currentRoute.isFromPrePopulatedDatabase
                )
                Task { @MainActor in
                    self.updateCurrentRoute(returnRoute, resetDirectionIndex: true)
                    let first = polylineCoords.first.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "nil"
                    let last = polylineCoords.last.map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" } ?? "nil"
                    print("🏠 [HEAD HOME] Route updated: MAPKIT — polyline points=\(polylineCoords.count), first=(\(first)), last=(\(last))")
                }
            }
        }
    }
    
    private func polylineCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }
    
    private func encodePolylineForReturnRoute(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encoded = ""
        var prevLat = 0, prevLng = 0
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            encoded += encodePolylineSignedNumber(lat - prevLat)
            encoded += encodePolylineSignedNumber(lng - prevLng)
            prevLat = lat
            prevLng = lng
        }
        return encoded
    }
    
    private func encodePolylineSignedNumber(_ num: Int) -> String {
        var sgn = num << 1
        if num < 0 { sgn = ~sgn }
        return encodePolylineNumber(sgn)
    }
    
    private func encodePolylineNumber(_ num: Int) -> String {
        var n = num
        var result = ""
        while n >= 0x20 {
            result += String(UnicodeScalar((0x20 | (n & 0x1f)) + 63)!)
            n >>= 5
        }
        result += String(UnicodeScalar(n + 63)!)
        return result
    }
    
    // v1.9.16: Extract walking directions from MKRoute steps (helper for pre-calculation)
    // v1.9.77: Exclude final arrival instruction from navigation directions to prevent showing destination too early
    private func extractDirectionsFromMKRoute(_ route: MKRoute) -> [WalkingDirection] {
        var directions: [WalkingDirection] = []
        let lastStepWithInstructions = route.steps.lastIndex(where: { !$0.instructions.isEmpty })
        
        for (index, step) in route.steps.enumerated() {
            guard !step.instructions.isEmpty else { continue }
            
            // v1.9.77: Skip the final arrival instruction - it will be shown when user is close to destination
            // This prevents showing "The destination is on your right" when starting the walk
            let isLastStep = index == lastStepWithInstructions
            if isLastStep {
                // Check if this is an arrival instruction (contains "destination", "arrive", etc.)
                let lowercased = step.instructions.lowercased()
                if lowercased.contains("arrive") || lowercased.contains("destination") || lowercased.contains("your destination") {
                    // Skip this final arrival instruction - it's not a navigation step
                    continue
                }
            }
            
            let stepDistance = Int(step.distance)
            let stepDurationSeconds = max(60, stepDistance / 80 * 60)
            let durationText = stepDurationSeconds >= 60 ? "\(stepDurationSeconds / 60) min" : "\(stepDurationSeconds) sec"
            
            let distanceText: String
            if stepDistance < 1000 {
                distanceText = "\(stepDistance)m"
            } else {
                distanceText = String(format: "%.1f km", Double(stepDistance) / 1000.0)
            }
            
            let maneuver = self.extractManeuverType(from: step.instructions)
            
            let direction = WalkingDirection(
                instruction: step.instructions,
                distance: distanceText,
                distanceMeters: stepDistance,
                duration: durationText,
                maneuver: maneuver
            )
            directions.append(direction)
        }
        
        return directions
    }
    
    // v1.9.16: Extract maneuver type from instruction text
    private func extractManeuverType(from instruction: String) -> String {
        let lowercased = instruction.lowercased()
        if lowercased.contains("turn left") || lowercased.contains("left turn") {
            return "turn-left"
        } else if lowercased.contains("turn right") || lowercased.contains("right turn") {
            return "turn-right"
        } else if lowercased.contains("turn sharp left") {
            return "turn-sharp-left"
        } else if lowercased.contains("turn sharp right") {
            return "turn-sharp-right"
        } else if lowercased.contains("slight left") {
            return "turn-slight-left"
        } else if lowercased.contains("slight right") {
            return "turn-slight-right"
        } else if lowercased.contains("continue") || lowercased.contains("straight") {
            return "straight"
        } else if lowercased.contains("u-turn") || lowercased.contains("u turn") {
            return "uturn"
        } else if lowercased.contains("arrive") {
            return "arrive"
        }
        return "straight"
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
        
        // Refresh steps from pedometer every 5 seconds; live CMPedometer callbacks can be delayed/batched so steps stay 0
        if stepTrackingWasEnabled, walkSession.elapsedSeconds > 0, walkSession.elapsedSeconds % 5 == 0 {
            healthKitService.refreshSessionStepsFromPedometer()
        }
        // Update steps from pedometer/HealthKit (real-time)
        walkSession.stepsThisSession = healthKitService.stepCount
        
        // Use pedometer distance if available; otherwise keep GPS-derived distance (do not overwrite with 0 when stepCount is 0 — pedometer can lag or be zero while user is walking).
        // Sanity: don't overwrite GPS with pedometer when GPS suggests we're barely moving and pedometer is much larger (phone jitter / hand movement counted as distance).
        if healthKitService.distance > 0 {
            let prev = locationService.distanceWalked
            let pedometerM = healthKitService.distance
            let elapsed = walkSession.elapsedSeconds
            let maxPlausibleM = Double(max(elapsed, 1)) * 2.5 // 2.5 m/s max
            let gpsSuggestsStationary = prev < 5
            let pedometerMuchLarger = pedometerM > 10 && pedometerM > prev + 8
            if pedometerM <= maxPlausibleM && !(gpsSuggestsStationary && pedometerMuchLarger) {
                locationService.distanceWalked = pedometerM
                print("[WALKED_DIST] set from HealthKit: \(Int(pedometerM))m (was GPS \(Int(prev))m)")
            } else if gpsSuggestsStationary && pedometerMuchLarger {
                print("[WALKED_DIST] keeping GPS \(Int(prev))m (pedometer \(Int(pedometerM))m likely phone jitter)")
            }
        }
        
        #if targetEnvironment(simulator)
        // Only simulate on simulator (no real sensors)
        if walkSession.elapsedSeconds > 3 {
            let elapsedMinutes = Double(walkSession.elapsedSeconds) / 60.0
            walkSession.stepsThisSession = Int(elapsedMinutes * 100)
            locationService.distanceWalked = elapsedMinutes * 80
            print("[WALKED_DIST] simulator: set to \(Int(elapsedMinutes * 80))m (elapsed \(walkSession.elapsedSeconds)s)")
        }
        #endif
        
        // Check for marker proximity (location-based triggers)
        checkMarkerProximity()
        
        // v1.9.13: Check for home arrival (only if all waypoints visited)
        checkHomeArrival()
        
        // Force view update for nested observable
        objectWillChange.send()
        
        // Check for halfway point (50%). Skip if finding new route, or already on return leg (directions or user chose Head back).
        let elapsed = walkSession.elapsedSeconds
        if !isLoadingDelayChangeRoute, !isUsingReturnDirections, !isHeadingBack,
           !walkSession.halfwayAlertSent,
           elapsed >= 60,
           let returnTime = walkSession.estimatedReturnTime,
           Date() >= returnTime {
            let cameFrom = AppDelegate.cameFromWalkNotification
            print("[HALFWAY] entered returnTime=\(returnTime) walkingAlertsEnabled=\(walkingAlertsEnabled) cameFromWalkNotification=\(cameFrom)")
            if walkingAlertsEnabled {
                walkSession.halfwayAlertSent = true
                
                // Only show in-app alert if NOT coming from a push notification tap
                if !cameFrom {
                    print("[HALFWAY] showing in-app overlay (showHalfwayAlert=true)")
                    showHalfwayAlert = true
                    startAlertAutoDismissTimer(for: \.showHalfwayAlert)
                } else {
                    print("[HALFWAY] skipping in-app overlay (cameFromWalkNotification=true)")
                }
            } else {
                print("[HALFWAY] blocked walkingAlertsEnabled=false")
            }
        }
        
        // Check for return now point (80%) - skip if finding new route or already on return leg (directions or user chose Head back)
        if !isLoadingDelayChangeRoute, !isHeadingBack, !isUsingReturnDirections, walkSession.progress >= 0.8 && walkSession.progress < 1.0 {
            // Only show if not already shown and alerts are enabled
            if !walkSession.returnNowAlertSent {
                if walkingAlertsEnabled {
                    walkSession.returnNowAlertSent = true
                    showHalfwayAlert = false // Dismiss halfway alert if it's still showing
                    cancelAlertAutoDismissTimer() // Cancel previous timer
                    
                    if !AppDelegate.cameFromWalkNotification {
                        print("🚶 Showing return now alert (80%)")
                        showReturnNowAlert = true
                        startAlertAutoDismissTimer(for: \.showReturnNowAlert)
                    } else {
                        print("📱 Skipping return now in-app alert - user came from push notification")
                    }
                } else {
                    print("🔕 Return now alert blocked - walkingAlertsEnabled = false")
                }
            }
        }
        
        // Check if walk is complete (100%) - skip if finding new route or already on return leg; when on return with all waypoints visited, rely on home arrival instead.
        let onReturnWithAllVisited = (selectedRoute.map { route in
            route.qrMarkers.count > 0 && visitedMarkerIds.count == route.qrMarkers.count
        } ?? false) && isUsingReturnDirections
        if !isLoadingDelayChangeRoute, !isHeadingBack, !isUsingReturnDirections, walkSession.progress >= 1.0, !onReturnWithAllVisited {
            // Only show if not already shown and alerts are enabled
            if !walkSession.walkCompleteAlertSent {
                if walkingAlertsEnabled {
                    walkSession.walkCompleteAlertSent = true
                    showHalfwayAlert = false // Dismiss previous alerts if they're still showing
                    showReturnNowAlert = false // Dismiss previous alerts if they're still showing
                    cancelAlertAutoDismissTimer() // Cancel previous timer
                    
                    if !AppDelegate.cameFromWalkNotification {
                        print("🚶 Showing walk complete alert (100%)")
                        showWalkCompleteAlert = true
                        startAlertAutoDismissTimer(for: \.showWalkCompleteAlert)
                    } else {
                        print("📱 Skipping walk complete in-app alert - user came from push notification")
                    }
                } else {
                    print("🔕 Walk complete alert blocked - walkingAlertsEnabled = false")
                }
            }
        }
    }
    
    // MARK: - Location-Based Marker Detection
    private func checkMarkerProximity() {
        guard let route = selectedRoute,
              let userLocation = locationService.currentLocation else { return }
        
        // Get route path for dynamic radius calculation
        let routePath = route.routePath
        
        // v1.9.84: Check if approaching final destination (last marker) to show arrival instruction
        // Only check if we haven't visited the last marker yet (still on outbound leg)
        if let lastMarker = route.qrMarkers.last,
           !visitedMarkerIds.contains(lastMarker.id),
           !isUsingReturnDirections,  // v1.9.84: Don't show arrival instruction during return leg
           let arrivalInst = arrivalInstruction {
            let markerLocation = CLLocation(latitude: lastMarker.coordinate.latitude, longitude: lastMarker.coordinate.longitude)
            let distanceToLastMarker = userLocation.distance(from: markerLocation)
            
            // Show arrival instruction when within 30m of final destination
            if distanceToLastMarker < 30 {
                // Temporarily add arrival instruction to cached directions so banner can show it
                if !cachedOriginalDirections.contains(where: { $0.id == arrivalInst.id }) {
                    cachedOriginalDirections.append(arrivalInst)
                    // Set direction index only if within LocationService's waypoint list (avoid index out of range crash)
                    let arrivalIndex = cachedOriginalDirections.count - 1
                    let safeIndex = min(arrivalIndex, locationService.safeMaxDirectionIndex)
                    locationService.currentDirectionIndex = safeIndex
                    DebugLogger.shared.log("📍 Showing arrival instruction - within \(Int(distanceToLastMarker))m of final destination (index: \(safeIndex), requested: \(arrivalIndex))", category: "ARRIVAL")
                }
            } else {
                // Remove arrival instruction if we're further away
                if let arrivalIndex = cachedOriginalDirections.firstIndex(where: { $0.id == arrivalInst.id }) {
                    cachedOriginalDirections.remove(at: arrivalIndex)
                    // Reset direction index if it was pointing to the arrival instruction; clamp to service's valid range
                    if locationService.currentDirectionIndex >= cachedOriginalDirections.count {
                        locationService.currentDirectionIndex = min(max(0, cachedOriginalDirections.count - 1), locationService.safeMaxDirectionIndex)
                    }
                }
            }
        } else if isUsingReturnDirections || (route.qrMarkers.last.map { visitedMarkerIds.contains($0.id) } ?? false) {
            // v1.9.84: Clear arrival instruction if we're on return leg or have visited last marker
            if let arrivalInst = arrivalInstruction,
               let arrivalIndex = cachedOriginalDirections.firstIndex(where: { $0.id == arrivalInst.id }) {
                cachedOriginalDirections.remove(at: arrivalIndex)
                if locationService.currentDirectionIndex >= cachedOriginalDirections.count {
                    locationService.currentDirectionIndex = min(max(0, cachedOriginalDirections.count - 1), locationService.safeMaxDirectionIndex)
                }
            }
        }
        
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
            
            // v2.1.7: Prevent rapid multiple waypoint activations (safeguard for close waypoints)
            let minTimeBetweenActivations: TimeInterval = 30.0 // 30 seconds
            let timeSinceLastActivation = lastWaypointActivationTime.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let canActivate = timeSinceLastActivation >= minTimeBetweenActivations
            
            if userDistanceToMarker < activationRadius {
                // Check if another waypoint was activated recently
                if !canActivate {
                    DebugLogger.shared.log("Waypoint activation BLOCKED: \(marker.name) (distance: \(Int(userDistanceToMarker))m, radius: \(Int(activationRadius))m) - too soon after last activation (\(String(format: "%.1f", timeSinceLastActivation))s < \(minTimeBetweenActivations)s)", category: "WAYPOINT")
                    continue // Skip this waypoint, check next one
                }
                
                let isLast = marker.id == route.qrMarkers.last?.id
                DebugLogger.shared.log("Waypoint ACTIVATED: \(marker.name) (distance: \(Int(userDistanceToMarker))m, radius: \(Int(activationRadius))m) isLast=\(isLast) contentType=\(marker.contentType.rawValue)", category: "WAYPOINT")
                lastWaypointActivationTime = Date() // Track activation time
                currentMarker = marker
                visitedMarkerIds.insert(marker.id)
                // #region agent log
                if marker.id == route.qrMarkers.last?.id {
                    let payload: [String: Any] = [
                        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                        "message": "LAST_MARKER_VISITED",
                        "hypothesisId": "H3",
                        "location": "WaitingRoomViewModel.swift:checkWaypointArrival",
                        "data": ["markerName": marker.name, "markerId": marker.id.uuidString, "distanceToMarker": userDistanceToMarker] as [String: Any]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: data, encoding: .utf8) {
                        line.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                    }
                    DebugLogger.shared.log("AGENT LAST_MARKER_VISITED markerName=\"\(marker.name)\" markerId=\(marker.id) distanceToMarker=\(String(format: "%.1f", userDistanceToMarker))m", category: "AGENT_RETURN_LEG")
                }
                // #endregion
                walkSession.markersScanned.append(marker)
                userProgress.qrScansCompleted += 1
                userProgress.todayQRScansCompleted += 1
                userProgress.addPoints(marker.pointsValue)
                
                // v1.9.84: If this is the last marker, clear arrival instruction for return leg
                if isLast, let arrivalInst = arrivalInstruction {
                    // Remove arrival instruction from cached directions
                    if let arrivalIndex = cachedOriginalDirections.firstIndex(where: { $0.id == arrivalInst.id }) {
                        cachedOriginalDirections.remove(at: arrivalIndex)
                        DebugLogger.shared.log("Cleared arrival instruction - reached final destination, preparing for return leg", category: "ARRIVAL")
                    }
                    // Clear the stored arrival instruction so it doesn't interfere with return directions
                    arrivalInstruction = nil
                }
                
                // Show the photo prompt (marker arrival sheet)
                showMarkerArrivalPrompt = true
                DebugLogger.shared.log("Set showMarkerArrivalPrompt=true for marker '\(marker.name)' (visited=\(visitedMarkerIds.count)/\(route.qrMarkers.count))", category: "ARRIVAL")
                
                // Send notification
                notificationService.sendMarkerArrivalNotification(markerName: marker.name)
                break
            }
        }
    }
    
    // v1.9.15: Check if user has reached home (start location) at the END of the walk
    // Fixed to use actual start location, not route end point
    // Only activates when:
    // 1. All waypoints have been visited
    // 2. User is returning to start (not at start at the beginning)
    // 3. User is within 30m of start location
    private func checkHomeArrival() {
        guard let route = selectedRoute,
              let userLocation = locationService.currentLocation,
              let startLocation = walkSession.startLocation ?? route.routePath.first,
              !hasReachedHome,
              walkSession.isActive else {
            if selectedRoute == nil || locationService.currentLocation == nil { return }
            if hasReachedHome { return }
            if !walkSession.isActive { DebugLogger.shared.log("checkHomeArrival SKIP: walkSession.isActive=false", category: "HOME"); return }
            return
        }
        
        // CRITICAL: Only check for home arrival if ALL waypoints have been visited
        // This ensures we're at the END of the walk, not the beginning
        guard visitedMarkerIds.count == route.qrMarkers.count,
              route.qrMarkers.count > 0 else { return }
        
        // Additional check: Ensure we've been walking for at least 30 seconds
        // This prevents false triggers if user starts near home
        guard walkSession.elapsedSeconds >= 30 else { return }
        
        let startPoint = CLLocation(latitude: startLocation.latitude, longitude: startLocation.longitude)
        let distanceToHome = userLocation.distance(from: startPoint)
        if distanceToHome < 50 && distanceToHome >= 30 {
            DebugLogger.shared.log("checkHomeArrival: approaching (distance: \(Int(distanceToHome))m, need <30m)", category: "HOME")
        }
        
        // v1.9.15: Use actual start location, not route end point
        // Activate when within 30 meters of start location
        if distanceToHome < 30 {
            DebugLogger.shared.log("Home arrival DETECTED (distance: \(Int(distanceToHome))m, elapsed: \(walkSession.elapsedSeconds)s, waypoints: \(visitedMarkerIds.count)/\(route.qrMarkers.count)) - setting showHomeArrivalPrompt=true", category: "HOME")
            hasReachedHome = true
            showHomeArrivalPrompt = true
            
            // v1.9.13: Cancel all walking notifications when reaching start/end point
            notificationService.cancelAllWalkingNotifications()
            
            // Send home arrival notification
            notificationService.sendHomeArrivalNotification()
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
    
    // v1.9.13: Dismiss home arrival prompt
    func dismissHomeArrivalPrompt() {
        showHomeArrivalPrompt = false
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
        // v1.7.12: Run on background thread
        if let old = selectedClinician, !isSameClinician {
            let oldTopic = "clinician_" + old.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            DispatchQueue.global(qos: .utility).async {
                Messaging.messaging().unsubscribe(fromTopic: oldTopic) { error in
                    if let error = error {
                        print("Error unsubscribing from topic: \(error)")
                    } else {
                        print("Unsubscribed from topic: \(oldTopic)")
                    }
                }
            }
        }
        
        // Subscribe to new clinician topic - but only if:
        // 1. It's a different clinician, OR
        // 2. Notifications are still enabled (user hasn't disabled them)
        let newTopic = "clinician_" + clinician.fullTitle.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        
        if !isSameClinician || notificationsEnabled {
            print("🔔 Subscribing to topic: \(newTopic)")
            // v1.7.12: Run on background thread to avoid main thread blocking
            DispatchQueue.global(qos: .utility).async {
                Messaging.messaging().subscribe(toTopic: newTopic) { error in
                    if let error = error {
                        print("❌ Subscription failed: \(error.localizedDescription)")
                    } else {
                        print("✅ Subscription success: \(newTopic)")
                        print("🔔 Topic subscription confirmed - background notifications should work")
                    }
                }
            }
        } else {
            print("🔕 Skipping subscription - same clinician and notifications disabled")
        }
        
        selectedClinician = clinician
        // Preserve appointment time when updating waitTimeInfo
        let preservedAppointmentTime = waitTimeInfo.appointmentTime
        // Create WaitTimeInfo with appointment time already set to avoid publishing during view updates
        waitTimeInfo = WaitTimeInfo(
            estimatedMinutes: clinician.currentWaitMinutes,
            lastUpdated: clinician.lastUpdated,
            clinicianName: clinician.fullTitle,
            queuePosition: clinician.queuePosition,
            appointmentTime: preservedAppointmentTime
        )
        
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
        
        // v1.7.16: Mark first Firebase update as processed when user selects a clinician
        // This fixes the bug where new users miss their first delay alert because
        // isFirstFirebaseUpdate was never set to false (since they had no clinician during initial sync)
        // The current delay becomes the "baseline" - any future changes will trigger alerts
        if isFirstFirebaseUpdate {
            isFirstFirebaseUpdate = false
            print("📊 Established delay baseline for new user: \(clinician.currentWaitMinutes) min")
        }
        
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
    
    // MARK: - Appointment Time (v1.9.56)
    
    /// Set the user's appointment time for estimated time-to-be-seen calculation
    func setAppointmentTime(_ time: Date?) {
        waitTimeInfo.appointmentTime = time
        
        if let time = time {
            // Persist to UserDefaults
            UserDefaults.standard.set(time.timeIntervalSince1970, forKey: "appointmentTime")
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            print("📅 Appointment time set: \(formatter.string(from: time))")
        } else {
            UserDefaults.standard.removeObject(forKey: "appointmentTime")
            print("📅 Appointment time cleared")
        }
    }
    
    /// Clear the appointment time
    func clearAppointmentTime() {
        setAppointmentTime(nil)
    }
    
    /// Restore appointment time from UserDefaults (called on init)
    private func restoreAppointmentTime() {
        let timestamp = UserDefaults.standard.double(forKey: "appointmentTime")
        if timestamp > 0 {
            let savedTime = Date(timeIntervalSince1970: timestamp)
            // Only restore if the appointment time is today and in the future (or within last 2 hours)
            let now = Date()
            let calendar = Calendar.current
            if calendar.isDateInToday(savedTime) && savedTime.timeIntervalSince(now) > -7200 { // -2 hours grace
                waitTimeInfo.appointmentTime = savedTime
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                print("📅 Restored appointment time: \(formatter.string(from: savedTime))")
            } else {
                // Clear stale appointment time
                UserDefaults.standard.removeObject(forKey: "appointmentTime")
                print("📅 Cleared stale appointment time")
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
            
            // v1.7.12: Run on background thread
            DispatchQueue.global(qos: .utility).async {
                Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                    if error == nil {
                        print("🔕 Unsubscribed from topic: \(topic)")
                    }
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
        
        // v1.7.12: Unsubscribe on background thread to avoid main thread blocking
        DispatchQueue.global(qos: .utility).async {
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if let error = error {
                    print("❌ Error unsubscribing (preference already saved): \(error)")
                } else {
                    print("✅ Unsubscription confirmed for: \(topic)")
                }
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
        
        // v1.7.12: Subscribe on background thread to avoid main thread blocking
        DispatchQueue.global(qos: .utility).async {
            Messaging.messaging().subscribe(toTopic: topic) { error in
                if let error = error {
                    print("❌ Error subscribing: \(error)")
                } else {
                    print("✅ Subscription confirmed for: \(topic)")
                }
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
        
        // v1.7.12: Run on background thread to avoid main thread blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
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
    
    // MARK: - Walking Alerts (v1.9.17)
    func disableWalkingAlerts() {
        walkingAlertsEnabled = false
        notificationService.cancelAllWalkingNotifications()
        cancelAlertAutoDismissTimer()
        
        // Dismiss any currently shown alerts
        showHalfwayAlert = false
        showReturnNowAlert = false
        showWalkCompleteAlert = false
        
        print("🔕 Walking alerts disabled")
    }
    
    func enableWalkingAlerts() {
        walkingAlertsEnabled = true
        print("🔔 Walking alerts enabled")
    }
    
    func cancelAlertAutoDismissTimer() {
        alertAutoDismissTimer?.invalidate()
        alertAutoDismissTimer = nil
    }
    
    private func startAlertAutoDismissTimer(for alertKeyPath: WritableKeyPath<WaitingRoomViewModel, Bool>) {
        cancelAlertAutoDismissTimer()
        // v1.9.16: Capture the keyPath identifier before the closure to avoid Sendable issues
        // Use comparison to determine which property to set (key paths can't be switched directly)
        let alertType: AlertType
        if alertKeyPath == \.showHalfwayAlert {
            alertType = .halfway
        } else if alertKeyPath == \.showReturnNowAlert {
            alertType = .returnNow
        } else if alertKeyPath == \.showWalkCompleteAlert {
            alertType = .walkComplete
        } else {
            alertType = .halfway // Fallback
        }
        
        alertAutoDismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Directly set the property based on the alert type (avoids Sendable/subscript issues)
                switch alertType {
                case .halfway:
                    self.showHalfwayAlert = false
                case .returnNow:
                    self.showReturnNowAlert = false
                case .walkComplete:
                    self.showWalkCompleteAlert = false
                }
                self.alertAutoDismissTimer = nil
                print("⏱️ Auto-dismissed alert after 10 seconds")
            }
        }
        RunLoop.current.add(alertAutoDismissTimer!, forMode: .common)
    }
    
    // v1.9.16: Helper enum to avoid Sendable issues with WritableKeyPath
    private enum AlertType {
        case halfway
        case returnNow
        case walkComplete
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


