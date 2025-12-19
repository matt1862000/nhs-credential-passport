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
            // Check for pending notification from cold launch
            checkForPendingPushNotification()
        }
    }
    
    private func checkForPendingPushNotification() {
        // Delay to ensure app is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let pending = AppDelegate.pendingNotification {
                // Keep suppress flag ON to prevent Firebase listener from showing alerts
                AppDelegate.suppressInAppAlertsFlag = true
                
                // Clear the pending notification
                AppDelegate.pendingNotification = nil
                
                // Parse the notification to show as in-app alert
                let body = pending["body"] ?? ""
                
                // Determine if it's an increase or decrease based on body
                if body.contains("increased") {
                    viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: true)
                    viewModel.showWaitTimeIncreasedAlert = true
                } else {
                    viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: false)
                    viewModel.showWaitTimeDecreasedAlert = true
                }
                
                print("📱 Showing alert from push notification")
                
                // Clear suppress flag after a delay (after alert is shown)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    AppDelegate.suppressInAppAlertsFlag = false
                }
            }
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

#Preview {
    MainTabView()
}


