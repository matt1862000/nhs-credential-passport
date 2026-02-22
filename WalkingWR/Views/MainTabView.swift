//
//  MainTabView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import CoreLocation

struct MainTabView: View {
    // ViewModel is passed in from SplashScreenView (already loaded data)
    @ObservedObject var viewModel: WaitingRoomViewModel
    
    @State private var selectedTab = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding: Bool
    @State private var hasCheckedPendingNotification = false
    @Environment(\.scenePhase) private var scenePhase
    
    // Navigation state for deep linking from empty clinic screen
    @State private var showLocalRoutePicker = false
    @State private var wellbeingCategory: WellbeingCategory = .breathing
    @State private var wellbeingExercise: WellbeingContent? = nil
    
    init(viewModel: WaitingRoomViewModel) {
        self.viewModel = viewModel
        // Only show onboarding if user hasn't completed it before
        _showOnboarding = State(initialValue: !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
        
        // v1.8.10: Make bottom tab bar solid to prevent content overlap
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        ZStack {
            if showOnboarding {
                OnboardingView(showOnboarding: $showOnboarding)
                    .transition(.opacity)
            } else {
                TabView(selection: $selectedTab) {
                    WaitTimeView(
                        viewModel: viewModel,
                        selectedTab: $selectedTab,
                        showLocalRoutePicker: $showLocalRoutePicker,
                        wellbeingCategory: $wellbeingCategory,
                        wellbeingExercise: $wellbeingExercise
                    )
                        .tabItem {
                            Label("Delay", systemImage: "clock.fill")
                        }
                        .tag(0)
                        .id(0) // Stable identity to avoid "invalid reuse after initialization failure" when switching tabs
                    
                    RouteSelectionView(viewModel: viewModel, showLocalRoutePicker: $showLocalRoutePicker)
                        .tabItem {
                            Label("Walk", systemImage: "figure.walk")
                        }
                        .tag(1)
                        .id(1)
                    
                    WellbeingView(viewModel: viewModel, selectedCategory: $wellbeingCategory, selectedExercise: $wellbeingExercise)
                        .tabItem {
                            Label("Wellbeing", systemImage: "heart.fill")
                        }
                        .tag(2)
                        .id(2)
                    
                    ProfileView(viewModel: viewModel, healthKitService: viewModel.healthKitService)
                        .tabItem {
                            Label("Progress", systemImage: "trophy.fill")
                        }
                        .tag(3)
                        .id(3)
                }
                .tint(.tealAccent)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: showOnboarding)
        .fullScreenCover(isPresented: .init(
            get: {
                // Only show when ViewModel sets showClinicianSelection (once per session when no clinician, or when clinicians appear after skip).
                // Avoids re-presenting on every Firebase snapshot.
                guard !showOnboarding else { return false }
                return viewModel.showClinicianSelection
            },
            set: { viewModel.showClinicianSelection = $0 }
        )) {
            ClinicianSelectionView(
                viewModel: viewModel,
                isPresented: $viewModel.showClinicianSelection,
                onNavigateToWalk: {
                    // Switch to Walk tab and open route picker
                    selectedTab = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showLocalRoutePicker = true
                    }
                },
                onNavigateToBreathing: {
                    // Switch to Wellbeing tab and open random breathing exercise
                    selectedTab = 2
                    wellbeingCategory = .breathing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Pick a random breathing exercise
                        wellbeingExercise = WellbeingContent.breathingExercises.randomElement()
                    }
                },
                onNavigateToDigitalSkills: {
                    // Switch to Wellbeing tab and select Digital Skills category
                    selectedTab = 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        wellbeingCategory = .digital
                    }
                }
            )
            .id("clinicianSelection") // Stable identity to avoid invalid reuse after initialization failure
        }
        .onAppear {
            // Only check once per cold launch
            guard !hasCheckedPendingNotification else { return }
            hasCheckedPendingNotification = true
            
            // On cold launch, delay to ensure AppDelegate.didReceive has completed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                checkForPendingPushNotification()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // App became active - check for pending push notification
                // Small delay to ensure AppDelegate.didReceive has completed
                print("📱 Scene became active (was: \(oldPhase)) - will check for pending notification")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    checkForPendingPushNotification()
                }
            }
        }
        .onAppear {
            // Trigger prepop on appear if we already have location (onChange doesn't fire for initial value)
            if let loc = viewModel.locationService.currentLocation {
                Task {
                    await PrePopulatedPOIService.shared.downloadDatabaseIfNeeded(userLocation: loc.coordinate)
                    ensurePOIsReadyForLocation(loc.coordinate)
                    tryStartRoutePreGen(at: loc.coordinate)
                }
            }
        }
        .onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
            guard let loc = newLocation else { return }
            // Cancel pre-gen if user moved significantly
            if let preGenLoc = RoutePreGenService.shared.preGeneratedAtLocation {
                let moved = CLLocation(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
                    .distance(from: CLLocation(latitude: preGenLoc.latitude, longitude: preGenLoc.longitude))
                if moved > 50 {
                    RoutePreGenService.shared.cancelAndClear()
                }
            }
            Task {
                await PrePopulatedPOIService.shared.downloadDatabaseIfNeeded(userLocation: loc.coordinate)
                ensurePOIsReadyForLocation(loc.coordinate)
                tryStartRoutePreGen(at: loc.coordinate)
            }
        }
        // When clinician list updates (Firebase snapshot), try to start pre-gen if POIs already ready
        .onChange(of: viewModel.availableClinicians.count) { _, _ in
            if let loc = viewModel.locationService.currentLocation {
                tryStartRoutePreGen(at: loc.coordinate)
            }
        }
        // Global delay alerts - use the reusable modifier
        .delayAlerts(viewModel: viewModel)
    }
    
    /// Try to start route pre-generation for all clinician durations.
    /// Only starts if POIs are available (from pre-pop DB) and clinicians are loaded.
    private func tryStartRoutePreGen(at coordinate: CLLocationCoordinate2D) {
        let clinicians = viewModel.availableClinicians
        guard !clinicians.isEmpty else { return }
        // Check if POIs are available from pre-pop DB
        guard let pois = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: coordinate, radiusMeters: 2500), pois.count >= 20 else { return }
        RoutePreGenService.shared.startPreGenForAllClinicians(pois: pois, clinicians: clinicians, location: coordinate)
    }
    
    /// When we have location, ensure POIs are ready for route generation. Prefer cache and pre-pop DB to avoid a live API call.
    private func ensurePOIsReadyForLocation(_ coordinate: CLLocationCoordinate2D) {
        // 1. Prefer cached POIs (no API call)
        if let cached = POICacheService.shared.getCachedPOIs(near: coordinate), !cached.isEmpty {
            GoogleMapsService.shared.setEarlyPrefetchedPOIs(cached, for: coordinate)
            return
        }
        // 2. Prefer pre-populated DB POIs (no API call)
        let radiusMeters = 2500.0
        if let dbPOIs = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: coordinate, radiusMeters: radiusMeters), !dbPOIs.isEmpty {
            GoogleMapsService.shared.setEarlyPrefetchedPOIs(dbPOIs, for: coordinate)
            return
        }
        // 3. No cache or pre-pop — do live fetch (only if we have API key)
        if GoogleMapsService.shared.hasAPIKey {
            GoogleMapsService.shared.prefetchPOIsEarly(location: coordinate)
        }
    }

    private func checkForPendingPushNotification() {
        print("📱 checkForPendingPushNotification called - pending: \(AppDelegate.pendingNotification != nil)")
        
        // Only proceed if there's actually a pending notification from push tap
        guard let pending = AppDelegate.pendingNotification else {
            // No pending notification - clear any stale flags
            print("📱 No pending notification found")
            AppDelegate.suppressInAppAlertsFlag = false
            return
        }
        
        print("📱 Found pending notification from push tap: \(pending)")
        
        // Keep suppress flag ON to prevent Firebase listener from showing duplicate alerts
        AppDelegate.suppressInAppAlertsFlag = true
        
        // Clear the pending notification immediately
        AppDelegate.pendingNotification = nil
        
        // Parse the notification to show as in-app alert
        let body = pending["body"] ?? ""
        
        // Determine if it's an increase or decrease based on body
        if body.contains("increased") {
            viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: true)
            viewModel.showWaitTimeIncreasedAlert = true
            print("📱 Showing INCREASED alert from push notification")
        } else {
            viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: false)
            viewModel.showWaitTimeDecreasedAlert = true
            print("📱 Showing DECREASED alert from push notification")
        }
        
        // Clear suppress flag after a short delay to allow alert to show
        // Then Firebase can resume normal operation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppDelegate.suppressInAppAlertsFlag = false
            print("📱 Cleared suppress flag - Firebase alerts enabled")
        }
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @Binding var showOnboarding: Bool
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    
    let pages: [(icon: String, title: String, description: String, color: Color)] = [
        ("clock.badge.checkmark.fill", "Real-Time Updates", "See your clinic delay, updated live from the clinic system.", .tealAccent),
        ("figure.walk.motion", "Walk While You Wait", "Choose a walking route matched to your delay time. Stay active, reduce anxiety.", .mintGreen),
        ("bell.badge.fill", "Smart Notifications", "We'll alert you when it's time to head back. No need to worry about missing your slot.", .softAmber),
        ("heart.circle.fill", "Wellbeing Support", "Discover breathing exercises, gratitude prompts, and digital health tips along the way.", .lavenderMist)
    ]
    
    var body: some View {
        ZStack {
            AnimatedGradientBackground()
            
            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button("Skip") {
                        withAnimation {
                            hasCompletedOnboarding = true
                            showOnboarding = false
                        }
                    }
                    .font(.bodyMedium)
                    .foregroundColor(.primary)
                    .padding()
                }
                
                Spacer()
                
                // Page content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(
                            icon: pages[index].icon,
                            title: pages[index].title,
                            description: pages[index].description,
                            color: pages[index].color
                        )
                        .tag(index)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(currentPage == index ? Color.tealAccent : Color.tealAccent.opacity(0.3))
                            .frame(width: currentPage == index ? 10 : 8, height: currentPage == index ? 10 : 8)
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }
                .padding(.bottom, 30)
                
                // Get Started button
                Button(action: {
                    if currentPage < pages.count - 1 {
                        withAnimation {
                            currentPage += 1
                        }
                    } else {
                        withAnimation {
                            hasCompletedOnboarding = true
                            showOnboarding = false
                        }
                    }
                }) {
                    HStack {
                        Text(currentPage == pages.count - 1 ? "Get Started" : "Next")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
        }
    }
}

struct OnboardingPageView: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    @State private var appeared = false
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 140, height: 140)
                
                Image(systemName: icon)
                    .font(.system(size: 60))
                    .foregroundStyle(color)
            }
            .scaleEffect(appeared ? 1 : 0.8)
            .opacity(appeared ? 1 : 0)
            
            VStack(spacing: 12) {
                Text(title)
                    .font(.titleLarge)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.bodyLarge)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
        .onDisappear {
            appeared = false
        }
    }
}

// MARK: - Delay Alert ViewModifier
/// Uses UIKit UIAlertController to show alerts above ALL content including sheets
/// This is the only reliable way to show alerts over presented views in iOS
struct DelayAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: WaitingRoomViewModel
    
    // Track current alert to dismiss old ones when new alert comes in
    private static weak var currentDelayAlert: UIAlertController?
    
    func body(content: Content) -> some View {
        content
            // Watch for ViewModel alert triggers
            .onChange(of: viewModel.showWaitTimeIncreasedAlert) { _, shouldShow in
                if shouldShow {
                    let title = "Clinic Delay Updated"
                    let message = buildIncreaseMessage()
                    viewModel.showWaitTimeIncreasedAlert = false
                    // Delay to let any re-renders settle, then show UIKit alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showUIKitAlert(title: title, message: message)
                    }
                }
            }
            .onChange(of: viewModel.showWaitTimeDecreasedAlert) { _, shouldShow in
                if shouldShow {
                    let title = "Delay Reduction"
                    let message = buildDecreaseMessage()
                    viewModel.showWaitTimeDecreasedAlert = false
                    // Delay to let any re-renders settle, then show UIKit alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showUIKitAlert(title: title, message: message)
                    }
                }
            }
    }
    
    private func showUIKitAlert(title: String, message: String) {
        // Dismiss any existing delay alert first (prevents stacking old alerts)
        if let existingAlert = DelayAlertsModifier.currentDelayAlert,
           existingAlert.presentingViewController != nil {
            existingAlert.dismiss(animated: false) {
                // Show new alert after dismissing old one
                self.presentNewAlert(title: title, message: message)
            }
        } else {
            // No existing alert, show new one directly
            presentNewAlert(title: title, message: message)
        }
    }
    
    private func presentNewAlert(title: String, message: String) {
        // Get the top-most view controller (works even with sheets/covers)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topController = window.rootViewController else {
            return
        }
        
        // Find the top-most presented view controller
        while let presented = topController.presentedViewController {
            topController = presented
        }
        
        // Create and show UIAlertController
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Stop Alerts", style: .destructive) { _ in
            DelayAlertsModifier.currentDelayAlert = nil
            viewModel.disableNotifications()
        })
        
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            DelayAlertsModifier.currentDelayAlert = nil
        })
        
        // Store reference to dismiss later if new alert comes in
        DelayAlertsModifier.currentDelayAlert = alert
        
        topController.present(alert, animated: true)
        
        // Auto-dismiss after 15 seconds if user doesn't interact (prevents stuck alerts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak alert] in
            // Only dismiss if this alert is still being presented
            if alert?.presentingViewController != nil {
                alert?.dismiss(animated: true)
                DelayAlertsModifier.currentDelayAlert = nil
                print("⏱️ Auto-dismissed delay alert after 15 seconds")
            }
        }
    }
    
    private func buildIncreaseMessage() -> String {
        if let info = viewModel.waitTimeChangeInfo {
            let increase = info.newMinutes - info.oldMinutes
            return "The clinic delay has increased by \(increase) minutes (now \(info.newMinutes) min delay)."
        }
        return "The clinic delay has been updated."
    }
    
    private func buildDecreaseMessage() -> String {
        if let info = viewModel.waitTimeChangeInfo {
            if info.newMinutes == 0 {
                return "The clinic is now running on time."
            } else if info.newMinutes <= 5 {
                return "The clinic delay has reduced to \(info.newMinutes) minutes."
            } else {
                let decrease = info.oldMinutes - info.newMinutes
                return "The clinic delay has reduced by \(decrease) minutes (now \(info.newMinutes) min delay)."
            }
        }
        return "The clinic delay has been updated."
    }
}

extension View {
    func delayAlerts(viewModel: WaitingRoomViewModel) -> some View {
        modifier(DelayAlertsModifier(viewModel: viewModel))
    }
}

#Preview {
    MainTabView(viewModel: WaitingRoomViewModel())
}


