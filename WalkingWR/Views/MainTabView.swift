//
//  MainTabView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var viewModel = WaitingRoomViewModel()
    @State private var selectedTab = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var hasCheckedPendingNotification = false
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Only show onboarding if user hasn't completed it before
        _showOnboarding = State(initialValue: !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
    }
    
    var body: some View {
        ZStack {
            if showOnboarding {
                OnboardingView(showOnboarding: $showOnboarding)
                    .transition(.opacity)
            } else {
                TabView(selection: $selectedTab) {
                    WaitTimeView(viewModel: viewModel, selectedTab: $selectedTab)
                        .tabItem {
                            Label("Delay", systemImage: "clock.fill")
                        }
                        .tag(0)
                    
                    RouteSelectionView(viewModel: viewModel)
                        .tabItem {
                            Label("Walk", systemImage: "figure.walk")
                        }
                        .tag(1)
                    
                    WellbeingView(viewModel: viewModel)
                        .tabItem {
                            Label("Wellbeing", systemImage: "heart.fill")
                        }
                        .tag(2)
                    
                    ProfileView(viewModel: viewModel, healthKitService: viewModel.healthKitService)
                        .tabItem {
                            Label("Progress", systemImage: "trophy.fill")
                        }
                        .tag(3)
                }
                .tint(.tealAccent)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: showOnboarding)
        .fullScreenCover(isPresented: .init(
            get: { !showOnboarding && (viewModel.showClinicianSelection || !viewModel.hasSelectedClinician) },
            set: { if !$0 { viewModel.showClinicianSelection = false } }
        )) {
            ClinicianSelectionView(
                viewModel: viewModel,
                isPresented: $viewModel.showClinicianSelection
            )
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
        // Global delay alerts - use the reusable modifier
        .delayAlerts(viewModel: viewModel)
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
        ("figure.walk.motion", "Walk While You Wait", "Choose a walking route matched to your wait time. Stay active, reduce anxiety.", .mintGreen),
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
/// Uses a custom overlay alert that works reliably on iOS 18
/// Shows above all content including sheets
struct DelayAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: WaitingRoomViewModel
    
    // Local state to isolate alerts from ViewModel changes (iOS 18 compatibility)
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    func body(content: Content) -> some View {
        content
            // Watch for ViewModel alert triggers
            .onChange(of: viewModel.showWaitTimeIncreasedAlert) { _, shouldShow in
                if shouldShow {
                    alertTitle = "Clinic Delay Updated"
                    alertMessage = buildIncreaseMessage()
                    viewModel.showWaitTimeIncreasedAlert = false
                    // Delay to let any re-renders settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showAlert = true
                    }
                }
            }
            .onChange(of: viewModel.showWaitTimeDecreasedAlert) { _, shouldShow in
                if shouldShow {
                    alertTitle = "Delay Reduction"
                    alertMessage = buildDecreaseMessage()
                    viewModel.showWaitTimeDecreasedAlert = false
                    // Delay to let any re-renders settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showAlert = true
                    }
                }
            }
            // Custom overlay alert - shows above everything
            .overlay {
                if showAlert {
                    CustomAlertOverlay(
                        title: alertTitle,
                        message: alertMessage,
                        onOK: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showAlert = false
                            }
                        },
                        onStopAlerts: {
                            viewModel.toggleNotifications()
                            withAnimation(.easeOut(duration: 0.2)) {
                                showAlert = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showAlert)
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

// MARK: - Custom Alert Overlay
/// A custom alert that displays as an overlay, immune to iOS 18 re-render issues
struct CustomAlertOverlay: View {
    let title: String
    let message: String
    let onOK: () -> Void
    let onStopAlerts: () -> Void
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { } // Prevent tap-through
            
            // Alert card
            VStack(spacing: 0) {
                // Content
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
                
                Divider()
                
                // Buttons
                HStack(spacing: 0) {
                    Button(action: onStopAlerts) {
                        Text("Stop Alerts")
                            .font(.body)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    
                    Divider()
                        .frame(height: 44)
                    
                    Button(action: onOK) {
                        Text("OK")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 50)
        }
    }
}

extension View {
    func delayAlerts(viewModel: WaitingRoomViewModel) -> some View {
        modifier(DelayAlertsModifier(viewModel: viewModel))
    }
}

#Preview {
    MainTabView()
}


