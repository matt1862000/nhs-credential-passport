//
//  RouteSelectionView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import UserNotifications
import UIKit

// MARK: - Timeout Helper (shared with GoogleMapsService)
/// Wraps an async operation with a timeout, throwing TimeoutError if exceeded
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Start the operation
        group.addTask {
            try await operation()
        }
        
        // Start timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timeout
        }
        
        // Return first completed task, cancel the other
        guard let result = try await group.next() else {
            throw TimeoutError.timeout
        }
        group.cancelAll()
        return result
    }
}

// TimeoutError is defined in GoogleMapsService.swift
import MapKit
import CoreLocation

// #region agent log
/// Path for debug instrumentation: app Documents (writable on device) so log can be retrieved via Xcode → Download Container → AppData/Documents/debug.log
fileprivate func _agentLogPath() -> String {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.map { $0.appendingPathComponent("debug.log").path } ?? "/Users/raihant/Documents/WalkingWR/.cursor/debug.log"
}
// #endregion agent log

// MARK: - Refresh race state (MapKit started before Let's Go; Google on Let's Go; last route always Google)
/// Shared state so MapKit task (started on preview) and Google task (started on Let's Go) can coordinate:
/// If MapKit finishes first → show MapKit. If Google finishes first → show Google and never show MapKit.
/// When Google finishes → always show Google (final route is always Google).
private final class RefreshRaceState {
    var googleApplied = false
    var walkStarted = false
}

struct RouteSelectionView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var showLocalRoutePicker: Bool
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors for light/dark mode
    @State private var selectedDifficulty: RouteDifficulty? = nil
    @State private var showIndoorOnly = false
    @State private var showAccessibleOnly = false
    @State private var showActiveWalk = false
    // v1.9.36: pendingActiveWalk moved to ViewModel for iOS 17 compatibility
    @State private var showHelpSheet = false
    @State private var localRouteDuration: Int = 10
    @State private var localRouteUseCustom = false
    
    init(viewModel: WaitingRoomViewModel, showLocalRoutePicker: Binding<Bool> = .constant(false)) {
        self.viewModel = viewModel
        self._showLocalRoutePicker = showLocalRoutePicker
    }
    
    // Check if we have an active clinic delay to base suggestion on
    private var hasActiveClinicDelay: Bool {
        viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable
    }
    
    // v2.0.1: Check if delay is too short for a walk
    // Need at least 15 minutes (10 min walk + 5 min buffer) to recommend a walk
    private var isDelayTooShortForWalk: Bool {
        guard hasActiveClinicDelay else { return false }
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - 5
        return availableTime < 10  // Minimum walk is 10 minutes
    }
    
    // Calculate recommended duration based on delay time (with 5 min buffer)
    // Defaults to 30 min if no clinic is active (free walk mode - best route reliability)
    // v2.0.1: Minimum walk is 10 minutes, so need 15+ min delay
    private var recommendedDuration: Int {
        // If no active clinic, default to 30 min (most reliable routes)
        if !hasActiveClinicDelay {
            return 30
        }
        
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - 5
        
        // v2.0.1: If delay is too short, still return 10 but UI will show warning
        if availableTime < 10 {
            return 10  // Will show warning that walk may not fit
        }
        
        let presetOptions = [10, 15, 20, 25, 30]
        
        // Find the best preset option that fits within available time
        if let bestOption = presetOptions.reversed().first(where: { $0 <= availableTime }) {
            return bestOption
        }
        return 10 // Default to minimum preset
    }
    
    // Whether custom time should be auto-selected:
    // When delay > 35 min (i.e., 30 min walk + 5 min buffer)
    // Only applies when a clinic is active - free walk mode uses preset 30 min
    private var shouldUseCustom: Bool {
        guard hasActiveClinicDelay else { return false }
        let delayMinutes = viewModel.waitTimeInfo.estimatedMinutes
        // Use custom only if delay > 35 min (allows 31-60 min walks via slider)
        return delayMinutes > 35
    }
    
    // Custom duration value based on delay (with 6 min buffer)
    private var customDurationForDelay: Int {
        max(10, viewModel.waitTimeInfo.estimatedMinutes - 6)
    }
    
    var filteredRoutes: [WalkingRoute] {
        var routes = viewModel.availableRoutes
        
        if let difficulty = selectedDifficulty {
            routes = routes.filter { $0.difficulty == difficulty }
        }
        
        if showIndoorOnly {
            routes = routes.filter { $0.isIndoor }
        }
        
        if showAccessibleOnly {
            routes = routes.filter { $0.isAccessible }
        }
        
        return routes
    }
    
    // Curated outdoor routes
    var curatedFilteredRoutes: [WalkingRoute] {
        filteredRoutes.filter { $0.routeType == .curated }
    }
    
    // Indoor routes
    var indoorFilteredRoutes: [WalkingRoute] {
        filteredRoutes.filter { $0.routeType == .indoor || $0.isIndoor }
    }
    
    // MARK: - Main Navigation View
    private var mainNavigationView: some View {
        NavigationStack {
            mainContent
                .navigationTitle(viewModel.walkSession.isActive ? "" : "Choose a Route")
                #if os(iOS)
                .navigationBarTitleDisplayMode(viewModel.walkSession.isActive ? .inline : .large)
                .navigationBarHidden(viewModel.walkSession.isActive)
                .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
                #endif
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { showHelpSheet = true }) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.coralPink)
                        }
                    }
                }
        }
    }
    
    private var mainContent: some View {
        ZStack {
            AnimatedGradientBackground()
            
            routeListContent
        }
    }
    
    private var routeListContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                bannerView
                
                LocalRouteCard(
                    onTap: { showLocalRoutePicker = true },
                    locationService: viewModel.locationService
                )
                
                routeSections
                
                RouteFiltersCompact(
                    selectedDifficulty: $selectedDifficulty,
                    showIndoorOnly: $showIndoorOnly,
                    showAccessibleOnly: $showAccessibleOnly
                )
                
                Spacer(minLength: 100)
            }
            .padding(.horizontal, 20)
        }
    }
    
    @ViewBuilder
    private var bannerView: some View {
        if viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable {
            TimeRemainingBanner(minutes: viewModel.waitTimeInfo.estimatedMinutes)
                .padding(.top, 20)
        } else {
            NoClinicianBanner()
                .padding(.top, 20)
        }
    }
    
    private var routeSections: some View {
        VStack(spacing: 12) {
            if !curatedFilteredRoutes.isEmpty {
                CollapsibleRouteSection(
                    title: "Curated Routes",
                    subtitle: "\(curatedFilteredRoutes.count) verified walks",
                    icon: "checkmark.seal.fill",
                    iconColor: .mintGreen,
                    routes: curatedFilteredRoutes,
                    viewModel: viewModel,
                    isRecommended: isRecommended,
                    isTooLong: isTooLong
                )
            }
            
            if !indoorFilteredRoutes.isEmpty {
                CollapsibleRouteSection(
                    title: "Indoor Routes",
                    subtitle: "Stay inside the building",
                    icon: "building.2.fill",
                    iconColor: .lavenderMist,
                    routes: indoorFilteredRoutes,
                    viewModel: viewModel,
                    isRecommended: isRecommended,
                    isTooLong: isTooLong
                )
            }
        }
    }
    
    var body: some View {
        mainNavigationView
            .fullScreenCover(isPresented: $showActiveWalk, onDismiss: {
                print("🔍 [iOS17 DEBUG] fullScreenCover DISMISSED")
            }) {
                // v1.9.28: Immersive full-screen presentation - no navigation context
                let _ = print("🔍 [iOS17 DEBUG] fullScreenCover PRESENTING ActiveWalkView")
                ActiveWalkView(viewModel: viewModel, locationService: viewModel.locationService, isPresented: $showActiveWalk)
            }
            .addSheets(
                showHelpSheet: $showHelpSheet,
                showLocalRoutePicker: $showLocalRoutePicker,
                viewModel: viewModel,
                locationService: viewModel.locationService,
                localRouteDuration: $localRouteDuration,
                localRouteUseCustom: $localRouteUseCustom,
                showActiveWalk: $showActiveWalk
            )
            .addAlerts(viewModel: viewModel)
            .onChange(of: showActiveWalk) { oldValue, newValue in
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                print("🔍 [iOS17 DEBUG] [\(timeString)] 🗺️ showActiveWalk changed: \(oldValue) → \(newValue)")
            }
            // v1.9.38: iOS 17 fix - onDismiss doesn't reliably fire for sheets
            // Use onChange to detect when pre-walk anxiety sheet is dismissed
            .onChange(of: viewModel.showPreWalkWellbeing) { oldValue, newValue in
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                print("🔍 [iOS17 FIX] [\(timeString)] showPreWalkWellbeing changed: \(oldValue) → \(newValue)")
                print("🔍 [iOS17 FIX] [\(timeString)]   pendingActiveWalk: \(viewModel.pendingActiveWalk)")
                
                // When sheet dismisses (true → false) AND we have a pending walk, show the map
                if oldValue == true && newValue == false && viewModel.pendingActiveWalk {
                    print("🔍 [iOS17 FIX] [\(timeString)]   ✅ Pre-walk sheet dismissed with pending walk - showing map")
                    viewModel.pendingActiveWalk = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        showActiveWalk = true
                    }
                }
            }
            // v1.9.40: iOS 17 fix - onDismiss doesn't reliably fire for post-walk sheet
            // Use onChange to detect when post-walk anxiety sheet is dismissed
            .onChange(of: viewModel.showPostWalkWellbeing) { oldValue, newValue in
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                print("🔍 [iOS17 FIX] [\(timeString)] showPostWalkWellbeing changed: \(oldValue) → \(newValue)")
                
                // When sheet dismisses (true → false), trigger HealthKit offer logic
                if oldValue == true && newValue == false {
                    print("🔍 [iOS17 FIX] [\(timeString)]   Post-walk sheet dismissed - checking HealthKit offer")
                    
                    let hasDeclinedOffer = UserDefaults.standard.bool(forKey: "healthKitSyncOfferDeclined")
                    let stepTrackingWasEnabled = viewModel.stepTrackingWasEnabled
                    let motionWasAuthorizedAtWalkStart = viewModel.motionWasAuthorizedAtWalkStart
                    let isMotionAuthorized = viewModel.healthKitService.isMotionAuthorized
                    let isMotionDenied = viewModel.healthKitService.isMotionDenied
                    let isHealthKitAuthorized = viewModel.healthKitService.isAuthorized
                    
                    print("🔍 [iOS17 FIX] [\(timeString)]   stepTrackingWasEnabled: \(stepTrackingWasEnabled)")
                    print("🔍 [iOS17 FIX] [\(timeString)]   motionWasAuthorizedAtWalkStart: \(motionWasAuthorizedAtWalkStart)")
                    print("🔍 [iOS17 FIX] [\(timeString)]   isMotionAuthorized: \(isMotionAuthorized)")
                    print("🔍 [iOS17 FIX] [\(timeString)]   isMotionDenied: \(isMotionDenied)")
                    print("🔍 [iOS17 FIX] [\(timeString)]   isHealthKitAuthorized: \(isHealthKitAuthorized)")
                    print("🔍 [iOS17 FIX] [\(timeString)]   hasDeclinedOffer: \(hasDeclinedOffer)")
                    
                    // Same logic as onDismiss handler in addSheets
                    if !stepTrackingWasEnabled && !isMotionAuthorized && !isMotionDenied {
                        // Flow 2, Walk 1: Absent-minded user - request Motion permission
                        print("🔍 [iOS17 FIX] [\(timeString)]   📲 Requesting Motion permission (Flow 2, Walk 1)")
                        viewModel.healthKitService.requestMotionAuthorization { authorized in
                            print("🔍 [iOS17 FIX] Motion authorization result: \(authorized ? "authorized" : "denied")")
                        }
                    } else if (stepTrackingWasEnabled || motionWasAuthorizedAtWalkStart) && !isHealthKitAuthorized && !hasDeclinedOffer {
                        // Flow 1 or Flow 2 Walk 2: Motion is authorized → show HealthKit offer
                        print("🔍 [iOS17 FIX] [\(timeString)]   ✅ Showing HealthKit sync offer")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.showHealthKitSyncOffer = true
                        }
                    } else {
                        print("🔍 [iOS17 FIX] [\(timeString)]   ❌ No permission dialog needed")
                    }
                }
            }
            .onChange(of: showLocalRoutePicker) { _, isShowing in
                if isShowing {
                    // Pre-select duration based on delay time
                    if shouldUseCustom {
                        localRouteUseCustom = true
                        localRouteDuration = customDurationForDelay
                    } else {
                        localRouteUseCustom = false
                        localRouteDuration = recommendedDuration
                    }
                }
            }
    }
    
    func isRecommended(_ route: WalkingRoute) -> Bool {
        let buffer = 5
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - buffer
        return route.durationMinutes <= availableTime && route.durationMinutes >= availableTime - 5
    }
    
    func isTooLong(_ route: WalkingRoute) -> Bool {
        let buffer = 5
        return route.durationMinutes > viewModel.waitTimeInfo.estimatedMinutes - buffer
    }
}

// MARK: - Time Remaining Banner
struct TimeRemainingBanner: View {
    let minutes: Int
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill")
                .font(.title3)
                .foregroundColor(.tealAccent)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Your clinic delay")
                    .font(.caption)
                    .foregroundColor(.primary)
                
                Text("\(minutes) minutes")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            Spacer()
            
            Text("Choose a route that fits")
                .font(.caption)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .cardStyle()
    }
}

// MARK: - No Clinician Banner
struct NoClinicianBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.title3)
                .foregroundColor(.tealAccent)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Explore walking routes")
                    .font(.caption)
                    .foregroundColor(.primary)
                
                Text("Stay active while you wait")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("Select a clinician for\npersonalised timing")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .cardStyle()
    }
}

// MARK: - Local Route Card
struct LocalRouteCard: View {
    let onTap: () -> Void
    @ObservedObject var locationService: LocationService
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors
    
    var body: some View {
        Button(action: {
            // Only request location if missing or stale (>30s) - avoid re-fetch right after a lock
            let locationAge = locationService.currentLocation.map { Date().timeIntervalSince($0.timestamp) } ?? .infinity
            if locationService.currentLocation == nil || locationAge > 30 {
                locationService.requestCurrentLocation()
            }
            onTap()
        }) {
            VStack(spacing: 16) {
                // Featured header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Create Your Route")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    LinearGradient(
                                        colors: [.tealAccent, .mintGreen],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                        }
                        
                        Text("AI-powered route based on your location")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.tealAccent, .mintGreen],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                }
                
                // Features row
                HStack(spacing: 16) {
                    FeatureTag(icon: "building.2", text: "Real POIs")
                    FeatureTag(icon: "road.lanes", text: "Walking paths")
                    FeatureTag(icon: "clock", text: "10-60 min")
                }
                
                // Status and action
                HStack {
                    if locationService.currentLocation != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.mintGreen)
                            Text("Location ready")
                                .font(.caption)
                                .foregroundColor(.mintGreen)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "location")
                                .font(.caption)
                                .foregroundColor(.softAmber)
                            Text("Tap to enable location")
                                .font(.caption)
                                .foregroundColor(.softAmber)
                        }
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Text("Get Started")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [.tealAccent, .mintGreen],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.darkCardBackground : Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [.tealAccent.opacity(0.5), .mintGreen.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: colorScheme == .dark ? 2 : 1
                            )
                    )
                    .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feature Tag
struct FeatureTag: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - Collapsible Route Section
struct CollapsibleRouteSection: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let routes: [WalkingRoute]
    @ObservedObject var viewModel: WaitingRoomViewModel
    let isRecommended: (WalkingRoute) -> Bool
    let isTooLong: (WalkingRoute) -> Bool
    
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors
    @State private var isExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(iconColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.body)
                            .foregroundColor(iconColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.bodyMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Route count badge
                    Text("\(routes.count)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(iconColor)
                        .clipShape(Circle())
                    
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
                .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
                .cornerRadius(12)
                .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(routes) { route in
                        CompactRouteCard(
                            route: route,
                            isRecommended: isRecommended(route),
                            isTooLong: isTooLong(route),
                            onSelect: {
                                viewModel.selectRoute(route)
                                viewModel.startWalk()
                            }
                        )
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Compact Route Card
struct CompactRouteCard: View {
    let route: WalkingRoute
    let isRecommended: Bool
    let isTooLong: Bool
    let onSelect: () -> Void
    
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors
    @State private var isExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Main row - tappable to expand
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(route.color.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: route.icon)
                            .font(.callout)
                            .foregroundColor(route.color)
                    }
                    
                    // Info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(route.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            if isRecommended {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(.mintGreen)
                            }
                            
                            if isTooLong {
                                Text("LONG")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.coralPink)
                                    .clipShape(Capsule())
                            }
                        }
                        
                        HStack(spacing: 8) {
                            if route.triggerStopsMinutes > 0 {
                                Label("\(route.totalDisplayMinutes)m (incl. stops)", systemImage: "clock")
                            } else {
                                Label("\(route.durationMinutes)m", systemImage: "clock")
                            }
                            Label("\(route.qrMarkers.count) spots", systemImage: "mappin")
                            if route.isIndoor {
                                Label("Indoor", systemImage: "building.2")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Expand indicator
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            
            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Map preview (for outdoor routes with path)
                    if !route.isIndoor && route.routePath.count >= 2 {
                        RouteMapPreview(route: route)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if route.isIndoor {
                        // Indoor route - show building icon instead
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "building.2.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.lavenderMist)
                                Text("Indoor Route")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(height: 100)
                            Spacer()
                        }
                        .background(colorScheme == .dark ? Color.darkCardBackground.opacity(0.6) : Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Description
                    Text(route.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Route details
                    HStack(spacing: 16) {
                        // Duration & Distance
                        VStack(alignment: .leading, spacing: 4) {
                            if route.triggerStopsMinutes > 0 {
                                Label("\(route.totalDisplayMinutes) min (incl. ~\(route.triggerStopsMinutes) min at stops)", systemImage: "clock.fill")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            } else {
                                Label("\(route.durationMinutes) minutes", systemImage: "clock.fill")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            Label("\(route.distanceMeters)m distance", systemImage: "figure.walk")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        // Difficulty badge
                        HStack(spacing: 4) {
                            Image(systemName: difficultyIcon)
                                .font(.caption2)
                            Text(route.difficulty.rawValue.capitalized)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(difficultyColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(difficultyColor.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    
                    // Landmarks/Discovery spots
                    if !route.landmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Discovery Spots")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            FlowLayout(spacing: 6) {
                                ForEach(route.landmarks.prefix(5), id: \.self) { landmark in
                                    Text(landmark)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(colorScheme == .dark ? Color.darkCardBackground.opacity(0.8) : Color.gray.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                if route.landmarks.count > 5 {
                                    Text("+\(route.landmarks.count - 5) more")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(colorScheme == .dark ? Color.darkCardBackground.opacity(0.8) : Color.gray.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    
                    // Features row
                    HStack(spacing: 12) {
                        if route.isAccessible {
                            Label("Accessible", systemImage: "figure.roll")
                                .font(.caption2)
                                .foregroundColor(.tealAccent)
                        }
                        if route.isIndoor {
                            Label("Indoor", systemImage: "building.2")
                                .font(.caption2)
                                .foregroundColor(.lavenderMist)
                        }
                        if route.isCurated {
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundColor(.mintGreen)
                        }
                    }
                    
                    // Coming Soon banner (replaces Start button)
                    HStack {
                        Text("Coming Soon")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.2))
                    .foregroundColor(.secondary)
                    .cornerRadius(10)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
        .cornerRadius(10)
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
    
    var difficultyIcon: String {
        switch route.difficulty {
        case .easy: return "leaf.fill"
        case .moderate: return "figure.walk"
        case .challenging: return "flame.fill"
        }
    }
    
    var difficultyColor: Color {
        switch route.difficulty {
        case .easy: return .mintGreen
        case .moderate: return .softAmber
        case .challenging: return .coralPink
        }
    }
}

// MARK: - Route Map Preview
struct RouteMapPreview: View {
    let route: WalkingRoute
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors
    
    var body: some View {
        Map {
            // Start marker (stable id avoids invalid reuse)
            if let start = route.routePath.first {
                Annotation("Start", coordinate: start) {
                    ZStack {
                        Circle()
                            .fill(Color.mintGreen)
                            .frame(width: 24, height: 24)
                        Image(systemName: "figure.walk")
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                    .id("start-\(route.id)")
                }
            }
            
            // Discovery markers
            ForEach(route.qrMarkers.prefix(3)) { marker in
                Annotation("", coordinate: marker.coordinate) {
                    Circle()
                        .fill(route.color)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .id(marker.id)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .disabled(true) // Prevent interaction - it's just a preview
        .overlay(
            // Gradient overlay at bottom for better text readability if needed
            LinearGradient(
                colors: [.clear, (colorScheme == .dark ? Color.darkCardBackground : Color.white).opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Compact Route Filters
struct RouteFiltersCompact: View {
    @Binding var selectedDifficulty: RouteDifficulty?
    @Binding var showIndoorOnly: Bool
    @Binding var showAccessibleOnly: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter routes")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Indoor filter
                    FilterChip(
                        title: "Indoor",
                        icon: "building.2",
                        isSelected: showIndoorOnly,
                        color: .lavenderMist,
                        action: { showIndoorOnly.toggle() }
                    )
                    
                    // Accessible filter
                    FilterChip(
                        title: "Accessible",
                        icon: "figure.roll",
                        isSelected: showAccessibleOnly,
                        color: .tealAccent,
                        action: { showAccessibleOnly.toggle() }
                    )
                    
                    Divider()
                        .frame(height: 20)
                    
                    // Difficulty filters
                    ForEach(RouteDifficulty.allCases, id: \.self) { difficulty in
                        FilterChip(
                            title: difficulty.rawValue.capitalized,
                            icon: difficultyIcon(difficulty),
                            isSelected: selectedDifficulty == difficulty,
                            color: difficultyColor(difficulty),
                            action: {
                                if selectedDifficulty == difficulty {
                                    selectedDifficulty = nil
                                } else {
                                    selectedDifficulty = difficulty
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
    
    func difficultyIcon(_ difficulty: RouteDifficulty) -> String {
        switch difficulty {
        case .easy: return "leaf"
        case .moderate: return "figure.walk"
        case .challenging: return "flame"
        }
    }
    
    func difficultyColor(_ difficulty: RouteDifficulty) -> Color {
        switch difficulty {
        case .easy: return .mintGreen
        case .moderate: return .softAmber
        case .challenging: return .coralPink
        }
    }
}

// MARK: - Local Route Picker Sheet
struct LocalRoutePickerSheet: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @ObservedObject var locationService: LocationService
    @StateObject private var mapsService = GoogleMapsService.shared
    @Binding var selectedDuration: Int
    @Binding var useCustomTime: Bool
    @Binding var isPresented: Bool
    @Binding var showActiveWalk: Bool  // v1.9.28: Show fullscreen ActiveWalkView
    // v1.9.36: pendingActiveWalk now in viewModel for iOS 17 compatibility
    @State private var isGenerating = false  // Button shows spinner
    @State private var showLoadingScreen = false  // v1.8.3: Separate flag for loading screen transition
    @State private var routeGenerationComplete = false  // v1.8.5: Signals route is ready (triggers stage animation completion)
    @State private var isShuffling = false  // Separate state for shuffle loading
    @State private var isStartingWalk = false  // v1.6.45: Loading state for Let's Go button
    @State private var routeRefreshStatus: String? = nil  // v1.9.22: Status message during route refresh
    @State private var shouldCancelBackgroundWork = false  // v1.9.22: Flag to cancel background generation
    @State private var isRouteRefreshed = false  // v1.9.22: Track if route has been refreshed
    @State private var isRefreshingRoutes = false  // Loading state when user taps Refresh to reload route list
    @State private var refreshRaceState = RefreshRaceState()  // MapKit vs Google race: last route always Google
    /// When true, first route came from 30s Google fallback — skip Google refresh on Let's Go.
    @State private var currentRouteIsFromGoogle30sFallback = false
    @State private var generatedRoute: WalkingRoute?
    @State private var generatedRouteData: GeneratedRoute?
    @State private var showMapPreview = false
    @State private var errorMessage: String?
    @State private var customTimeValue: Double = 10  // Minimum walk duration is 10 minutes
    
    
    // Store last valid route for recycling when shuffle exhausts options
    @State private var lastValidRoute: WalkingRoute?
    @State private var lastValidRouteData: GeneratedRoute?
    @State private var isRecycledRoute = false  // Indicates shuffle fell back to previous route
    @State private var isDeadZoneFallback = false  // v1.6.39: Indicates route is 70-74% (closest available)
    @State private var shownPlaceIdSets: [Set<String>] = []  // Track all shown route combinations
    
    // Store route before shuffle so Cancel restores it (not exits completely)
    @State private var routeBeforeShuffle: WalkingRoute?
    @State private var routeDataBeforeShuffle: GeneratedRoute?
    
    // Pre-generated routes for instant shuffling
    // v1.6.47: Added isDeadZoneFallback per-route so warning only shows for actual fallback routes
    // v2.1.x: Added isFromGoogle — skip Let's Go refresh only when the route being started is from Google
    @State private var allRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] = []
    @State private var currentRouteIndex: Int = 0
    @State private var isPreGeneratingRoutes = false
    @State private var preGenerationComplete = false
    @State private var viewedRouteIndices: Set<Int> = []  // Track which routes user has seen
    @State private var showPremiumUpsell = false  // Show upgrade message when all routes viewed
    @State private var showLocationLimitAlert = false  // Show when free tier location limit reached
    
    
    // v1.6.25: Route deduplication - track unique route signatures
    @State private var routeSignatures: Set<String> = []  // Unique signatures: "sortedPOIIds|distanceBucket"
    @State private var usedPrimaryPOIs: Set<String> = []  // v1.9.52: Track primary POI names to prevent semantic duplicates
    @State private var varietyExhausted = false  // True when no more unique routes possible
    
    // v1.8.8: Store rejected short routes - may add ONE at end if ≤2 acceptable routes
    @State private var rejectedShortRoutes: [(route: WalkingRoute, data: GeneratedRoute)] = []
    
    // v2.1.10: "+1" button — user can generate up to 5 additional routes on demand
    @State private var additionalRoutesGenerated: Int = 0
    @State private var isGeneratingAdditionalRoute = false
    private let maxAdditionalRoutes = 5
    
    // v2.1.9: Cross-bucket route pool — routes generated for one duration whose actual
    // Google-measured duration fits a different bucket. Keyed by rounded 5-min duration.
    // Persists across duration switches within a session so routes aren't "wasted".
    // Cross-bucket pool is now session-level in RouteCacheService so it survives Cancel (e.g. 20min run → Cancel → 15min reuses 15min route)
    
    // Pre-fetched POIs for faster route generation
    @State private var prefetchedPOIs: [PlaceResult] = []
    @State private var isPrefetchingPOIs = false
    @State private var prefetchedForLocation: CLLocationCoordinate2D?
    
    // Track where routes were pre-generated (for movement detection)
    @State private var preGeneratedAtLocation: CLLocationCoordinate2D?
    private let movementThresholdMeters: Double = 50  // Invalidate cache if moved >50m
    
    let durationOptions = [10, 15, 20, 25, 30]
    let maxRoutesToGenerate = 10  // Back to 10 - directions now use free Apple MapKit!
    let targetInBandRoutes = 2   // Stop generation once we have 2 routes within 80-120% of target
    
    // RUN_SUMMARY: for 10 vs 20 min (or any) comparison — set during generation, logged when done
    @State private var runSummaryStartTime: Date?
    @State private var runSummarySource: String = ""
    @State private var runSummaryTimeToFirstRouteSec: TimeInterval?
    
    // v2.0.1: Check if delay is too short for a walk
    // Need at least 15 minutes (10 min walk + 5 min buffer) to recommend a walk
    private var isDelayTooShortForWalk: Bool {
        // Only applies when a clinic is active
        guard viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable else { return false }
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - 5
        return availableTime < 10  // Minimum walk is 10 minutes
    }
    
    /// Indices into allRoutes for display: in-band routes first, then out-of-band (so the 16 min "fast" route stays visible as an option and isn’t replaced by a 25 min one).
    private var displayedRouteIndices: [Int] {
        let inBand = allRoutes.indices.filter { Self.isRouteInBand(allRoutes[$0].route, selectedDuration: selectedDuration) }
        let outOfBand = allRoutes.indices.filter { !inBand.contains($0) }
        return inBand + outOfBand
    }
    
    /// True when this route is out of band (show "Shorter/longer than X–Y min" banner). Uses same rule as in-band: duration + min distance for bucket; applies to all buckets.
    private func isRouteOutOfBand(_ route: WalkingRoute) -> Bool {
        return !Self.isRouteInBand(route, selectedDuration: selectedDuration)
    }
    
    /// True when we have no in-band routes at all (show single-closest banner). Applies to all buckets.
    private var hasOnlyOutOfBandRoutes: Bool {
        return !allRoutes.isEmpty && !allRoutes.indices.contains(where: { Self.isRouteInBand(allRoutes[$0].route, selectedDuration: selectedDuration) })
    }
    
    /// Cap displayed duration when unreasonably high for distance (e.g. 25 min for 1 km). When targetDurationMinutes is provided, also caps to at most 125% of target. Delegates to WalkingRoute.withDurationSanityCap().
    private static func applyDurationSanityCap(_ route: WalkingRoute, targetDurationMinutes: Int? = nil) -> WalkingRoute {
        route.withDurationSanityCap(targetDurationMinutes: targetDurationMinutes)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                // Show map preview — in-band routes first (duration + min distance for selected bucket)
                if showMapPreview {
                    if !allRoutes.isEmpty {
                        let displayed = displayedRouteIndices
                        let effectiveIndex = displayed.contains(currentRouteIndex) ? currentRouteIndex : (displayed.first ?? 0)
                        let entry = allRoutes[effectiveIndex]
                        mapPreviewSection(
                            route: entry.route,
                            totalDisplayedRoutes: displayed.count,
                            displayedPosition: (displayed.firstIndex(of: effectiveIndex) ?? 0) + 1,
                            showOutOfBandBanner: hasOnlyOutOfBandRoutes || isRouteOutOfBand(entry.route),
                            outOfBandLabel: (hasOnlyOutOfBandRoutes ? nil : (isRouteOutOfBand(entry.route) ? {
                                let (minAcc, maxAcc) = Self.minMaxAcceptableMinutes(for: selectedDuration)
                                return entry.route.durationMinutes < minAcc ? "Shorter than \(minAcc)–\(maxAcc) min" : "Longer than \(minAcc)–\(maxAcc) min"
                            }() : nil)),
                            isDeadZoneFallback: entry.isDeadZoneFallback
                        )
                        .onChange(of: displayed.count) { _, _ in
                            if !displayed.contains(currentRouteIndex) {
                                currentRouteIndex = displayed.first ?? 0
                                let e = allRoutes[currentRouteIndex]
                                generatedRoute = e.route
                                generatedRouteData = e.data
                                isDeadZoneFallback = e.isDeadZoneFallback
                            }
                        }
                        .onChange(of: allRoutes.count) { _, _ in
                            let d = displayedRouteIndices
                            if !d.contains(currentRouteIndex) {
                                currentRouteIndex = d.first ?? 0
                                if allRoutes.indices.contains(currentRouteIndex) {
                                    let e = allRoutes[currentRouteIndex]
                                    generatedRoute = e.route
                                    generatedRouteData = e.data
                                    isDeadZoneFallback = e.isDeadZoneFallback
                                }
                            }
                            logRoutePreviewSummary()
                        }
                    } else if let route = generatedRoute {
                        mapPreviewSection(route: route, totalDisplayedRoutes: 1, displayedPosition: 1, showOutOfBandBanner: false, isDeadZoneFallback: isDeadZoneFallback)
                    }
                } else if showLoadingScreen || (isShuffling && generatedRoute == nil) {
                    // v1.8.3: Show loading view only after button has shown spinner
                    firstTimeGenerationView()
                } else if let error = errorMessage, generatedRoute == nil, showMapPreview {
                    // Shuffle failed - show error with retry
                    shuffleErrorView(error: error)
                } else {
                    // Stage 1: Duration picker
                    ScrollView {
                        VStack(spacing: 20) {
                            // Header - matching design
                            VStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.tealAccent.opacity(0.2))
                                        .frame(width: 100, height: 100)
                                    
                                    Image(systemName: "location.north.fill")
                                        .font(.system(size: 44))
                                        .foregroundStyle(Color.tealAccent)
                                        .rotationEffect(.degrees(45))
                                }
                                
                                Text("Create Local Route")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                
                                // Recommendation card based on delay
                                if viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable {
                                    let delayMinutes = viewModel.waitTimeInfo.estimatedMinutes
                                    let recommendedWalk = max(5, delayMinutes - 5)
                                    let waitInfo = viewModel.waitTimeInfo
                                    
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 12) {
                                            Image(systemName: "clock.badge.checkmark")
                                                .font(.title2)
                                                .foregroundColor(.tealAccent)
                                            
                                            // v1.9.56: Show appointment time context if available
                                            if let appointmentTime = waitInfo.formattedAppointmentTime,
                                               let estimatedSeen = waitInfo.formattedEstimatedTimeToBeSeen {
                                                Text("Your appointment is at **\(appointmentTime)**. With a **\(delayMinutes) min** delay, you'll be seen around **\(estimatedSeen)**. We recommend a **\(recommendedWalk) min** walk.")
                                                    .font(.subheadline)
                                                    .foregroundColor(.primary)
                                                    .multilineTextAlignment(.leading)
                                            } else {
                                                Text("Based on your **\(delayMinutes) min** wait, we recommend a **\(recommendedWalk) min** walk to get you back in time.")
                                                    .font(.subheadline)
                                                    .foregroundColor(.primary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                        }
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.tealAccent.opacity(0.15))
                                    )
                                    .padding(.horizontal, 4)
                                } else {
                                    Text("Choose a duration for your walk")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.top, 8)
                            
                            // v2.0.1: Warning when delay is too short for a walk
                            if isDelayTooShortForWalk {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Wait time is short")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("Your \(viewModel.waitTimeInfo.estimatedMinutes)-minute delay may not allow time for a walk. Consider staying near reception.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            
                            // Duration picker
                            VStack(alignment: .leading, spacing: 12) {
                                Text("How long would you like to walk?")
                                    .font(.bodyMedium)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 12) {
                                    ForEach(durationOptions, id: \.self) { duration in
                                        DurationOptionButton(
                                            duration: duration,
                                            isSelected: !useCustomTime && selectedDuration == duration,
                                            onSelect: {
                                                useCustomTime = false
                                                selectedDuration = duration
                                            }
                                        )
                                    }
                                    
                                    // Custom time button
                                    Button(action: {
                                        useCustomTime = true
                                        selectedDuration = Int(customTimeValue)
                                    }) {
                                        VStack(spacing: 4) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.title3)
                                            Text("Custom")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(useCustomTime ? Color.tealAccent : Color.tealAccent.opacity(0.1))
                                        )
                                        .foregroundColor(useCustomTime ? .white : .tealAccent)
                                    }
                                }
                                
                            // Custom time slider
                            if useCustomTime {
                                let delayTime = viewModel.waitTimeInfo.estimatedMinutes
                                let selectedTime = Int(customTimeValue)
                                let isOverTime = selectedTime >= delayTime
                                let isCloseToTime = selectedTime >= delayTime - 5 && selectedTime < delayTime
                                
                                let sliderColor: Color = {
                                    if isOverTime { return .coralPink }
                                    if isCloseToTime { return .softAmber }
                                    return .tealAccent
                                }()
                                
                                VStack(spacing: 8) {
                                        HStack {
                                            Text("\(selectedTime) minutes")
                                                .font(.titleMedium)
                                                .fontWeight(.bold)
                                                .foregroundColor(sliderColor)
                                            
                                            Spacer()
                                            
                                            Text("~\(selectedTime * 100) steps")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Slider(value: $customTimeValue, in: 10...60, step: 5)
                                            .tint(sliderColor)
                                            .onChange(of: customTimeValue) { _, newValue in
                                                selectedDuration = Int(newValue)
                                            }
                                        
                                        HStack {
                                            Text("10 min")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("60 min")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        // Warning messages
                                        if isOverTime {
                                            HStack(spacing: 8) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundColor(.coralPink)
                                                Text("This exceeds your \(delayTime) min delay. You may miss your appointment.")
                                                    .font(.caption)
                                                    .foregroundColor(.coralPink)
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.coralPink.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        } else if isCloseToTime {
                                            HStack(spacing: 8) {
                                                Image(systemName: "clock.badge.exclamationmark")
                                                    .foregroundColor(.softAmber)
                                                Text("This is close to your \(delayTime) min delay. Allow time to return.")
                                                    .font(.caption)
                                                    .foregroundColor(.softAmber)
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.softAmber.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                    }
                                    .padding(.top, 8)
                                    .onAppear {
                                        // Sync customTimeValue with selectedDuration when custom is selected
                                        if customTimeValue != Double(selectedDuration) {
                                            customTimeValue = Double(selectedDuration)
                                        }
                                    }
                                }
                            }
                            .onChange(of: selectedDuration) { _, newValue in
                                // Sync customTimeValue when selectedDuration changes and custom is active
                                if useCustomTime && customTimeValue != Double(newValue) {
                                    customTimeValue = Double(newValue)
                                }
                            }
                            .padding(20)
                            .cardStyle()
                            
                            // v1.8.11: Removed circular loop route card with steps/distance
                            
                            // Error message
                            if let error = errorMessage {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.softAmber)
                                        
                                        Text(error)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Button("Dismiss") {
                                            errorMessage = nil
                                        }
                                        .font(.caption)
                                        .foregroundColor(.tealAccent)
                                    }
                                }
                                .padding(12)
                                .background(Color.softAmber.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            
                            // Location permission prompt
                            if !locationService.isAuthorized {
                                let isDenied = locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted
                                
                                VStack(spacing: 12) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "location.slash")
                                            .foregroundColor(.softAmber)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Location required")
                                                .font(.bodyMedium)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                            
                                            Text(isDenied ? "Enable location in Settings" : "We need your location to create a route")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Spacer()
                                    }
                                    
                                    if isDenied {
                                        Button(action: {
                                            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                                UIApplication.shared.open(settingsURL)
                                            }
                                        }) {
                                            HStack {
                                                Image(systemName: "gear")
                                                Text("Open Settings")
                                            }
                                            .font(.bodyMedium)
                                            .fontWeight(.medium)
                                        }
                                        .buttonStyle(PrimaryButtonStyle(color: .softAmber))
                                    } else {
                                        Button(action: {
                                            locationService.requestPermission()
                                        }) {
                                            HStack {
                                                Image(systemName: "location.fill")
                                                Text("Allow Location Access")
                                            }
                                            .font(.bodyMedium)
                                            .fontWeight(.medium)
                                        }
                                        .buttonStyle(PrimaryButtonStyle(color: .tealAccent))
                                    }
                                }
                                .padding(16)
                                .cardStyle()
                            }
                            
                            // Generate button
                            if locationService.isAuthorized {
                                let locationReady = locationService.currentLocation != nil
                                
                                HStack(spacing: 12) {
                                    Button(action: generateRoute) {
                                        HStack {
                                            if isGenerating {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                Text("Loading…")
                                            } else if !locationReady {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                Text("Finding Location...")
                                            } else {
                                                Image(systemName: "sparkles")
                                                Text("Generate Route")
                                            }
                                        }
                                    }
                                    .buttonStyle(PrimaryButtonStyle(color: locationReady && !isGenerating ? .tealAccent : .gray))
                                    .disabled(!locationReady || isGenerating)
                                }
                            }
                            
                            Spacer(minLength: 40)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
            }
            .fullScreenCover(isPresented: $showActiveWalk) {
                // v1.9.28: Immersive full-screen presentation - no navigation context
                ActiveWalkView(viewModel: viewModel, locationService: viewModel.locationService, isPresented: $showActiveWalk)
            }
            
            .onChange(of: showActiveWalk) { oldValue, newValue in
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                if !newValue && oldValue {
                    print("🔍 [MOTION DEBUG] [\(timeString)] 🚪 showActiveWalk changed: true → false (fullscreen dismissed)")
                    print("🔍 [MOTION DEBUG] [\(timeString)]   stepTrackingWasEnabled: \(viewModel.stepTrackingWasEnabled)")
                    print("🔍 [MOTION DEBUG] [\(timeString)]   showPreWalkWellbeing: \(viewModel.showPreWalkWellbeing)")
                    print("🔍 [MOTION DEBUG] [\(timeString)]   showPostWalkWellbeing: \(viewModel.showPostWalkWellbeing)")
                    print("🔍 [MOTION DEBUG] [\(timeString)]   Motion auth status: \(viewModel.healthKitService.isMotionAuthorized ? "authorized" : "not authorized")")
                }
            }
            .onAppear {
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                print("🔍 [MOTION DEBUG] [\(timeString)] 📱 RouteSelectionView.onAppear()")
                print("🔍 [MOTION DEBUG] [\(timeString)]   showPreWalkWellbeing: \(viewModel.showPreWalkWellbeing)")
                print("🔍 [MOTION DEBUG] [\(timeString)]   showPostWalkWellbeing: \(viewModel.showPostWalkWellbeing)")
                print("🔍 [MOTION DEBUG] [\(timeString)]   stepTrackingWasEnabled: \(viewModel.stepTrackingWasEnabled)")
                print("🔍 [MOTION DEBUG] [\(timeString)]   Motion auth status: \(viewModel.healthKitService.isMotionAuthorized ? "authorized" : "not authorized")")
                
                // Only request location if we don't have one or it's stale (>30s) - avoid re-fetching seconds after a lock
                let locationAge = locationService.currentLocation.map { Date().timeIntervalSince($0.timestamp) } ?? .infinity
                if locationService.currentLocation == nil || locationAge > 30 {
                    locationService.requestCurrentLocation()
                }
                // Sync customTimeValue with selectedDuration if in custom mode
                if useCustomTime {
                    customTimeValue = Double(selectedDuration)
                }
                // Pre-fetch POIs while user selects duration (speeds up Generate)
                prefetchPOIsIfNeeded()
                
            }
            .onChange(of: locationService.currentLocation) { _, newLocation in
                // Re-fetch POIs if location significantly changed
                if newLocation != nil, prefetchedPOIs.isEmpty {
                    prefetchPOIsIfNeeded()
                }
            }
            .onChange(of: routeGenerationComplete) { _, newValue in
                // Safety timeout: if "Your route is ready" is shown but onAnimationComplete never fires
                // (e.g. main thread blocked by polyline decode or other work), force transition after 8s
                guard newValue else { return }
                print("[ROUTE_GEN] 🏁 [SAFETY] routeGenerationComplete=true → scheduling 8s fallback (will force dismiss if still on loading screen)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if showLoadingScreen {
                        print("[ROUTE_GEN] 🏁 [SAFETY] 8s timeout fired → forcing showLoadingScreen=false, showMapPreview=true (was stuck)")
                        showLoadingScreen = false
                        showMapPreview = true
                    } else {
                        print("[ROUTE_GEN] 🏁 [SAFETY] 8s timeout fired → showLoadingScreen already false, no-op")
                    }
                }
            }
            // Delay alerts - must show even when route sheet is open
            .alert("Location Limit Reached", isPresented: $showLocationLimitAlert) {
                Button("Maybe Later", role: .cancel) {
                    isPresented = false // Close the sheet
                }
                Button("Upgrade") {
                    // TODO: Open subscription/upgrade flow
                    print("🔓 User tapped Upgrade - show subscription options")
                }
            } message: {
                let stats = POICacheService.shared.getCacheStats()
                Text("You've saved routes in \(stats.locations) different locations. Upgrade to WaitWell+ for unlimited locations and more features!")
            }
        }
    }
    
    // MARK: - Route Calculations
    
    var estimatedSteps: Int {
        selectedDuration * 100
    }
    
    var numberOfMarkers: Int {
        // 1 discovery spot per 5 minutes of walking
        return max(1, selectedDuration / 5)
    }
    
    var estimatedDistance: Int {
        selectedDuration * 80
    }
    
    // MARK: - Route Deduplication (v1.6.25)
    
    /// Generate a unique signature for a route based on its waypoints and distance
    /// This allows detecting "same route" even if POI order differs slightly
    func generateRouteSignature(places: [PlaceResult], distanceMeters: Int) -> String {
        // v1.6.47: Use coordinates instead of placeIds for duplicate detection
        // Same POI from different sources (Google/Apple/OSM) have different IDs but same location
        // Round to ~10m precision (4 decimal places) to catch same location
        
        if places.isEmpty {
            let distanceBucket = (distanceMeters / 500) * 500  // 500m buckets for empty routes
            return "empty|\(distanceBucket)"
        }
        
        // Create coordinate-based signature (sorted for order-independence)
        let coordStrings = places.map { place -> String in
            let lat = String(format: "%.4f", place.coordinate.latitude)
            let lon = String(format: "%.4f", place.coordinate.longitude)
            return "\(lat),\(lon)"
        }.sorted()
        
        return coordStrings.joined(separator: "|")
    }
    
    /// Check if a route is a duplicate based on its signature
    func isRouteUnique(places: [PlaceResult], distanceMeters: Int) -> Bool {
        let signature = generateRouteSignature(places: places, distanceMeters: distanceMeters)
        return !routeSignatures.contains(signature)
    }
    
    /// Register a route signature as "seen"
    /// v1.9.52: Now also registers the primary POI to prevent semantic duplicates
    func registerRouteSignature(places: [PlaceResult], distanceMeters: Int) {
        let signature = generateRouteSignature(places: places, distanceMeters: distanceMeters)
        routeSignatures.insert(signature)
        
        // v1.9.52: Also register primary POI
        registerPrimaryPOI(places: places)
    }
    
    /// Reset route signatures when starting fresh
    func resetRouteSignatures() {
        routeSignatures.removeAll()
        usedPrimaryPOIs.removeAll()  // v1.9.52: Also reset primary POI tracking
        varietyExhausted = false
    }
    
    // MARK: - Primary POI Tracking (v1.9.52)
    // Prevents routes with same "primary POI" from appearing as different routes
    // e.g., "Star Inn Saunter" and "Star Inn Peek" both feature The Star Inn
    
    /// Extract the primary POI from a route - this is the main featured location
    /// The primary POI is typically:
    /// 1. The first meaningful POI (not generic like "footpath" or "bench")
    /// 2. The POI the route is likely named after
    func extractPrimaryPOI(from places: [PlaceResult]) -> String? {
        // Generic POI types that shouldn't be primary
        let genericKeywords = [
            "footpath", "path", "road", "street", "lane", "avenue", "close", "drive",
            "bench", "bin", "post box", "telephone", "bollard", "sign", "lamp",
            "looking", "towards", "junction", "crossing", "corner"
        ]
        
        for place in places {
            let cleanedName = GoogleMapsService.cleanPOIDisplayName(place.name).lowercased()
            
            // Skip if too short (likely just a grid reference)
            guard cleanedName.count >= 3 else { continue }
            
            // Skip generic POIs
            let isGeneric = genericKeywords.contains { cleanedName.contains($0) }
            if isGeneric { continue }
            
            // Found a meaningful POI - this is our primary
            return cleanedName
        }
        
        // Fallback: use first POI if no meaningful one found
        return places.first.map { GoogleMapsService.cleanPOIDisplayName($0.name).lowercased() }
    }
    
    /// Check if a route's primary POI has already been used
    func isPrimaryPOIUnique(places: [PlaceResult]) -> Bool {
        guard let primaryPOI = extractPrimaryPOI(from: places) else { return true }
        return !usedPrimaryPOIs.contains(primaryPOI)
    }
    
    /// Register a route's primary POI as used
    func registerPrimaryPOI(places: [PlaceResult]) {
        if let primaryPOI = extractPrimaryPOI(from: places) {
            usedPrimaryPOIs.insert(primaryPOI)
            print("🎯 Registered primary POI: '\(primaryPOI)' (total: \(usedPrimaryPOIs.count) unique primaries)")
        }
    }
    
    /// Check if a route is truly unique - both signature AND primary POI must be unique
    func isRouteTrulyUnique(places: [PlaceResult], distanceMeters: Int) -> Bool {
        let signatureUnique = isRouteUnique(places: places, distanceMeters: distanceMeters)
        let primaryUnique = isPrimaryPOIUnique(places: places)
        
        if !signatureUnique {
            print("⚠️ Route rejected: duplicate signature")
        } else if !primaryUnique {
            if let primary = extractPrimaryPOI(from: places) {
                print("⚠️ Route rejected: primary POI '\(primary)' already used in another route")
            }
        }
        
        return signatureUnique && primaryUnique
    }
    
    // MARK: - Waypoint Permutation (v1.6.26)
    
    /// Check if a route can benefit from waypoint permutation
    /// Only allows permutation if:
    /// 1. Has 2+ waypoints
    /// 2. Reversed order would create a meaningfully different signature
    func canPermuteRoute(_ places: [PlaceResult], distanceMeters: Int) -> Bool {
        guard places.count >= 2 else { return false }
        
        // Check if reversed order creates a new signature
        let reversedPlaces = Array(places.reversed())
        let reversedSignature = generateRouteSignature(places: reversedPlaces, distanceMeters: distanceMeters)
        
        // Only allow if the reversed signature is truly unique
        return !routeSignatures.contains(reversedSignature)
    }
    
    /// Generate a permuted (reversed waypoint order) version of a route
    /// Returns nil if permutation wouldn't create a unique route
    /// v1.6.47: Now includes isDeadZoneFallback - inherits from original route
    /// v2.1.x: isFromGoogle inherited so permuted route skips refresh when from Google
    func createPermutedRoute(from route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool = false, isFromGoogle: Bool = false) -> (route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)? {
        guard data.places.count >= 2 else { return nil }
        guard canPermuteRoute(data.places, distanceMeters: data.distanceMeters) else { return nil }
        
        // Reverse waypoint order
        let reversedPlaces = Array(data.places.reversed())
        let reversedMarkers = Array(route.qrMarkers.reversed())
        
        // Create new route with reversed waypoints
        let permutedRoute = WalkingRoute(
            name: route.name + " (alt)",  // Mark as alternative
            description: route.description,
            durationMinutes: route.durationMinutes,
            distanceMeters: route.distanceMeters,
            difficulty: route.difficulty,
            isIndoor: route.isIndoor,
            isAccessible: route.isAccessible,
            landmarks: ["Start"] + reversedPlaces.map { $0.name } + ["Return"],
            icon: route.icon,
            color: route.color,
            qrMarkers: reversedMarkers,
            routeType: route.routeType,
            trimmed: nil,  // Will need new directions
            walkingDirections: [],  // Will need new directions
            isFromPrePopulatedDatabase: route.isFromPrePopulatedDatabase
        )
        
        // Create permuted data with reversed places
        let permutedData = GeneratedRoute(
            places: reversedPlaces,
            polyline: "",  // Will need new directions
            distanceMeters: data.distanceMeters,
            durationSeconds: data.durationSeconds,
            legs: [],  // Clear legs - need new routing
            hasLimitedPOIs: data.hasLimitedPOIs,
            poiCount: data.poiCount
        )
        
        // v1.6.47: Permuted route inherits fallback status from original
        return (permutedRoute, permutedData, isDeadZoneFallback, isFromGoogle)
    }
    
    /// Pre-fetch POIs in background while user selects duration
    func prefetchPOIsIfNeeded() {
        guard let userLocation = locationService.currentLocation else { return }
        guard mapsService.hasAPIKey else { return }
        guard !isPrefetchingPOIs else { return }
        guard prefetchedPOIs.isEmpty else { return }  // Already fetched
        
        // 🚀 FIRST: Check if we have early-prefetched POIs from clinician selection
        // This speeds up route generation significantly!
        if let earlyPOIs = mapsService.getEarlyPrefetchedPOIs(for: userLocation.coordinate) {
            prefetchedPOIs = earlyPOIs
            prefetchedForLocation = userLocation.coordinate
            print("⚡ Using \(earlyPOIs.count) EARLY-prefetched POIs - instant route ready!")
            return
        }
        
        // Check if this location is already cached (free) or would need a new slot
        let cacheService = POICacheService.shared
        
        // Check if we already have cached POIs for this location
        if let cachedPOIs = cacheService.getCachedPOIs(near: userLocation.coordinate) {
            prefetchedPOIs = cachedPOIs
            prefetchedForLocation = userLocation.coordinate
            print("📦 Using \(cachedPOIs.count) cached POIs - no API call needed!")
            return
        }
        
        // Would need a new cache slot - check if allowed
        if !cacheService.canAddLocation(at: userLocation.coordinate) {
            // Silently skip prefetch - don't show alert during background prefetch
            // Alert will show when user actively taps "Generate Route"
            print("📦 Location limit reached - skipping background prefetch (alert on Generate)")
            return
        }
        
        isPrefetchingPOIs = true
        prefetchedForLocation = userLocation.coordinate
        print("🚀 Pre-fetching POIs while user selects duration...")
        
        Task {
            do {
                // Use a generous radius to cover most duration options
                let pois = try await mapsService.findNearbyPlaces(
                    location: userLocation.coordinate,
                    radiusMeters: 2500  // Cover up to ~60min walks
                )
                await MainActor.run {
                    prefetchedPOIs = pois
                    isPrefetchingPOIs = false
                    print("✅ Pre-fetched \(pois.count) POIs - ready for fast route generation!")
                }
            } catch {
                await MainActor.run {
                    isPrefetchingPOIs = false
                    print("⚠️ POI pre-fetch failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func generateRoute() {
        let generateStartTime = Date()
        runSummaryStartTime = generateStartTime
        runSummarySource = ""
        runSummaryTimeToFirstRouteSec = nil
        
        // Immediate logging to detect button tap
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("🔘 BUTTON TAPPED - generateRoute() called at \(Date())")
        print("═══════════════════════════════════════════════════════════")
        print("   isGenerating (before): \(isGenerating)")
        print("   showLoadingScreen (before): \(showLoadingScreen)")
        print("   showMapPreview (before): \(showMapPreview)")
        print("   selectedDuration: \(selectedDuration)min")
        print("   locationService.currentLocation: \(locationService.currentLocation != nil ? "available" : "nil")")
        
        // v1.6.46: Guard against double-tap or rapid re-tap
        guard !isGenerating else {
            print("⚠️ Already generating - ignoring tap")
            return
        }
        
        isGenerating = true
        routeGenerationComplete = false  // v1.8.5: Reset for new generation
        currentRouteIsFromGoogle30sFallback = false
        errorMessage = nil
        mapsService.resetRouteAttempts()
        
        print("   isGenerating (after): \(isGenerating)")
        
        // v1.8.3: Don't set showLoadingScreen here - only set it on cache MISS
        // This prevents showing loading screen when we have cached routes
        
        print("🚀 GENERATE ROUTE START - \(selectedDuration)min")
        
        guard let userLocation = locationService.currentLocation else {
            print("❌ No user location available")
            isGenerating = false
            showLoadingScreen = false
            routeGenerationComplete = false
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: generateStartTime)
        
        print("⏱️ [ROUTE GENERATION] [\(timeString)] 🚀 generateRoutes() STARTED")
        print("📍 Location: (\(String(format: "%.5f", userLocation.coordinate.latitude)), \(String(format: "%.5f", userLocation.coordinate.longitude)))")
        print("🔑 mapsService.hasAPIKey: \(mapsService.hasAPIKey)")
        print("⏱️ [ROUTE GENERATION] [\(timeString)]   Target duration: \(selectedDuration)min")
        
        // v1.8.14: Move all cache checks into async Task to prevent main thread blocking
        // This allows the button to show "Finding places..." immediately
        if mapsService.hasAPIKey {
            // Use Google APIs for smart routing
            print("⏱️ [ROUTE GENERATION] [\(timeString)] 🚀 Starting async Task for route generation...")
            Task {
                let taskStartTime = Date()
                let taskTimeString = formatter.string(from: taskStartTime)
                print("ROUTE_START duration=\(selectedDuration) (grep this + first ROUTE_FIRST_DISPLAYED for time-to-preview)")
                print("⏱️ [ROUTE GENERATION] [\(taskTimeString)] 📥 Task started")
                // v1.8.14: Check location limit INSIDE Task to prevent main thread blocking
                let cacheService = POICacheService.shared
                let hasCachedPOIs = cacheService.getCachedPOIs(near: userLocation.coordinate) != nil
                
                if !hasCachedPOIs {
                    print("📦 No cached POIs for this location")
                    // No cached POIs - would need a new slot
                    if !cacheService.canAddLocation(at: userLocation.coordinate) {
                        await MainActor.run {
                            showLocationLimitAlert = true
                            print("🔒 Location limit reached - showing upgrade prompt")
                            isGenerating = false
                            showLoadingScreen = false
                            routeGenerationComplete = false
                        }
                        return
                    }
                } else {
                    print("📦 POIs already cached for this location")
                }
                
                print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Starting generation...")
                
                // Show loading screen immediately so user sees "Finding places nearby" (and stages) right away
                await MainActor.run {
                    if isGenerating && !showMapPreview {
                        print("📺 SHOWING LOADING SCREEN (Finding places → Calculating routes → …)")
                        showLoadingScreen = true
                    }
                }
                
                // If postcode hit and prepop DB not ready: stay on "Finding places nearby" until download finishes OR 10s, then proceed
                let inPostcodeArea = await PrePopulatedPOIService.shared.isInTargetPostcodeArea(userLocation.coordinate)
                if inPostcodeArea && !PrePopulatedPOIService.shared.hasDownloadedDatabase {
                    let prepopWaitStart = Date()
                    await PrePopulatedPOIService.shared.ensureDatabaseReadyWithTimeout(userLocation: userLocation.coordinate, waitUpToSeconds: 10.0)
                    let prepopWaitElapsed = Date().timeIntervalSince(prepopWaitStart)
                    print("📊 [TELEM] PREPOP_WAIT_ELAPSED seconds=\(String(format: "%.2f", prepopWaitElapsed)) (postcode hit, max 10s)")
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Prepop wait done → advancing to Calculating routes")
                }
                
                // CHECK CACHE FIRST (with movement detection)
                print("🔍 Checking for cached routes...")
                // v2.1.10: If session cache is from a different location (e.g. Cancel at WF2 → open at S66), wipe it
                RouteCacheService.shared.clearSessionCacheIfLocationChanged(from: userLocation.coordinate, threshold: 50)
                
                let shouldUseCache: Bool
                if let preGenLocation = preGeneratedAtLocation {
                    let distanceMoved = distanceBetweenCoordinates(userLocation.coordinate, preGenLocation)
                    shouldUseCache = distanceMoved <= movementThresholdMeters
                    print("   preGeneratedAtLocation exists, distanceMoved: \(Int(distanceMoved))m")
                    if !shouldUseCache {
                        print("📍 User moved \(Int(distanceMoved))m (>\(Int(movementThresholdMeters))m) - skipping cache, regenerating fresh")
                        // v2.1.9: Clear session cache (same-duration + cross-bucket pool) when user moves significantly (routes are location-specific)
                        await MainActor.run {
                            RouteCacheService.shared.clearSessionCache()
                            print("[ROUTE_DEBUG] 🔄 Cleared session cache (same-duration + cross-bucket pool) — user moved \(Int(distanceMoved))m")
                        }
                    }
                } else {
                    shouldUseCache = true  // No pre-gen location yet, check cache anyway
                    print("   No preGeneratedAtLocation, will check cache")
                }
                
                print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Checking route cache...")
                
                let cacheCheckStartTime = Date()
                if shouldUseCache, let cachedRoutes = RouteCacheService.shared.getCachedRoutes(near: userLocation.coordinate, durationMinutes: selectedDuration), !cachedRoutes.isEmpty {
                    let cacheCheckElapsed = Date().timeIntervalSince(cacheCheckStartTime)
                    let sourceLabel = cachedRoutes.first?.isFromPrePopulatedDatabase == true ? "prepop_database" : "memory_cache"
                    await MainActor.run { runSummarySource = sourceLabel }
                    let firstActual = cachedRoutes.first?.route.durationSeconds ?? 0
                    let firstActualMin = firstActual / 60
                    let ratioPct = selectedDuration > 0 ? Int(round(Double(firstActualMin) / Double(selectedDuration) * 100)) : 0
                    let inBand = (ratioPct >= 80 && ratioPct <= 120)
                    let timeToFirstRoute = Date().timeIntervalSince(generateStartTime)
                    print("ROUTE_RESULT target=\(selectedDuration) actual=\(firstActualMin) ratio_pct=\(ratioPct) in_80_120=\(inBand ? "Y" : "n") waypoints=\(cachedRoutes.first?.route.places.count ?? 0) elapsed_sec=— mode=\(sourceLabel) time_to_first_route_sec=\(String(format: "%.2f", timeToFirstRoute))")
                    print("ROUTES_SOURCE | using_routes source=\(sourceLabel) count=\(cachedRoutes.count) duration=\(selectedDuration) (confirm: app is using \(sourceLabel == "prepop_database" ? "pre-populated database" : "in-memory cache") for routes)")
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - CACHE HIT! Found \(cachedRoutes.count) cached routes")
                    print("⏱️ [TIMING] Cache check: \(String(format: "%.3f", cacheCheckElapsed))s")
                    print("📦 Using \(cachedRoutes.count) cached routes for \(selectedDuration)min")
                    print("[ROUTE_DEBUG] 📦 CACHE_FLOW: cachedRoutes.count=\(cachedRoutes.count), isFromPrePopulatedDatabase=\(cachedRoutes.first?.isFromPrePopulatedDatabase ?? false), firstPlaces=\(cachedRoutes.first?.route.places.count ?? 0)")
                    
                    // v1.9.50: If we have 10 cached routes, return immediately (no POI fetching needed)
                    if cachedRoutes.count >= 10 {
                        let totalTime = Date().timeIntervalSince(generateStartTime)
                        print("⚡ FULL CACHE (10 routes) - returning immediately, skipping POI fetch")
                        print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                        print("⏱️ [TIMING] TOTAL TIME: \(String(format: "%.2f", totalTime))s (cache only, no POI fetch)")
                        print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                        // Continue with cached routes (existing logic below handles this)
                    }
                    
                    // v1.6.46: Show loading screen IMMEDIATELY for cache hits
                    // This ensures the stage animation plays before showing map preview
                    await MainActor.run {
                        showLoadingScreen = true
                        print("📺 SHOWING LOADING SCREEN (cache hit)")
                    }
                    
                    // v1.6.45: Load ALL cached routes, not just the first one
                    // v1.6.47: Include isDeadZoneFallback per-route for accurate warning display
                    // v1.9.23: OPTIMIZED - Load first route immediately, rest in background
                    var loadedRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] = []
                    var loadedPlaceIdSets: [Set<String>] = []
                    
                    let totalCached = cachedRoutes.count
                    let firstCached = cachedRoutes[0]
                    
                    // v1.9.24: Load FIRST route IMMEDIATELY with minimal processing (<0.1s)
                    let firstLoadStartTime = Date()
                    print("⏱️ [CACHE] Loading first route immediately...")
                    
                    // v2.1.7: Filter close waypoints from cached routes (100m under 25min, 200m for 25+ min). Pre-populated routes always use 200m to match DB/trigger zone (e.g. Outwood Primary / Kirkhamgate Village Hall ~98 ft → collapse).
                    let filteredCachedRoute = mapsService.filterCloseWaypointsSync(from: firstCached.route, durationMinutes: selectedDuration, origin: userLocation.coordinate, isFromPrePopulatedDatabase: firstCached.isFromPrePopulatedDatabase)
                    // Add on-route POIs when route has 1–2 waypoints so single-waypoint cache/prepop routes get extra stops (same as generated routes).
                    var firstRouteData: GeneratedRoute = (filteredCachedRoute.places.count <= 2 && !prefetchedPOIs.isEmpty)
                        ? mapsService.addOnRoutePOIsIfNeeded(filteredCachedRoute, origin: userLocation.coordinate, candidatePOIs: prefetchedPOIs, durationMinutes: selectedDuration)
                        : filteredCachedRoute
                    
                    // Create markers early so we can use them for MapKit full-loop (prepop) or display
                    let firstMarkersForPrepop: [QRMarker] = {
                        let realPlaces = firstRouteData.places.filter { $0.name != "Route Point" }
                        return realPlaces.enumerated().map { index, place in
                            let content = WellbeingContent.breathingExercises.randomElement() ?? WellbeingContent.breathingExercises[0]
                            return QRMarker(
                                code: "POI\(index + 1)",
                                name: place.displayName,
                                location: place.vicinity ?? "Local POI",
                                coordinate: place.coordinate,
                                contentType: .breathingExercise,
                                content: content,
                                pointsValue: 20 + (index * 5)
                            )
                        }
                    }()
                    
                    // Pre-populated routes: show map immediately with cached polyline/directions; refresh with MapKit in background (avoids 30s+ wait when rate limited)
                    var polylineToUse = firstRouteData.polyline
                    var durationToUse = firstRouteData.durationSeconds
                    var distanceToUse = firstRouteData.distanceMeters
                    var directionsFromGpsToFirst: [WalkingDirection] = []
                    var directionsFromLastToGps: [WalkingDirection] = []
                    var firstDirections: [WalkingDirection] = []
                    if firstCached.isFromPrePopulatedDatabase {
                        // PREPOP: Use cached data only — show map immediately; MapKit refresh runs in background (see Task below)
                        firstDirections = firstCached.directions ?? []
                        print("📦 PREPOP: Showing map immediately with cached polyline/directions; MapKit refresh will run in background")
                    } else {
                        // Memory cache (non-prepop): use cached directions
                        firstDirections = directionsFromGpsToFirst + (firstCached.directions ?? []) + directionsFromLastToGps
                    }
                    // v2.1.7: Filter contradictory directions from cached directions too
                    if !firstDirections.isEmpty {
                        firstDirections = filterContradictoryDirections(firstDirections)
                        print("⚡ Using directions for preview (MapKit full-loop or cached)")
                        
                        // #region agent log
                        let logData4: [String: Any] = [
                            "sessionId": "debug-session",
                            "runId": "run1",
                            "hypothesisId": "B",
                            "location": "RouteSelectionView.swift:1892",
                            "message": "Using cached directions (first route)",
                            "data": [
                                "cachedDirectionsCount": firstDirections.count,
                                "waypointInstructions": firstDirections.filter { $0.instruction.contains("Waypoint") }.map { $0.instruction },
                                "waypointsCount": firstRouteData.places.count,
                                "hasWaypointInstructions": firstDirections.contains { $0.instruction.contains("Waypoint") }
                            ],
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                        ]
                        if let logJSON4 = try? JSONSerialization.data(withJSONObject: logData4),
                           let logString4 = String(data: logJSON4, encoding: .utf8) {
                            logString4.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                        }
                        // #endregion
                    }
                    
                    let firstMarkers = firstMarkersForPrepop
                    let firstRouteDifficulty: RouteDifficulty = (durationToUse / 60) <= 10 ? .easy : ((durationToUse / 60) <= 20 ? .moderate : .challenging)
                    
                    let firstRouteName = firstCached.name ?? "Local Discovery"
                    let firstRouteDesc = firstCached.description ?? "A \(firstRouteData.formattedDuration) walk passing \(firstRouteData.places.count) local points of interest."
                    
                    let firstRoute = WalkingRoute(
                        name: firstRouteName,
                        description: firstRouteDesc,
                        durationMinutes: max(1, durationToUse / 60),
                        distanceMeters: distanceToUse,
                        difficulty: firstRouteDifficulty,
                        isIndoor: false,
                        isAccessible: true,
                        landmarks: ["Start"] + firstRouteData.places.map { $0.name } + ["Return"],
                        icon: "location.fill",
                        color: .tealAccent,
                        qrMarkers: firstMarkers,
                        routeType: .local,
                        trimmed: polylineToUse,
                        walkingDirections: firstDirections,
                        usedOSRMRouting: firstRouteData.usedOSRM,
                        isFromPrePopulatedDatabase: firstCached.isFromPrePopulatedDatabase,
                        travelToStartMinutes: firstCached.route.travelToStartSeconds.map { $0 / 60 }
                    )
                    
                    var cappedFirst = Self.applyDurationSanityCap(firstRoute, targetDurationMinutes: selectedDuration)
                    var firstRoutePreviewSource = firstCached.isFromPrePopulatedDatabase ? "prepop" : "cache"
                    // Re-measure first route with Google whenever we have key and waypoints (prepop or cache) so duration/distance are accurate (e.g. village hall 6 min 0.4 mi, not 25 min 2 km).
                    if !mapsService.hasAPIKey || firstRouteData.places.isEmpty {
                        print("[ROUTE_DEBUG] ⚠️ FIRST route: Google re-measure SKIPPED — hasAPIKey=\(mapsService.hasAPIKey), places=\(firstRouteData.places.count) (route will keep synthetic \(cappedFirst.durationMinutes)min / \(cappedFirst.distanceMeters)m)")
                    }
                    if mapsService.hasAPIKey && !firstRouteData.places.isEmpty {
                        // #region agent log
                        let _origin = userLocation.coordinate
                        let _prepopEntry: [String: Any] = [
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                            "location": "RouteSelectionView:prepop_first:before_google",
                            "message": "Attempting Google re-measure for first route (prepop or cache)",
                            "runId": "run1",
                            "hypothesisId": "H1_H4",
                            "data": [
                                "routeName": cappedFirst.name,
                                "origin_lat": _origin.latitude,
                                "origin_lng": _origin.longitude,
                                "waypointNames": firstRouteData.places.map { $0.name }
                            ]
                        ]
                        if let _pd = try? JSONSerialization.data(withJSONObject: _prepopEntry), let _ps = String(data: _pd, encoding: .utf8) { _ps.appendLine(toFile: _agentLogPath()) }
                        // #endregion agent log
                        // 🔍 DIAGNOSTIC: Log values BEFORE Google re-measure (first cached route)
                        let firstPreGoogleDur = cappedFirst.durationMinutes
                        let firstPreGoogleDist = cappedFirst.distanceMeters
                        let firstCoordsStr = firstRouteData.places.map { p in "'\(p.name)' (\(String(format: "%.5f", p.coordinate.latitude)),\(String(format: "%.5f", p.coordinate.longitude)))" }.joined(separator: ", ")
                        print("[ROUTE_DEBUG] 🔍 FIRST route: BEFORE Google: \(firstPreGoogleDur) min, \(firstPreGoogleDist) m, waypoints=[\(firstCoordsStr)], origin=(\(String(format: "%.5f", userLocation.coordinate.latitude)),\(String(format: "%.5f", userLocation.coordinate.longitude)))")
                        if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: firstRouteData.places, targetDurationMinutes: selectedDuration) {
                            // 🔍 DIAGNOSTIC: Log Google re-measure result
                            print("[ROUTE_DEBUG] 🔍 FIRST route: Google re-measure: \(googleResult.durationSeconds)s (\(googleResult.durationSeconds/60)min), \(googleResult.distanceMeters)m (was \(firstPreGoogleDur)min/\(firstPreGoogleDist)m)")
                            // v2.1.11: Mark as "google_duration" not "google" — getGoogleDirectionsRoute only re-measures
                            // duration/distance, it does NOT update polyline or directions. The full refreshRouteWithGoogleOnly()
                            // must still run on Let's Go so the walking map gets a Google-snapped polyline.
                            firstRoutePreviewSource = "google_duration"
                            // v2.1.11: Carry Google polyline — it's a real road-following polyline, no extra API call needed
                            let googlePolyline = googleResult.polyline.isEmpty ? cappedFirst.trimmed : googleResult.polyline
                            let correctedRoute = WalkingRoute(
                                name: cappedFirst.name,
                                description: cappedFirst.description,
                                durationMinutes: googleResult.durationSeconds / 60,
                                distanceMeters: googleResult.distanceMeters,
                                difficulty: cappedFirst.difficulty,
                                isIndoor: cappedFirst.isIndoor,
                                isAccessible: cappedFirst.isAccessible,
                                landmarks: cappedFirst.landmarks,
                                icon: cappedFirst.icon,
                                color: cappedFirst.color,
                                qrMarkers: cappedFirst.qrMarkers,
                                routeType: cappedFirst.routeType,
                                trimmed: googlePolyline,
                                walkingDirections: cappedFirst.walkingDirections,
                                usedOSRMRouting: false,
                                isFromPrePopulatedDatabase: cappedFirst.isFromPrePopulatedDatabase,
                                travelToStartMinutes: cappedFirst.travelToStartMinutes
                            )
                            cappedFirst = Self.applyDurationSanityCap(correctedRoute, targetDurationMinutes: selectedDuration)
                            // v2.1.8: Update GeneratedRoute with Google values so e.data matches e.route
                            let _oldDur = firstRouteData.durationSeconds
                            let _oldDist = firstRouteData.distanceMeters
                            firstRouteData = GeneratedRoute(
                                places: firstRouteData.places,
                                polyline: googlePolyline ?? firstRouteData.polyline,
                                distanceMeters: googleResult.distanceMeters,
                                durationSeconds: googleResult.durationSeconds,
                                legs: googleResult.legs ?? firstRouteData.legs,
                                usedOSRM: false,
                                travelToStartSeconds: firstRouteData.travelToStartSeconds
                            )
                            print("[ROUTE_DEBUG] 🔍 FIRST route: data updated → \(firstRouteData.durationSeconds)s / \(firstRouteData.distanceMeters)m (was \(_oldDur)s / \(_oldDist)m), isFromGoogle=\(firstRoutePreviewSource == "google"), route=\(cappedFirst.durationMinutes)min / \(cappedFirst.distanceMeters)m")
                        } else {
                            // #region agent log
                            let _prepopNil: [String: Any] = [
                                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                                "location": "RouteSelectionView:prepop_first:google_nil",
                                "message": "Google re-measure returned nil; route will show prepop/live",
                                "runId": "run1",
                                "hypothesisId": "H4",
                                "data": ["routeName": cappedFirst.name, "waypointNames": firstRouteData.places.map { $0.name }]
                            ]
                            if let _nd = try? JSONSerialization.data(withJSONObject: _prepopNil), let _ns = String(data: _nd, encoding: .utf8) { _ns.appendLine(toFile: _agentLogPath()) }
                            // #endregion agent log
                        }
                    }
                    let firstRouteWaypointsStr = firstRouteData.places.map { $0.name }.joined(separator: " → ")
                    let firstRouteDistanceKm = String(format: "%.1f", Double(cappedFirst.distanceMeters) / 1000)
                    print("[ROUTE_GEN] ROUTE_PREVIEW \(cappedFirst.name), \(firstRouteWaypointsStr). \(cappedFirst.durationMinutes) min \(firstRouteDistanceKm)km, \(firstRoutePreviewSource)")
                    let firstIsFromGoogle = firstRoutePreviewSource == "google"
                    print("[ROUTE_DEBUG] 📦 APPEND_FIRST: isFromGoogle=\(firstIsFromGoogle), data=\(firstRouteData.durationSeconds)s/\(firstRouteData.distanceMeters)m, route=\(cappedFirst.durationMinutes)min/\(cappedFirst.distanceMeters)m, places=\(firstRouteData.places.count)")
                    loadedRoutes.append((route: cappedFirst, data: firstRouteData, isDeadZoneFallback: firstCached.isDeadZoneFallback, isFromGoogle: firstIsFromGoogle))
                    loadedPlaceIdSets.append(Set(firstRouteData.places.map { $0.placeId }))
                    
                    // v2.1.9: Store first cached route in cross-bucket pool if out-of-band after Google re-measure
                    // v2.1.11: Check google_duration — duration is accurate even though full refresh hasn't run
                    if firstRoutePreviewSource.hasPrefix("google") {
                        await MainActor.run {
                            if !Self.isRouteInBand(cappedFirst, selectedDuration: selectedDuration) {
                                storeCrossBucketRoute(route: cappedFirst, data: firstRouteData, isFromGoogle: false)
                            }
                        }
                    }
                    
                    // v1.9.24: Show first route IMMEDIATELY (<0.1s), enhance in background
                    await MainActor.run {
                        // #region agent log
                        if firstRoute.qrMarkers.count > 1 {
                            let distances = (0..<firstRoute.qrMarkers.count-1).map { i in
                                let loc1 = CLLocation(latitude: firstRoute.qrMarkers[i].coordinate.latitude, longitude: firstRoute.qrMarkers[i].coordinate.longitude)
                                let loc2 = CLLocation(latitude: firstRoute.qrMarkers[i+1].coordinate.latitude, longitude: firstRoute.qrMarkers[i+1].coordinate.longitude)
                                return loc1.distance(from: loc2)
                            }
                            let logData: [String: Any] = [
                                "sessionId": "debug-session",
                                "runId": "run1",
                                "hypothesisId": "H",
                                "location": "RouteSelectionView.swift:1959",
                                "message": "Cached route assigned: final waypoint distances",
                                "data": [
                                    "routeName": firstRoute.name,
                                    "waypointCount": firstRoute.qrMarkers.count,
                                    "waypoints": firstRoute.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                                    "distances": distances,
                                    "minDistance": distances.min() ?? 0,
                                    "source": "cache",
                                    "places": firstRouteData.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] }
                                ],
                                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                            ]
                            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                               let logString = String(data: logJSON, encoding: .utf8) {
                                logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                            }
                        }
                        // #endregion
                        
                        isGenerating = false
                        routeGenerationComplete = true  // Mark complete so user can see first route
                        allRoutes = loadedRoutes
                        let timeToFirst = Date().timeIntervalSince(generateStartTime)
                        runSummaryTimeToFirstRouteSec = timeToFirst
                        logRoutePreviewSummary()
                        
                        // Auto-advance to route 2 if available (skip template Route 1)
                        if cachedRoutes.count >= 2 {
                            currentRouteIndex = 1
                            // We'll update this when second route loads
                        } else {
                            currentRouteIndex = 0
                            generatedRoute = cappedFirst
                            generatedRouteData = firstRouteData
                            lastValidRoute = cappedFirst
                            lastValidRouteData = firstRouteData
                            viewedRouteIndices = [0]
                            print("[ROUTE_DEBUG] 📦 SET_STATE: generatedRouteData=\(firstRouteData.durationSeconds)s/\(firstRouteData.distanceMeters)m, generatedRoute=\(cappedFirst.durationMinutes)min/\(cappedFirst.distanceMeters)m")
                            print("TIME_SOURCE | PREVIEW: First route shown: \(cappedFirst.durationMinutes) min, \(cappedFirst.distanceMeters)m — FROM CACHE/PRE-POP (Google refresh pending)")
                        }
                        
                        isRecycledRoute = false
                        isDeadZoneFallback = firstCached.isDeadZoneFallback
                        shownPlaceIdSets = loadedPlaceIdSets
                        let timeToFirstRoute = Date().timeIntervalSince(generateStartTime)
                        print("ROUTE_FIRST_DISPLAYED time_to_first_route_sec=\(String(format: "%.2f", timeToFirstRoute)) duration=\(selectedDuration) source=cache")
                    }
                    
                    // PREPOP ONLY: Google/MapKit validate-and-reorder (all routes: update preview time from Google, then reorder valid first when user on route 1)
                    print("[ROUTE_DEBUG] 📦 BRANCH_DECISION: isPrepop=\(firstCached.isFromPrePopulatedDatabase), allRoutesEmpty=\(allRoutes.isEmpty), cachedRoutesCount=\(cachedRoutes.count)")
                    if firstCached.isFromPrePopulatedDatabase, !allRoutes.isEmpty, cachedRoutes.count == 1 {
                        print("[ROUTE_DEBUG] 📦 LAUNCHING prepopMapKitValidateAndReorder (cachedRoutes.count == 1)")
                        Task {
                            await prepopMapKitValidateAndReorder(userLocation: userLocation.coordinate, selectedDuration: selectedDuration)
                        }
                    } else if cachedRoutes.count > 1 {
                        print("[ROUTE_DEBUG] 📦 SKIP prepopValidate — cachedRoutes.count=\(cachedRoutes.count) > 1, background cache loading will handle")
                    } else {
                        print("[ROUTE_DEBUG] 📦 SKIP prepopValidate — isPrepop=\(firstCached.isFromPrePopulatedDatabase), allRoutesEmpty=\(allRoutes.isEmpty)")
                    }
                    
                    // Gemini name/description for first pre-populated route — run in parallel, don't block
                    if firstCached.isFromPrePopulatedDatabase,
                       (firstCached.name == nil || (firstCached.name ?? "").isEmpty || (firstCached.name ?? "") == "Local Discovery"),
                       !filteredCachedRoute.places.isEmpty {
                        let placesForGemini = firstRouteData.places
                        let durationMin = max(1, durationToUse / 60)
                        let diff = firstRouteDifficulty
                        let origin = userLocation.coordinate
                        Task {
                            let waypointInfos = placesForGemini.map {
                                GeminiService.WaypointInfo(name: $0.name, types: $0.types ?? [], vicinity: $0.vicinity)
                            }
                            let content = await GeminiService.shared.generateRouteContent(
                                waypoints: waypointInfos,
                                durationMinutes: durationMin,
                                distanceMeters: distanceToUse,
                                difficulty: diff,
                                originCoordinate: (lat: origin.latitude, lon: origin.longitude)
                            )
                            await MainActor.run {
                                guard allRoutes.indices.contains(0) else { return }
                                let existing = allRoutes[0].route
                                let updated = WalkingRoute(
                                    name: content.name,
                                    description: content.description,
                                    durationMinutes: existing.durationMinutes,
                                    distanceMeters: existing.distanceMeters,
                                    difficulty: existing.difficulty,
                                    isIndoor: existing.isIndoor,
                                    isAccessible: existing.isAccessible,
                                    landmarks: existing.landmarks,
                                    icon: existing.icon,
                                    color: existing.color,
                                    qrMarkers: existing.qrMarkers,
                                    routeType: existing.routeType,
                                    trimmed: existing.trimmed,
                                    walkingDirections: existing.walkingDirections,
                                    usedOSRMRouting: existing.usedOSRMRouting,
                                    isFromPrePopulatedDatabase: existing.isFromPrePopulatedDatabase,
                                    travelToStartMinutes: existing.travelToStartMinutes
                                )
                                allRoutes[0] = (route: updated, data: allRoutes[0].data, isDeadZoneFallback: allRoutes[0].isDeadZoneFallback, isFromGoogle: allRoutes[0].isFromGoogle)
                                if currentRouteIndex == 0 {
                                    generatedRoute = updated
                                }
                            }
                        }
                    }
                    
                    let firstLoadTime = Date().timeIntervalSince(firstLoadStartTime)
                    print("═══════════════════════════════════════════════════════════")
                    print("✅ FIRST ROUTE LOADED in \(String(format: "%.2f", firstLoadTime))s - showing immediately")
                    print("   📍 Route: \(firstRoute.name), \(firstRoute.durationMinutes)min, \(firstRoute.qrMarkers.count) POIs")
                    if cachedRoutes.count > 1 {
                        print("   ⏳ Loading \(cachedRoutes.count - 1) more routes in background...")
                    }
                    print("═══════════════════════════════════════════════════════════")
                    
                    // v1.9.24: Enhance first route in background (markers, directions if missing)
                    // v1.9.25: Check cancellation flag to stop if user taps "Let's Go"
                    Task {
                        // Check if user action cancelled background work
                        let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                        if shouldCancel {
                            print("⏱️ [CACHE] First route enhancement cancelled - user initiated action")
                            return
                        }
                        
                        var needsUpdate = false
                        var enhancedMarkers = firstMarkers
                        var enhancedDirections = firstDirections
                        
                        // Enhance markers if needed (full processing for better quality)
                        if firstMarkers.isEmpty || firstMarkers.count != firstRouteData.places.count {
                            // Check cancellation before heavy work
                            let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                            if shouldCancel {
                                print("⏱️ [CACHE] Marker enhancement cancelled")
                                return
                            }
                            
                            enhancedMarkers = await MainActor.run {
                                // #region agent log
                                if firstRouteData.places.count > 1 {
                                    let distances = (0..<firstRouteData.places.count-1).map { i in
                                        let loc1 = CLLocation(latitude: firstRouteData.places[i].coordinate.latitude, longitude: firstRouteData.places[i].coordinate.longitude)
                                        let loc2 = CLLocation(latitude: firstRouteData.places[i+1].coordinate.latitude, longitude: firstRouteData.places[i+1].coordinate.longitude)
                                        return loc1.distance(from: loc2)
                                    }
                                    let logData: [String: Any] = [
                                        "sessionId": "debug-session",
                                        "runId": "run1",
                                        "hypothesisId": "H",
                                        "location": "RouteSelectionView.swift:1994",
                                        "message": "Cached route: waypoint distances",
                                        "data": [
                                            "routeName": firstCached.name ?? "Unknown",
                                            "waypointCount": firstRouteData.places.count,
                                            "waypoints": firstRouteData.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                                            "distances": distances,
                                            "minDistance": distances.min() ?? 0,
                                            "source": "cache"
                                        ],
                                        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                                    ]
                                    if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                                       let logString = String(data: logJSON, encoding: .utf8) {
                                        logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                                    }
                                }
                                // #endregion
                                return createMarkersFromPlaces(firstRouteData.places, origin: userLocation.coordinate)
                            }
                            needsUpdate = true
                        }
                        
                        // Enhance directions if missing
                        if enhancedDirections.isEmpty {
                            // Check cancellation before MapKit call
                            let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                            if shouldCancel {
                                print("⏱️ [CACHE] Direction enhancement cancelled")
                                return
                            }
                            
                            enhancedDirections = await MainActor.run {
                                extractWalkingDirections(from: firstRouteData.legs, waypoints: firstRouteData.places)
                            }
                            
                            // Get MapKit directions if still empty
                            if enhancedDirections.isEmpty && !firstRouteData.places.isEmpty {
                                // Final cancellation check before expensive MapKit call
                                let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                                if shouldCancel {
                                    print("⏱️ [CACHE] MapKit enhancement cancelled - freeing quota")
                                    return
                                }
                                
                                print("🍎 Enhancing first route with MapKit directions...")
                                let waypointCoords = firstRouteData.places.map { $0.coordinate }
                                let waypointNames = firstRouteData.places.map { $0.name }
                                enhancedDirections = await mapsService.getMapKitDirectionsForRoute(
                                    origin: userLocation.coordinate,
                                    waypoints: waypointCoords,
                                    destination: userLocation.coordinate,
                                    waypointNames: waypointNames
                                )
                            }
                            
                            if !enhancedDirections.isEmpty {
                                needsUpdate = true
                            }
                        }
                        
                        // Update route with enhanced data
                        if needsUpdate {
                            await MainActor.run {
                                if let index = allRoutes.firstIndex(where: { $0.route.name == firstRoute.name }) {
                                    let existingRoute = allRoutes[index].route
                                    let updatedRoute = WalkingRoute(
                                        name: existingRoute.name,
                                        description: existingRoute.description,
                                        durationMinutes: existingRoute.durationMinutes,
                                        distanceMeters: existingRoute.distanceMeters,
                                        difficulty: existingRoute.difficulty,
                                        isIndoor: existingRoute.isIndoor,
                                        isAccessible: existingRoute.isAccessible,
                                        landmarks: existingRoute.landmarks,
                                        icon: existingRoute.icon,
                                        color: existingRoute.color,
                                        qrMarkers: enhancedMarkers,
                                        routeType: existingRoute.routeType,
                                        trimmed: existingRoute.trimmed,
                                        walkingDirections: enhancedDirections,
                                        usedOSRMRouting: existingRoute.usedOSRMRouting,
                                        isFromPrePopulatedDatabase: existingRoute.isFromPrePopulatedDatabase
                                    )
                                    allRoutes[index] = (route: updatedRoute, data: allRoutes[index].data, isDeadZoneFallback: allRoutes[index].isDeadZoneFallback, isFromGoogle: allRoutes[index].isFromGoogle)
                                    
                                    if currentRouteIndex == index {
                                        generatedRoute = updatedRoute
                                    }
                                }
                                print("⏱️ [CACHE] First route enhanced with full markers/directions")
                            }
                        }
                    }
                    
                    // v1.9.23: Load remaining routes in background (parallel processing)
                    if cachedRoutes.count > 1 {
                        print("[ROUTE_DEBUG] 📦 BACKGROUND_CACHE: Loading remaining \(cachedRoutes.count - 1) routes in background (will Google re-measure each)")
                        print("⏱️ [CACHE] Loading remaining \(cachedRoutes.count - 1) routes in background...")
                        await MainActor.run {
                            mapsService.retryStatus = "Loading \(cachedRoutes.count - 1) more routes..."
                        }
                        
                        // Process remaining routes in parallel
                        await withTaskGroup(of: (route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool, placeIds: Set<String>).self) { group in
                            for (index, cached) in cachedRoutes.dropFirst().enumerated() {
                                group.addTask {
                                    // v2.1.7: Filter close waypoints from cached routes (100m under 25min, 200m for 25+ min). Pre-populated routes use 200m to match DB/trigger zone.
                                    let filteredCachedRoute = mapsService.filterCloseWaypointsSync(from: cached.route, durationMinutes: selectedDuration, origin: userLocation.coordinate, isFromPrePopulatedDatabase: cached.isFromPrePopulatedDatabase)
                                    var routeData: GeneratedRoute = (filteredCachedRoute.places.count <= 2 && !prefetchedPOIs.isEmpty)
                                        ? mapsService.addOnRoutePOIsIfNeeded(filteredCachedRoute, origin: userLocation.coordinate, candidatePOIs: prefetchedPOIs, durationMinutes: selectedDuration)
                                        : filteredCachedRoute
                                    
                                    // Pre-populated routes: start = GPS; prepend GPS → first waypoint, append last waypoint → GPS (return to start)
                                    var polylineToUse = routeData.polyline
                                    var durationToUse = routeData.durationSeconds
                                    var distanceToUse = routeData.distanceMeters
                                    var directionsFromGpsToFirst: [WalkingDirection] = []
                                    var directionsFromLastToGps: [WalkingDirection] = []
                                    if cached.isFromPrePopulatedDatabase, let firstPlace = routeData.places.first {
                                        if let merged = await mapsService.prependGpsToFirstWaypointLeg(
                                            userLocation: userLocation.coordinate,
                                            firstWaypoint: firstPlace.coordinate,
                                            existingRoutePolyline: routeData.polyline,
                                            existingDurationSeconds: routeData.durationSeconds,
                                            existingDistanceMeters: routeData.distanceMeters
                                        ) {
                                            polylineToUse = merged.polyline
                                            durationToUse = merged.durationSeconds
                                            distanceToUse = merged.distanceMeters
                                            directionsFromGpsToFirst = merged.directionsFromGpsToFirst
                                        }
                                        if let lastPlace = routeData.places.last {
                                            if let withReturn = await mapsService.appendLastWaypointToGpsLeg(
                                                userLocation: userLocation.coordinate,
                                                lastWaypoint: lastPlace.coordinate,
                                                existingRoutePolyline: polylineToUse,
                                                existingDurationSeconds: durationToUse,
                                                existingDistanceMeters: distanceToUse
                                            ) {
                                                polylineToUse = withReturn.polyline
                                                durationToUse = withReturn.durationSeconds
                                                distanceToUse = withReturn.distanceMeters
                                                directionsFromLastToGps = withReturn.directionsFromLastToGps
                                            }
                                        }
                                    }
                                    
                                    let markers = await MainActor.run {
                                        createMarkersFromPlaces(routeData.places, origin: userLocation.coordinate)
                                    }
                                    
                                    // First directions = from GPS to first waypoint (pre-populated); then cached or extracted route directions
                                    var directions: [WalkingDirection] = directionsFromGpsToFirst
                                    if let cachedDirections = cached.directions, !cachedDirections.isEmpty {
                                        // v2.1.7: Filter contradictory directions from cached directions too
                                        let filteredCachedDirections = await MainActor.run {
                                            filterContradictoryDirections(cachedDirections)
                                        }
                                        // #region agent log
                                        let logData5: [String: Any] = [
                                            "sessionId": "debug-session",
                                            "runId": "run1",
                                            "hypothesisId": "B",
                                            "location": "RouteSelectionView.swift:2154",
                                            "message": "Using cached directions (background route)",
                                            "data": [
                                                "cachedDirectionsCount": cachedDirections.count,
                                                "filteredDirectionsCount": filteredCachedDirections.count,
                                                "waypointInstructions": filteredCachedDirections.filter { $0.instruction.contains("Waypoint") }.map { $0.instruction },
                                                "waypointsCount": routeData.places.count,
                                                "hasWaypointInstructions": filteredCachedDirections.contains { $0.instruction.contains("Waypoint") }
                                            ],
                                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                                        ]
                                        if let logJSON5 = try? JSONSerialization.data(withJSONObject: logData5),
                                           let logString5 = String(data: logJSON5, encoding: .utf8) {
                                            logString5.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                                        }
                                        // #endregion
                                        
                                        // v2.1.7: Use filtered cached directions (after GPS→first leg directions)
                                        directions += filteredCachedDirections
                                    } else {
                                        directions += await MainActor.run {
                                            extractWalkingDirections(from: routeData.legs, waypoints: routeData.places)
                                        }
                                    }
                                    directions += directionsFromLastToGps
                                    
                                    // Re-measure with Google when available so preview matches reality (fixes wrong 25min/2km for short routes)
                                    var isFromGoogle = false
                                    let _bgRouteName = cached.name ?? "Local Discovery"
                                    if !mapsService.hasAPIKey || routeData.places.isEmpty {
                                        print("[ROUTE_DEBUG] ⚠️ BG_CACHE route '\(_bgRouteName)': Google re-measure SKIPPED — hasAPIKey=\(mapsService.hasAPIKey), places=\(routeData.places.count) (keeping synthetic \(durationToUse/60)min / \(distanceToUse)m)")
                                    }
                                    if mapsService.hasAPIKey && !routeData.places.isEmpty {
                                        // #region agent log
                                        let _bgOrigin = userLocation.coordinate
                                        let _routeName = cached.name ?? "Local Discovery"
                                        let _bgEntry: [String: Any] = [
                                            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                                            "location": "RouteSelectionView:background_cache:before_google",
                                            "message": "Attempting Google re-measure for background cached route",
                                            "runId": "run1",
                                            "hypothesisId": "H1_H4",
                                            "data": [
                                                "routeName": _routeName,
                                                "origin_lat": _bgOrigin.latitude,
                                                "origin_lng": _bgOrigin.longitude,
                                                "waypointNames": routeData.places.map { $0.name }
                                            ]
                                        ]
                                        if let _bd = try? JSONSerialization.data(withJSONObject: _bgEntry), let _bs = String(data: _bd, encoding: .utf8) { _bs.appendLine(toFile: _agentLogPath()) }
                                        // #endregion agent log
                                        // 🔍 DIAGNOSTIC: Log values BEFORE Google re-measure (cache/prepop path)
                                        let preGoogleDurSec = durationToUse
                                        let preGoogleDistM = distanceToUse
                                        let preGoogleCoordsStr = routeData.places.map { p in "'\(p.name)' (\(String(format: "%.5f", p.coordinate.latitude)),\(String(format: "%.5f", p.coordinate.longitude)))" }.joined(separator: ", ")
                                        print("[ROUTE_DEBUG] 🔍 CACHE route '\(_routeName)': BEFORE Google: \(preGoogleDurSec)s (\(preGoogleDurSec/60)min), \(preGoogleDistM)m, waypoints=[\(preGoogleCoordsStr)]")
                                        if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: routeData.places, targetDurationMinutes: selectedDuration) {
                                            // 🔍 DIAGNOSTIC: Log Google re-measure result
                                            print("[ROUTE_DEBUG] 🔍 CACHE route '\(_routeName)': Google re-measure: \(googleResult.durationSeconds)s (\(googleResult.durationSeconds/60)min), \(googleResult.distanceMeters)m (was \(preGoogleDurSec/60)min/\(preGoogleDistM)m)")
                                            durationToUse = googleResult.durationSeconds
                                            distanceToUse = googleResult.distanceMeters
                                            // v2.1.11: Carry Google polyline for preview display (real road-following polyline, no extra API call)
                                            if !googleResult.polyline.isEmpty {
                                                polylineToUse = googleResult.polyline
                                            }
                                            // v2.1.8: Update GeneratedRoute with Google values so e.data matches e.route
                                            routeData = GeneratedRoute(
                                                places: routeData.places,
                                                polyline: !googleResult.polyline.isEmpty ? googleResult.polyline : routeData.polyline,
                                                distanceMeters: googleResult.distanceMeters,
                                                durationSeconds: googleResult.durationSeconds,
                                                legs: googleResult.legs ?? routeData.legs,
                                                usedOSRM: false,
                                                travelToStartSeconds: routeData.travelToStartSeconds
                                            )
                                        } else {
                                            print("[ROUTE_DEBUG] 🔍 CACHE route '\(_routeName)': Google re-measure FAILED — keeping prepop values: \(preGoogleDurSec/60)min, \(preGoogleDistM)m")
                                            // #region agent log
                                            let _bgNil: [String: Any] = [
                                                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                                                "location": "RouteSelectionView:background_cache:google_nil",
                                                "message": "Google re-measure returned nil for background route",
                                                "runId": "run1",
                                                "hypothesisId": "H4",
                                                "data": ["routeName": _routeName, "waypointNames": routeData.places.map { $0.name }]
                                            ]
                                            if let _bnd = try? JSONSerialization.data(withJSONObject: _bgNil), let _bns = String(data: _bnd, encoding: .utf8) { _bns.appendLine(toFile: _agentLogPath()) }
                                            // #endregion agent log
                                        }
                                    }
                                    
                                    let routeDifficulty: RouteDifficulty = (durationToUse / 60) <= 10 ? .easy : ((durationToUse / 60) <= 20 ? .moderate : .challenging)
                                    
                                    // Pre-populated routes from DB often have no name/description — generate with Gemini
                                    var routeName = cached.name ?? "Local Discovery"
                                    var routeDesc = cached.description ?? "A \(routeData.formattedDuration) walk passing \(routeData.places.count) local points of interest."
                                    if (cached.name == nil || (cached.name ?? "").isEmpty || (cached.name ?? "") == "Local Discovery"),
                                       cached.isFromPrePopulatedDatabase,
                                       !routeData.places.isEmpty {
                                        let waypointInfos = routeData.places.map {
                                            GeminiService.WaypointInfo(name: $0.name, types: $0.types ?? [], vicinity: $0.vicinity)
                                        }
                                        let content = await GeminiService.shared.generateRouteContent(
                                            waypoints: waypointInfos,
                                            durationMinutes: max(1, durationToUse / 60),
                                            distanceMeters: distanceToUse,
                                            difficulty: routeDifficulty,
                                            originCoordinate: nil
                                        )
                                        routeName = content.name
                                        routeDesc = content.description
                                    }
                                    
                                    let localRoute = WalkingRoute(
                                        name: routeName,
                                        description: routeDesc,
                                        durationMinutes: max(1, durationToUse / 60),
                                        distanceMeters: distanceToUse,
                                        difficulty: routeDifficulty,
                                        isIndoor: false,
                                        isAccessible: true,
                                        landmarks: ["Start"] + routeData.places.map { $0.name } + ["Return"],
                                        icon: "location.fill",
                                        color: .tealAccent,
                                        qrMarkers: markers,
                                        routeType: .local,
                                        trimmed: polylineToUse,
                                        walkingDirections: directions,
                                        usedOSRMRouting: routeData.usedOSRM,
                                        isFromPrePopulatedDatabase: cached.isFromPrePopulatedDatabase
                                    )
                                    let cappedRoute = Self.applyDurationSanityCap(localRoute, targetDurationMinutes: selectedDuration)
                                    let waypointsStr = routeData.places.map { $0.name }.joined(separator: " → ")
                                    let distanceKm = String(format: "%.1f", Double(cappedRoute.distanceMeters) / 1000)
                                    let source = isFromGoogle ? "google" : (cached.isFromPrePopulatedDatabase ? "prepop" : "cache")
                                    print("[ROUTE_GEN] ROUTE_PREVIEW \(cappedRoute.name), \(waypointsStr). \(cappedRoute.durationMinutes) min \(distanceKm)km, \(source)")
                                    
                                    let placeIds = Set(routeData.places.map { $0.placeId })
                                    return (route: cappedRoute, data: routeData, isDeadZoneFallback: cached.isDeadZoneFallback, isFromGoogle: isFromGoogle, placeIds: placeIds)
                                }
                            }
                            
                            // Collect results as they complete
                            var backgroundRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] = []
                            var backgroundPlaceIdSets: [Set<String>] = []
                            
                            for await result in group {
                                backgroundRoutes.append((route: result.route, data: result.data, isDeadZoneFallback: result.isDeadZoneFallback, isFromGoogle: result.isFromGoogle))
                                backgroundPlaceIdSets.append(result.placeIds)
                            }
                            
                            // Update UI with all loaded routes
                            await MainActor.run {
                                // #region agent log
                                for (idx, bgRoute) in backgroundRoutes.enumerated() {
                                    if bgRoute.route.qrMarkers.count > 1 {
                                        let distances = (0..<bgRoute.route.qrMarkers.count-1).map { i in
                                            let loc1 = CLLocation(latitude: bgRoute.route.qrMarkers[i].coordinate.latitude, longitude: bgRoute.route.qrMarkers[i].coordinate.longitude)
                                            let loc2 = CLLocation(latitude: bgRoute.route.qrMarkers[i+1].coordinate.latitude, longitude: bgRoute.route.qrMarkers[i+1].coordinate.longitude)
                                            return loc1.distance(from: loc2)
                                        }
                                        let logData: [String: Any] = [
                                            "sessionId": "debug-session",
                                            "runId": "run1",
                                            "hypothesisId": "G",
                                            "location": "RouteSelectionView.swift:2192",
                                            "message": "Background route added: final waypoint distances",
                                            "data": [
                                                "routeName": bgRoute.route.name,
                                                "routeIndex": allRoutes.count + idx,
                                                "waypointCount": bgRoute.route.qrMarkers.count,
                                                "waypoints": bgRoute.route.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                                                "distances": distances,
                                                "minDistance": distances.min() ?? 0,
                                                "source": "background"
                                            ],
                                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                                        ]
                                        if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                                           let logString = String(data: logJSON, encoding: .utf8) {
                                            logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                                        }
                                    }
                                }
                                // #endregion
                                
                                // Prioritise in-band routes: sort so in-band come first, then only append enough to reach targetInBandRoutes
                                let sortedBg = backgroundRoutes.enumerated().sorted { a, b in
                                    let aInBand = Self.isRouteInBand(a.element.route, selectedDuration: selectedDuration)
                                    let bInBand = Self.isRouteInBand(b.element.route, selectedDuration: selectedDuration)
                                    if aInBand != bInBand { return aInBand }
                                    return a.offset < b.offset
                                }
                                // Bypass in-band cap for cached/session routes — these were already
                                // accepted previously (e.g. +1 routes). The cap should only limit
                                // NEW generation, not restoring what the user already had.
                                for item in sortedBg {
                                    let added = appendRouteIfAllowed(
                                        route: item.element.route,
                                        data: item.element.data,
                                        isDeadZoneFallback: item.element.isDeadZoneFallback,
                                        isFromGoogle: item.element.isFromGoogle,
                                        source: "cache-load",
                                        bypassInBandCap: true
                                    )
                                    if added {
                                        shownPlaceIdSets.append(backgroundPlaceIdSets[item.offset])
                                    }
                                }
                                print("[ROUTE_GEN] ⏹️ In-band routes after cache load: \(inBandRouteCount())/\(targetInBandRoutes) target")
                                
                                // If we auto-advanced to route 2, make sure it's set
                                if currentRouteIndex == 1 && allRoutes.count > 1 {
                                    let secondRoute = allRoutes[1]
                                    generatedRoute = secondRoute.route
                                    generatedRouteData = secondRoute.data
                                    lastValidRoute = secondRoute.route
                                    lastValidRouteData = secondRoute.data
                                    viewedRouteIndices = [1]
                                    print("TIME_SOURCE | PREVIEW: Second route shown: \(secondRoute.route.durationMinutes) min — FROM CACHE (no Google refresh until Let's Go)")
                                }
                                
                                mapsService.retryStatus = nil  // Clear status
                                print("⏱️ [CACHE] Background loading complete - \(allRoutes.count) total routes")
                                logRoutePreviewSummary()
                            }
                        }
                        // v2.1.11: Safety-net sweep — Google-remeasure any routes still showing synthetic values
                        // Skip if we already have enough in-band routes (saves API calls)
                        let inBandBeforeSweep = await MainActor.run { inBandRouteCount() }
                        if inBandBeforeSweep < targetInBandRoutes {
                            await googleRemeasureSweep(userLocation: userLocation.coordinate, selectedDuration: selectedDuration)
                        } else {
                            print("[ROUTE_GEN] ⏹️ SWEEP skipped — already have \(inBandBeforeSweep)/\(targetInBandRoutes) in-band routes")
                        }
                        
                        // PREPOP ONLY: MapKit validate-and-reorder now that all routes are in allRoutes
                        if firstCached.isFromPrePopulatedDatabase, !allRoutes.isEmpty {
                            Task {
                                await prepopMapKitValidateAndReorder(userLocation: userLocation.coordinate, selectedDuration: selectedDuration)
                            }
                        }
                    }
                    
                    // v1.9.24: Register route signatures for all cached routes
                    for cachedRoute in cachedRoutes {
                        registerRouteSignature(places: cachedRoute.route.places, distanceMeters: cachedRoute.route.distanceMeters)
                    }
                    
                    // MapKit started before Let's Go — when it completes, show MapKit only if Google hasn't yet
                    // On Let's Go we start Google; last route shown is always Google
                    refreshRaceState.walkStarted = false
                    refreshRaceState.googleApplied = false
                    let userLoc = userLocation.coordinate
                    let raceState = refreshRaceState
                    print("⏱️ [MAPKIT-PREVIEW] Starting MapKit refresh for first route (in flight before Let's Go)...")
                    Task {
                        let mapKitRoute = await mapsService.refreshRouteWithMapKit(route: firstRoute, userLocation: userLoc)
                        await MainActor.run {
                            if raceState.walkStarted {
                                if !raceState.googleApplied {
                                    viewModel.updateCurrentRoute(mapKitRoute)
                                    print("DIRECTIONS | MapKit (preview) finished after Let's Go — applied (Google not yet)")
                                } else {
                                    print("DIRECTIONS | MapKit (preview) finished after Let's Go — ignored (Google already applied)")
                                }
                            } else {
                                if let index = allRoutes.firstIndex(where: { $0.route.name == firstRoute.name }) {
                                    // v2.1.9: Don't overwrite Google-remeasured route with MapKit estimate
                                    if allRoutes[index].isFromGoogle {
                                        print("TIME_SOURCE | PREVIEW: MapKit refresh skipped — route already Google-remeasured (\(allRoutes[index].route.durationMinutes) min)")
                                    } else {
                                        allRoutes[index].route = mapKitRoute
                                        if currentRouteIndex == index {
                                            generatedRoute = mapKitRoute
                                        }
                                        print("TIME_SOURCE | PREVIEW: MapKit refresh done — preview shows \(mapKitRoute.durationMinutes) min (Google will run on Let's Go)")
                                    }
                                }
                            }
                            routeRefreshStatus = nil
                        }
                    }
                    
                    // v1.9.28: Clear any status messages - routes are ready to use
                    routeRefreshStatus = nil
                    
                    // Mark complete immediately (don't wait for refresh or background loading)
                    // Refresh happens in background and updates route when ready
                    routeGenerationComplete = true
                    
                    // Lower-bucket + extend: add extra route options (short base extended to target) when prepop and we have room. Skip if we already have enough in-band routes.
                    let inBandBeforeExtend = await MainActor.run { inBandRouteCount() }
                    if firstCached.isFromPrePopulatedDatabase, cachedRoutes.count < maxRoutesToGenerate, inBandBeforeExtend < targetInBandRoutes {
                        print("[ROUTE_DEBUG] 📦 LOWER_BUCKET: Launching extend task (isPrepop=true, cachedRoutes=\(cachedRoutes.count) < max=\(maxRoutesToGenerate))")
                        Task {
                            guard let (lowerRoutes, candidatePOIs) = PrePopulatedPOIService.shared.getLowerBucketRoutesForExtend(near: userLocation.coordinate, extendToDuration: selectedDuration) else {
                                print("[ROUTE_DEBUG] 📦 LOWER_BUCKET: No lower bucket routes available")
                                return
                            }
                            print("[ROUTE_DEBUG] 📦 LOWER_BUCKET: Found \(lowerRoutes.count) routes to extend, \(candidatePOIs.count) candidate POIs")
                            for cached in lowerRoutes {
                                guard await MainActor.run(body: { allRoutes.count }) < maxRoutesToGenerate else { break }
                                guard let extended = await mapsService.extendRouteToTargetDuration(cachedRoute: cached, userLocation: userLocation.coordinate, targetMinutes: selectedDuration, candidatePOIs: candidatePOIs) else { continue }
                                var routeData = extended.route
                                var displayRoute = RouteConversionHelper.walkingRoute(from: routeData, origin: userLocation.coordinate, name: extended.name ?? "Extended route", description: extended.description ?? "Route extended to \(selectedDuration) min")
                                var isFromGoogle = false
                                
                                // v2.1.9: Google re-measure extended routes so displayed duration is accurate
                                print("[ROUTE_DEBUG] 🔍 Extended route '\(displayRoute.name)': BEFORE Google: \(displayRoute.durationMinutes)min / \(displayRoute.distanceMeters)m, places=\(routeData.places.count)")
                                if mapsService.hasAPIKey && !routeData.places.isEmpty {
                                    if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: routeData.places, targetDurationMinutes: selectedDuration) {
                                        print("[ROUTE_DEBUG] 🔍 Extended route '\(displayRoute.name)': Google re-measure: \(googleResult.durationSeconds)s (\(googleResult.durationSeconds/60)min), \(googleResult.distanceMeters)m (was \(displayRoute.durationMinutes)min/\(displayRoute.distanceMeters)m)")
                                        // v2.1.11: Carry Google polyline for preview display
                                        let extGooglePoly = googleResult.polyline.isEmpty ? displayRoute.trimmed : googleResult.polyline
                                        displayRoute = WalkingRoute(
                                            name: displayRoute.name,
                                            description: displayRoute.description,
                                            durationMinutes: max(1, googleResult.durationSeconds / 60),
                                            distanceMeters: googleResult.distanceMeters,
                                            difficulty: displayRoute.difficulty,
                                            isIndoor: displayRoute.isIndoor,
                                            isAccessible: displayRoute.isAccessible,
                                            landmarks: displayRoute.landmarks,
                                            icon: displayRoute.icon,
                                            color: displayRoute.color,
                                            qrMarkers: displayRoute.qrMarkers,
                                            routeType: displayRoute.routeType,
                                            trimmed: extGooglePoly,
                                            walkingDirections: displayRoute.walkingDirections,
                                            usedOSRMRouting: false,
                                            isFromPrePopulatedDatabase: displayRoute.isFromPrePopulatedDatabase,
                                            travelToStartMinutes: displayRoute.travelToStartMinutes
                                        )
                                        routeData = GeneratedRoute(
                                            places: routeData.places,
                                            polyline: extGooglePoly ?? routeData.polyline,
                                            distanceMeters: googleResult.distanceMeters,
                                            durationSeconds: googleResult.durationSeconds,
                                            legs: googleResult.legs ?? routeData.legs,
                                            usedOSRM: false,
                                            travelToStartSeconds: routeData.travelToStartSeconds
                                        )
                                    } else {
                                        print("[ROUTE_DEBUG] 🔍 Extended route '\(displayRoute.name)': Google re-measure FAILED — keeping synthetic \(displayRoute.durationMinutes)min / \(displayRoute.distanceMeters)m")
                                    }
                                } else {
                                    print("[ROUTE_DEBUG] 🔍 Extended route '\(displayRoute.name)': Google SKIPPED — hasAPIKey=\(mapsService.hasAPIKey), places=\(routeData.places.count)")
                                }
                                
                                let cappedRoute = Self.applyDurationSanityCap(displayRoute, targetDurationMinutes: selectedDuration)
                                await MainActor.run {
                                    let added = appendRouteIfAllowed(
                                        route: cappedRoute,
                                        data: routeData,
                                        isFromGoogle: isFromGoogle,
                                        source: "lower-bucket-extend"
                                    )
                                    if added {
                                        registerRouteSignature(places: routeData.places, distanceMeters: routeData.distanceMeters)
                                        logRoutePreviewSummary()
                                    }
                                }
                            }
                        }
                    }
                    
                    // Only pre-generate more if we don't have enough in-band routes
                    let inBandAfterCache = await MainActor.run { inBandRouteCount() }
                    if inBandAfterCache >= targetInBandRoutes {
                        print("[ROUTE_GEN] ⏹️ Already have \(inBandAfterCache)/\(targetInBandRoutes) in-band routes from cache — skipping pre-generation")
                        await MainActor.run { logRunSummary() }
                    } else if cachedRoutes.count < maxRoutesToGenerate {
                        print("📦 Only \(inBandAfterCache)/\(targetInBandRoutes) in-band routes — will pre-generate more")
                        preGenerateRemainingRoutes()
                    } else {
                        print("📦 All \(cachedRoutes.count) routes loaded from cache")
                        await MainActor.run { logRunSummary() }
                        // v1.6.46: Background refresh - search for potentially better routes
                        backgroundRefreshRoutes(at: userLocation.coordinate, duration: selectedDuration)
                    }
                    
                    return
                }
                
                print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - CACHE MISS - generating fresh route...")
                print("ROUTE_PHASE phase=cache_miss_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                print("ROUTES_SOURCE | source=live_generation duration=\(selectedDuration) (no database/cache hit, generating routes now)")
                await MainActor.run { runSummarySource = "live_generation" }
                
                // 🔧 DEBUG: Database-only mode - don't generate routes if database doesn't have them
                if RoutingToggles.databaseOnlyMode {
                    print("🚫 [DATABASE-ONLY MODE] Cache miss - NOT falling back to real-time route generation")
                    print("🚫 [DATABASE-ONLY MODE] This confirms the database does not have routes for:")
                    print("   📍 Location: (\(String(format: "%.5f", userLocation.coordinate.latitude)), \(String(format: "%.5f", userLocation.coordinate.longitude)))")
                    print("   ⏱️ Duration: \(selectedDuration)min")
                    await MainActor.run {
                        isGenerating = false
                        errorMessage = "DATABASE-ONLY MODE: No routes found in database for \(selectedDuration)min. Check console logs for database contents."
                    }
                    return
                }
                
                // v1.8.7: Loading screen Task already started at the beginning of Task block
                
                do {
                    // If prefetch is in progress, wait up to 3s for it to reach a minimum POI count (faster than starting a new fetch)
                    var (prefetchCount, isPrefetching) = await MainActor.run { (prefetchedPOIs.count, isPrefetchingPOIs) }
                    if prefetchCount == 0 && isPrefetching {
                        let waitStart = Date()
                        for _ in 0..<15 {
                            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                            (prefetchCount, isPrefetching) = await MainActor.run { (prefetchedPOIs.count, isPrefetchingPOIs) }
                            if prefetchCount >= 15 || !isPrefetching { break }
                            if Date().timeIntervalSince(waitStart) >= 3.0 { break }
                        }
                        if prefetchCount > 0 {
                            print("⏱️ Pre-fetch ready after \(String(format: "%.1f", Date().timeIntervalSince(waitStart)))s wait (\(prefetchCount) POIs)")
                        }
                    }
                    // Use pre-fetched POIs if available (faster!)
                    let poisToUse = await MainActor.run { prefetchedPOIs.isEmpty ? nil : prefetchedPOIs }
                    if let pois = poisToUse {
                        print("⚡ Using \(pois.count) pre-fetched POIs for instant route generation")
                    } else {
                        print("⚠️ No pre-fetched POIs - will fetch during generation (slower)")
                    }
                    
                    print("[ROUTE_GEN] ⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Starting route generation (target \(selectedDuration)min)...")
                    print("ROUTE_PHASE phase=route_gen_call_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    let routeGenStartTime = Date()
                    let userLoc = userLocation.coordinate
                    // #region agent log
                    do {
                        let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:route_gen_start", "message": "route_gen_start", "data": ["selectedDuration": selectedDuration], "hypothesisId": "H1"]
                        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                    } catch {}
                    // #endregion agent log
                    
                    // Google fallback: trigger when MapKit is throttling (so we don't wait 30s) or after max 30s. Only show preview when result is within 10% of target; iterate with tighter/wider waypoints until sensible or max attempts.
                    let fallbackTask = Task {
                        let fallbackStart = Date()
                        let maxWaitSeconds = 30.0
                        let pollInterval: UInt64 = 2_000_000_000 // 2s
                        var shouldRunFallback = false
                        while Date().timeIntervalSince(fallbackStart) < maxWaitSeconds {
                            let stillGenerating = await MainActor.run { showLoadingScreen && !routeGenerationComplete && isGenerating }
                            guard stillGenerating else {
                                // #region agent log
                                do {
                                    let elapsed = Date().timeIntervalSince(fallbackStart)
                                    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_exit", "message": "fallback_exit", "data": ["reason": "stillGenerating_false", "elapsed": String(format: "%.1f", elapsed)], "hypothesisId": "H2"]
                                    if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                                } catch {}
                                // #endregion agent log
                                return
                            }
                            let throttling = await mapsService.shouldPauseBackgroundGeneration()
                            let elapsed = Date().timeIntervalSince(fallbackStart)
                            // #region agent log
                            do {
                                let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_poll", "message": "fallback_poll", "data": ["elapsed": String(format: "%.1f", elapsed), "throttling": throttling, "stillGenerating": true], "hypothesisId": "H2"]
                                if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                            } catch {}
                            // #endregion agent log
                            if throttling {
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] MapKit throttling detected at \(String(format: "%.1f", elapsed))s — triggering Google fallback")
                                // #region agent log
                                do {
                                    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_exit", "message": "fallback_exit", "data": ["reason": "throttling", "elapsed": String(format: "%.1f", elapsed)], "hypothesisId": "H2"]
                                    if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                                } catch {}
                                // #endregion agent log
                                shouldRunFallback = true
                                break
                            }
                            if elapsed >= maxWaitSeconds - 0.5 {
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] Max wait \(Int(maxWaitSeconds))s reached — triggering Google fallback")
                                // #region agent log
                                do {
                                    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_exit", "message": "fallback_exit", "data": ["reason": "max_wait_30s", "elapsed": String(format: "%.1f", elapsed)], "hypothesisId": "H2"]
                                    if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                                } catch {}
                                // #endregion agent log
                                shouldRunFallback = true
                                break
                            }
                            try? await Task.sleep(nanoseconds: pollInterval)
                        }
                        let shouldRun = await MainActor.run { showLoadingScreen && !routeGenerationComplete && isGenerating }
                        guard shouldRun, shouldRunFallback, mapsService.hasAPIKey else {
                            // #region agent log
                            do {
                                let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_abort", "message": "fallback_abort", "data": ["shouldRun": shouldRun, "shouldRunFallback": shouldRunFallback, "hasAPIKey": mapsService.hasAPIKey], "hypothesisId": "H3"]
                                if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                            } catch {}
                            // #endregion agent log
                            return
                        }
                        // #region agent log
                        let fallbackDuration = await MainActor.run { selectedDuration }
                        do {
                            let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_google_start", "message": "fallback_google_start", "data": ["duration": fallbackDuration], "hypothesisId": "H3"]
                            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                        } catch {}
                        // #endregion agent log
                        var places = await MainActor.run { prefetchedPOIs.isEmpty ? [] : prefetchedPOIs }
                        if places.isEmpty {
                            let duration = await MainActor.run { selectedDuration }
                            let radius = max(800, duration * 80)
                            do {
                                places = try await withTimeout(seconds: 5) {
                                    try await mapsService.findNearbyPlaces(
                                        location: userLoc,
                                        radiusMeters: radius,
                                        skipGoogle: false,
                                        minimumForEarlyReturn: 5,
                                        maxWaitSecondsForFirstRoute: 5
                                    )
                                }
                            } catch {
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] POI fetch failed or timed out — skipping")
                                return
                            }
                        }
                        if places.isEmpty { return }
                        let duration = await MainActor.run { selectedDuration }
                        let minAcceptable = max(1, Int(Double(duration) * 0.9))
                        let maxAcceptable = Int(Double(duration) * 1.1)
                        let sortedByDistance = places.sorted { distanceBetweenCoordinates(userLoc, $0.coordinate) < distanceBetweenCoordinates(userLoc, $1.coordinate) }
                        let tightBands: [(Double, Double)] = [(10, 28), (8, 22), (6, 18)]
                        let wideBands: [(Double, Double)] = [(28, 999), (32, 999), (36, 999)]
                        var tightIndex = 0
                        var wideIndex = 0
                        let fallbackLoopStart = Date()
                        for attempt in 0..<4 {
                            let attemptElapsed = Date().timeIntervalSince(fallbackLoopStart)
                            print("[ROUTE_GEN] ⏱️ [FALLBACK] Attempt \(attempt + 1) starting at +\(String(format: "%.1f", attemptElapsed))s (Google call)")
                            let minMult: Double
                            let maxMult: Double
                            if attempt == 0 {
                                // Cap first attempt so we don't pick POIs that produce 88min (align with main out-of-band: maxMult 30)
                                minMult = 24.0
                                maxMult = 30.0
                            } else if tightIndex > 0 {
                                let band = tightBands[min(tightIndex - 1, tightBands.count - 1)]
                                minMult = band.0
                                maxMult = band.1
                            } else if wideIndex > 0 {
                                let band = wideBands[min(wideIndex - 1, wideBands.count - 1)]
                                minMult = band.0
                                maxMult = band.1
                            } else {
                                minMult = 24.0
                                maxMult = 999.0
                            }
                            let minDist = Double(duration) * minMult
                            let maxDist = Double(duration) * maxMult
                            let pool = sortedByDistance.filter { d in
                                let dist = distanceBetweenCoordinates(userLoc, d.coordinate)
                                return dist >= minDist && dist <= maxDist
                            }
                            let candidatePool = pool.isEmpty ? sortedByDistance : pool
                            let count = duration <= 15 ? 1 : min(2, candidatePool.count)
                            let selected: [PlaceResult]
                            if count == 1 {
                                selected = Array(candidatePool.prefix(1))
                            } else {
                                let minSeparation = 400.0
                                let first = candidatePool.first
                                if let first = first, let second = candidatePool.first(where: { p in
                                    p.placeId != first.placeId && distanceBetweenCoordinates(first.coordinate, p.coordinate) >= minSeparation
                                }) {
                                    selected = [first, second]
                                } else {
                                    selected = Array(candidatePool.prefix(2))
                                }
                            }
                            let markers = RouteConversionHelper.markersFromPlaces(selected, origin: userLoc)
                            let minimalRoute = WalkingRoute(
                                name: "Quick route",
                                description: "About \(duration) min",
                                durationMinutes: 0,
                                distanceMeters: 0,
                                difficulty: .moderate,
                                isIndoor: false,
                                isAccessible: true,
                                landmarks: ["Start"] + selected.map(\.name) + ["Return"],
                                icon: "location.fill",
                                color: .tealAccent,
                                qrMarkers: markers,
                                routeType: .local,
                                encodedPolyline: nil,
                                walkingDirections: [],
                                usedOSRMRouting: false,
                                isFromPrePopulatedDatabase: false,
                                travelToStartMinutes: nil
                            )
                            guard let refreshed = await mapsService.refreshRouteWithGoogleOnly(route: minimalRoute, userLocation: userLoc) else { continue }
                            let actualMin = refreshed.durationMinutes
                            if actualMin >= minAcceptable && actualMin <= maxAcceptable {
                                let placesForData = refreshed.qrMarkers.map { m in
                                    PlaceResult(
                                        placeId: m.id.uuidString,
                                        name: m.name,
                                        vicinity: m.location,
                                        geometry: PlaceGeometry(location: PlaceLocation(lat: m.coordinate.latitude, lng: m.coordinate.longitude)),
                                        types: ["point_of_interest"],
                                        source: .unknown
                                    )
                                }
                                var generatedData = GeneratedRoute(
                                    places: placesForData,
                                    polyline: refreshed.encodedPolyline ?? "",
                                    distanceMeters: refreshed.distanceMeters,
                                    durationSeconds: refreshed.durationMinutes * 60,
                                    legs: []
                                )
                                let enrichedData = mapsService.addOnRoutePOIsIfNeeded(generatedData, origin: userLoc, candidatePOIs: places, durationMinutes: duration)
                                generatedData = enrichedData
                                let enrichedMarkers = RouteConversionHelper.markersFromPlaces(generatedData.places, origin: userLoc)
                                let waypointInfos = generatedData.places.map {
                                    GeminiService.WaypointInfo(name: $0.name, types: $0.types ?? [], vicinity: $0.vicinity)
                                }
                                let fallbackDifficulty: RouteDifficulty = actualMin <= 10 ? .easy : (actualMin <= 20 ? .moderate : .challenging)
                                let beforeGemini = Date().timeIntervalSince(fallbackLoopStart)
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] In-band at +\(String(format: "%.1f", beforeGemini))s — enriching done, calling Gemini for name/description")
                                let routeContent = await GeminiService.shared.generateRouteContent(
                                    waypoints: waypointInfos,
                                    durationMinutes: actualMin,
                                    distanceMeters: refreshed.distanceMeters,
                                    difficulty: fallbackDifficulty
                                )
                                let displayRoute = WalkingRoute(
                                    name: routeContent.name,
                                    description: routeContent.description,
                                    durationMinutes: refreshed.durationMinutes,
                                    distanceMeters: refreshed.distanceMeters,
                                    difficulty: refreshed.difficulty,
                                    isIndoor: refreshed.isIndoor,
                                    isAccessible: refreshed.isAccessible,
                                    landmarks: ["Start"] + generatedData.places.map(\.name) + ["Return"],
                                    icon: refreshed.icon,
                                    color: refreshed.color,
                                    qrMarkers: enrichedMarkers,
                                    routeType: refreshed.routeType,
                                    encodedPolyline: refreshed.encodedPolyline,
                                    walkingDirections: refreshed.walkingDirections,
                                    usedOSRMRouting: refreshed.usedOSRMRouting,
                                    isFromPrePopulatedDatabase: refreshed.isFromPrePopulatedDatabase,
                                    travelToStartMinutes: refreshed.travelToStartMinutes
                                )
                                await MainActor.run {
                                    // Don't replace if main already delivered — user may already be viewing route 1 (e.g. 28min); add fallback as route 2 if different
                                    let mainAlreadyShown = routeGenerationComplete && !allRoutes.isEmpty
                                    if mainAlreadyShown {
                                        let newPlaceIds = Set(generatedData.places.map(\.placeId))
                                        let isDuplicate = shownPlaceIdSets.contains(newPlaceIds)
                                        if !isDuplicate {
                                            let cappedFallback = displayRoute.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                                            let added = appendRouteIfAllowed(
                                                route: cappedFallback,
                                                data: generatedData,
                                                isFromGoogle: true,
                                                source: "google-30s-fallback"
                                            )
                                            if added {
                                                shownPlaceIdSets.append(newPlaceIds)
                                                registerRouteSignature(places: generatedData.places, distanceMeters: refreshed.distanceMeters)
                                                logRoutePreviewSummary()
                                            }
                                        } else {
                                            print("[ROUTE_GEN] ⏱️ [FALLBACK] Route within 10% (\(actualMin)min) — duplicate, not replacing main")
                                        }
                                    } else {
                                        currentRouteIsFromGoogle30sFallback = true
                                        let cappedFallback = displayRoute.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                                        generatedRoute = cappedFallback
                                        generatedRouteData = generatedData
                                        routeGenerationComplete = true
                                        isGenerating = false
                                        showLoadingScreen = false
                                        lastValidRoute = cappedFallback
                                        lastValidRouteData = generatedData
                                        allRoutes = [(cappedFallback, generatedData, false, true)]
                                        currentRouteIndex = 0
                                        preGenerationComplete = true
                                        isPreGeneratingRoutes = false
                                        viewedRouteIndices = [0]
                                        shownPlaceIdSets = [Set(generatedData.places.map(\.placeId))]
                                        routeRefreshStatus = nil
                                        registerRouteSignature(places: generatedData.places, distanceMeters: refreshed.distanceMeters)
                                        showMapPreview = true
                                        logRoutePreviewSummary()
                                        print("[ROUTE_GEN] ⏱️ [FALLBACK] Route within 10% (\(actualMin)min) — skip refresh on Let's Go")
                                    }
                                    // #region agent log
                                    do {
                                        let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_preview", "message": "fallback_preview_shown", "data": ["actualMin": actualMin, "target": duration], "hypothesisId": "H4"]
                                        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                                    } catch {}
                                    do {
                                        let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:preview_route_shown", "message": "preview_route_shown", "data": ["source": "fallback", "targetDuration": duration, "actualDuration": actualMin, "inBand10pct": true], "hypothesisId": "H6"]
                                        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                                    } catch {}
                                    // #endregion agent log
                                }
                                return
                            }
                            if actualMin > maxAcceptable {
                                tightIndex += 1
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] Attempt \(attempt + 1): \(actualMin)min too long (target \(duration), 10% = \(minAcceptable)–\(maxAcceptable)) — tightening")
                            } else {
                                wideIndex += 1
                                print("[ROUTE_GEN] ⏱️ [FALLBACK] Attempt \(attempt + 1): \(actualMin)min too short — widening next")
                            }
                        }
                        print("[ROUTE_GEN] ⏱️ [FALLBACK] No route within 10% after 4 attempts — not showing fallback")
                        // #region agent log
                        do {
                            let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:fallback_preview", "message": "fallback_preview_skipped", "data": ["reason": "no_route_in_10pct_after_4"], "hypothesisId": "H4"]
                            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                        } catch {}
                        // #endregion agent log
                    }
                    
                    // v1.9.51: Collect excluded POIs for duplicate detection (empty for first route)
                    let excludedPlaceIds: Set<String> = []
                    let excludedPOIs: [PlaceResult] = []
                    
                    // v2.0.2: Use topology-safe route generation (guarantees a route, especially for short walks)
                    let result = try await mapsService.generateRouteTopologySafe(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        excludePOIs: excludedPOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                        prefetchedPOIs: poisToUse
                    )
                    
                    let keptFallback = await MainActor.run(body: { currentRouteIsFromGoogle30sFallback })
                    if keptFallback {
                        print("[ROUTE_GEN] ⏱️ [30s FALLBACK] Main generation finished late — keeping Google fallback route")
                        // #region agent log
                        do {
                            let routeGenTime = Date().timeIntervalSince(routeGenStartTime)
                            let totalTime = Date().timeIntervalSince(generateStartTime)
                            let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:main_route_done", "message": "main_route_done", "data": ["keptFallback": true, "routeGenTime": String(format: "%.1f", routeGenTime), "totalTime": String(format: "%.1f", totalTime)], "hypothesisId": "H5"]
                            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                        } catch {}
                        // #endregion agent log
                        return
                    }
                    
                    let routeGenTime = Date().timeIntervalSince(routeGenStartTime)
                    let totalTime = Date().timeIntervalSince(generateStartTime)
                    let waypointNamesReady = result.places.map { $0.name }.joined(separator: " → ")
                    print("[ROUTE_GEN] ROUTE_PHASE phase=route_ready_elapsed elapsed_sec=\(String(format: "%.2f", totalTime)) waypoints=[\(waypointNamesReady)] duration=\(result.durationSeconds / 60)min distance=\(result.distanceMeters)m")
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Route generated in \(String(format: "%.2f", routeGenTime))s")
                    print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                    print("⏱️ [TIMING] ROUTE GENERATION SUMMARY")
                    print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                    print("⏱️ [TIMING] Total time: \(String(format: "%.2f", totalTime))s")
                    print("⏱️ [TIMING] Route generation: \(String(format: "%.2f", routeGenTime))s")
                    if let prefetched = poisToUse {
                        let googleCount = prefetched.filter { $0.source == .google }.count
                        let freeCount = prefetched.count - googleCount
                        print("⏱️ [TIMING] POI sources: \(freeCount) free (Apple/OSM/Geograph), \(googleCount) Google")
                        if googleCount == 0 {
                            print("⏱️ [TIMING] 💰 Cost saved: Google Places skipped")
                        }
                    }
                    print("⏱️ [TIMING] Route: \(result.durationSeconds / 60)min, \(result.places.count) waypoints")
                    print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                    // #region agent log
                    do {
                        let totalTime = Date().timeIntervalSince(generateStartTime)
                        let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:main_route_done", "message": "main_route_done", "data": ["keptFallback": false, "routeGenTime": String(format: "%.1f", routeGenTime), "totalTime": String(format: "%.1f", totalTime), "resultMin": result.durationSeconds / 60], "hypothesisId": "H5"]
                        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                    } catch {}
                    // #endregion agent log
                    
                    // Validate result
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        await MainActor.run {
                            errorMessage = "Could not find suitable places nearby. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                        }
                        return
                    }
                    
                    // v2.1.7: Filter close waypoints from fresh routes (100m under 25min, 200m for 25+ min to avoid clustered village waypoints).
                    let filteredResult = mapsService.filterCloseWaypointsSync(from: result, durationMinutes: selectedDuration, origin: userLocation.coordinate)
                    
                    print("ROUTE_PHASE phase=markers_start_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Creating markers...")
                    
                    // Create markers from places (needs MainActor for some operations)
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(filteredResult.places, origin: userLocation.coordinate)
                    }
                    print("ROUTE_PHASE phase=markers_done_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    
                    // Ensure we have at least one marker
                    guard !markers.isEmpty else {
                        await MainActor.run {
                            errorMessage = "No discovery spots could be created. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                        }
                        return
                    }
                    
                    // v1.9.49: Start route naming in parallel (Optimization 4: Parallel Gemini Naming)
                    // Start naming as soon as we have POIs, in parallel with directions/markers
                    let waypointInfos = filteredResult.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    
                    // Try Gemini first for Route 1 (3s timeout), then fall back to template
                    let namingTask = Task {
                        let difficulty: RouteDifficulty = filteredResult.durationMinutes <= 10 ? .easy : (filteredResult.durationMinutes <= 20 ? .moderate : .challenging)
                        return await GeminiService.shared.generateRouteContent(
                            waypoints: waypointInfos,
                            durationMinutes: filteredResult.durationMinutes,
                            distanceMeters: filteredResult.distanceMeters,
                            difficulty: difficulty
                        )
                    }
                    
                    print("ROUTE_PHASE phase=directions_start_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Extracting directions...")
                    
                    // Extract walking directions from OSRM/Google legs (in parallel with naming)
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: filteredResult.legs, waypoints: filteredResult.places)
                    }
                    
                    // v1.6.14: If no directions (OSRM was used), get them from Apple MapKit
                    if directions.isEmpty && !filteredResult.places.isEmpty {
                        print("🍎 No directions from route - getting from MapKit...")
                        let mapKitStartTime = Date()
                        let waypointCoords = filteredResult.places.map { $0.coordinate }
                        let waypointNames = filteredResult.places.map { $0.name }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate,
                            waypointNames: waypointNames
                        )
                        print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - MapKit directions took \(String(format: "%.2f", Date().timeIntervalSince(mapKitStartTime)))s")
                    }
                    print("ROUTE_PHASE phase=directions_done_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = filteredResult.durationMinutes <= 10 ? .easy : (filteredResult.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    // Get route name (Gemini or template fallback)
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Getting route name (parallel)...")
                    let routeContent = await namingTask.value
                    print("⚡ Route 1: '\(routeContent.name)' (Gemini or template)")
                    
                    let routeName = routeContent.name
                    let description = routeContent.description
                    
                    // v2.1.0: Debug logging for polyline quality at route creation
                    let polylinePointCount = filteredResult.polyline.isEmpty ? 0 : PolylineDecoder.decode(filteredResult.polyline).count
                    if filteredResult.polyline.isEmpty {
                        print("🚨 [ROUTE CREATION] '\(routeName)': NO POLYLINE from route generation!")
                        print("🚨 [ROUTE CREATION] Route will show straight lines between waypoints")
                    } else if polylinePointCount < 10 {
                        print("⚠️ [ROUTE CREATION] '\(routeName)': Low-quality polyline (\(polylinePointCount) points)")
                    } else {
                        print("✅ [ROUTE CREATION] '\(routeName)': Good polyline with \(polylinePointCount) points")
                    }
                    
                    // Create the walking route with actual polyline and directions
                    let localRoute = WalkingRoute(
                        name: routeName,
                        description: description,
                        durationMinutes: max(1, filteredResult.durationMinutes),
                        distanceMeters: filteredResult.distanceMeters,
                        difficulty: routeDifficulty,
                        isIndoor: false,
                        isAccessible: true,
                        landmarks: ["Start"] + filteredResult.places.map { $0.name } + ["Return"],
                        icon: "location.fill",
                        color: .tealAccent,
                        qrMarkers: markers,
                        routeType: .local,
                        trimmed: filteredResult.polyline,
                        walkingDirections: directions,
                        usedOSRMRouting: filteredResult.usedOSRM  // v1.7.1: Track OSRM usage for polyline refresh
                    )
                    
                    // v2.1.x: Snap POIs to road and replace polyline so route doesn’t go into buildings (e.g. school grounds)
                    var displayRoute = localRoute
                    var mainRouteDurationFromGoogle = false
                    print("ROUTE_PHASE phase=road_snap_start_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    if let snappedRoute = await mapsService.refreshRouteWithGoogleOnly(route: localRoute, userLocation: userLocation.coordinate) {
                        displayRoute = snappedRoute
                        mainRouteDurationFromGoogle = true
                        print("🛤️ [ROUTE CREATION] Applied road snap — polyline and markers now on road (no off-road POI)")
                    }
                    displayRoute = Self.applyDurationSanityCap(displayRoute, targetDurationMinutes: selectedDuration)
                    print("ROUTE_PHASE phase=road_snap_done_elapsed elapsed_sec=\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))")
                    
                    // FINAL SAFETY CHECK: Deduplicate before storing (use filteredResult)
                    print("🛡️ ROUTE SELECTION VIEW: Final deduplication check before storing route")
                    let deduplicatedResult = await MainActor.run {
                        // Access GoogleMapsService to deduplicate
                        let service = GoogleMapsService.shared
                        // Create a temporary route to use finalizeRouteDedup (use filteredResult)
                        let tempRoute = GeneratedRoute(
                            places: filteredResult.places,
                            polyline: filteredResult.polyline,
                            distanceMeters: filteredResult.distanceMeters,
                            durationSeconds: filteredResult.durationSeconds,
                            legs: filteredResult.legs
                        )
                        // This will call deduplicateRoutePlaces internally
                        return service.finalizeRouteDedupForView(tempRoute)
                    }
                    
                    // When main result is outside acceptable band, try Google in background so we show route 1 immediately.
                    var googleSecondRoute: (route: WalkingRoute, data: GeneratedRoute)? = nil
                    let (minAcceptable, maxAcceptable) = Self.minMaxAcceptableMinutes(for: selectedDuration)
                    var mainActualMin = deduplicatedResult.durationMinutes
                    var mainInBand = Self.isRouteInBand(displayRoute, selectedDuration: selectedDuration)
                    let mainWaypointNames = filteredResult.places.map { $0.name }.joined(separator: " → ")
                    print("[ROUTE_GEN] Main route: \(mainActualMin)min for \(selectedDuration)min target (band \(minAcceptable)–\(maxAcceptable)) inBand=\(mainInBand) waypoints=[\(mainWaypointNames)]")
                    var mainRoutePreviewSource = filteredResult.usedOSRM ? "osrm" : "mapkit"
                    // Always re-measure preview with Google when we have key and waypoints so preview time matches Google (what user sees after Let's Go). If Google fails, keep existing duration.
                    if mapsService.hasAPIKey && !filteredResult.places.isEmpty {
                        // #region agent log
                        let _liveOrigin = userLocation.coordinate
                        let _liveEntry: [String: Any] = [
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                            "location": "RouteSelectionView:live_main:before_google",
                            "message": "Attempting Google re-measure for live main route",
                            "runId": "run1",
                            "hypothesisId": "H1_H4",
                            "data": [
                                "routeName": displayRoute.name,
                                "origin_lat": _liveOrigin.latitude,
                                "origin_lng": _liveOrigin.longitude,
                                "waypointNames": filteredResult.places.map { $0.name }
                            ]
                        ]
                        if let _ld = try? JSONSerialization.data(withJSONObject: _liveEntry), let _ls = String(data: _ld, encoding: .utf8) { _ls.appendLine(toFile: _agentLogPath()) }
                        // #endregion agent log
                        if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: filteredResult.places, targetDurationMinutes: selectedDuration) {
                            mainRoutePreviewSource = "google"
                            let googleDurationMin = googleResult.durationSeconds / 60
                            displayRoute = WalkingRoute(
                                name: displayRoute.name,
                                description: displayRoute.description,
                                durationMinutes: googleDurationMin,
                                distanceMeters: googleResult.distanceMeters,
                                difficulty: displayRoute.difficulty,
                                isIndoor: displayRoute.isIndoor,
                                isAccessible: displayRoute.isAccessible,
                                landmarks: displayRoute.landmarks,
                                icon: displayRoute.icon,
                                color: displayRoute.color,
                                qrMarkers: displayRoute.qrMarkers,
                                routeType: displayRoute.routeType,
                                trimmed: displayRoute.trimmed,
                                walkingDirections: displayRoute.walkingDirections,
                                usedOSRMRouting: displayRoute.usedOSRMRouting,
                                isFromPrePopulatedDatabase: displayRoute.isFromPrePopulatedDatabase,
                                travelToStartMinutes: displayRoute.travelToStartMinutes
                            )
                            displayRoute = Self.applyDurationSanityCap(displayRoute, targetDurationMinutes: selectedDuration)
                            mainActualMin = displayRoute.durationMinutes
                            mainInBand = Self.isRouteInBand(displayRoute, selectedDuration: selectedDuration)
                            let remeasureWaypoints = filteredResult.places.map { $0.name }.joined(separator: " → ")
                            print("[ROUTE_GEN] Main route duration re-measured with Google: \(mainActualMin)min (display only, was \(deduplicatedResult.durationMinutes)min) waypoints=[\(remeasureWaypoints)]")
                        } else {
                            // #region agent log
                            let _liveNil: [String: Any] = [
                                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                                "location": "RouteSelectionView:live_main:google_nil",
                                "message": "Google re-measure returned nil for live main route",
                                "runId": "run1",
                                "hypothesisId": "H4",
                                "data": ["routeName": displayRoute.name, "waypointNames": filteredResult.places.map { $0.name }]
                            ]
                            if let _lnd = try? JSONSerialization.data(withJSONObject: _liveNil), let _lns = String(data: _lnd, encoding: .utf8) { _lns.appendLine(toFile: _agentLogPath()) }
                            // #endregion agent log
                        }
                    }
                    if !mainInBand && mapsService.hasAPIKey {
                        var placesForOutOfBand: [PlaceResult] = poisToUse ?? []
                        if placesForOutOfBand.isEmpty {
                            placesForOutOfBand = await MainActor.run { prefetchedPOIs.isEmpty ? [] : prefetchedPOIs }
                        }
                        if placesForOutOfBand.isEmpty {
                            // No prefetched POIs — fetch on demand so we can try for an in-band route (e.g. main was 16 min, we want 20–30)
                            print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] No prefetched POIs — fetching on demand...")
                            let existingFromRoute = deduplicatedResult.places
                            let newGooglePOIs = await mapsService.fetchGooglePOIsOnDemand(
                                location: userLocation.coordinate,
                                radiusMeters: 2500,
                                existingPOIs: existingFromRoute
                            )
                            placesForOutOfBand = existingFromRoute + newGooglePOIs
                            if !placesForOutOfBand.isEmpty {
                                await MainActor.run { prefetchedPOIs = placesForOutOfBand }
                                print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Got \(placesForOutOfBand.count) POIs for background attempt")
                            }
                        }
                        if !placesForOutOfBand.isEmpty {
                            print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Will try Google in background (main=\(mainActualMin)min, placesCount=\(placesForOutOfBand.count))")
                            let duration = selectedDuration
                            let coord = userLocation.coordinate
                            Task {
                                let sortedByDistance = placesForOutOfBand.sorted { distanceBetweenCoordinates(coord, $0.coordinate) < distanceBetweenCoordinates(coord, $1.coordinate) }
                                let maxAttempts = min(25, 15 + duration / 5)
                                print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Trying closest-first Google round-trip (\(sortedByDistance.count) POIs, max \(maxAttempts) single-POI attempts)")
                                func addOutOfBandRoute(refreshed: WalkingRoute, enrichedData: GeneratedRoute, cappedGoogleRoute: WalkingRoute) async {
                                    let waypointsStr = enrichedData.places.map { $0.name }.joined(separator: " → ")
                                    let distKm = String(format: "%.1f", Double(cappedGoogleRoute.distanceMeters) / 1000)
                                    await MainActor.run {
                                        let added = appendRouteIfAllowed(
                                            route: cappedGoogleRoute,
                                            data: enrichedData,
                                            isFromGoogle: true,
                                            source: "main-out-of-band"
                                        )
                                        if added {
                                            shownPlaceIdSets.append(Set(enrichedData.places.map { $0.placeId }))
                                            registerRouteSignature(places: enrichedData.places, distanceMeters: refreshed.distanceMeters)
                                            currentRouteIndex = allRoutes.count - 1
                                            generatedRoute = cappedGoogleRoute
                                            generatedRouteData = enrichedData
                                            if !viewedRouteIndices.contains(currentRouteIndex) { viewedRouteIndices.insert(currentRouteIndex) }
                                            logRoutePreviewSummary()
                                        }
                                    }
                                }
                                func buildEnrichedAndRoute(refreshed: WalkingRoute, selected: [PlaceResult]) -> (WalkingRoute, GeneratedRoute) {
                                    let placesForData = refreshed.qrMarkers.map { m in
                                        PlaceResult(
                                            placeId: m.id.uuidString,
                                            name: m.name,
                                            vicinity: m.location,
                                            geometry: PlaceGeometry(location: PlaceLocation(lat: m.coordinate.latitude, lng: m.coordinate.longitude)),
                                            types: ["point_of_interest"],
                                            source: .unknown
                                        )
                                    }
                                    let googleResult = GeneratedRoute(
                                        places: placesForData,
                                        polyline: refreshed.encodedPolyline ?? "",
                                        distanceMeters: refreshed.distanceMeters,
                                        durationSeconds: refreshed.durationMinutes * 60,
                                        legs: []
                                    )
                                    let enrichedData = mapsService.addOnRoutePOIsIfNeeded(googleResult, origin: coord, candidatePOIs: placesForOutOfBand, durationMinutes: duration)
                                    let enrichedMarkers = RouteConversionHelper.markersFromPlaces(enrichedData.places, origin: coord)
                                    let googleRoute = WalkingRoute(
                                        name: routeName,
                                        description: description,
                                        durationMinutes: refreshed.durationMinutes,
                                        distanceMeters: refreshed.distanceMeters,
                                        difficulty: refreshed.difficulty,
                                        isIndoor: refreshed.isIndoor,
                                        isAccessible: refreshed.isAccessible,
                                        landmarks: ["Start"] + enrichedData.places.map(\.name) + ["Return"],
                                        icon: refreshed.icon,
                                        color: refreshed.color,
                                        qrMarkers: enrichedMarkers,
                                        routeType: refreshed.routeType,
                                        encodedPolyline: refreshed.encodedPolyline,
                                        walkingDirections: refreshed.walkingDirections,
                                        usedOSRMRouting: false,
                                        isFromPrePopulatedDatabase: false,
                                        travelToStartMinutes: refreshed.travelToStartMinutes
                                    )
                                    let cappedGoogleRoute = googleRoute.withDurationSanityCap(targetDurationMinutes: duration)
                                    return (cappedGoogleRoute, enrichedData)
                                }
                                let singlePOILimit = min(maxAttempts, sortedByDistance.count)
                                for index in 0..<singlePOILimit {
                                    guard index < sortedByDistance.count else { break }
                                    let selected = [sortedByDistance[index]]
                                    let markers = RouteConversionHelper.markersFromPlaces(selected, origin: coord)
                                    let minimalRoute = WalkingRoute(
                                        name: routeName,
                                        description: description,
                                        durationMinutes: 0,
                                        distanceMeters: 0,
                                        difficulty: routeDifficulty,
                                        isIndoor: false,
                                        isAccessible: true,
                                        landmarks: ["Start"] + selected.map(\.name) + ["Return"],
                                        icon: "location.fill",
                                        color: .tealAccent,
                                        qrMarkers: markers,
                                        routeType: .local,
                                        encodedPolyline: nil,
                                        walkingDirections: [],
                                        usedOSRMRouting: false,
                                        isFromPrePopulatedDatabase: false,
                                        travelToStartMinutes: nil
                                    )
                                    let refreshedOpt = await mapsService.refreshRouteWithGoogleOnly(route: minimalRoute, userLocation: coord)
                                    if let refreshed = refreshedOpt {
                                        let candidateRoute = WalkingRoute(name: refreshed.name, description: refreshed.description, durationMinutes: refreshed.durationMinutes, distanceMeters: refreshed.distanceMeters, difficulty: refreshed.difficulty, isIndoor: refreshed.isIndoor, isAccessible: refreshed.isAccessible, landmarks: refreshed.landmarks, icon: refreshed.icon, color: refreshed.color, qrMarkers: refreshed.qrMarkers, routeType: refreshed.routeType, trimmed: refreshed.trimmed, walkingDirections: refreshed.walkingDirections, usedOSRMRouting: false, isFromPrePopulatedDatabase: false, travelToStartMinutes: refreshed.travelToStartMinutes)
                                        guard Self.isRouteInBand(candidateRoute, selectedDuration: duration) else {
                                            print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] POI \(index) \(selected[0].name): \(refreshed.durationMinutes)min (outside band)")
                                            continue
                                        }
                                        let (cappedGoogleRoute, enrichedData) = buildEnrichedAndRoute(refreshed: refreshed, selected: selected)
                                        print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] In-band at POI index \(index) (\(selected[0].name)) in \(index + 1) attempts")
                                        await addOutOfBandRoute(refreshed: refreshed, enrichedData: enrichedData, cappedGoogleRoute: cappedGoogleRoute)
                                        return
                                    } else {
                                        print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] POI \(index) \(selected[0].name): Google returned nil")
                                    }
                                }
                                print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] No in-band from closest-first, trying band-based fallback...")
                                let bands = Self.outOfBandWaypointBands(for: duration)
                                for attempt in 0..<bands.count {
                                    let (minMult, maxMult) = bands[attempt]
                                    let minDist = Double(duration) * minMult
                                    let maxDist = Double(duration) * maxMult
                                    let pool = sortedByDistance.filter { d in
                                        let dist = distanceBetweenCoordinates(coord, d.coordinate)
                                        return dist >= minDist && dist <= maxDist
                                    }
                                    let candidatePool = pool.isEmpty ? sortedByDistance : pool
                                    let count = duration <= 15 ? 1 : min(2, candidatePool.count)
                                    let selected: [PlaceResult]
                                    if count == 1 {
                                        selected = Array(candidatePool.prefix(1))
                                    } else {
                                        let minSeparation = 400.0
                                        let first = candidatePool.first
                                        if let first = first, let second = candidatePool.first(where: { p in
                                            p.placeId != first.placeId && distanceBetweenCoordinates(first.coordinate, p.coordinate) >= minSeparation
                                        }) {
                                            selected = [first, second]
                                        } else {
                                            selected = Array(candidatePool.prefix(2))
                                        }
                                    }
                                    let markers = RouteConversionHelper.markersFromPlaces(selected, origin: coord)
                                    let minimalRoute = WalkingRoute(
                                        name: routeName,
                                        description: description,
                                        durationMinutes: 0,
                                        distanceMeters: 0,
                                        difficulty: routeDifficulty,
                                        isIndoor: false,
                                        isAccessible: true,
                                        landmarks: ["Start"] + selected.map(\.name) + ["Return"],
                                        icon: "location.fill",
                                        color: .tealAccent,
                                        qrMarkers: markers,
                                        routeType: .local,
                                        encodedPolyline: nil,
                                        walkingDirections: [],
                                        usedOSRMRouting: false,
                                        isFromPrePopulatedDatabase: false,
                                        travelToStartMinutes: nil
                                    )
                                    let refreshedOpt = await mapsService.refreshRouteWithGoogleOnly(route: minimalRoute, userLocation: coord)
                                    if let refreshed = refreshedOpt {
                                        let candidateRoute = WalkingRoute(name: refreshed.name, description: refreshed.description, durationMinutes: refreshed.durationMinutes, distanceMeters: refreshed.distanceMeters, difficulty: refreshed.difficulty, isIndoor: refreshed.isIndoor, isAccessible: refreshed.isAccessible, landmarks: refreshed.landmarks, icon: refreshed.icon, color: refreshed.color, qrMarkers: refreshed.qrMarkers, routeType: refreshed.routeType, trimmed: refreshed.trimmed, walkingDirections: refreshed.walkingDirections, usedOSRMRouting: false, isFromPrePopulatedDatabase: false, travelToStartMinutes: refreshed.travelToStartMinutes)
                                        guard Self.isRouteInBand(candidateRoute, selectedDuration: duration) else {
                                            print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Band attempt \(attempt + 1): \(refreshed.durationMinutes)min (outside band or distance < min for \(duration)min bucket)")
                                            continue
                                        }
                                        let (cappedGoogleRoute, enrichedData) = buildEnrichedAndRoute(refreshed: refreshed, selected: selected)
                                        print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Band attempt \(attempt + 1): Google in-band \(refreshed.durationMinutes)min — adding as route 2 (background)")
                                        await addOutOfBandRoute(refreshed: refreshed, enrichedData: enrichedData, cappedGoogleRoute: cappedGoogleRoute)
                                        return
                                    } else {
                                        print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Band attempt \(attempt + 1): Google returned nil")
                                    }
                                }
                                print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] No in-band route after closest-first + \(bands.count) band attempts (background)")
                            }
                        } else {
                            print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Skipped (places.isEmpty)")
                        }
                    } else if !mainInBand {
                        print("[ROUTE_GEN] ⏱️ [MAIN OUT-OF-BAND] Skipped (hasAPIKey=\(mapsService.hasAPIKey))")
                    }
                    
                    await MainActor.run {
                        // #region agent log
                        if displayRoute.qrMarkers.count > 1 {
                            let distances = (0..<displayRoute.qrMarkers.count-1).map { i in
                                let loc1 = CLLocation(latitude: displayRoute.qrMarkers[i].coordinate.latitude, longitude: displayRoute.qrMarkers[i].coordinate.longitude)
                                let loc2 = CLLocation(latitude: displayRoute.qrMarkers[i+1].coordinate.latitude, longitude: displayRoute.qrMarkers[i+1].coordinate.longitude)
                                return loc1.distance(from: loc2)
                            }
                            let logData: [String: Any] = [
                                "sessionId": "debug-session",
                                "runId": "run1",
                                "hypothesisId": "G",
                                "location": "RouteSelectionView.swift:2375",
                                "message": "Route assigned to view: final waypoint distances",
                                "data": [
                                    "routeName": displayRoute.name,
                                    "waypointCount": displayRoute.qrMarkers.count,
                                    "waypoints": displayRoute.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                                    "distances": distances,
                                    "minDistance": distances.min() ?? 0
                                ],
                                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                            ]
                            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                               let logString = String(data: logJSON, encoding: .utf8) {
                                logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                            }
                        }
                        // #endregion
                        
                        isGenerating = false
                        routeGenerationComplete = true  // v1.8.5: Trigger stage animation completion
                        runSummaryTimeToFirstRouteSec = runSummaryStartTime.map { Date().timeIntervalSince($0) }
                        let cappedDisplay = Self.applyDurationSanityCap(displayRoute, targetDurationMinutes: selectedDuration)
                        generatedRoute = cappedDisplay
                        generatedRouteData = deduplicatedResult
                        print("TIME_SOURCE | Fresh route shown: \(cappedDisplay.durationMinutes) min — FROM MAPKIT/OSRM (Google refresh will run after Let's Go)")
                        // #region agent log
                        do {
                            let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "RouteSelectionView:preview_route_shown", "message": "preview_route_shown", "data": ["source": "main", "targetDuration": selectedDuration, "actualDuration": deduplicatedResult.durationMinutes, "inBand10pct": (deduplicatedResult.durationMinutes >= Int(Double(selectedDuration) * 0.9) && deduplicatedResult.durationMinutes <= Int(Double(selectedDuration) * 1.1))], "hypothesisId": "H6"]
                            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) { s.appendLine(toFile: _agentLogPath()) }
                        } catch {}
                        // #endregion agent log
                        // Save as last valid for recycling on shuffle
                        lastValidRoute = cappedDisplay
                        lastValidRouteData = deduplicatedResult
                        
                        // v1.8.8: Check if initial route is too short (< 50% of target)
                        let minAcceptablePercent = 0.50
                        let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                        let isShortRoute = deduplicatedResult.durationMinutes < minAcceptableDuration
                        if isShortRoute {
                            print("⚠️ Initial route is short fallback (\(deduplicatedResult.durationMinutes)min < \(minAcceptableDuration)min target 50%)")
                        }
                        
                        // Initialize route array: always route 1 = main; if Google produced in-band, add as route 2 and auto-switch to it (cap duration for display)
                        var routesToShow: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] = [(route: Self.applyDurationSanityCap(displayRoute, targetDurationMinutes: selectedDuration), data: deduplicatedResult, isDeadZoneFallback: isShortRoute, isFromGoogle: mainRoutePreviewSource == "google")]
                        var placeIdSetsToShow: [Set<String>] = [Set(filteredResult.places.map { $0.placeId })]
                        var initialRouteIndex = 0
                        if let second = googleSecondRoute {
                            routesToShow.append((route: Self.applyDurationSanityCap(second.route, targetDurationMinutes: selectedDuration), data: second.data, isDeadZoneFallback: false, isFromGoogle: true))
                            placeIdSetsToShow.append(Set(second.data.places.map { $0.placeId }))
                            initialRouteIndex = 1  // Auto-switch to route 2 (Google) when available so user sees the better option
                        }
                        allRoutes = routesToShow
                        currentRouteIndex = initialRouteIndex
                        preGenerationComplete = false
                        isRecycledRoute = false  // First route is never recycled
                        isDeadZoneFallback = isShortRoute  // v1.8.8: Mark if below 50%
                        rejectedShortRoutes = []  // v1.8.8: Clear any previous rejected routes
                        viewedRouteIndices = [initialRouteIndex]  // Mark the shown route as viewed
                        shownPlaceIdSets = placeIdSetsToShow
                        // Session cache: so Cancel → Generate again is instant (even before pre-gen completes)
                        let liveSessionMeta = routesToShow.map { e in
                            RouteCacheService.CachedRouteWithMetadata(
                                route: e.data,
                                name: e.route.name,
                                description: e.route.description,
                                directions: e.route.walkingDirections,
                                isDeadZoneFallback: e.isDeadZoneFallback,
                                isFromPrePopulatedDatabase: false
                            )
                        }
                        RouteCacheService.shared.setSessionRoutes(liveSessionMeta, at: userLocation.coordinate, durationMinutes: selectedDuration)
                        // When we auto-switch to route 2, update generatedRoute/generatedRouteData so preview shows the Google route (capped)
                        if initialRouteIndex == 1, routesToShow.count > 1 {
                            generatedRoute = routesToShow[1].route
                            generatedRouteData = routesToShow[1].data
                        }
                        
                        // v1.8.0: Register first route's signature to prevent duplicates! (use filteredResult)
                        registerRouteSignature(places: filteredResult.places, distanceMeters: filteredResult.distanceMeters)
                        
                        // v1.8.13: Don't show map preview immediately - let stage animations complete first
                        // showMapPreview = true  // REMOVED - this was causing stages to be skipped
                        
                        let totalTime = Date().timeIntervalSince(generateStartTime)
                        let route1WaypointNames = filteredResult.places.map { $0.name }.joined(separator: " → ")
                        let distanceKm = String(format: "%.1f", Double(displayRoute.distanceMeters) / 1000)
                        print("ROUTE_FIRST_DISPLAYED time_to_first_route_sec=\(String(format: "%.2f", totalTime)) duration=\(selectedDuration) source=live")
                        print("═══════════════════════════════════════════════════════════")
                        print("[ROUTE_GEN] ROUTE_PREVIEW \(displayRoute.name), \(route1WaypointNames). \(displayRoute.durationMinutes) min \(distanceKm)km, \(mainRoutePreviewSource)")
                        logRoutePreviewSummary()
                        print("[ROUTE_GEN] ✅ ROUTE 1 READY - Total time: \(String(format: "%.2f", totalTime))s waypoints=[\(route1WaypointNames)] duration=\(displayRoute.durationMinutes)min distance=\(displayRoute.distanceMeters)m")
                        print("   📍 \(filteredResult.places.count) POIs, \(filteredResult.durationMinutes)min, \(filteredResult.distanceMeters)m")
                        print("═══════════════════════════════════════════════════════════")
                        
                        // Print simple route summary (use filteredResult)
                        let poiNames = filteredResult.places.map { $0.name }.joined(separator: " → ")
                        print("\n📋 ROUTES SUMMARY - \(selectedDuration)min")
                        print("\(selectedDuration)min - route 1: \(poiNames)\n")
                        
                        // Print comprehensive API call summary
                        print("")
                        print("═══════════════════════════════════════════════════════════")
                        print("📊 COMPREHENSIVE API CALL SUMMARY")
                        print("═══════════════════════════════════════════════════════════")
                        mapsService.printAPICallSummary()
                        GeminiService.shared.printAPICallSummary()
                        print("═══════════════════════════════════════════════════════════")
                        print("")
                        
                        // v1.9.28: Clear any status messages - routes are ready
                        routeRefreshStatus = nil
                        
                        // Start pre-generating more routes in background (only if we need more in-band routes)
                        if !hasEnoughInBandRoutes() {
                            preGenerateRemainingRoutes()
                        } else {
                            print("[ROUTE_GEN] ⏹️ First route is in-band — skipping pre-generation (have \(inBandRouteCount())/\(targetInBandRoutes))")
                        }
                    }
                    
                    // MapKit started before Let's Go (live path) — same race: last route always Google
                    refreshRaceState.walkStarted = false
                    refreshRaceState.googleApplied = false
                    let liveRaceState = refreshRaceState
                    let liveFirstRoute = displayRoute
                    let liveUserLoc = userLocation.coordinate
                    Task {
                        let mapKitRoute = await mapsService.refreshRouteWithMapKit(route: liveFirstRoute, userLocation: liveUserLoc)
                        await MainActor.run {
                            if liveRaceState.walkStarted {
                                if !liveRaceState.googleApplied {
                                    viewModel.updateCurrentRoute(mapKitRoute)
                                    print("DIRECTIONS | MapKit (live) finished after Let's Go — applied (Google not yet)")
                                }
                            } else {
                                if allRoutes.indices.contains(0), allRoutes[0].route.name == liveFirstRoute.name {
                                    // v2.1.9: Don't overwrite Google-remeasured route with MapKit estimate
                                    if allRoutes[0].isFromGoogle {
                                        print("TIME_SOURCE | PREVIEW: MapKit (live) skipped — already Google-remeasured (\(allRoutes[0].route.durationMinutes) min)")
                                    } else {
                                        allRoutes[0].route = mapKitRoute
                                        if currentRouteIndex == 0 { generatedRoute = mapKitRoute }
                                        print("TIME_SOURCE | PREVIEW: MapKit (live) done — preview shows \(mapKitRoute.durationMinutes) min (Google on Let's Go)")
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                        showLoadingScreen = false  // Dismiss immediately on error
                        routeRefreshStatus = nil  // v1.9.28: Clear status on error
                        routeGenerationComplete = false
                        errorMessage = "Could not find a route within time limit. Try different options."
                        print("❌ Smart routing error: \(error)")
                        print("⏱️ Failed after \(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s")
                    }
                }
            }
        } else {
            // Use basic generation (fallback)
            print("⚠️ No API key - using basic route generation")
            generateBasicRoute(from: userLocation.coordinate)
        }
        
        print("🏁 generateRoute() function completed (Task launched if applicable)")
    }
    
    // MARK: - View Builders (extracted to help compiler)
    
    @ViewBuilder
    private func firstTimeGenerationView() -> some View {
        // v1.8.2: Live map with animated route exploration
        // v1.8.5: Added sequential stage animation with completion callback
        RouteExplorationLoadingView(
            userLocation: locationService.currentLocation?.coordinate,
            currentAttempt: mapsService.currentRouteAttempt,
            attemptCount: mapsService.routeAttemptCount,
            statusText: mapsService.retryStatus ?? "Finding the best route...",
            isComplete: routeGenerationComplete,
            onAnimationComplete: {
                // Transition to preview after animation completes
                showLoadingScreen = false
                showMapPreview = true  // v1.8.13: Now show the preview after stages complete
            }
        )
    }
    
    @ViewBuilder
    private func shuffleErrorView(error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.softAmber)
            
            Text("Couldn't find a different route")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack(spacing: 16) {
                Button("Try Again") {
                    errorMessage = nil
                    isShuffling = true
                    generateRouteForShuffle()
                }
                .buttonStyle(PrimaryButtonStyle())
                
                Button("Change Options") {
                    showMapPreview = false
                    errorMessage = nil
                }
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    @ViewBuilder
    private func shuffleLoadingOverlay() -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.tealAccent)
                
                Text(mapsService.retryStatus ?? "Finding alternative route...")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Button("Cancel") {
                    isShuffling = false
                    if let previousRoute = routeBeforeShuffle {
                        generatedRoute = previousRoute
                        generatedRouteData = routeDataBeforeShuffle
                    }
                    routeBeforeShuffle = nil
                    routeDataBeforeShuffle = nil
                }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground).opacity(0.95))
                    .shadow(radius: 20)
            )
        }
        .transition(.opacity)
    }
    
    @ViewBuilder
    private func mapPreviewSection(route: WalkingRoute, totalDisplayedRoutes: Int = 1, displayedPosition: Int = 1, showOutOfBandBanner: Bool = false, outOfBandLabel: String? = nil, isDeadZoneFallback: Bool = false) -> some View {
        // #region agent log - Log when route is displayed in UI
        let _ = {
            if route.qrMarkers.count > 1 {
                let distances = (0..<route.qrMarkers.count-1).map { i in
                    let loc1 = CLLocation(latitude: route.qrMarkers[i].coordinate.latitude, longitude: route.qrMarkers[i].coordinate.longitude)
                    let loc2 = CLLocation(latitude: route.qrMarkers[i+1].coordinate.latitude, longitude: route.qrMarkers[i+1].coordinate.longitude)
                    return loc1.distance(from: loc2)
                }
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "G",
                    "location": "RouteSelectionView.swift:2642",
                    "message": "Route displayed in UI: final waypoint distances",
                    "data": [
                        "routeName": route.name,
                        "routeIndex": currentRouteIndex,
                        "waypointCount": route.qrMarkers.count,
                        "waypoints": route.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                        "distances": distances,
                        "minDistance": distances.min() ?? 0,
                        "source": "ui_display"
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                   let logString = String(data: logJSON, encoding: .utf8) {
                    logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                    print("📊 [DEBUG LOG] Logged route '\(route.name)' with \(route.qrMarkers.count) waypoints, min distance: \(distances.min() ?? 0)m")
                }
            }
        }()
        // #endregion
        
        return ZStack {
            LocalRouteMapPreview(
                route: route,
                userLocation: locationService.currentLocation?.coordinate,
                generatedData: generatedRouteData,
                isRecycled: isRecycledRoute,
                targetDurationMinutes: selectedDuration,
                currentRouteIndex: displayedPosition,
                totalRoutes: max(1, totalDisplayedRoutes),
                isLoadingMoreRoutes: isPreGeneratingRoutes,
                showPremiumUpsell: showPremiumUpsell,
                hasLimitedPOIs: mapsService.hasLimitedPOIs,
                varietyExhausted: varietyExhausted,
                isDeadZoneFallback: isDeadZoneFallback,
                showOutOfBandBanner: showOutOfBandBanner,
                outOfBandLabel: outOfBandLabel,
                selectedDuration: selectedDuration,
                isStartingWalk: isStartingWalk,  // v1.6.45: Loading state
                routeRefreshStatus: routeRefreshStatus,  // v1.9.22: Status message during refresh
                onStartWalk: { handleStartWalk(route: route) },
                onShuffle: { shuffleToNextRoute() },
                onBack: { handleBackFromPreview() },
                onGenerateAdditional: { handleGenerateAdditionalRoute() },
                isGeneratingAdditional: isGeneratingAdditionalRoute,
                additionalRoutesRemaining: maxAdditionalRoutes - additionalRoutesGenerated,
                onRefresh: nil,  // Refresh button removed
                isRefreshingRoutes: isRefreshingRoutes
            )
            // Final dedup when user sees preview: ensure all waypoints are unique (e.g. avoid two "The Star Inn")
            .task(id: route.id) {
                await runPreviewDedupIfNeeded(route: route)
            }
            // v1.6.47: Force re-render when route data changes - SwiftUI can optimize away re-renders
            .id("preview-\(allRoutes.count)-\(currentRouteIndex)-\(isPreGeneratingRoutes)")
            .background(Color(.systemBackground))
            .disabled(isShuffling)
            
            if isShuffling {
                shuffleLoadingOverlay()
            }
        }
    }
    
    /// Run final waypoint dedup when preview is shown; replace route in state if duplicates were removed.
    private func runPreviewDedupIfNeeded(route: WalkingRoute) async {
        guard let origin = locationService.currentLocation?.coordinate else { return }
        guard let result = await mapsService.deduplicateWalkingRouteForPreview(route: route, origin: origin) else { return }
        let (dedupedRoute, dedupedData) = result
        await MainActor.run {
            let idx = currentRouteIndex
            guard idx < allRoutes.count else { return }
            allRoutes[idx] = (route: dedupedRoute, data: dedupedData, isDeadZoneFallback: allRoutes[idx].isDeadZoneFallback, isFromGoogle: allRoutes[idx].isFromGoogle)
            generatedRoute = dedupedRoute
            generatedRouteData = dedupedData
        }
    }
    
    private func handleStartWalk(route: WalkingRoute) {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("DIRECTIONS | Filter Xcode console by: DIRECTIONS")
        print("DIRECTIONS | [\(timeString)] 🚶 Let's Go tapped — route: '\(route.name)' dirs: \(route.walkingDirections.count)")
        print("⏱️ [LET'S GO] [\(timeString)] 🚶 handleStartWalk() STARTED")
        print("⏱️ [LET'S GO] [\(timeString)]   Route: '\(route.name)'")
        print("⏱️ [LET'S GO] [\(timeString)]   Duration: \(route.durationMinutes)min, Waypoints: \(route.qrMarkers.count)")
        let timeSourceNote = (currentRouteIndex == 0 && isRouteRefreshed)
            ? "FROM GOOGLE (refreshed on preview)"
            : "FROM CACHE (background Google refresh will run — map/time will update when done)"
        print("TIME_SOURCE | LET'S GO: Time on preview was \(route.durationMinutes) min — \(timeSourceNote)")
        
        // Mark walk started so MapKit task (if still in flight) only updates if Google hasn't yet
        refreshRaceState.walkStarted = true
        
        // v2.1.0: Cancel background generation immediately
        shouldCancelBackgroundWork = true
        print("⏱️ [LET'S GO] [\(timeString)] 🛑 Cancelling background generation to prioritize user action")
        
        // v2.1.1: INSTANT MAP DISPLAY
        // Show map immediately with current route, refresh directions in background
        // This eliminates the delay when tapping "Let's Go"
        
        // Start walk IMMEDIATELY with current route
        viewModel.selectRoute(route)
        viewModel.startWalk()
        // When the route being started came from Google, set pill so it shows "X mins left" and we skip refresh below
        let startedRouteIsFromGoogle = currentRouteIndex < allRoutes.count && allRoutes[currentRouteIndex].isFromGoogle
        if startedRouteIsFromGoogle {
            viewModel.updateCurrentRoute(route, sourceIsGoogle: true)
        }
        
        // Show map right away
        if viewModel.showPreWalkWellbeing {
            viewModel.pendingActiveWalk = true
            print("⏱️ [LET'S GO] [\(timeString)] ⏳ Pre-walk anxiety check showing - map will appear after")
            isPresented = false
        } else {
            isPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                showActiveWalk = true
            }
            print("⏱️ [LET'S GO] [\(timeString)] 🗺️ Walk started INSTANTLY - showing map with current route")
        }
        
        let instantElapsed = Date().timeIntervalSince(startTime)
        print("⏱️ [LET'S GO] [\(timeString)] ✅ Instant start: \(String(format: "%.3f", instantElapsed))s")
        
        // v2.1.11: ALWAYS run Google refresh on Let's Go — even if route was duration-remeasured
        // with getGoogleDirectionsRoute during cache load, the full refreshRouteWithGoogleOnly()
        // is needed to provide Google-snapped polyline and walking directions for the active walk.
        Task {
            let wasFromGoogle = await MainActor.run {
                currentRouteIndex < allRoutes.count && allRoutes[currentRouteIndex].isFromGoogle
            }
            print("DIRECTIONS | Let's Go Google refresh — wasFromGoogle=\(wasFromGoogle) (always refreshing)")
            let taskTimeString = formatter.string(from: Date())
            let routeSource: String
            if route.usedOSRMRouting {
                routeSource = "cached_OSM"
            } else if route.isFromPrePopulatedDatabase {
                routeSource = "prepop"
            } else {
                routeSource = "mapkit_or_google"
            }
            print("DIRECTIONS | ========== direction refresh (Google on Let's Go) ==========")
            print("REFRESH_SOURCE | [\(taskTimeString)] route_source=\(routeSource) name='\(route.name)' waypoints=\(route.qrMarkers.count)")
            
            // Wait briefly for location (often nil the instant user taps Let's Go)
            var userLocation: CLLocationCoordinate2D?
            for attempt in 0..<10 {
                userLocation = locationService.currentLocation?.coordinate
                if userLocation != nil {
                    print("DIRECTIONS | [\(taskTimeString)] Location ready after \(attempt) wait(s) (0.5s each)")
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
            guard let userLocation = userLocation else {
                print("DIRECTIONS | [\(taskTimeString)] ❌ No location after 5s - cannot refresh route (banner will stay 'loading directions')")
                return
            }
            
            // Google only — MapKit was already started on preview; race: show MapKit if it finishes first, else show Google; last is always Google
            guard mapsService.hasAPIKey else {
                print("REFRESH_SOURCE | [\(formatter.string(from: Date()))] step=google_skipped reason=no_api_key")
                return
            }
            
            let googleStart = Date()
            print("REFRESH_SOURCE | [\(formatter.string(from: Date()))] step=google_start (Google refresh on Let's Go)")
            print("DIRECTIONS | [\(taskTimeString)] 🌐 Google refresh starting...")
            if let refreshedRoute = await mapsService.refreshRouteWithGoogleOnly(
                route: route,
                userLocation: userLocation
            ) {
                let googleElapsed = Date().timeIntervalSince(googleStart)
                print("REFRESH_SOURCE | [\(formatter.string(from: Date()))] step=google_done elapsed=\(String(format: "%.2f", googleElapsed))s")
                // Cap refreshed duration so it matches preview: avoid showing 45 min when preview was 8 min (same sanity cap as elsewhere, using preview duration as target)
                let previewTargetMin = route.durationMinutes
                let cappedRefreshedRoute = refreshedRoute.withDurationSanityCap(targetDurationMinutes: previewTargetMin)
                if cappedRefreshedRoute.durationMinutes != refreshedRoute.durationMinutes {
                    print("DIRECTIONS | [\(formatter.string(from: Date()))] Duration capped for display: Google=\(refreshedRoute.durationMinutes)min → \(cappedRefreshedRoute.durationMinutes)min (preview was \(previewTargetMin)min)")
                }
                let targetMin = await MainActor.run { selectedDuration }
                // Only offer adjust when route is at least 10% over requested time (e.g. 11+ min for 10 min, 17+ for 15 min).
                let overThreshold = max(1, Int(ceil(Double(targetMin) * 0.10)))
                if refreshedRoute.durationMinutes > targetMin + overThreshold,
                   refreshedRoute.qrMarkers.count >= 2,
                   route.qrMarkers.count >= 2 {
                    var bestShortened: WalkingRoute? = nil
                    var bestShortenedMins = Int.max
                    for dropIndex in 0..<route.qrMarkers.count {
                        let keptMarkers = route.qrMarkers.enumerated().filter { $0.offset != dropIndex }.map(\.element)
                        guard keptMarkers.count >= 1 else { continue }
                        let routeWithDropped = WalkingRoute(
                            name: route.name,
                            description: route.description,
                            durationMinutes: route.durationMinutes,
                            distanceMeters: route.distanceMeters,
                            difficulty: route.difficulty,
                            isIndoor: route.isIndoor,
                            isAccessible: route.isAccessible,
                            landmarks: ["Start"] + keptMarkers.map { $0.name } + ["Return"],
                            icon: route.icon,
                            color: route.color,
                            qrMarkers: keptMarkers,
                            routeType: route.routeType,
                            encodedPolyline: nil,
                            walkingDirections: [],
                            usedOSRMRouting: false,
                            isFromPrePopulatedDatabase: route.isFromPrePopulatedDatabase,
                            travelToStartMinutes: route.travelToStartMinutes
                        )
                        if let shortened = await mapsService.refreshRouteWithGoogleOnly(route: routeWithDropped, userLocation: userLocation),
                           shortened.durationMinutes <= targetMin + 3,
                           shortened.durationMinutes < bestShortenedMins {
                            bestShortened = shortened
                            bestShortenedMins = shortened.durationMinutes
                        }
                    }
                    if let adjusted = bestShortened {
                        // Apply same road-snapping rules to adjusted route so POIs are snapped to the road (matches rest of app).
                        let adjustedSnapped = await mapsService.ensureWaypointsSnappedToRoads(route: adjusted)
                        await MainActor.run {
                            viewModel.offerAdjustedRoute(adjustedSnapped)
                            print("DIRECTIONS | [\(formatter.string(from: Date()))] 📋 Offered shorter route (\(adjustedSnapped.durationMinutes)min) — Google was \(refreshedRoute.durationMinutes)min vs target \(targetMin)min")
                        }
                    }
                }
                await MainActor.run {
                    refreshRaceState.googleApplied = true
                    viewModel.updateCurrentRoute(refreshedRoute, sourceIsGoogle: true)
                    isRouteRefreshed = true
                    print("DIRECTIONS | [\(formatter.string(from: Date()))] ✅ Google route applied (last route is always Google)")
                }
                
                if mapsService.lastRouteHadRestrictedRoads {
                    print("DIRECTIONS | Google had restricted roads - fetching MapKit fallback...")
                    if let mapKitFallback = await mapsService.getMapKitFallbackRoute(for: refreshedRoute) {
                        await MainActor.run {
                            viewModel.updateCurrentRoute(mapKitFallback)
                            print("DIRECTIONS | ✅ MapKit fallback applied (restricted roads)")
                        }
                    }
                }
            } else {
                print("REFRESH_SOURCE | [\(formatter.string(from: Date()))] step=google_failed (keeping current route; MapKit may apply if it finishes)")
                print("DIRECTIONS | [\(formatter.string(from: Date()))] ⚠️ Google refresh failed")
            }
            print("DIRECTIONS | ========== direction refresh finished ==========")
        }
    }
    
    private func handleBackFromPreview() {
        print("🔙 handleBackFromPreview - resetting all generation state")
        
        // Reset view state
        showMapPreview = false
        showLoadingScreen = false
        isGenerating = false
        routeGenerationComplete = false
        
        // Reset route data
        generatedRoute = nil
        generatedRouteData = nil
        lastValidRoute = nil
        lastValidRouteData = nil
        
        // Reset MapKit vs Google race state for next walk
        refreshRaceState.walkStarted = false
        refreshRaceState.googleApplied = false
        currentRouteIsFromGoogle30sFallback = false
        
        // Reset pre-generation state
        allRoutes = []
        currentRouteIndex = 0
        preGenerationComplete = false
        isPreGeneratingRoutes = false
        viewedRouteIndices = []
        showPremiumUpsell = false
        routeSignatures = []
        varietyExhausted = false
        rejectedShortRoutes = []  // v1.8.8: Clear rejected routes
        shownPlaceIdSets = []  // Reset shown place IDs
        additionalRoutesGenerated = 0  // v2.1.10: Reset +1 button cap
        isGeneratingAdditionalRoute = false
        
        // Reset error state
        errorMessage = nil
    }
    
    private func handleDeleteRoute() {
        guard !allRoutes.isEmpty else { return }
        
        allRoutes.remove(at: currentRouteIndex)
        
        if allRoutes.isEmpty {
            generatedRoute = nil
            generatedRouteData = nil
            lastValidRoute = nil
            lastValidRouteData = nil
            shownPlaceIdSets = []
            allRoutes = []
            currentRouteIndex = 0
            preGenerationComplete = false
            viewedRouteIndices = []
            resetRouteSignatures()
            showPremiumUpsell = false
            showMapPreview = false
            errorMessage = nil
            rejectedShortRoutes = []  // v1.8.8: Clear rejected routes
            print("🗑️ Deleted last route - returning to options")
        } else {
            if currentRouteIndex >= allRoutes.count {
                currentRouteIndex = allRoutes.count - 1
            }
            let nextRoute = allRoutes[currentRouteIndex]
            generatedRoute = nextRoute.route
            generatedRouteData = nextRoute.data
            print("🗑️ Deleted route - now showing \(currentRouteIndex + 1) of \(allRoutes.count)")
        }
    }
    
    /// v2.1.10: Generate one additional route on demand (+1 button). Appends to allRoutes instead of replacing.
    private func handleGenerateAdditionalRoute() {
        guard !varietyExhausted else {
            print("[+1] Variety exhausted — ignoring")
            return
        }
        guard additionalRoutesGenerated < maxAdditionalRoutes else {
            print("[+1] Cap reached (\(maxAdditionalRoutes)) — ignoring")
            return
        }
        guard let userLocation = locationService.currentLocation else {
            print("[+1] No user location — ignoring")
            return
        }
        guard mapsService.hasAPIKey else {
            print("[+1] No API key — ignoring")
            return
        }
        
        isGeneratingAdditionalRoute = true
        additionalRoutesGenerated += 1
        let remaining = maxAdditionalRoutes - additionalRoutesGenerated
        print("[+1] Generating additional route (\(additionalRoutesGenerated)/\(maxAdditionalRoutes), \(remaining) remaining)")
        
        Task {
            let deadline = Date().addingTimeInterval(10) // 10-second hard timeout
            var attempt = 0
            var added = false
            
            while Date() < deadline {
                attempt += 1
                print("[+1] Attempt \(attempt) (remaining: \(String(format: "%.1f", deadline.timeIntervalSinceNow))s)")
                
                do {
                    let excludedPlaceIds = await MainActor.run {
                        shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                    let excludedPOIs = await MainActor.run {
                        allRoutes.flatMap { $0.data.places }
                    }
                    let poisToUse = await MainActor.run {
                        prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    }
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        excludePOIs: excludedPOIs,
                        prefetchedPOIs: poisToUse
                    )
                    
                    // Check timeout after generation returns
                    guard Date() < deadline else {
                        print("[+1] ⏱️ Timeout after generation returned (attempt \(attempt))")
                        break
                    }
                    
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        print("[+1] Attempt \(attempt): empty result — retrying")
                        continue
                    }
                    
                    // Quick in-band check before doing expensive naming/directions work
                    let durationMin = max(1, result.durationMinutes)
                    let wouldBeInBand = await MainActor.run {
                        let minBand = Int(Double(selectedDuration) * 0.80)
                        let maxBand = Int(Double(selectedDuration) * 1.20)
                        return durationMin >= minBand && durationMin <= maxBand
                    }
                    if !wouldBeInBand {
                        print("[+1] Attempt \(attempt): out-of-band (\(durationMin)min) — retrying")
                        // Store in cross-bucket pool before retrying
                        await MainActor.run {
                            storeCrossBucketRoute(route: WalkingRoute(
                                name: "pending", description: "", durationMinutes: durationMin,
                                distanceMeters: result.distanceMeters, difficulty: .easy,
                                isIndoor: false, isAccessible: true, landmarks: [],
                                icon: "location.fill", color: .tealAccent, qrMarkers: [],
                                routeType: .local, trimmed: result.polyline,
                                walkingDirections: [], usedOSRMRouting: result.usedOSRM
                            ), data: result, isFromGoogle: false)
                        }
                        continue
                    }
                    
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                    }
                    guard !markers.isEmpty else {
                        print("[+1] Attempt \(attempt): no markers — retrying")
                        continue
                    }
                    
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: result.legs, waypoints: result.places)
                    }
                    
                    // Name the route in parallel with directions
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    let namingTask = Task {
                        await GeminiService.shared.generateRouteContent(
                            waypoints: waypointInfos,
                            durationMinutes: result.durationMinutes,
                            distanceMeters: result.distanceMeters,
                            difficulty: nil
                        )
                    }
                    
                    if directions.isEmpty && !result.places.isEmpty {
                        let waypointCoords = result.places.map { $0.coordinate }
                        let waypointNames = result.places.map { $0.name }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate,
                            waypointNames: waypointNames
                        )
                    }
                    
                    let routeDifficulty: RouteDifficulty = durationMin <= 10 ? .easy : (durationMin <= 20 ? .moderate : .challenging)
                    let aiContent = await namingTask.value
                    
                    added = await MainActor.run {
                        let route = WalkingRoute(
                            name: aiContent.name,
                            description: aiContent.description,
                            durationMinutes: durationMin,
                            distanceMeters: result.distanceMeters,
                            difficulty: routeDifficulty,
                            isIndoor: false,
                            isAccessible: true,
                            landmarks: ["Start"] + result.places.map { $0.name } + ["Return"],
                            icon: "location.fill",
                            color: .tealAccent,
                            qrMarkers: markers,
                            routeType: .local,
                            trimmed: result.polyline,
                            walkingDirections: directions,
                            usedOSRMRouting: result.usedOSRM
                        )
                        
                        let newPlaceIds = Set(result.places.map { $0.placeId })
                        if !shownPlaceIdSets.contains(newPlaceIds) {
                            shownPlaceIdSets.append(newPlaceIds)
                        }
                        
                        // Append to allRoutes — bypass in-band cap since user explicitly requested +1
                        let didAdd = appendRouteIfAllowed(
                            route: route,
                            data: result,
                            isDeadZoneFallback: false,
                            isFromGoogle: false,
                            source: "+1_button",
                            bypassInBandCap: true
                        )
                        
                        if didAdd {
                            print("[+1] ✅ Added '\(route.name)' — now \(allRoutes.count) route(s)")
                            logRoutePreviewSummary()
                        }
                        return didAdd
                    }
                    
                    if added { break }
                    print("[+1] Attempt \(attempt): appendRouteIfAllowed rejected — retrying")
                    
                } catch {
                    print("[+1] Attempt \(attempt): error \(error.localizedDescription) — retrying")
                }
            }
            
            // Finished: either added a route or timed out
            await MainActor.run {
                isGeneratingAdditionalRoute = false
                if added {
                    // Update session cache so Cancel → Generate reuses all routes including this new one
                    if let coord = locationService.currentLocation?.coordinate {
                        let sessionMeta = allRoutes.map { e in
                            RouteCacheService.CachedRouteWithMetadata(
                                route: e.data,
                                name: e.route.name,
                                description: e.route.description,
                                directions: e.route.walkingDirections,
                                isDeadZoneFallback: e.isDeadZoneFallback,
                                isFromPrePopulatedDatabase: false
                            )
                        }
                        RouteCacheService.shared.setSessionRoutes(sessionMeta, at: coord, durationMinutes: selectedDuration)
                        print("[+1] 💾 Session cache updated with \(allRoutes.count) route(s)")
                    }
                } else {
                    // No valid route found within 10s — mark variety exhausted
                    varietyExhausted = true
                    print("[+1] ❌ No valid in-band route found after \(attempt) attempt(s) / 10s — variety exhausted")
                }
            }
        }
    }
    
    /// Refresh route list from cache/database. Shows loading, calls RouteCacheService.getCachedRoutes(), then updates allRoutes.
    private func handleRefreshRoutes() {
        guard let userCoord = locationService.currentLocation?.coordinate else {
            return
        }
        Task {
            await MainActor.run { isRefreshingRoutes = true }
            defer { Task { @MainActor in isRefreshingRoutes = false } }
            guard let cachedRoutes = RouteCacheService.shared.getCachedRoutes(near: userCoord, durationMinutes: selectedDuration),
                  !cachedRoutes.isEmpty else {
                return
            }
            var loadedRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] = []
            var loadedPlaceIdSets: [Set<String>] = []
            for cached in cachedRoutes {
                let filteredCachedRoute = mapsService.filterCloseWaypointsSync(from: cached.route, durationMinutes: selectedDuration, origin: userCoord, isFromPrePopulatedDatabase: cached.isFromPrePopulatedDatabase)
                var polylineToUse = filteredCachedRoute.polyline
                var durationToUse = filteredCachedRoute.durationSeconds
                var distanceToUse = filteredCachedRoute.distanceMeters
                var directionsFromGpsToFirst: [WalkingDirection] = []
                var directionsFromLastToGps: [WalkingDirection] = []
                if cached.isFromPrePopulatedDatabase, let firstPlace = filteredCachedRoute.places.first {
                    if let merged = await mapsService.prependGpsToFirstWaypointLeg(
                        userLocation: userCoord,
                        firstWaypoint: firstPlace.coordinate,
                        existingRoutePolyline: filteredCachedRoute.polyline,
                        existingDurationSeconds: filteredCachedRoute.durationSeconds,
                        existingDistanceMeters: filteredCachedRoute.distanceMeters
                    ) {
                        polylineToUse = merged.polyline
                        durationToUse = merged.durationSeconds
                        distanceToUse = merged.distanceMeters
                        directionsFromGpsToFirst = merged.directionsFromGpsToFirst
                    }
                    if let lastPlace = filteredCachedRoute.places.last,
                       let withReturn = await mapsService.appendLastWaypointToGpsLeg(
                        userLocation: userCoord,
                        lastWaypoint: lastPlace.coordinate,
                        existingRoutePolyline: polylineToUse,
                        existingDurationSeconds: durationToUse,
                        existingDistanceMeters: distanceToUse
                       ) {
                        polylineToUse = withReturn.polyline
                        durationToUse = withReturn.durationSeconds
                        distanceToUse = withReturn.distanceMeters
                        directionsFromLastToGps = withReturn.directionsFromLastToGps
                    }
                }
                let markers = await MainActor.run {
                    createMarkersFromPlaces(filteredCachedRoute.places, origin: userCoord)
                }
                var directions: [WalkingDirection] = directionsFromGpsToFirst
                if let cachedDirections = cached.directions, !cachedDirections.isEmpty {
                    let filtered = await MainActor.run { filterContradictoryDirections(cachedDirections) }
                    directions += filtered
                } else {
                    directions += await MainActor.run {
                        extractWalkingDirections(from: filteredCachedRoute.legs, waypoints: filteredCachedRoute.places)
                    }
                }
                directions += directionsFromLastToGps
                let routeDifficulty: RouteDifficulty = (durationToUse / 60) <= 10 ? .easy : ((durationToUse / 60) <= 20 ? .moderate : .challenging)
                var routeName = cached.name ?? "Local Discovery"
                var routeDesc = cached.description ?? "A \(filteredCachedRoute.formattedDuration) walk passing \(filteredCachedRoute.places.count) local points of interest."
                if (cached.name == nil || (cached.name ?? "").isEmpty || (cached.name ?? "") == "Local Discovery"),
                   cached.isFromPrePopulatedDatabase,
                   !filteredCachedRoute.places.isEmpty {
                    let waypointInfos = filteredCachedRoute.places.map {
                        GeminiService.WaypointInfo(name: $0.name, types: $0.types ?? [], vicinity: $0.vicinity)
                    }
                    let content = await GeminiService.shared.generateRouteContent(
                        waypoints: waypointInfos,
                        durationMinutes: max(1, durationToUse / 60),
                        distanceMeters: distanceToUse,
                        difficulty: routeDifficulty,
                        originCoordinate: nil
                    )
                    routeName = content.name
                    routeDesc = content.description
                }
                let localRoute = WalkingRoute(
                    name: routeName,
                    description: routeDesc,
                    durationMinutes: max(1, durationToUse / 60),
                    distanceMeters: distanceToUse,
                    difficulty: routeDifficulty,
                    isIndoor: false,
                    isAccessible: true,
                    landmarks: ["Start"] + filteredCachedRoute.places.map { $0.name } + ["Return"],
                    icon: "location.fill",
                    color: .tealAccent,
                    qrMarkers: markers,
                    routeType: .local,
                    trimmed: polylineToUse,
                    walkingDirections: directions,
                    usedOSRMRouting: filteredCachedRoute.usedOSRM,
                    isFromPrePopulatedDatabase: cached.isFromPrePopulatedDatabase,
                    travelToStartMinutes: cached.route.travelToStartSeconds.map { $0 / 60 }
                )
                loadedRoutes.append((route: localRoute, data: filteredCachedRoute, isDeadZoneFallback: cached.isDeadZoneFallback, isFromGoogle: false))
                loadedPlaceIdSets.append(Set(filteredCachedRoute.places.map { $0.placeId }))
            }
            await MainActor.run {
                allRoutes = loadedRoutes
                shownPlaceIdSets = loadedPlaceIdSets
                currentRouteIndex = 0
                if let first = loadedRoutes.first {
                    generatedRoute = first.route
                    generatedRouteData = first.data
                    lastValidRoute = first.route
                    lastValidRouteData = first.data
                    isDeadZoneFallback = first.isDeadZoneFallback
                }
                viewedRouteIndices = [0]
                logRoutePreviewSummary()
            }
        }
    }
    
    // MARK: - Prepop MapKit validate and reorder
    
    /// Validity band for requested duration (same as RouteCacheService: 80–120%, edge 75–125%). Applies to all buckets.
    private static func minMaxAcceptableMinutes(for selectedDuration: Int) -> (min: Int, max: Int) {
        let rounded = RouteCacheService.roundToNearest5Minutes(selectedDuration)
        let isEdge = rounded <= 5 || rounded >= 55
        let minPercent = isEdge ? 0.75 : 0.80
        let maxPercent = isEdge ? 1.25 : 1.20
        let minAcceptable = Int(Double(rounded) * minPercent)
        let maxAcceptable = Int(Double(rounded) * maxPercent)
        return (minAcceptable, maxAcceptable)
    }
    
    /// Minimum route distance (m) for a route to count as in-band for the given duration bucket. Prevents short walks (e.g. 800 m) being shown as in-band for long targets. Generalisable to all buckets.
    private static func minDistanceMetersForInBand(for selectedDuration: Int) -> Int {
        let rounded = max(1, RouteCacheService.roundToNearest5Minutes(selectedDuration))
        return max(200, rounded * 50)  // at least 50 m/min implied
    }
    
    /// True if route is in-band for the selected duration: duration within 80–120% and distance at least min for that bucket. Use for all buckets (prepop and non-prepop).
    private static func isRouteInBand(_ route: WalkingRoute, selectedDuration: Int) -> Bool {
        let (minAcc, maxAcc) = minMaxAcceptableMinutes(for: selectedDuration)
        let durationOk = route.durationMinutes >= minAcc && route.durationMinutes <= maxAcc
        let minDist = minDistanceMetersForInBand(for: selectedDuration)
        let distanceOk = route.distanceMeters >= minDist
        return durationOk && distanceOk
    }
    
    /// Count how many routes currently in allRoutes are in-band (80-120% of target duration + min distance).
    private func inBandRouteCount() -> Int {
        allRoutes.filter { Self.isRouteInBand($0.route, selectedDuration: selectedDuration) }.count
    }
    
    /// True if we already have enough in-band routes and should stop generating more.
    private func hasEnoughInBandRoutes() -> Bool {
        inBandRouteCount() >= targetInBandRoutes
    }
    
    /// Centralized gate: append a route to allRoutes only if we haven't reached the in-band target.
    /// Out-of-band routes are always redirected to the cross-bucket pool.
    /// Returns true if the route was appended to allRoutes, false if it was redirected/rejected.
    @discardableResult
    private func appendRouteIfAllowed(
        route: WalkingRoute,
        data: GeneratedRoute,
        isDeadZoneFallback: Bool = false,
        isFromGoogle: Bool,
        source: String,
        bypassInBandCap: Bool = false
    ) -> Bool {
        let isInBand = Self.isRouteInBand(route, selectedDuration: selectedDuration)
        
        // Out-of-band routes never shown — store in cross-bucket pool
        if !isInBand {
            if isFromGoogle {
                storeCrossBucketRoute(route: route, data: data, isFromGoogle: isFromGoogle)
            }
            print("[ROUTE_GEN] ⏹️ [\(source)] '\(route.name)' out-of-band (\(route.durationMinutes)min) — cross-bucket pool")
            return false
        }
        
        // Already have enough in-band routes — redirect excess (unless bypassed by +1 button)
        if !bypassInBandCap && hasEnoughInBandRoutes() {
            if isFromGoogle {
                storeCrossBucketRoute(route: route, data: data, isFromGoogle: isFromGoogle)
            }
            print("[ROUTE_GEN] ⏹️ [\(source)] '\(route.name)' in-band but already have \(inBandRouteCount())/\(targetInBandRoutes) — skipped")
            return false
        }
        
        // Append
        allRoutes.append((route: route, data: data, isDeadZoneFallback: isDeadZoneFallback, isFromGoogle: isFromGoogle))
        let currentInBand = inBandRouteCount()
        print("[ROUTE_GEN] ✅ [\(source)] '\(route.name)' \(route.durationMinutes)min \(String(format: "%.1f", Double(route.distanceMeters)/1000))km — route \(allRoutes.count) (inBand: \(currentInBand)/\(targetInBandRoutes))")
        
        // Immediately dismiss loading indicator once we have enough in-band routes
        // (post-loop sweep/fallback work continues silently in background)
        if currentInBand >= targetInBandRoutes && isPreGeneratingRoutes {
            isPreGeneratingRoutes = false
            preGenerationComplete = true
            print("[ROUTE_GEN] ✅ Loading indicator dismissed (\(currentInBand)/\(targetInBandRoutes) in-band reached via \(source))")
        }
        
        return true
    }
    
    /// Log all displayed routes in a single, copy-paste-friendly block so you can share exactly what the app shows (1 of N … N of N).
    /// Search logs for "DISPLAYED ROUTES" to find this block.
    private func logRoutePreviewSummary() {
        guard !allRoutes.isEmpty else { return }
        let inBand = allRoutes.indices.filter { Self.isRouteInBand(allRoutes[$0].route, selectedDuration: selectedDuration) }
        let outOfBand = allRoutes.indices.filter { !inBand.contains($0) }
        let displayed = inBand + outOfBand
        print("[ROUTE_GEN] ========== DISPLAYED ROUTES (paste this block) ==========")
        print("[ROUTE_GEN] Target: \(selectedDuration) min | Total: \(displayed.count) routes")
        for (pos, idx) in displayed.enumerated() {
            let e = allRoutes[idx]
            let waypoints = e.data.places.map { $0.name }.joined(separator: " → ")
            let distKm = String(format: "%.1f", Double(e.route.distanceMeters) / 1000)
            let source = e.isFromGoogle ? "google" : (e.route.isFromPrePopulatedDatabase ? "prepop" : "live")
            print("[ROUTE_GEN]   \(pos + 1) of \(displayed.count): \(e.route.name) | \(waypoints) | \(e.route.durationMinutes) min \(distKm) km | \(source)")
            // 🔍 DIAGNOSTIC: Show raw GeneratedRoute values vs displayed WalkingRoute values + waypoint coords
            let rawDurMin = e.data.durationSeconds / 60
            let rawDistM = e.data.distanceMeters
            let displayDurMin = e.route.durationMinutes
            let displayDistM = e.route.distanceMeters
            let coordsStr = e.data.places.map { p in "'\(p.name)' (\(String(format: "%.5f", p.coordinate.latitude)),\(String(format: "%.5f", p.coordinate.longitude)))" }.joined(separator: ", ")
            if rawDurMin != displayDurMin || rawDistM != displayDistM {
                print("[ROUTE_DEBUG] ⚠️ RAW data: \(rawDurMin) min \(rawDistM) m vs DISPLAY: \(displayDurMin) min \(displayDistM) m (sanity cap changed values)")
            }
            print("[ROUTE_GEN]          📍 Waypoint coords: \(coordsStr)")
            print("[ROUTE_DEBUG] 📊 Raw GeneratedRoute: \(e.data.durationSeconds)s / \(e.data.distanceMeters)m | WalkingRoute: \(e.route.durationMinutes)min / \(e.route.distanceMeters)m | places_in_data=\(e.data.places.count) | isFromGoogle=\(e.isFromGoogle)")
        }
        print("[ROUTE_GEN] ========== END DISPLAYED ROUTES ==========")
        // v2.1.9: Log session cross-bucket pool status
        let bucketSummary = RouteCacheService.shared.sessionCrossBucketPoolSummary()
        if !bucketSummary.isEmpty {
            print("[ROUTE_DEBUG] 🔄 Cross-bucket pool (session): \(bucketSummary)")
        }
    }
    
    /// One-block summary for comparing runs (e.g. 10 min vs 20 min). Paste two blocks to compare.
    /// Search for "[RUN_SUMMARY]" to find this in console.
    private func logRunSummary() {
        let source = runSummarySource.isEmpty ? "unknown" : runSummarySource
        let timeToFirst = runSummaryTimeToFirstRouteSec.map { String(format: "%.2f", $0) } ?? "—"
        let total = allRoutes.count
        let inBand = inBandRouteCount()
        let totalElapsed = runSummaryStartTime.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "—"
        print("")
        print("[RUN_SUMMARY] ═══════════════════════════════════════════════════════════")
        print("[RUN_SUMMARY] target_min=\(selectedDuration) source=\(source) time_to_first_route_sec=\(timeToFirst) total_elapsed_sec=\(totalElapsed) total_routes=\(total) in_band=\(inBand)")
        for (i, e) in allRoutes.enumerated() {
            let wpCount = e.data.places.count
            let distKm = String(format: "%.1f", Double(e.route.distanceMeters) / 1000)
            let src = e.isFromGoogle ? "google" : (e.route.isFromPrePopulatedDatabase ? "prepop" : "live")
            print("[RUN_SUMMARY]   \(i + 1). \(e.route.name) | \(e.route.durationMinutes) min | \(distKm) km | \(wpCount) waypoints | \(src)")
        }
        print("[RUN_SUMMARY] ═══════════════════════════════════════════════════════════")
        print("")
    }
    
    // MARK: - v2.1.11: Google Re-measure Sweep
    
    /// Safety-net: iterate every route in allRoutes that is NOT yet Google-measured,
    /// call Google Directions, and update both WalkingRoute and GeneratedRoute in-place.
    /// Called once after all route generation/loading is complete, before the final summary.
    private func googleRemeasureSweep(userLocation: CLLocationCoordinate2D, selectedDuration: Int) async {
        guard mapsService.hasAPIKey else {
            print("[ROUTE_DEBUG] 🔄 SWEEP: skipped — no API key")
            return
        }
        
        // Snapshot non-Google route names (use name for identity so index shifts are safe)
        let targets: [(name: String, data: GeneratedRoute)] = await MainActor.run {
            allRoutes.compactMap { entry in
                entry.isFromGoogle ? nil : (name: entry.route.name, data: entry.data)
            }
        }
        guard !targets.isEmpty else {
            print("[ROUTE_DEBUG] 🔄 SWEEP: all \(await MainActor.run { allRoutes.count }) routes already Google-measured ✓")
            return
        }
        print("[ROUTE_DEBUG] 🔄 SWEEP: \(targets.count) route(s) need Google re-measure")
        
        for target in targets {
            guard !target.data.places.isEmpty else {
                print("[ROUTE_DEBUG] 🔄 SWEEP: '\(target.name)' has no waypoints — skipping")
                continue
            }
            
            if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation, waypoints: target.data.places, targetDurationMinutes: selectedDuration) {
                let googleDurMin = max(1, googleResult.durationSeconds / 60)
                let correctedData = GeneratedRoute(
                    places: target.data.places,
                    polyline: target.data.polyline,
                    distanceMeters: googleResult.distanceMeters,
                    durationSeconds: googleResult.durationSeconds,
                    legs: target.data.legs,
                    usedOSRM: target.data.usedOSRM,
                    travelToStartSeconds: target.data.travelToStartSeconds
                )
                
                await MainActor.run {
                    guard let idx = allRoutes.firstIndex(where: { $0.route.name == target.name }) else { return }
                    let existing = allRoutes[idx]
                    let correctedRoute = WalkingRoute(
                        name: existing.route.name,
                        description: existing.route.description,
                        durationMinutes: googleDurMin,
                        distanceMeters: googleResult.distanceMeters,
                        difficulty: existing.route.difficulty,
                        isIndoor: existing.route.isIndoor,
                        isAccessible: existing.route.isAccessible,
                        landmarks: existing.route.landmarks,
                        icon: existing.route.icon,
                        color: existing.route.color,
                        qrMarkers: existing.route.qrMarkers,
                        routeType: existing.route.routeType,
                        trimmed: existing.route.trimmed,
                        walkingDirections: existing.route.walkingDirections,
                        usedOSRMRouting: existing.route.usedOSRMRouting,
                        isFromPrePopulatedDatabase: existing.route.isFromPrePopulatedDatabase,
                        travelToStartMinutes: existing.route.travelToStartMinutes
                    )
                    let cappedRoute = Self.applyDurationSanityCap(correctedRoute, targetDurationMinutes: selectedDuration)
                    allRoutes[idx] = (route: cappedRoute, data: correctedData, isDeadZoneFallback: existing.isDeadZoneFallback, isFromGoogle: true)
                    if currentRouteIndex == idx {
                        generatedRoute = cappedRoute
                        generatedRouteData = correctedData
                        lastValidRoute = cappedRoute
                        lastValidRouteData = correctedData
                    }
                    print("[ROUTE_DEBUG] 🔄 SWEEP: '\(target.name)' updated → \(googleDurMin)min / \(googleResult.distanceMeters)m (was \(existing.route.durationMinutes)min / \(existing.route.distanceMeters)m)")
                    
                    // Store in cross-bucket pool if out-of-band
                    if !Self.isRouteInBand(cappedRoute, selectedDuration: selectedDuration) {
                        storeCrossBucketRoute(route: cappedRoute, data: correctedData, isFromGoogle: true)
                    }
                }
            } else {
                print("[ROUTE_DEBUG] 🔄 SWEEP: '\(target.name)' Google re-measure FAILED — keeping original values")
            }
        }
        
        print("[ROUTE_DEBUG] 🔄 SWEEP: complete")
    }
    
    // MARK: - v2.1.9: Cross-Bucket Route Pool
    
    /// Store an out-of-band route in the cross-bucket pool for potential reuse at its actual duration.
    /// Only stores Google-verified routes whose actual duration lands in a different 5-min bucket than the current request.
    private func storeCrossBucketRoute(route: WalkingRoute, data: GeneratedRoute, isFromGoogle: Bool) {
        let currentBucket = RouteCacheService.roundToNearest5Minutes(selectedDuration)
        RouteCacheService.shared.addToSessionCrossBucket(route: route, data: data, isFromGoogle: isFromGoogle, currentBucket: currentBucket)
    }
    
    /// Retrieve and remove routes from the session cross-bucket pool that are in-band for the given duration.
    /// Returns routes ready to be added to allRoutes. Removes them from the pool once consumed.
    private func consumeCrossBucketRoutes(for targetDuration: Int) -> [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)] {
        let entries = RouteCacheService.shared.consumeSessionCrossBucket(for: targetDuration) { route, sel in
            Self.isRouteInBand(route, selectedDuration: sel)
        }
        return entries.map { entry in
            let cappedRoute = Self.applyDurationSanityCap(entry.route, targetDurationMinutes: targetDuration)
            return (route: cappedRoute, data: entry.data, isDeadZoneFallback: false, isFromGoogle: entry.isFromGoogle)
        }
    }
    
    /// Waypoint distance bands (minMult, maxMult) for main out-of-band Google attempts. Distances are duration * mult (meters). Per-bucket so short durations don't get tiny routes and long durations get long enough round-trips. Applies to all buckets (5–60 min).
    private static func outOfBandWaypointBands(for duration: Int) -> [(minMult: Double, maxMult: Double)] {
        let rounded = RouteCacheService.roundToNearest5Minutes(duration)
        switch rounded {
        case 5, 10, 15:
            return [(24, 26), (26, 28), (22, 24)]
        case 20, 25, 30:
            return [(20, 22), (22, 24), (18, 21)]
        default:
            return [(22, 25), (25, 28), (20, 23)]
        }
    }
    
    /// For prepop: run MapKit for every route in allRoutes, update each route's preview time (and polyline/directions) to MapKit's result; then if user has only looked at route 1, reorder so MapKit-valid routes come first. Never removes routes.
    private func prepopMapKitValidateAndReorder(userLocation: CLLocationCoordinate2D, selectedDuration: Int) async {
        let (minAcceptable, maxAcceptable) = Self.minMaxAcceptableMinutes(for: selectedDuration)
        var isValidByRouteName: [String: Bool] = [:]
        
        let countAndNames: (count: Int, names: [String]) = await MainActor.run {
            guard !allRoutes.isEmpty else { return (0, []) }
            let names = allRoutes.map { $0.route.name }
            return (allRoutes.count, names)
        }
        guard countAndNames.count > 0 else { return }
        let count = countAndNames.count
        let names = countAndNames.names
        
        for i in 0..<count {
            if await MainActor.run(body: { shouldCancelBackgroundWork }) {
                print("📦 PREPOP MAPKIT: Cancelled - user initiated action")
                return
            }
            
            let routeName = names[i]
            let entry: (route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool, isFromGoogle: Bool)? = await MainActor.run {
                guard let idx = allRoutes.firstIndex(where: { $0.route.name == routeName }) else { return nil }
                let e = allRoutes[idx]
                return (e.route, e.data, e.isDeadZoneFallback, e.isFromGoogle)
            }
            guard let (route, data, isDeadZoneFallback, isFromGoogle) = entry else { continue }
            
            // v2.1.9: Skip validation for Google-remeasured routes — Google is more accurate
            if isFromGoogle {
                isValidByRouteName[route.name] = route.durationMinutes >= minAcceptable && route.durationMinutes <= maxAcceptable
                print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) skipped — already Google-remeasured (\(route.durationMinutes) min)")
                continue
            }
            
            // v2.1.10: Try Google re-measure FIRST (more accurate than MapKit for walking routes)
            // This is the safety net that catches routes with synthetic prepop estimates
            var didGoogleRemeasure = false
            if mapsService.hasAPIKey && !data.places.isEmpty {
                print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) '\(route.name)': attempting Google re-measure (current: \(route.durationMinutes)min / \(route.distanceMeters)m)")
                if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation, waypoints: data.places, targetDurationMinutes: selectedDuration) {
                    let googleDurMin = max(1, googleResult.durationSeconds / 60)
                    let isValid = googleDurMin >= minAcceptable && googleDurMin <= maxAcceptable
                    let updatedRoute = WalkingRoute(
                        name: route.name,
                        description: route.description,
                        durationMinutes: googleDurMin,
                        distanceMeters: googleResult.distanceMeters,
                        difficulty: route.difficulty,
                        isIndoor: route.isIndoor,
                        isAccessible: route.isAccessible,
                        landmarks: route.landmarks,
                        icon: route.icon,
                        color: route.color,
                        qrMarkers: route.qrMarkers,
                        routeType: route.routeType,
                        trimmed: route.trimmed,
                        walkingDirections: route.walkingDirections,
                        usedOSRMRouting: route.usedOSRMRouting,
                        isFromPrePopulatedDatabase: route.isFromPrePopulatedDatabase,
                        travelToStartMinutes: route.travelToStartMinutes
                    )
                    let updatedData = GeneratedRoute(
                        places: data.places,
                        polyline: data.polyline,
                        distanceMeters: googleResult.distanceMeters,
                        durationSeconds: googleResult.durationSeconds,
                        legs: data.legs,
                        usedOSRM: data.usedOSRM,
                        travelToStartSeconds: data.travelToStartSeconds
                    )
                    isValidByRouteName[route.name] = isValid
                    didGoogleRemeasure = true
                    await MainActor.run {
                        if let idx = allRoutes.firstIndex(where: { $0.route.name == routeName }) {
                            allRoutes[idx] = (route: updatedRoute, data: updatedData, isDeadZoneFallback: isDeadZoneFallback, isFromGoogle: true)
                            if currentRouteIndex == idx {
                                generatedRoute = updatedRoute
                                generatedRouteData = updatedData
                                lastValidRoute = updatedRoute
                                lastValidRouteData = updatedData
                            }
                            print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) Google re-measured — \(googleDurMin) min / \(googleResult.distanceMeters)m (was \(route.durationMinutes)min / \(route.distanceMeters)m, valid: \(isValid))")
                        }
                    }
                    // v2.1.10: If Google re-measure puts route out-of-band, store in cross-bucket pool
                    if !isValid {
                        await MainActor.run {
                            storeCrossBucketRoute(route: updatedRoute, data: updatedData, isFromGoogle: true)
                        }
                    }
                } else {
                    print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) '\(route.name)': Google re-measure FAILED — falling back to MapKit")
                }
            }
            
            // Fall back to MapKit if Google wasn't available or failed
            if !didGoogleRemeasure {
                let mapKitRoute = await mapsService.refreshRouteWithMapKit(route: route, userLocation: userLocation)
                if mapKitRoute.durationMinutes > 0, let poly = mapKitRoute.trimmed, !poly.isEmpty {
                    let durationMin = mapKitRoute.durationMinutes
                    let isValid = durationMin >= minAcceptable && durationMin <= maxAcceptable
                    let updatedRoute = WalkingRoute(
                        name: route.name,
                        description: route.description,
                        durationMinutes: durationMin,
                        distanceMeters: mapKitRoute.distanceMeters,
                        difficulty: route.difficulty,
                        isIndoor: route.isIndoor,
                        isAccessible: route.isAccessible,
                        landmarks: route.landmarks,
                        icon: route.icon,
                        color: route.color,
                        qrMarkers: route.qrMarkers,
                        routeType: route.routeType,
                        trimmed: poly,
                        walkingDirections: mapKitRoute.walkingDirections,
                        usedOSRMRouting: route.usedOSRMRouting,
                        isFromPrePopulatedDatabase: route.isFromPrePopulatedDatabase,
                        travelToStartMinutes: route.travelToStartMinutes
                    )
                    let updatedData = GeneratedRoute(
                        places: data.places,
                        polyline: poly,
                        distanceMeters: mapKitRoute.distanceMeters,
                        durationSeconds: durationMin * 60,
                        legs: data.legs,
                        usedOSRM: data.usedOSRM,
                        travelToStartSeconds: data.travelToStartSeconds
                    )
                    isValidByRouteName[route.name] = isValid
                    await MainActor.run {
                        if let idx = allRoutes.firstIndex(where: { $0.route.name == routeName }) {
                            allRoutes[idx] = (route: updatedRoute, data: updatedData, isDeadZoneFallback: isDeadZoneFallback, isFromGoogle: false)
                            if currentRouteIndex == idx {
                                generatedRoute = updatedRoute
                                generatedRouteData = updatedData
                                lastValidRoute = updatedRoute
                                lastValidRouteData = updatedData
                            }
                            print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) MapKit fallback — \(durationMin) min (valid: \(isValid))")
                        }
                    }
                } else {
                    isValidByRouteName[route.name] = false
                    print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Route \(i + 1)/\(count) MapKit returned empty — marking invalid")
                }
            }
        }
        
        let shouldReorder: Bool = await MainActor.run {
            currentRouteIndex == 0 && isValidByRouteName.values.contains(true)
        }
        guard shouldReorder else { return }
        
        await MainActor.run {
            let ordered = allRoutes.enumerated().sorted { a, b in
                let validA = isValidByRouteName[a.element.route.name] ?? false
                let validB = isValidByRouteName[b.element.route.name] ?? false
                if validA != validB { return validA }
                return a.offset < b.offset
            }
            allRoutes = ordered.map(\.element)
            print("[ROUTE_DEBUG] 📦 PREPOP VALIDATE: Reordered — valid routes first (\(allRoutes.count) total)")
            logRoutePreviewSummary()
        }
    }
    
    // MARK: - v1.9.41: Background MapKit Route Refresh
    
    /// Refreshes the route with MapKit in the background after walk starts
    /// This is called when Google API was unavailable/failed, giving instant start + better navigation
    /// The rate limiter ensures this doesn't conflict with other MapKit operations
    private func refreshRouteInBackground(
        route: WalkingRoute,
        viewModel: WaitingRoomViewModel,
        locationService: LocationService,
        mapsService: GoogleMapsService
    ) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        
        // Wait a moment for walk to fully start and location to stabilize
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds
        
        let startTime = Date()
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [BG REFRESH] [\(timeString)] 🚀 Background MapKit refresh starting...")
        
        // Check if walk is still active
        let isActive = await MainActor.run { viewModel.walkSession.isActive }
        guard isActive else {
            print("⏱️ [BG REFRESH] [\(timeString)] ❌ Walk ended - skipping refresh")
            return
        }
        
        // Get current user location
        let userLocation = await MainActor.run { locationService.currentLocation?.coordinate }
        guard let location = userLocation else {
            print("⏱️ [BG REFRESH] [\(timeString)] ❌ No location available - skipping refresh")
            return
        }
        
        print("⏱️ [BG REFRESH] [\(timeString)] 📍 User location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("⏱️ [BG REFRESH] [\(timeString)] 🎯 Waypoints: \(route.qrMarkers.count)")
        
        // Refresh route with MapKit (uses rate limiter internally)
        let refreshedRoute = await mapsService.refreshRouteWithMapKit(
            route: route,
            userLocation: location
        )
        
        let elapsed = Date().timeIntervalSince(startTime)
        let endTimeString = formatter.string(from: Date())
        
        print("⏱️ [BG REFRESH] [\(endTimeString)] ⏱️ MapKit refresh took \(String(format: "%.2f", elapsed))s")
        
        // Check again if walk is still active before updating
        let stillActive = await MainActor.run { viewModel.walkSession.isActive }
        guard stillActive else {
            print("⏱️ [BG REFRESH] [\(endTimeString)] ⚠️ Walk ended during refresh - not updating route")
            return
        }
        
        // Update route on main thread
        await MainActor.run {
            let updateTimeString = formatter.string(from: Date())
            
            // Compare quality - only update if refreshed route is valid
            let oldDirections = route.walkingDirections.count
            let newDirections = refreshedRoute.walkingDirections.count
            let oldDistance = route.distanceMeters
            let newDistance = refreshedRoute.distanceMeters
            
            print("⏱️ [BG REFRESH] [\(updateTimeString)] 📊 Route comparison:")
            print("⏱️ [BG REFRESH] [\(updateTimeString)]   Original: \(oldDirections) directions, \(oldDistance)m")
            print("⏱️ [BG REFRESH] [\(updateTimeString)]   Refreshed: \(newDirections) directions, \(newDistance)m")
            
            // Only update if refreshed route has valid directions (use updateCurrentRoute so pill stays in sync and never reverts to longer duration)
            if newDirections > 0 {
                print("PILL | caller: MapKit background refresh — route=\(refreshedRoute.durationMinutes)min before: display=\(viewModel.displayDurationMinutesForPill ?? -1) lock=\(viewModel.hasReceivedGoogleRefreshForPill)")
                viewModel.updateCurrentRoute(refreshedRoute)
                
                print("⏱️ [BG REFRESH] [\(updateTimeString)] ✅ Route updated successfully!")
                print("╔═══════════════════════════════════════════════════════════╗")
                print("║  🔄 BACKGROUND ROUTE REFRESH COMPLETE                     ║")
                print("╠═══════════════════════════════════════════════════════════╣")
                print("║  Duration: \(String(format: "%.1f", elapsed))s")
                print("║  Directions: \(oldDirections) → \(newDirections)")
                print("║  Distance: \(oldDistance)m → \(newDistance)m")
                print("╚═══════════════════════════════════════════════════════════╝")
            } else {
                print("⏱️ [BG REFRESH] [\(updateTimeString)] ⚠️ Refreshed route has no directions - keeping original")
            }
        }
    }
    
    /// Wrapper for shuffle that manages the shuffle loading state
    func generateRouteForShuffle() {
        guard let userLocation = locationService.currentLocation else {
            isShuffling = false
            return
        }
        
        // 🔧 DEBUG: Database-only mode - don't generate new routes via shuffle
        if RoutingToggles.databaseOnlyMode {
            print("🚫 [DATABASE-ONLY MODE] Shuffle disabled - only database routes allowed")
            Task { @MainActor in
                isShuffling = false
                errorMessage = "DATABASE-ONLY MODE: Shuffle disabled. Only pre-populated routes allowed."
            }
            return
        }
        
        if mapsService.hasAPIKey {
            Task {
                do {
                    // Flatten all previously shown place IDs to exclude from new route
                    let excludedPlaceIds = await MainActor.run {
                        shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                    
                    // v1.9.51: Also collect actual POI objects from previous routes for duplicate detection
                    let excludedPOIs = await MainActor.run {
                        allRoutes.flatMap { $0.data.places }
                    }
                    
                    // Use pre-fetched POIs if available
                    let poisToUse = await MainActor.run {
                        prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    }
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        excludePOIs: excludedPOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                        prefetchedPOIs: poisToUse
                    )
                    
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        await MainActor.run {
                            // Recycle previous route if available
                            if let previousRoute = lastValidRoute, let previousData = lastValidRouteData {
                                generatedRoute = previousRoute
                                generatedRouteData = previousData
                                isRecycledRoute = true
                            } else {
                                errorMessage = "Could not find different places nearby. Try changing options."
                            }
                            isShuffling = false
                            showMapPreview = true
                        }
                        return
                    }
                    
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                    }
                    
                    guard !markers.isEmpty else {
                        await MainActor.run {
                            // Recycle previous route if available
                            if let previousRoute = lastValidRoute, let previousData = lastValidRouteData {
                                generatedRoute = previousRoute
                                generatedRouteData = previousData
                                isRecycledRoute = true
                            } else {
                                errorMessage = "No discovery spots could be created. Try changing options."
                            }
                            isShuffling = false
                            showMapPreview = true
                        }
                        return
                    }
                    
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: result.legs, waypoints: result.places)
                    }
                    
                    // v1.9.49: Start route naming in parallel (Optimization 4: Parallel Gemini Naming)
                    // Start naming as soon as we have POIs, in parallel with directions
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    
                    // Start Gemini naming in parallel (has 3s timeout, template fallback)
                    let namingTask = Task {
                        await GeminiService.shared.generateRouteContent(
                            waypoints: waypointInfos,
                            durationMinutes: result.durationMinutes,
                            distanceMeters: result.distanceMeters,
                            difficulty: nil
                        )
                    }
                    
                    // v1.6.14: If no directions, get them from Apple MapKit (in parallel with naming)
                    if directions.isEmpty && !result.places.isEmpty {
                        let waypointCoords = result.places.map { $0.coordinate }
                        let waypointNames = result.places.map { $0.name }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate,
                            waypointNames: waypointNames
                        )
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    // Get route name (should be ready or nearly ready by now)
                    let aiContent = await namingTask.value
                    
                    let routeName = aiContent.name
                    let description = aiContent.description
                    
                    await MainActor.run {
                        let route = WalkingRoute(
                            name: routeName,
                            description: description,
                            durationMinutes: max(1, result.durationMinutes),
                            distanceMeters: result.distanceMeters,
                            difficulty: routeDifficulty,
                            isIndoor: false,
                            isAccessible: true,
                            landmarks: ["Start"] + result.places.map { $0.name } + ["Return"],
                            icon: "location.fill",
                            color: .tealAccent,
                            qrMarkers: markers,
                            routeType: .local,
                            trimmed: result.polyline,
                            walkingDirections: directions,
                            usedOSRMRouting: result.usedOSRM  // v1.7.1: Track OSRM usage
                        )
                        
                        // Check if this route has been shown before in this session
                        let newPlaceIds = Set(result.places.map { $0.placeId })
                        let isRepeatRoute = shownPlaceIdSets.contains(newPlaceIds)
                        
                        // Track this route combination
                        if !isRepeatRoute {
                            shownPlaceIdSets.append(newPlaceIds)
                        }
                        
                        // Save as last valid route for recycling
                        lastValidRoute = route
                        lastValidRouteData = result
                        
                        generatedRoute = route
                        generatedRouteData = result
                        isRecycledRoute = isRepeatRoute  // True if same places shown before
                        showMapPreview = true
                        isShuffling = false
                        
                        if isRepeatRoute {
                            print("🔄 Shuffle returned previously shown places - marking as recycled")
                        } else {
                            print("✨ New route combination shown (total unique: \(shownPlaceIdSets.count))")
                        }
                    }
                } catch {
                    await MainActor.run {
                        // If we have a previous valid route, recycle it
                        if let previousRoute = lastValidRoute, let previousData = lastValidRouteData {
                            generatedRoute = previousRoute
                            generatedRouteData = previousData
                            isRecycledRoute = true
                            showMapPreview = true
                            isShuffling = false
                        } else {
                            isShuffling = false
                            showMapPreview = true
                            errorMessage = "No routes available within time limit. Try changing your options."
                        }
                    }
                }
            }
        } else {
            // No API - recycle previous or show error
            if let previousRoute = lastValidRoute, let previousData = lastValidRouteData {
                generatedRoute = previousRoute
                generatedRouteData = previousData
                isRecycledRoute = true
                showMapPreview = true
                isShuffling = false
            } else {
                isShuffling = false
                showMapPreview = true
                errorMessage = "Maps service not available."
            }
        }
    }
    
    /// Handle shuffle button press - cycles through displayed (in-band) routes only
    func shuffleToNextRoute() {
        let displayed = displayedRouteIndices
        guard displayed.count > 1 else {
            print("🔀 Only 1 displayed route - Next button disabled")
            return
        }
        
        // v1.6.46: Track that user skipped the current route (decreases its quality score)
        if let currentRoute = generatedRoute, let userLocation = locationService.currentLocation {
            RouteCacheService.shared.incrementSkipCount(
                routeName: currentRoute.name,
                at: userLocation.coordinate,
                durationMinutes: selectedDuration
            )
        }
        
        // Cycle to next in displayed (in-band) list
        if let pos = displayed.firstIndex(of: currentRouteIndex), pos + 1 < displayed.count {
            currentRouteIndex = displayed[pos + 1]
            let nextRoute = allRoutes[currentRouteIndex]
            
            // #region agent log
            if nextRoute.route.qrMarkers.count > 1 {
                let distances = (0..<nextRoute.route.qrMarkers.count-1).map { i in
                    let loc1 = CLLocation(latitude: nextRoute.route.qrMarkers[i].coordinate.latitude, longitude: nextRoute.route.qrMarkers[i].coordinate.longitude)
                    let loc2 = CLLocation(latitude: nextRoute.route.qrMarkers[i+1].coordinate.latitude, longitude: nextRoute.route.qrMarkers[i+1].coordinate.longitude)
                    return loc1.distance(from: loc2)
                }
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "G",
                    "location": "RouteSelectionView.swift:3143",
                    "message": "Route displayed (shuffle): final waypoint distances",
                    "data": [
                        "routeName": nextRoute.route.name,
                        "routeIndex": currentRouteIndex,
                        "waypointCount": nextRoute.route.qrMarkers.count,
                        "waypoints": nextRoute.route.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                        "distances": distances,
                        "minDistance": distances.min() ?? 0,
                        "source": "shuffle"
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                   let logString = String(data: logJSON, encoding: .utf8) {
                    logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
            }
            // #endregion
            
            generatedRoute = nextRoute.route
            generatedRouteData = nextRoute.data
            print("[ROUTE_DEBUG] 📦 SET_STATE (shuffle): generatedRouteData=\(nextRoute.data.durationSeconds)s/\(nextRoute.data.distanceMeters)m, generatedRoute=\(nextRoute.route.durationMinutes)min/\(nextRoute.route.distanceMeters)m, idx=\(currentRouteIndex)")
            // Check if this route has been viewed before
            isRecycledRoute = viewedRouteIndices.contains(currentRouteIndex)
            viewedRouteIndices.insert(currentRouteIndex)  // Mark as viewed
            
            // v1.6.47: Use per-route flag instead of calculating (more accurate)
            isDeadZoneFallback = nextRoute.isDeadZoneFallback
            
            // v2.1.11: Request MapKit polyline for preview if route only has synthetic straight lines
            refreshPreviewPolylineIfNeeded(at: currentRouteIndex)
            
            print("🔀 Showing route \(displayed.firstIndex(of: currentRouteIndex)! + 1) of \(displayed.count) (recycled: \(isRecycledRoute), fallback: \(isDeadZoneFallback))")
        } else {
            // v1.6.45: At last displayed route - cycle back to first displayed (no dialog)
            currentRouteIndex = displayed[0]
            let firstRoute = allRoutes[currentRouteIndex]
            
            // #region agent log
            if firstRoute.route.qrMarkers.count > 1 {
                let distances = (0..<firstRoute.route.qrMarkers.count-1).map { i in
                    let loc1 = CLLocation(latitude: firstRoute.route.qrMarkers[i].coordinate.latitude, longitude: firstRoute.route.qrMarkers[i].coordinate.longitude)
                    let loc2 = CLLocation(latitude: firstRoute.route.qrMarkers[i+1].coordinate.latitude, longitude: firstRoute.route.qrMarkers[i+1].coordinate.longitude)
                    return loc1.distance(from: loc2)
                }
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "G",
                    "location": "RouteSelectionView.swift:3157",
                    "message": "Route displayed (cycle back): final waypoint distances",
                    "data": [
                        "routeName": firstRoute.route.name,
                        "routeIndex": 0,
                        "waypointCount": firstRoute.route.qrMarkers.count,
                        "waypoints": firstRoute.route.qrMarkers.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                        "distances": distances,
                        "minDistance": distances.min() ?? 0,
                        "source": "cycle"
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                   let logString = String(data: logJSON, encoding: .utf8) {
                    logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
            }
            // #endregion
            
            generatedRoute = firstRoute.route
            generatedRouteData = firstRoute.data
            isRecycledRoute = true  // Always recycled when cycling back
            showPremiumUpsell = true  // Show upgrade message when all routes viewed
            
            // v1.6.47: Use per-route flag instead of calculating
            isDeadZoneFallback = firstRoute.isDeadZoneFallback
            
            // v2.1.11: Request MapKit polyline for preview if needed
            refreshPreviewPolylineIfNeeded(at: currentRouteIndex)
            
            print("🔄 Cycling back to route 1 of \(displayed.count)")
        }
    }
    
    /// Trigger MapKit polyline refresh for a route at the given index if it only has a synthetic polyline.
    /// Synthetic polylines from the soft-cap estimator have <10 points (straight lines between waypoints).
    /// Real walking polylines from MapKit have 20+ points that follow actual roads.
    private func refreshPreviewPolylineIfNeeded(at index: Int) {
        guard allRoutes.indices.contains(index) else { return }
        let route = allRoutes[index].route
        // Already has a real polyline (10+ points) or uses OSRM — skip
        if route.routePath.count >= 10 || route.usedOSRMRouting { return }
        // No waypoints to route through — skip
        guard !route.qrMarkers.isEmpty else { return }
        guard let userLoc = locationService.currentLocation?.coordinate else { return }
        
        print("🗺️ [POLYLINE-PREVIEW] Route '\(route.name)' has \(route.routePath.count) polyline points — requesting MapKit refresh")
        Task {
            let refreshed = await mapsService.refreshRouteWithMapKit(route: route, userLocation: userLoc)
            await MainActor.run {
                guard allRoutes.indices.contains(index),
                      allRoutes[index].route.name == route.name else { return }
                // Only update if MapKit gave us a real polyline
                if refreshed.routePath.count >= 10 {
                    allRoutes[index].route = refreshed
                    if currentRouteIndex == index {
                        generatedRoute = refreshed
                    }
                    print("🗺️ [POLYLINE-PREVIEW] ✅ '\(route.name)' updated with \(refreshed.routePath.count)-point MapKit polyline")
                } else {
                    print("🗺️ [POLYLINE-PREVIEW] ⚠️ MapKit returned \(refreshed.routePath.count) points for '\(route.name)' — keeping as-is")
                }
            }
        }
    }
    
    /// Pre-generate remaining routes in background for instant shuffling
    func preGenerateRemainingRoutes() {
        guard let userLocation = locationService.currentLocation else { return }
        guard mapsService.hasAPIKey else { return }
        guard !isPreGeneratingRoutes else { return }
        
        // 🔧 DEBUG: Database-only mode - don't pre-generate additional routes
        if RoutingToggles.databaseOnlyMode {
            print("🚫 [DATABASE-ONLY MODE] Pre-generation disabled - only database routes allowed")
            return
        }
        
        isPreGeneratingRoutes = true
        varietyExhausted = false
        shouldCancelBackgroundWork = false  // v1.9.22: Reset cancel flag
        
        // v2.1.9: Inject cross-bucket routes from pool before generating new ones
        let crossBucketInjected = consumeCrossBucketRoutes(for: selectedDuration)
        if !crossBucketInjected.isEmpty {
            var injectedCount = 0
            for injected in crossBucketInjected {
                // Deduplicate against existing allRoutes
                let newSig = Set(injected.data.places.map { $0.placeId })
                let isDup = allRoutes.contains { existing in
                    Set(existing.data.places.map { $0.placeId }) == newSig
                }
                guard !isDup else {
                    print("[ROUTE_DEBUG] 🔄 Skipping duplicate during injection: '\(injected.route.name)'")
                    continue
                }
                let added = appendRouteIfAllowed(
                    route: injected.route,
                    data: injected.data,
                    isDeadZoneFallback: injected.isDeadZoneFallback,
                    isFromGoogle: injected.isFromGoogle,
                    source: "cross-bucket-inject"
                )
                if added {
                    registerRouteSignature(places: injected.data.places, distanceMeters: injected.data.distanceMeters)
                    shownPlaceIdSets.append(Set(injected.data.places.map { $0.placeId }))
                    injectedCount += 1
                }
            }
            if injectedCount > 0 {
                print("[ROUTE_DEBUG] 🔄 Injected \(injectedCount) route(s) from previous duration searches")
                logRoutePreviewSummary()
            }
        }
        
        // Check if cross-bucket injection already satisfied our in-band target
        if hasEnoughInBandRoutes() {
            print("[ROUTE_GEN] ⏹️ Cross-bucket injection gave us \(inBandRouteCount())/\(targetInBandRoutes) in-band routes — skipping pre-generation")
            isPreGeneratingRoutes = false
            preGenerationComplete = true
            logRoutePreviewSummary()
            logRunSummary()
            // Session cache: so Cancel → Generate again is instant when we had enough from cross-bucket
            let sessionMeta = allRoutes.map { e in
                RouteCacheService.CachedRouteWithMetadata(
                    route: e.data,
                    name: e.route.name,
                    description: e.route.description,
                    directions: e.route.walkingDirections,
                    isDeadZoneFallback: e.isDeadZoneFallback,
                    isFromPrePopulatedDatabase: false
                )
            }
            if let coord = locationService.currentLocation?.coordinate {
                RouteCacheService.shared.setSessionRoutes(sessionMeta, at: coord, durationMinutes: selectedDuration)
            }
            return
        }
        
        print("🚀 Starting background pre-generation (need \(targetInBandRoutes - inBandRouteCount()) more in-band routes)...")
        
        Task {
            let preGenTaskStart = Date()
            var routesGenerated = allRoutes.count
            var consecutiveDuplicates = 0
            let maxConsecutiveDuplicates = 3  // Stop after 3 duplicates in a row - variety exhausted
            var consecutiveFailures = 0
            let maxConsecutiveFailures = 3  // Reduced from 5 - stop earlier if failing
            
            // Get pre-fetched POIs once for all iterations
            let poisToUse = await MainActor.run { prefetchedPOIs.isEmpty ? nil : prefetchedPOIs }
            
            while routesGenerated < maxRoutesToGenerate && consecutiveFailures < maxConsecutiveFailures && consecutiveDuplicates < maxConsecutiveDuplicates {
                // Check if we've reached the in-band target
                let currentInBand = await MainActor.run { inBandRouteCount() }
                if currentInBand >= targetInBandRoutes {
                    print("[ROUTE_GEN] ⏹️ Reached \(currentInBand)/\(targetInBandRoutes) in-band routes — stopping pre-generation")
                    // Immediately dismiss the loading indicator — post-loop work (sweep, fallback) continues silently
                    await MainActor.run {
                        if isPreGeneratingRoutes {
                            isPreGeneratingRoutes = false
                            preGenerationComplete = true
                            print("[ROUTE_GEN] ✅ Loading indicator dismissed (2/2 in-band reached)")
                        }
                    }
                    break
                }
                // v1.9.22: Check if user action cancelled background work
                let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                if shouldCancel {
                    print("🛑 Background generation cancelled - user initiated action")
                    await MainActor.run { isPreGeneratingRoutes = false }
                    return
                }
                
                // v1.6.33: Check rate limit - pause briefly if too high
                if await mapsService.shouldPauseBackgroundGeneration() {
                    // Wait 5 seconds then continue (quota refreshes over time)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    // Don't skip - just continue after brief pause
                }
                
                do {
                    // Collect all place IDs we've already used
                    let excludedPlaceIds = await MainActor.run {
                        shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                    
                    // v1.9.51: Also collect actual POI objects from previous routes for duplicate detection
                    let excludedPOIs = await MainActor.run {
                        allRoutes.flatMap { $0.data.places }
                    }
                    
                    // v1.8.15: Smart multi-waypoint - only for 30+ min routes where it helps
                    // For shorter routes (10-25min), multi-waypoint mode often produces WORSE results
                    // because the POI pool is smaller and falls back to suboptimal single-waypoint routes
                    let currentRouteCount = await MainActor.run { allRoutes.count }
                    let preferMulti = currentRouteCount >= 1 && currentRouteCount <= 3 && selectedDuration >= 30  // Routes 2-4, 30+ min only
                    
                    var result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        excludePOIs: excludedPOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                        prefetchedPOIs: poisToUse,
                        preferMultiWaypoint: preferMulti
                    )
                    
                    // Validate result
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        consecutiveFailures += 1
                        continue
                    }
                    
                    // v1.9.52: Use enhanced duplicate detection - checks BOTH signature AND primary POI
                    // This prevents routes like "Star Inn Saunter" and "Star Inn Peek" from both appearing
                    let isUnique = await MainActor.run {
                        isRouteTrulyUnique(places: result.places, distanceMeters: result.distanceMeters)
                    }
                    
                    if !isUnique {
                        consecutiveDuplicates += 1
                        print("⚠️ Duplicate route detected (signature or primary POI) - \(consecutiveDuplicates)/\(maxConsecutiveDuplicates)")
                        if consecutiveDuplicates >= maxConsecutiveDuplicates {
                            print("🛑 Variety exhausted - stopping early (found \(routesGenerated) unique routes)")
                            await MainActor.run { varietyExhausted = true }
                        }
                        continue
                    }
                    
                    // Reset duplicate counter on finding unique route
                    consecutiveDuplicates = 0
                    
                    // Create markers and directions
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                    }
                    
                    guard !markers.isEmpty else {
                        consecutiveFailures += 1
                        continue
                    }
                    
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: result.legs, waypoints: result.places)
                    }
                    
                    // v1.6.14: If no directions, get them from Apple MapKit
                    if directions.isEmpty && !result.places.isEmpty {
                        let waypointCoords = result.places.map { $0.coordinate }
                        let waypointNames = result.places.map { $0.name }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate,
                            waypointNames: waypointNames
                        )
                    }
                    
                    // v1.9.49: Start route naming in parallel (Optimization 4: Parallel Gemini Naming)
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    
                    // Start Gemini naming in parallel (has 3s timeout, template fallback)
                    let namingTask = Task {
                        await GeminiService.shared.generateRouteContent(
                            waypoints: waypointInfos,
                            durationMinutes: result.durationMinutes,
                            distanceMeters: result.distanceMeters,
                            difficulty: nil
                        )
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    // Get route name (should be ready or nearly ready by now)
                    let aiContent = await namingTask.value
                    
                    let routeName = aiContent.name
                    let description = aiContent.description
                    
                    var route = WalkingRoute(
                        name: routeName,
                        description: description,
                        durationMinutes: max(1, result.durationMinutes),
                        distanceMeters: result.distanceMeters,
                        difficulty: routeDifficulty,
                        isIndoor: false,
                        isAccessible: true,
                        landmarks: ["Start"] + result.places.map { $0.name } + ["Return"],
                        icon: "location.fill",
                        color: .tealAccent,
                        qrMarkers: markers,
                        routeType: .local,
                        trimmed: result.polyline,
                        walkingDirections: directions,
                        usedOSRMRouting: result.usedOSRM  // v1.7.1: Track OSRM usage
                    )
                    var isFromGoogle = result.usedGoogleDirections
                    // v2.1.12: Skip explicit re-measure if generateLocalRoute already used Google Directions
                    if isFromGoogle {
                        print("[ROUTE_DEBUG] 🔍 PRE-GEN route '\(route.name)': already Google-measured (\(route.durationMinutes)min, \(route.distanceMeters)m) — skipping redundant re-measure")
                    } else if mapsService.hasAPIKey && !result.places.isEmpty {
                        // 🔍 DIAGNOSTIC: Log values BEFORE Google re-measure
                        let preGoogleDur = route.durationMinutes
                        let preGoogleDist = route.distanceMeters
                        let preGoogleWaypoints = result.places.map { "'\($0.name)' (\(String(format: "%.5f", $0.coordinate.latitude)),\(String(format: "%.5f", $0.coordinate.longitude)))" }.joined(separator: ", ")
                        print("[ROUTE_DEBUG] 🔍 PRE-GEN route '\(route.name)': BEFORE Google: \(preGoogleDur) min, \(preGoogleDist) m, waypoints=[\(preGoogleWaypoints)]")
                        if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: result.places, targetDurationMinutes: selectedDuration) {
                            // 🔍 DIAGNOSTIC: Log Google re-measure result
                            print("[ROUTE_DEBUG] 🔍 PRE-GEN route '\(route.name)': Google re-measure: \(googleResult.durationSeconds)s (\(googleResult.durationSeconds/60)min), \(googleResult.distanceMeters)m")
                            route = WalkingRoute(
                                name: route.name,
                                description: route.description,
                                durationMinutes: max(1, googleResult.durationSeconds / 60),
                                distanceMeters: googleResult.distanceMeters,
                                difficulty: route.difficulty,
                                isIndoor: route.isIndoor,
                                isAccessible: route.isAccessible,
                                landmarks: route.landmarks,
                                icon: route.icon,
                                color: route.color,
                                qrMarkers: route.qrMarkers,
                                routeType: route.routeType,
                                trimmed: route.trimmed,
                                walkingDirections: route.walkingDirections,
                                usedOSRMRouting: route.usedOSRMRouting,
                                isFromPrePopulatedDatabase: route.isFromPrePopulatedDatabase,
                                travelToStartMinutes: route.travelToStartMinutes
                            )
                            isFromGoogle = true
                            // v2.1.8: Update GeneratedRoute with Google values so e.data matches e.route
                            result = GeneratedRoute(
                                places: result.places,
                                polyline: result.polyline,
                                distanceMeters: googleResult.distanceMeters,
                                durationSeconds: googleResult.durationSeconds,
                                legs: result.legs
                            )
                        }
                    }
                    
                    await MainActor.run {
                        // v1.8.8: Check if route is too short (< 50% of target)
                        // Short routes are stored but not added - may use ONE at end if needed
                        let minAcceptablePercent = 0.50
                        let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                        let routeDuration = route.durationMinutes
                        
                        if routeDuration < minAcceptableDuration {
                            // Store for potential use at end if we have ≤2 routes
                            rejectedShortRoutes.append((route: route, data: result))
                            // v2.1.9: Also store in cross-bucket pool for the route's actual duration
                            if isFromGoogle {
                                storeCrossBucketRoute(route: route, data: result, isFromGoogle: isFromGoogle)
                            }
                            print("📦 Stored short route (\(routeDuration)min < \(minAcceptableDuration)min) - may use later if needed")
                            consecutiveFailures += 1  // Count as failure for loop control
                            return
                        }
                        
                        // FINAL SAFETY CHECK: Deduplicate before storing
                        let deduplicatedResult = mapsService.finalizeRouteDedupForView(result)
                        
                        // Only show in-band routes; out-of-band routes go to cross-bucket pool
                        let cappedRoute = Self.applyDurationSanityCap(route, targetDurationMinutes: selectedDuration)
                        
                        let added = appendRouteIfAllowed(
                            route: cappedRoute,
                            data: deduplicatedResult,
                            isFromGoogle: isFromGoogle,
                            source: "pre-gen-loop"
                        )
                        
                        if !added {
                            consecutiveFailures += 1
                            return
                        }
                        
                        // v1.6.25: Register route signature for deduplication
                        registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                        let placeIds = Set(result.places.map { $0.placeId })
                        shownPlaceIdSets.append(placeIds)
                        
                        routesGenerated = allRoutes.count
                        consecutiveFailures = 0  // Reset on success
                        print("✅ Pre-generated route \(routesGenerated) (unique: \(routeSignatures.count))")
                        
                        // v1.6.45: Auto-advance to first AI route when user is still on placeholder
                        if allRoutes.count == 2 && currentRouteIndex == 0 {
                            currentRouteIndex = 1
                            let newRoute = allRoutes[1]
                            generatedRoute = newRoute.route
                            generatedRouteData = newRoute.data
                            viewedRouteIndices.insert(1)
                            print("🚀 Auto-advanced to first AI-generated route")
                        }
                        
                        // v1.6.26: Try waypoint permutation for 2+ waypoint routes (cap duration for display, all buckets)
                        if result.places.count >= 2 && !hasEnoughInBandRoutes() {
                            if let permuted = createPermutedRoute(from: cappedRoute, data: result, isDeadZoneFallback: false, isFromGoogle: isFromGoogle) {
                                let cappedP = permuted.route.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                                let permAdded = appendRouteIfAllowed(
                                    route: cappedP,
                                    data: permuted.data,
                                    isDeadZoneFallback: permuted.isDeadZoneFallback,
                                    isFromGoogle: permuted.isFromGoogle,
                                    source: "pre-gen-permuted"
                                )
                                if permAdded {
                                    registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                    routesGenerated = allRoutes.count
                                }
                            }
                        }
                        
                        // v1.6.47: Merge routes into cache - skip first (fast) route, only cache routes 2+
                        let routesToCache = Array(allRoutes.dropFirst()) // Skip fast-generated route 1
                        if !routesToCache.isEmpty {
                            let routeData = routesToCache.map { $0.data }
                            let routeNames = routesToCache.map { $0.route.name as String? }
                            let routeDescriptions = routesToCache.map { $0.route.description as String? }
                            let routeDirections = routesToCache.map { $0.route.walkingDirections }
                            let mergeResult = RouteCacheService.shared.mergeRoutes(
                                routeData,
                                at: userLocation.coordinate,
                                durationMinutes: selectedDuration,
                                names: routeNames,
                                descriptions: routeDescriptions,
                                directions: routeDirections
                            )
                            print("💾 Merged \(routesToCache.count) routes (skipped fast route 1): \(mergeResult.added) added, \(mergeResult.replaced) replaced")
                        }
                    }
                    
                } catch {
                    consecutiveFailures += 1
                    print("⚠️ Pre-generation error: \(error.localizedDescription)")
                }
                
                // Small delay between generations to avoid rate limiting
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
            
            // Check if we only found 1-2 routes - if so, try Google API for more POIs
            // But skip if we already have enough in-band routes
            let currentRouteCount = await MainActor.run { allRoutes.count }
            let inBandBeforeFallback = await MainActor.run { inBandRouteCount() }
            var updatedPOIs = poisToUse
            
            if currentRouteCount <= 2 && mapsService.hasAPIKey && inBandBeforeFallback < targetInBandRoutes {
                print("⚠️ Only \(currentRouteCount) routes found - calling Google API for more POIs...")
                
                let existingPOIs = poisToUse ?? []
                let newGooglePOIs = await mapsService.fetchGooglePOIsOnDemand(
                    location: userLocation.coordinate,
                    radiusMeters: 2500,
                    existingPOIs: existingPOIs
                )
                
                if !newGooglePOIs.isEmpty {
                    print("🌐 Got \(newGooglePOIs.count) new POIs from Google - generating more routes...")
                    
                    // Update POIs list with Google results
                    let combinedPOIs = existingPOIs + newGooglePOIs
                    updatedPOIs = combinedPOIs
                    
                    // Also update the prefetchedPOIs for future use
                    await MainActor.run {
                        prefetchedPOIs = combinedPOIs
                    }
                    
                    // Try generating more routes with the new POIs
                    var googleRoutesGenerated = 0
                    let maxGoogleRoutes = 5  // Try to get up to 5 more routes from Google
                    var googleFailures = 0
                    let googleFallbackStart = Date()
                    let googleFallbackTimeout: TimeInterval = 60  // Stop after 60s — no point burning API calls
                    
                    while googleRoutesGenerated < maxGoogleRoutes && googleFailures < 3 {
                        // Time gate: bail after 1 minute
                        let elapsed = Date().timeIntervalSince(googleFallbackStart)
                        if elapsed >= googleFallbackTimeout {
                            print("[ROUTE_GEN] 🌐 Google fallback timeout after \(String(format: "%.1f", elapsed))s — stopping")
                            break
                        }
                        do {
                            let excludedPlaceIds = await MainActor.run {
                                shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                            }
                            
                            // v1.9.51: Also collect actual POI objects from previous routes for duplicate detection
                            let excludedPOIs = await MainActor.run {
                                allRoutes.flatMap { $0.data.places }
                            }
                            
                            var result = try await mapsService.generateLocalRoute(
                                from: userLocation.coordinate,
                                targetDurationMinutes: selectedDuration,
                                difficulty: nil,
                                excludePlaceIds: excludedPlaceIds,
                                excludePOIs: excludedPOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                                prefetchedPOIs: combinedPOIs
                            )
                            
                            guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                                print("[ROUTE_GEN] 🌐 Google fallback attempt: invalid result (places=\(result.places.count) dist=\(result.distanceMeters) dur=\(result.durationSeconds))")
                                googleFailures += 1
                                continue
                            }
                            
                            let newPlaceIds = Set(result.places.map { $0.placeId })
                            let isDuplicate = await MainActor.run { shownPlaceIdSets.contains(newPlaceIds) }
                            
                            if isDuplicate {
                                print("[ROUTE_GEN] 🌐 Google fallback attempt: duplicate route")
                                googleFailures += 1
                                continue
                            }
                            
                            let markers = await MainActor.run {
                                createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                            }
                            
                            guard !markers.isEmpty else {
                                print("[ROUTE_GEN] 🌐 Google fallback attempt: no markers")
                                googleFailures += 1
                                continue
                            }
                            
                            var directions = await MainActor.run {
                                extractWalkingDirections(from: result.legs)
                            }
                            
                            if directions.isEmpty && !result.places.isEmpty {
                                let waypointCoords = result.places.map { $0.coordinate }
                                let waypointNames = result.places.map { $0.name }
                                directions = await mapsService.getMapKitDirectionsForRoute(
                                    origin: userLocation.coordinate,
                                    waypoints: waypointCoords,
                                    destination: userLocation.coordinate,
                                    waypointNames: waypointNames
                                )
                            }
                            
                            // v1.9.49: Start route naming in parallel (Optimization 4: Parallel Gemini Naming)
                            let waypointInfos = result.places.map { place in
                                GeminiService.WaypointInfo(
                                    name: place.name,
                                    types: place.types ?? [],
                                    vicinity: place.vicinity
                                )
                            }
                            
                            // Start Gemini naming in parallel (has 3s timeout, template fallback)
                            let namingTask = Task {
                                await GeminiService.shared.generateRouteContent(
                                    waypoints: waypointInfos,
                                    durationMinutes: result.durationMinutes,
                                    distanceMeters: result.distanceMeters,
                                    difficulty: nil
                                )
                            }
                            
                            let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                            
                            // Get route name (should be ready or nearly ready by now)
                            let aiContent = await namingTask.value
                            
                            var route = WalkingRoute(
                                name: aiContent.name,
                                description: aiContent.description,
                                durationMinutes: max(1, result.durationMinutes),
                                distanceMeters: result.distanceMeters,
                                difficulty: routeDifficulty,
                                isIndoor: false,
                                isAccessible: true,
                                landmarks: ["Start"] + result.places.map { $0.name } + ["Return"],
                                icon: "location.fill",
                                color: .tealAccent,
                                qrMarkers: markers,
                                routeType: .local,
                                trimmed: result.polyline,
                                walkingDirections: directions
                            )
                            
                            // v2.1.12: Skip explicit re-measure if generateLocalRoute already used Google Directions
                            var isActuallyFromGoogle = result.usedGoogleDirections
                            if isActuallyFromGoogle {
                                print("[ROUTE_DEBUG] 🔍 GOOGLE-POI route '\(route.name)': already Google-measured (\(route.durationMinutes)min, \(route.distanceMeters)m) — skipping redundant re-measure")
                            } else if mapsService.hasAPIKey && !result.places.isEmpty {
                                let preGoogleDur = route.durationMinutes
                                let preGoogleDist = route.distanceMeters
                                print("[ROUTE_DEBUG] 🔍 GOOGLE-POI route '\(route.name)': BEFORE Google: \(preGoogleDur)min, \(preGoogleDist)m")
                                if let googleResult = await mapsService.getGoogleDirectionsRoute(origin: userLocation.coordinate, waypoints: result.places, targetDurationMinutes: selectedDuration) {
                                    let googleDurMin = max(1, googleResult.durationSeconds / 60)
                                    print("[ROUTE_DEBUG] 🔍 GOOGLE-POI route '\(route.name)': Google re-measure: \(googleResult.durationSeconds)s (\(googleDurMin)min), \(googleResult.distanceMeters)m")
                                    route = WalkingRoute(
                                        name: route.name,
                                        description: route.description,
                                        durationMinutes: googleDurMin,
                                        distanceMeters: googleResult.distanceMeters,
                                        difficulty: route.difficulty,
                                        isIndoor: route.isIndoor,
                                        isAccessible: route.isAccessible,
                                        landmarks: route.landmarks,
                                        icon: route.icon,
                                        color: route.color,
                                        qrMarkers: route.qrMarkers,
                                        routeType: route.routeType,
                                        trimmed: route.trimmed,
                                        walkingDirections: route.walkingDirections
                                    )
                                    isActuallyFromGoogle = true
                                    // Update GeneratedRoute with Google values so data matches route
                                    result = GeneratedRoute(
                                        places: result.places,
                                        polyline: result.polyline,
                                        distanceMeters: googleResult.distanceMeters,
                                        durationSeconds: googleResult.durationSeconds,
                                        legs: result.legs
                                    )
                                } else {
                                    print("[ROUTE_DEBUG] 🔍 GOOGLE-POI route '\(route.name)': Google re-measure FAILED — keeping MapKit \(preGoogleDur)min / \(preGoogleDist)m")
                                }
                            }
                            
                            await MainActor.run {
                                // v1.8.8: Check if route is too short (< 50% of target)
                                let minAcceptablePercent = 0.50
                                let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                                let routeDuration = route.durationMinutes
                                
                                if routeDuration < minAcceptableDuration {
                                    // Store for potential use at end if we have ≤2 routes
                                    rejectedShortRoutes.append((route: route, data: result))
                                    // v2.1.9: Also store in cross-bucket pool for its actual duration
                                    if isActuallyFromGoogle {
                                        storeCrossBucketRoute(route: route, data: result, isFromGoogle: true)
                                    }
                                    print("[ROUTE_GEN] 🌐 Google fallback attempt: too short (\(routeDuration)min < \(minAcceptableDuration)min) - stored for later")
                                    googleFailures += 1
                                    return
                                }
                                
                                // FINAL SAFETY CHECK: Deduplicate before storing
                                let deduplicatedResult = mapsService.finalizeRouteDedupForView(result)
                                
                                // In-band Google fallback route — add to preview (gate checks in-band + target count)
                                let cappedRoute = route.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                                let added = appendRouteIfAllowed(
                                    route: cappedRoute,
                                    data: deduplicatedResult,
                                    isFromGoogle: isActuallyFromGoogle,
                                    source: "google-poi-fallback"
                                )
                                
                                if !added {
                                    googleFailures += 1
                                    return
                                }
                                
                                // v1.6.25: Register route signature for deduplication
                                registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                                shownPlaceIdSets.append(newPlaceIds)
                                
                                googleRoutesGenerated += 1
                                googleFailures = 0
                                print("🌐 ✅ Generated route \(allRoutes.count) (unique: \(routeSignatures.count)) using Google POIs")
                                
                                // v1.6.45: Auto-advance to first AI route when user is still on placeholder
                                if allRoutes.count == 2 && currentRouteIndex == 0 {
                                    currentRouteIndex = 1
                                    let newRoute = allRoutes[1]
                                    generatedRoute = newRoute.route  // already capped above
                                    generatedRouteData = newRoute.data
                                    viewedRouteIndices.insert(1)
                                    print("🚀 Auto-advanced to first AI-generated route (Google)")
                                }
                                
                                // v1.6.26: Try waypoint permutation for 2+ waypoint routes (cap duration for display)
                                if result.places.count >= 2 && !hasEnoughInBandRoutes() {
                                    if let permuted = createPermutedRoute(from: cappedRoute, data: result, isDeadZoneFallback: false, isFromGoogle: isActuallyFromGoogle) {
                                        let cappedPermuted = permuted.route.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                                        let permAdded = appendRouteIfAllowed(
                                            route: cappedPermuted,
                                            data: permuted.data,
                                            isDeadZoneFallback: permuted.isDeadZoneFallback,
                                            isFromGoogle: permuted.isFromGoogle,
                                            source: "google-poi-permuted"
                                        )
                                        if permAdded {
                                            registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                        }
                                    }
                                }
                                
                                // v1.6.47: Merge routes into cache - skip first (fast) route, only cache routes 2+
                                let routesToCache = Array(allRoutes.dropFirst())
                                if !routesToCache.isEmpty {
                                    let routeData = routesToCache.map { $0.data }
                                    let routeNames = routesToCache.map { $0.route.name as String? }
                                    let routeDescriptions = routesToCache.map { $0.route.description as String? }
                                    let routeDirections = routesToCache.map { $0.route.walkingDirections }
                                    let mergeResult = RouteCacheService.shared.mergeRoutes(
                                        routeData,
                                        at: userLocation.coordinate,
                                        durationMinutes: selectedDuration,
                                        names: routeNames,
                                        descriptions: routeDescriptions,
                                        directions: routeDirections
                                    )
                                    print("💾 Merged \(routesToCache.count) routes (skipped fast route 1): \(mergeResult.added) added, \(mergeResult.replaced) replaced (incl. Google)")
                                }
                            }
                            
                        } catch {
                            print("[ROUTE_GEN] 🌐 Google fallback attempt: error \(error.localizedDescription)")
                            googleFailures += 1
                        }
                        
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    let googleFallbackElapsed = Date().timeIntervalSince(preGenTaskStart)
                    print("[ROUTE_GEN] 🌐 Google fallback loop exit: generated=\(googleRoutesGenerated) failures=\(googleFailures) (maxFailures=3)")
                    print("[ROUTE_GEN] 🌐 Google fallback complete at +\(String(format: "%.2f", googleFallbackElapsed))s: +\(googleRoutesGenerated) routes")
                } else {
                    print("[ROUTE_GEN] 🌐 Google API returned no new POIs")
                }
            } else {
                print("[ROUTE_GEN] 🌐 Google fallback skipped: currentRouteCount=\(currentRouteCount) (need ≤2) or no API key")
            }
            
            // SAFETY NET: Pull fallback routes BEFORE the Google re-measure sweep
            // so that the sweep covers them too and they get accurate durations.
            await MainActor.run {
                if allRoutes.count < targetInBandRoutes {
                    let needed = targetInBandRoutes - allRoutes.count
                    print("[ROUTE_GEN] ⚠️ Only \(allRoutes.count) route(s) shown — pulling up to \(needed) best out-of-band route(s) as fallback")
                    
                    let fallbackCandidates = RouteCacheService.shared.takeSessionCrossBucketFallbackCandidates(needed: needed, selectedDuration: selectedDuration)
                    let existingSigs = Set(allRoutes.map { Set($0.data.places.map { $0.placeId }) })
                    for candidate in fallbackCandidates {
                        let sig = Set(candidate.data.places.map { $0.placeId })
                        if existingSigs.contains(sig) { continue }
                        let cappedFallback = candidate.route.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                        // Mark isFromGoogle as false so the sweep will re-measure them
                        allRoutes.append((route: cappedFallback, data: candidate.data, isDeadZoneFallback: true, isFromGoogle: false))
                        print("[ROUTE_GEN] ⚠️ Fallback: added '\(cappedFallback.name)' (\(cappedFallback.durationMinutes)min) from cross-bucket pool — pending Google re-measure")
                    }
                    if fallbackCandidates.isEmpty && !rejectedShortRoutes.isEmpty {
                        // Last resort: use rejected short routes
                        let bestShort = rejectedShortRoutes.max(by: { $0.data.durationMinutes < $1.data.durationMinutes })
                        if let fallback = bestShort {
                            let cappedFallbackRoute = fallback.route.withDurationSanityCap(targetDurationMinutes: selectedDuration)
                            // Mark isFromGoogle as false so the sweep will re-measure
                            allRoutes.append((route: cappedFallbackRoute, data: fallback.data, isDeadZoneFallback: true, isFromGoogle: false))
                            isDeadZoneFallback = true
                            print("[ROUTE_GEN] ⚠️ Last-resort fallback: added short route (\(fallback.data.durationMinutes)min) — pending Google re-measure")
                        }
                    }
                }
                rejectedShortRoutes.removeAll()
            }
            
            // v2.1.11: Final safety-net sweep — Google-remeasure ALL routes not yet Google-measured
            // This now covers both original routes AND any fallback routes just pulled from the pool
            await googleRemeasureSweep(userLocation: userLocation.coordinate, selectedDuration: selectedDuration)
            
            // After the sweep, remove any fallback routes that turned out to be wildly off-target
            // (e.g. Google says 45min for a 20min request) — keep them if they're the only option
            await MainActor.run {
                let routeCountBeforePrune = allRoutes.count
                if routeCountBeforePrune > 1 {
                    // Only prune dead-zone fallbacks that are way off (> 150% or < 50% of target)
                    let pruneMin = Int(Double(selectedDuration) * 0.50)
                    let pruneMax = Int(Double(selectedDuration) * 1.50)
                    var prunedIndices: [Int] = []
                    for (idx, entry) in allRoutes.enumerated() {
                        if entry.isDeadZoneFallback && (entry.route.durationMinutes < pruneMin || entry.route.durationMinutes > pruneMax) {
                            prunedIndices.append(idx)
                        }
                    }
                    // Don't prune if it would leave us with zero routes
                    if prunedIndices.count < routeCountBeforePrune {
                        for idx in prunedIndices.reversed() {
                            let pruned = allRoutes[idx]
                            print("[ROUTE_GEN] ✂️ Pruned fallback '\(pruned.route.name)' (\(pruned.route.durationMinutes)min) — too far from \(selectedDuration)min target after Google re-measure")
                            allRoutes.remove(at: idx)
                        }
                    }
                }
                
                isPreGeneratingRoutes = false
                preGenerationComplete = true
                
                // v1.6.25: Log variety status
                let uniqueCount = routeSignatures.count
                if varietyExhausted {
                    print("🏁 Pre-generation complete for \(selectedDuration)min! \(uniqueCount) unique routes (variety exhausted)")
                } else {
                    print("🏁 Pre-generation complete for \(selectedDuration)min! \(allRoutes.count) routes generated")
                }
                logRoutePreviewSummary()
                logRunSummary()
                
                // Session-only cache: so Cancel → Generate again (same location, same duration) is instant
                let sessionMeta = allRoutes.map { e in
                    RouteCacheService.CachedRouteWithMetadata(
                        route: e.data,
                        name: e.route.name,
                        description: e.route.description,
                        directions: e.route.walkingDirections,
                        isDeadZoneFallback: e.isDeadZoneFallback,
                        isFromPrePopulatedDatabase: false
                    )
                }
                RouteCacheService.shared.setSessionRoutes(sessionMeta, at: userLocation.coordinate, durationMinutes: selectedDuration)
                
                // Print simple route summary
                print("\n═══════════════════════════════════════════════════════════")
                print("📋 ROUTES SUMMARY - \(selectedDuration)min")
                print("═══════════════════════════════════════════════════════════")
                for (index, routeTuple) in allRoutes.enumerated() {
                    let route = routeTuple.data
                    let poiNames = route.places.map { $0.name }.joined(separator: " → ")
                    print("\(selectedDuration)min - route \(index + 1): \(poiNames)")
                }
                print("═══════════════════════════════════════════════════════════\n")
            }
            
            // AFTER completing current duration, pre-generate for OTHER durations
            await preGenerateOtherDurations(from: userLocation.coordinate, currentDuration: selectedDuration, pois: updatedPOIs)
        }
    }
    
    /// Pre-generate ONE route for each standard duration (except current) for instant switching
    /// Prioritizes: 1) Preset buttons (10-30) adjacent first, 2) Then fill gaps (5, 45, 60)
    func preGenerateOtherDurations(from location: CLLocationCoordinate2D, currentDuration: Int, pois: [PlaceResult]?) async {
        // Preset buttons users see first (most likely choices)
        let presetDurations = [10, 15, 20, 25, 30]
        // Custom/less common durations (fill in after)
        let gapDurations = [45, 60]
        
        // v1.6.33: Prioritize preset buttons first (adjacent ones at top), then gaps
        let presetOthers = presetDurations.filter { $0 != currentDuration }
        let gapOthers = gapDurations.filter { $0 != currentDuration }
        
        // Sort presets by distance from current (closest first)
        let sortedPresets = presetOthers.sorted { abs($0 - currentDuration) < abs($1 - currentDuration) }
        // Sort gaps by distance from current (closest first)  
        let sortedGaps = gapOthers.sorted { abs($0 - currentDuration) < abs($1 - currentDuration) }
        
        // Presets first, then gaps
        let durationsToGenerate = sortedPresets + sortedGaps
        
        // Store where we pre-generated (for movement detection)
        await MainActor.run {
            preGeneratedAtLocation = location
        }
        
        print("🔮 Pre-generating other durations (prioritized): \(durationsToGenerate.map { "\($0)min" }.joined(separator: ", "))")
        
        // Process in batches of 3 to respect MapKit rate limits while reducing wall-clock time
        let batchSize = 3
        let batches = stride(from: 0, to: durationsToGenerate.count, by: batchSize).map {
            Array(durationsToGenerate[$0..<min($0 + batchSize, durationsToGenerate.count)])
        }
        
        for batch in batches {
            // v1.6.33: Check rate limit - pause briefly if too high
            if await mapsService.shouldPauseBackgroundGeneration() {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            
            // Run this batch in parallel (up to batchSize concurrent)
            await withTaskGroup(of: (Int, Result<GeneratedRoute, Error>).self) { group in
                for duration in batch {
                    if RouteCacheService.shared.getCachedRoutes(near: location, durationMinutes: duration) != nil {
                        print("📦 \(duration)min already cached, skipping")
                        continue
                    }
                    group.addTask {
                        let excludedPOIs: [PlaceResult] = []
                        do {
                            let result = try await mapsService.generateLocalRoute(
                                from: location,
                                targetDurationMinutes: duration,
                                difficulty: nil,
                                excludePlaceIds: [],
                                excludePOIs: excludedPOIs,
                                prefetchedPOIs: pois
                            )
                            return (duration, .success(result))
                        } catch {
                            return (duration, .failure(error))
                        }
                    }
                }
                for await (duration, outcome) in group {
                    switch outcome {
                    case .success(let result):
                        guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                            print("⚠️ \(duration)min generation failed validation")
                            continue
                        }
                        RouteCacheService.shared.cacheRoutes([result], at: location, durationMinutes: duration)
                        print("✅ Pre-generated and cached \(duration)min route (\(result.durationSeconds/60)min actual)")
                    case .failure(let error):
                        print("⚠️ \(duration)min pre-generation error: \(error.localizedDescription)")
                    }
                }
            }
            
            // Delay between batches (not between every duration) to avoid thundering herd
            if batch != batches.last {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s between batches
            }
        }
        
        print("🏁 Other durations pre-generation complete!")
    }
    
    /// v1.6.46: Background refresh - search for new routes while using cached ones
    /// If a better route is found, it's merged into cache (replacing similar routes)
    func backgroundRefreshRoutes(at coordinate: CLLocationCoordinate2D, duration: Int) {
        // 🔧 DEBUG: Database-only mode - don't background refresh
        if RoutingToggles.databaseOnlyMode {
            print("🚫 [DATABASE-ONLY MODE] Background refresh disabled - only database routes allowed")
            return
        }
        
        Task {
            // Wait a bit before starting background refresh (let UI settle)
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // v1.9.22: Check if cancelled before starting
            let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
            if shouldCancel {
                print("🛑 Background refresh cancelled - user initiated action")
                return
            }
            
            print("🔄 Background refresh: searching for new routes at \(duration)min...")
            
            // Try to generate 1-2 new routes
            var newRoutes: [(route: WalkingRoute, data: GeneratedRoute)] = []
            
            for attempt in 1...2 {
                // v1.9.22: Check if cancelled on each iteration
                let shouldCancel = await MainActor.run { shouldCancelBackgroundWork }
                if shouldCancel {
                    print("🛑 Background refresh cancelled - user initiated action")
                    break
                }
                
                do {
                    // v1.6.33: Check rate limit
                    if await mapsService.shouldPauseBackgroundGeneration() {
                        print("🔄 Background refresh: rate limited, stopping")
                        break
                    }
                    
                    let poisToUse = await MainActor.run {
                        prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    }
                    let excludedPlaceIds = await MainActor.run {
                        shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                    
                    // v1.9.51: Also collect actual POI objects from previous routes for duplicate detection
                    let excludedPOIs = await MainActor.run {
                        allRoutes.flatMap { $0.data.places }
                    }
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: coordinate,
                        targetDurationMinutes: duration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        excludePOIs: excludedPOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                        prefetchedPOIs: poisToUse
                    )
                    
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        continue
                    }
                    
                    // Check if this route is truly unique
                    let isUnique = await MainActor.run {
                        isRouteUnique(places: result.places, distanceMeters: result.distanceMeters)
                    }
                    
                    if isUnique {
                        print("🔄 Background refresh: found unique route (attempt \(attempt))")
                        
                        // v1.9.49: Start route naming in parallel (Optimization 4: Parallel Gemini Naming)
                        let waypointInfos = result.places.map { place in
                            GeminiService.WaypointInfo(
                                name: place.name,
                                types: place.types ?? [],
                                vicinity: place.vicinity
                            )
                        }
                        
                        // Start Gemini naming in parallel (has 3s timeout, template fallback)
                        let namingTask = Task {
                            await GeminiService.shared.generateRouteContent(
                                waypoints: waypointInfos,
                                durationMinutes: result.durationMinutes,
                                distanceMeters: result.distanceMeters,
                                difficulty: nil
                            )
                        }
                        
                        // Get directions and markers in parallel with naming
                        let directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: coordinate,
                            waypoints: result.places.map { $0.coordinate },
                            destination: coordinate,
                            waypointNames: result.places.map { $0.name }
                        )
                        
                        let markers = await MainActor.run {
                            createMarkersFromPlaces(result.places, origin: coordinate)
                        }
                        let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                        
                        // Get route name (should be ready or nearly ready by now)
                        let aiContent = await namingTask.value
                        
                        let localRoute = WalkingRoute(
                            name: aiContent.name,
                            description: aiContent.description,
                            durationMinutes: max(1, result.durationMinutes),
                            distanceMeters: result.distanceMeters,
                            difficulty: routeDifficulty,
                            isIndoor: false,
                            isAccessible: true,
                            landmarks: ["Start"] + result.places.map { $0.name } + ["Return"],
                            icon: "location.fill",
                            color: .tealAccent,
                            qrMarkers: markers,
                            routeType: .local,
                            trimmed: result.polyline,
                            walkingDirections: directions,
                            usedOSRMRouting: result.usedOSRM
                        )
                        
                        newRoutes.append((route: localRoute, data: result))
                        await MainActor.run {
                            registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                        }
                    } else {
                        print("🔄 Background refresh: route was duplicate (attempt \(attempt))")
                    }
                    
                } catch {
                    print("🔄 Background refresh error: \(error.localizedDescription)")
                }
                
                // Small delay between attempts
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            // Merge any new routes into cache
            if !newRoutes.isEmpty {
                let allRouteData = newRoutes.map { $0.data }
                let allNames = newRoutes.map { $0.route.name as String? }
                let allDescriptions = newRoutes.map { $0.route.description as String? }
                let allDirections = newRoutes.map { $0.route.walkingDirections }
                
                let mergeResult = RouteCacheService.shared.mergeRoutes(
                    allRouteData,
                    at: coordinate,
                    durationMinutes: duration,
                    names: allNames,
                    descriptions: allDescriptions,
                    directions: allDirections
                )
                print("🔄 Background refresh complete: \(mergeResult.added) added, \(mergeResult.replaced) replaced")
            } else {
                print("🔄 Background refresh complete: no new unique routes found")
            }
        }
    }
    
    func generateBasicRoute(from coordinate: CLLocationCoordinate2D) {
        let markerCount = max(2, numberOfMarkers) // Ensure at least 2 markers
        let markers = generateLocalMarkers(
            around: coordinate,
            count: markerCount,
            radiusMeters: Double(estimatedDistance) / 2
        )
        
        // Ensure we have markers
        guard !markers.isEmpty else {
            errorMessage = "Could not generate route. Please try again."
            isGenerating = false
            showLoadingScreen = false
            routeGenerationComplete = false
            return
        }
        
        // Use distance-based duration so we never show target duration for a short fallback route (e.g. 20 min for a 10 min walk)
        let distanceM = max(100, estimatedDistance)
        let durationFromDistance = max(1, Int((Double(distanceM) / 80.0).rounded())) // ~80 m/min walking
        let displayDuration = min(selectedDuration, max(durationFromDistance, 1))
        let localRoute = WalkingRoute(
            name: "Local Discovery",
            description: "A circular route around your current location with \(markers.count) discovery spots.",
            durationMinutes: displayDuration,
            distanceMeters: distanceM,
            difficulty: displayDuration <= 10 ? .easy : (displayDuration <= 20 ? .moderate : .challenging),
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Start"] + markers.map { $0.name } + ["Return to Start"],
            icon: "location.fill",
            color: .tealAccent,
            qrMarkers: markers,
            routeType: .local,
            trimmed: nil
        )
        
        // Build GeneratedRoute from markers so "Places along your route:" chips always show
        let fallbackPlaces = markers.map { m in
            PlaceResult(
                placeId: m.id.uuidString,
                name: m.name,
                vicinity: m.location,
                geometry: PlaceGeometry(location: PlaceLocation(lat: m.coordinate.latitude, lng: m.coordinate.longitude)),
                types: ["point_of_interest"],
                source: .unknown
            )
        }
        let fallbackData = GeneratedRoute(
            places: fallbackPlaces,
            polyline: "",
            distanceMeters: distanceM,
            durationSeconds: displayDuration * 60,
            legs: []
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isGenerating = false
            routeGenerationComplete = true  // v1.8.5: Trigger stage animation completion
            generatedRoute = localRoute
            generatedRouteData = fallbackData
            print("TIME_SOURCE | Route shown (fallback path): \(localRoute.durationMinutes) min — FROM MAPKIT/OSRM (Google refresh will run after Let's Go)")
            // v1.8.13: Don't show map preview immediately - let stage animations complete first
            // showMapPreview = true  // REMOVED - this was causing stages to be skipped
        }
    }
    
    /// Calculate distance between two coordinates in meters
    func distanceBetweenCoordinates(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
    
    func createMarkersFromPlaces(_ places: [PlaceResult], origin: CLLocationCoordinate2D) -> [QRMarker] {
        // #region agent log
        if places.count > 1 {
            let distances = (0..<places.count-1).map { i in
                let loc1 = CLLocation(latitude: places[i].coordinate.latitude, longitude: places[i].coordinate.longitude)
                let loc2 = CLLocation(latitude: places[i+1].coordinate.latitude, longitude: places[i+1].coordinate.longitude)
                return loc1.distance(from: loc2)
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "D",
                "location": "RouteSelectionView.swift:3849",
                "message": "createMarkersFromPlaces: final waypoint distances",
                "data": [
                    "waypoints": places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                    "distances": distances,
                    "minDistance": distances.min() ?? 0
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
               let logString = String(data: logJSON, encoding: .utf8) {
                logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
        }
        // #endregion
        
        // Filter out placeholder "Route Point" POIs - these are just topology markers, not real waypoints
        let realPlaces = places.filter { $0.name != "Route Point" }
        
        return realPlaces.enumerated().map { index, place in
            // Always use a random breathing exercise (one of the 3 available)
            let content = WellbeingContent.breathingExercises.randomElement() ?? WellbeingContent.breathingExercises[0]
            
            return QRMarker(
                code: "POI\(index + 1)",
                name: place.displayName,  // Use cleaned display name (removes grid refs and location suffixes)
                location: place.vicinity ?? "Local POI",
                coordinate: place.coordinate,
                contentType: .breathingExercise,
                content: content,
                pointsValue: 20 + (index * 5)
            )
        }
    }
    
    /// Extract walking directions from Google Directions API legs
    /// v2.1.6: Now accepts waypoints to generate waypoint-specific arrival instructions
    func extractWalkingDirections(from legs: [DirectionsLeg], waypoints: [PlaceResult] = []) -> [WalkingDirection] {
        // #region agent log
        let logData1: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "A",
            "location": "RouteSelectionView.swift:4127",
            "message": "extractWalkingDirections: entry",
            "data": [
                "legsCount": legs.count,
                "waypointsCount": waypoints.count,
                "waypointNames": waypoints.map { $0.name }
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logJSON1 = try? JSONSerialization.data(withJSONObject: logData1),
           let logString1 = String(data: logJSON1, encoding: .utf8) {
            logString1.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
        }
        // #endregion
        
        var directions: [WalkingDirection] = []
        
        for (legIndex, leg) in legs.enumerated() {
            guard let steps = leg.steps else { continue }
            let isLastLeg = legIndex == legs.count - 1
            let isReturnLeg = legIndex == legs.count - 1 && waypoints.count > 0
            
            // #region agent log
            let logDataLeg: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "G",
                "location": "RouteSelectionView.swift:4192",
                "message": "Processing leg",
                "data": [
                    "legIndex": legIndex,
                    "stepsCount": steps.count,
                    "isLastLeg": isLastLeg,
                    "isReturnLeg": isReturnLeg,
                    "waypointsCount": waypoints.count,
                    "stepInstructions": steps.compactMap { $0.htmlInstructions }
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSONLeg = try? JSONSerialization.data(withJSONObject: logDataLeg),
               let logStringLeg = String(data: logJSONLeg, encoding: .utf8) {
                logStringLeg.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
            // #endregion
            
            for (stepIndex, step) in steps.enumerated() {
                guard let html = step.htmlInstructions else { continue }
                
                // Extract maneuver from HTML if present (e.g., "turn-left")
                let maneuver = extractManeuver(from: html)
                
                var direction = WalkingDirection.fromHTML(
                    html,
                    distance: step.distance.text,
                    distanceMeters: step.distance.value,
                    duration: step.duration.text,
                    maneuver: maneuver
                )
                
                // #region agent log
                let logDataStep: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "G",
                    "location": "RouteSelectionView.swift:4215",
                    "message": "Processing step",
                    "data": [
                        "legIndex": legIndex,
                        "stepIndex": stepIndex,
                        "isLastStepOfLeg": stepIndex == steps.count - 1,
                        "htmlInstruction": html,
                        "parsedInstruction": direction.instruction,
                        "distanceMeters": step.distance.value
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSONStep = try? JSONSerialization.data(withJSONObject: logDataStep),
                   let logStringStep = String(data: logJSONStep, encoding: .utf8) {
                    logStringStep.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
                // #endregion
                
                let isLastStepOfLeg = stepIndex == steps.count - 1
                
                // v2.1.6: Replace arrival instructions with waypoint-specific text
                if isLastStepOfLeg {
                    let instructionLower = direction.instruction.lowercased()
                    // Last step of leg = arrival; match all phrasings so every waypoint gets name + flag
                    let isArrivalInstruction =
                        instructionLower.contains("destination is on your right") ||
                        instructionLower.contains("destination is on your left") ||
                        instructionLower.contains("the destination is on your right") ||
                        instructionLower.contains("the destination is on your left") ||
                        instructionLower.contains("destination will be on the right") ||
                        instructionLower.contains("destination will be on the left") ||
                        instructionLower.contains("arrive at") ||
                        (instructionLower.contains("destination") && (instructionLower.contains("on your right") || instructionLower.contains("on your left") || instructionLower.contains("on the right") || instructionLower.contains("on the left"))) ||
                        (instructionLower.contains("destination") || instructionLower.contains("arrive"))
                    
                    if isArrivalInstruction {
                        if isReturnLeg {
                            // Last leg is return to origin
                            direction = WalkingDirection(
                                instruction: "Return to starting point",
                                distance: step.distance.text,
                                distanceMeters: step.distance.value,
                                duration: step.duration.text,
                                maneuver: "arrive"
                            )
                        } else if legIndex < waypoints.count {
                            // Intermediate waypoint - create waypoint-specific instruction
                            let waypointIndex = legIndex + 1 // 1-indexed for display
                            let waypoint = waypoints[legIndex]
                            let waypointName = waypoint.name
                            
                            // Determine left/right from original instruction
                            let side = instructionLower.contains("right") ? "right" : "left"
                            
                            // #region agent log
                            let logData2: [String: Any] = [
                                "location": "RouteSelectionView:extractWalkingDirections:side",
                                "message": "RouteSelectionView waypoint side",
                                "data": [
                                    "legIndex": legIndex,
                                    "waypointIndex": waypointIndex,
                                    "waypointName": waypointName,
                                    "side": side,
                                    "waypointsCount": waypoints.count,
                                    "instructionPrefix": String(direction.instruction.prefix(120)),
                                    "containsRight": instructionLower.contains("right"),
                                    "containsLeft": instructionLower.contains("left")
                                ],
                                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                                "hypothesisId": "E"
                            ]
                            if let logJSON2 = try? JSONSerialization.data(withJSONObject: logData2),
                               let logString2 = String(data: logJSON2, encoding: .utf8) {
                                logString2.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                            }
                            // #endregion
                            
                            direction = WalkingDirection(
                                instruction: "Waypoint \(waypointIndex) (\(waypointName)) is on your \(side)",
                                distance: step.distance.text,
                                distanceMeters: step.distance.value,
                                duration: step.duration.text,
                                maneuver: "arrive"
                            )
                        }
                        // If legIndex >= waypoints.count but not return leg, keep original instruction
                    }
                }
                
                directions.append(direction)
            }
        }
        
        // v2.1.7: Filter out contradictory directions using shared function
        let filteredDirections = filterContradictoryDirections(directions)
        
        // #region agent log
        let logData3: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "A",
            "location": "RouteSelectionView.swift:4196",
            "message": "extractWalkingDirections: exit",
            "data": [
                "directionsCount": filteredDirections.count,
                "originalCount": directions.count,
                "filteredCount": directions.count - filteredDirections.count,
                "waypointInstructions": filteredDirections.filter { $0.instruction.contains("Waypoint") }.map { $0.instruction },
                "allInstructions": filteredDirections.map { $0.instruction }
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logJSON3 = try? JSONSerialization.data(withJSONObject: logData3),
           let logString3 = String(data: logJSON3, encoding: .utf8) {
            logString3.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
        }
        // #endregion
        
        return filteredDirections
    }
    
    /// v2.1.7: Filter out contradictory/nonsensical directions from any direction list
    /// This can be applied to cached directions or freshly extracted directions
    @MainActor
    private func filterContradictoryDirections(_ directions: [WalkingDirection]) -> [WalkingDirection] {
        var filteredDirections: [WalkingDirection] = []
        for (index, direction) in directions.enumerated() {
            let instructionLower = direction.instruction.lowercased()
            let isStartOn = instructionLower.hasPrefix("start on") || instructionLower.contains("start on")
            let distanceIsZero = direction.distanceMeters == 0 || direction.distanceMeters < 5
            
            // Filter "Start on" instructions with 0m distance (they're always nonsensical)
            if isStartOn && distanceIsZero {
                // Check if there's a next step that's also on the same road (contradictory)
                var shouldSkip = false
                var skipReason = ""
                
                if index + 1 < directions.count {
                    let nextDirection = directions[index + 1]
                    let nextInstructionLower = nextDirection.instruction.lowercased()
                    _ = nextInstructionLower.contains("turn") && nextInstructionLower.contains("onto")
                    
                    // Extract road names from both instructions
                    let extractRoadName = { (text: String) -> String? in
                        let lower = text.lowercased()
                        // Try to extract road name after "on" or "onto"
                        if let onIndex = lower.range(of: " on ")?.upperBound ?? lower.range(of: " onto ")?.upperBound {
                            let afterOn = String(lower[onIndex...]).trimmingCharacters(in: .whitespaces)
                            // Take first few words as road name (up to 3 words)
                            let words = afterOn.components(separatedBy: .whitespaces).prefix(3)
                            return words.isEmpty ? nil : words.joined(separator: " ")
                        }
                        return nil
                    }
                    
                    let currentRoad = extractRoadName(direction.instruction)
                    let nextRoad = extractRoadName(nextDirection.instruction)
                    
                    // If both mention the same road, skip the "Start on" step (it's contradictory)
                    if let current = currentRoad, let next = nextRoad, current == next {
                        shouldSkip = true
                        skipReason = "contradictory: followed by turn onto same road"
                    }
                } else {
                    // Last step with "Start on" and 0m - doesn't make sense, filter it
                    shouldSkip = true
                    skipReason = "nonsensical: last step with 'Start on' and 0m"
                }
                
                if shouldSkip {
                    print("🗺️ [DIRECTIONS] Filtering step: '\(direction.instruction)' (0m) - \(skipReason)")
                    continue  // Skip this step
                }
            }
            
            filteredDirections.append(direction)
        }
        
        if filteredDirections.count != directions.count {
            print("🗺️ [DIRECTIONS] Filtered \(directions.count - filteredDirections.count) contradictory/nonsensical direction(s)")
        }
        
        return filteredDirections
    }
    
    /// Extract maneuver type from HTML instruction
    private func extractManeuver(from html: String) -> String? {
        let lowercased = html.lowercased()
        
        if lowercased.contains("turn <b>left") || lowercased.contains("turn left") {
            return "turn-left"
        } else if lowercased.contains("turn <b>right") || lowercased.contains("turn right") {
            return "turn-right"
        } else if lowercased.contains("slight <b>left") || lowercased.contains("slight left") {
            return "turn-slight-left"
        } else if lowercased.contains("slight <b>right") || lowercased.contains("slight right") {
            return "turn-slight-right"
        } else if lowercased.contains("sharp <b>left") || lowercased.contains("sharp left") {
            return "turn-sharp-left"
        } else if lowercased.contains("sharp <b>right") || lowercased.contains("sharp right") {
            return "turn-sharp-right"
        } else if lowercased.contains("u-turn") || lowercased.contains("uturn") {
            return "uturn-left"
        } else if lowercased.contains("roundabout") {
            return "roundabout-left"
        } else if lowercased.contains("continue") || lowercased.contains("straight") || lowercased.contains("head ") {
            return "straight"
        }
        
        return nil
    }
    
    func generateLocalMarkers(around center: CLLocationCoordinate2D, count: Int, radiusMeters: Double) -> [QRMarker] {
        var markers: [QRMarker] = []
        
        let markerNames = [
            ("Sunny Spot", "Open Area"),
            ("Quiet Corner", "Peaceful Space"),
            ("Nature View", "Scenic Point"),
            ("Rest Point", "Bench Area"),
            ("Green Space", "Garden Area")
        ]
        
        for i in 0..<count {
            let angle = (Double(i) / Double(count)) * 2 * .pi
            let randomRadius = radiusMeters * Double.random(in: 0.5...1.0)
            
            let latOffset = (randomRadius / 111000) * cos(angle)
            let lonOffset = (randomRadius / (111000 * cos(center.latitude * .pi / 180))) * sin(angle)
            
            let markerCoord = CLLocationCoordinate2D(
                latitude: center.latitude + latOffset,
                longitude: center.longitude + lonOffset
            )
            
            let nameIndex = i % markerNames.count
            
            // Always use a random breathing exercise (one of the 3 available)
            let content = WellbeingContent.breathingExercises.randomElement() ?? WellbeingContent.breathingExercises[0]
            
            let marker = QRMarker(
                code: "LOCAL\(i + 1)",
                name: markerNames[nameIndex].0,
                location: markerNames[nameIndex].1,
                coordinate: markerCoord,
                contentType: .breathingExercise,
                content: content,
                pointsValue: 15 + (i * 5)
            )
            
            markers.append(marker)
        }
        
        return markers
    }
    
}

// MARK: - Local Route Map Preview
struct LocalRouteMapPreview: View {
    let route: WalkingRoute
    let userLocation: CLLocationCoordinate2D?
    var generatedData: GeneratedRoute?
    var isRecycled: Bool = false   // True if this is a recycled route (no new options found)
    var targetDurationMinutes: Int = 0  // Original requested duration
    var currentRouteIndex: Int = 1  // 1-based index for display
    var totalRoutes: Int = 1
    var isLoadingMoreRoutes: Bool = false  // True when pre-generating in background
    var showPremiumUpsell: Bool = false  // True when all routes have been viewed
    var hasLimitedPOIs: Bool = false  // v1.6.10: True when POI count is below threshold
    var varietyExhausted: Bool = false  // v1.6.25: True when no more unique routes available
    var isDeadZoneFallback: Bool = false  // v1.6.39: True when route is 70-74% (closest available)
    var showOutOfBandBanner: Bool = false  // v2.1.x: No routes in band; showing closest, or this route is out of band
    var outOfBandLabel: String? = nil     // When non-nil: "Shorter than 20–30 min" etc.; when nil and banner: "No routes in ... showing closest"
    var selectedDuration: Int = 0  // For banner text (e.g. "requested 20–30 min")
    var isStartingWalk: Bool = false  // v1.6.45: Loading state for Let's Go button
    var routeRefreshStatus: String? = nil  // v1.9.22: Status message during route refresh
    
    // v1.6.45: Track map loading state
    @State private var isMapLoading = true
    
    // v1.8.3: Camera position that updates when route changes
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    // v1.6.28: Removed permission callbacks - permissions now requested during/after walk
    let onStartWalk: () -> Void          // Start the walk immediately
    let onShuffle: () -> Void            // Quick regenerate with same settings
    let onBack: () -> Void               // Go back to duration picker
    let onGenerateAdditional: () -> Void // Generate one more route (+1 button)
    var isGeneratingAdditional: Bool = false  // True while +1 route is being generated
    var additionalRoutesRemaining: Int = 5   // How many +1 presses left (0 = greyed out)
    var onRefresh: (() -> Void)? = nil   // Refresh route list from cache/database
    var isRefreshingRoutes: Bool = false // Loading state during refresh
    
    // v1.6.28: Simplified - no permission gates before walk
    // Permissions are now requested DURING the walk (optional step tracking)
    // and AFTER the walk (HealthKit sync option)
    
    /// +1 button is enabled only when: not currently generating, still has remaining presses, and variety is not exhausted
    var canGenerateAdditional: Bool {
        additionalRoutesRemaining > 0 && !isGeneratingAdditional && !varietyExhausted
    }
    
    var primaryButtonText: String {
        // Always show "Let's Go!" - spinner will appear at end if loading
        return "Let's Go!"
    }
    
    var primaryButtonIcon: String {
        // Always show walk icon - spinner indicates loading
        "figure.walk"
    }
    
    var primaryButtonColor: Color {
        .tealAccent
    }
    
    /// True if route duration exceeds requested target
    var isOverTarget: Bool {
        guard let data = generatedData, targetDurationMinutes > 0 else { return false }
        return data.durationMinutes > targetDurationMinutes
    }
    
    /// How many minutes over target
    var minutesOverTarget: Int {
        guard let data = generatedData else { return 0 }
        return max(0, data.durationMinutes - targetDurationMinutes)
    }
    
    var hasRealPolyline: Bool {
        route.trimmed != nil && !route.trimmed!.isEmpty
    }
    
    /// Split the route polyline at the last waypoint
    /// Returns outbound path (start → last waypoint) and return path (last waypoint → start)
    func splitRouteAtLastWaypoint() -> (outbound: [CLLocationCoordinate2D], returnLeg: [CLLocationCoordinate2D]) {
        let fullPath = route.routePath
        guard fullPath.count >= 4 else {
            // Route too short to split meaningfully
            let midpoint = fullPath.count / 2
            return (Array(fullPath.prefix(midpoint + 1)), Array(fullPath.suffix(from: midpoint)))
        }
        
        // Find the last waypoint (or approximate midpoint if no waypoints)
        guard let lastMarker = route.qrMarkers.last else {
            // No waypoints - split at midpoint
            let midpoint = fullPath.count / 2
            return (Array(fullPath.prefix(midpoint + 1)), Array(fullPath.suffix(from: midpoint)))
        }
        
        // Find the point on the polyline closest to the last waypoint
        var closestIndex = fullPath.count / 2
        var closestDistance = Double.infinity
        
        for (index, point) in fullPath.enumerated() {
            let dist = distanceBetweenPoints(point, lastMarker.coordinate)
            if dist < closestDistance {
                closestDistance = dist
                closestIndex = index
            }
        }
        
        // Split at this index (include the split point in both segments for continuity)
        let outbound = Array(fullPath.prefix(closestIndex + 1))
        let returnLeg = Array(fullPath.suffix(from: closestIndex))
        
        return (outbound, returnLeg)
    }
    
    private func distanceBetweenPoints(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
    
    /// Calculate camera position to show entire route
    var mapCameraPosition: MapCameraPosition {
        // v1.8.3: Use bounding box to ensure ENTIRE route is visible
        guard let userLoc = userLocation else {
            return .automatic
        }
        
        // Collect all points that must be visible
        // Start with user location (always required)
        var allPoints: [CLLocationCoordinate2D] = [userLoc]
        
        // Add POI markers (these MUST be visible)
        for marker in route.qrMarkers {
            allPoints.append(marker.coordinate)
            print("🗺️ Including POI: \(marker.name) at (\(String(format: "%.4f", marker.coordinate.latitude)), \(String(format: "%.4f", marker.coordinate.longitude)))")
        }
        
        // Add route polyline points (if available)
        let polylinePoints = route.routePath
        if !polylinePoints.isEmpty {
            allPoints.append(contentsOf: polylinePoints)
            print("🗺️ Including \(polylinePoints.count) polyline points")
        }
        
        // Also check generatedData for POI coordinates (backup)
        if let data = generatedData {
            for place in data.places {
                let coord = place.coordinate
                if !allPoints.contains(where: { abs($0.latitude - coord.latitude) < 0.0001 && abs($0.longitude - coord.longitude) < 0.0001 }) {
                    allPoints.append(coord)
                    print("🗺️ Including from generatedData: \(place.name)")
                }
            }
        }
        
        print("🗺️ Map preview: \(allPoints.count) total points to fit")
        
        // Log route POI sources
        if let data = generatedData {
            let googleCount = data.places.filter { $0.source == .google || (!$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") && !$0.placeId.hasPrefix("geograph_")) }.count
            let appleCount = data.places.filter { $0.source == .apple || $0.placeId.hasPrefix("apple_") }.count
            let osmCount = data.places.filter { $0.source == .osm || $0.placeId.hasPrefix("osm_") }.count
            let geographCount = data.places.filter { $0.source == .geograph || $0.placeId.hasPrefix("geograph_") }.count
            print("🗺️ Route POIs: 🌐 Google: \(googleCount), 🍎 Apple: \(appleCount), 🗺️ OSM: \(osmCount), 📸 Geograph: \(geographCount)")
        }
        
        // Log TOTAL cached POIs for location
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: userLoc) {
            let totalGoogle = cachedPOIs.filter { $0.source == .google || (!$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") && !$0.placeId.hasPrefix("geograph_")) }.count
            let totalApple = cachedPOIs.filter { $0.source == .apple || $0.placeId.hasPrefix("apple_") }.count
            let totalOSM = cachedPOIs.filter { $0.source == .osm || $0.placeId.hasPrefix("osm_") }.count
            let geographPOIs = cachedPOIs.filter { $0.source == .geograph || $0.placeId.hasPrefix("geograph_") }
            let totalGeograph = geographPOIs.count
            print("🗺️ TOTAL cached POIs: \(cachedPOIs.count) (🌐 Google: \(totalGoogle), 🍎 Apple: \(totalApple), 🗺️ OSM: \(totalOSM), 📸 Geograph: \(totalGeograph))")
            
            // List all Geograph POIs if any
            if totalGeograph > 0 {
                print("📸 ═══════════════════════════════════════════════════════════")
                print("📸 Geograph POIs (\(totalGeograph) total):")
                for (index, poi) in geographPOIs.enumerated() {
                    let distance = distanceBetweenPoints(userLoc, poi.coordinate)
                    print("📸   [\(index + 1)] \(poi.name) - \(Int(distance))m away")
                }
                print("📸 ═══════════════════════════════════════════════════════════")
            }
        }
        
        // Debug: Check if polyline exists
        print("🗺️ Polyline: \(route.trimmed != nil ? "✅ exists (\(route.routePath.count) points)" : "❌ missing")")
        print("🗺️ QR Markers: \(route.qrMarkers.count) markers")
        
        guard allPoints.count > 1 else {
            return .region(MKCoordinateRegion(center: userLoc, latitudinalMeters: 800, longitudinalMeters: 800))
        }
        
        // Calculate TRUE bounding box of all points (guard avoids force unwrap / invalid reuse)
        let latitudes = allPoints.map { $0.latitude }
        let longitudes = allPoints.map { $0.longitude }
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLng = longitudes.min(),
              let maxLng = longitudes.max() else {
            return .region(MKCoordinateRegion(center: userLoc, latitudinalMeters: 800, longitudinalMeters: 800))
        }
        
        // Center of the bounding box (not user location)
        let centerLat = (minLat + maxLat) / 2
        let centerLng = (minLng + maxLng) / 2
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng)
        
        // Span with 50% padding for labels and visual breathing room
        let latSpan = (maxLat - minLat) * 1.5
        let lngSpan = (maxLng - minLng) * 1.5
        
        // Ensure minimum zoom level for very short routes
        let finalLatSpan = max(0.01, latSpan)
        let finalLngSpan = max(0.01, lngSpan)
        
        print("🗺️ Bounds: lat[\(String(format: "%.4f", minLat))...\(String(format: "%.4f", maxLat))] lng[\(String(format: "%.4f", minLng))...\(String(format: "%.4f", maxLng))]")
        print("🗺️ Center: (\(String(format: "%.4f", centerLat)), \(String(format: "%.4f", centerLng))), Span: \(String(format: "%.4f", finalLatSpan)) x \(String(format: "%.4f", finalLngSpan))")
        
        let region = MKCoordinateRegion(
            center: center,  // Center on bounding box, not user
            span: MKCoordinateSpan(latitudeDelta: finalLatSpan, longitudeDelta: finalLngSpan)
        )
        
        return .region(region)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Map - with loading overlay
            ZStack {
                // Actual map - uses binding so camera updates when route changes
                Map(position: $cameraPosition) {
                // User's starting location (stable id for reuse)
                if let userLoc = userLocation {
                    Annotation("Start/End", coordinate: userLoc) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 24, height: 24)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                        }
                        .id("startEnd")
                    }
                }
                
                // Route polyline — show only real walking polylines (MapKit/Google), not OSRM or synthetic
                // Synthetic polylines from the soft-cap estimator have 3-5 points (straight lines between waypoints).
                // Real road-following polylines from MapKit/Google have 20+ points.
                if route.hasPolyline && !route.usedOSRMRouting && route.routePath.count >= 10 {
                    MapPolyline(coordinates: route.routePath)
                        .stroke(route.color, lineWidth: 4)
                }
                
                // Discovery markers (POIs) — stable id per marker
                // Name rendered as part of the view (not MapKit title) so it's always visible
                ForEach(route.qrMarkers) { marker in
                    Annotation("", coordinate: marker.coordinate) {
                        VStack(spacing: 2) {
                            ZStack {
                                Circle()
                                    .fill(Color.mintGreen)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "mappin")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            Text(marker.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                )
                        }
                        .id(marker.id)
                    }
                }
            }
            .mapStyle(.standard)
                .onAppear {
                    // Set initial camera position
                    cameraPosition = mapCameraPosition
                }
                .onChange(of: route.id) { _, _ in
                    // Update camera when route changes (swiping between routes)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        cameraPosition = mapCameraPosition
                    }
                }
                
                // v1.6.45: Clean loading overlay
                if isMapLoading {
                    ZStack {
                        // Soft gradient background
                        LinearGradient(
                            colors: [
                                Color(.systemBackground),
                                Color(.systemGray6)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        
                        // Simple centered spinner
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.tealAccent)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear {
                // Fade out loading overlay after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isMapLoading = false
                    }
                }
            }
            .onChange(of: route.id) { _, _ in
                // Reset loading state when route changes
                isMapLoading = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isMapLoading = false
                    }
                }
            }
            
            // Warning banners
            VStack(spacing: 0) {
                // Over target duration warning
                if isOverTarget {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text("Route is \(minutesOverTarget) min longer than your \(targetDurationMinutes) min delay")
                            .font(.caption)
                    }
                    .foregroundColor(.coralPink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.coralPink.opacity(0.1))
                }
            }
            
            // Bottom info panel
            VStack(spacing: 16) {
                // Route summary
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(route.name)
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                        }
                        
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                            Text("AI generated route")
                                .font(.caption)
                        }
                        .foregroundColor(.tealAccent)
                        
                        // v1.6.10: Low POI warning
                        if hasLimitedPOIs {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text("Limited options in this area")
                                    .font(.caption)
                            }
                            .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    // v2.1.11: Always use WalkingRoute for display — it has the Google-corrected values.
                    // GeneratedRoute (generatedData) may still hold stale synthetic/prepop estimates.
                    VStack(alignment: .trailing, spacing: 4) {
                        let _ = {
                            let dataDur = generatedData?.durationSeconds ?? -1
                            let dataDist = generatedData?.distanceMeters ?? -1
                            print("[ROUTE_DEBUG] 🖥️ UI_RENDER '\(route.name)': WalkingRoute=\(route.durationMinutes)min/\(route.distanceMeters)m | GeneratedRoute=\(dataDur)s(\(dataDur/60)min)/\(dataDist)m | showing WalkingRoute")
                        }()
                        Text("\(route.durationMinutes) min")
                            .font(.titleMedium)
                            .fontWeight(.bold)
                            .foregroundColor(.tealAccent)
                        
                        let distKm = Double(route.distanceMeters) / 1000.0
                        if distKm >= 1.0 {
                            Text(String(format: "%.1f km", distKm))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(route.distanceMeters)m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // AI-generated description
                if !route.description.isEmpty {
                    Text(route.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .italic()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                // Places found (if using smart routing)
                if let data = generatedData, !data.places.filter({ !GoogleMapsService.isJunkPOIName($0.name) }).isEmpty {
                    let displayPlaces = data.places.filter { !GoogleMapsService.isJunkPOIName($0.name) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Places along your route:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(displayPlaces) { place in
                                    HStack(spacing: 4) {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                        Text(place.displayName)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.mintGreen.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                
                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 12, height: 12)
                        Text("Start/End")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.mintGreen)
                            .frame(width: 12, height: 12)
                        Text("POI")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    if hasRealPolyline {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(route.color)
                                .frame(width: 16, height: 4)
                            Text("Route")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    Spacer()
                }
                
                // Route index indicator - left aligned, consistent caption font
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(currentRouteIndex) of \(totalRoutes)")
                            .font(.caption)
                            .foregroundColor(.primary)
                        
                        if isGeneratingAdditional {
                            // v2.1.10: +1 button pressed — show spinner until new route appears
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Generating route...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if isLoadingMoreRoutes {
                            ProgressView()
                                .scaleEffect(0.6)
                            if totalRoutes == 1 {
                                Text("Finding more options...")
                                .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Pick any or wait for more...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // v1.6.39: Dead zone fallback indicator
                    if isDeadZoneFallback {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text("Closest available route for this duration")
                                .font(.caption)
                        }
                        .foregroundColor(.softAmber)
                    }
                    
                    // v2.1.x: Out-of-band banner — per-route label (e.g. "Shorter than 20–30 min") or "No routes in band; showing closest"
                    if showOutOfBandBanner && selectedDuration > 0 {
                        let minAcc = Int(Double(selectedDuration) * 0.80)
                        let maxAcc = Int(Double(selectedDuration) * 1.20)
                        let text = outOfBandLabel ?? "No routes in \(minAcc)–\(maxAcc) min; showing closest (\(route.durationMinutes) min)"
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(text)
                                .font(.caption)
                        }
                        .foregroundColor(.softAmber)
                    }
                    
                    // v1.6.25: All routes found message
                    if varietyExhausted && !isLoadingMoreRoutes {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("You're seeing all available routes")
                                .font(.caption)
                        }
                        .foregroundColor(.tealAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.tealAccent.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    
                    // v1.8.17: Limited variety message - show when only 1-2 routes and not loading
                    if totalRoutes <= 2 && !isLoadingMoreRoutes && !varietyExhausted && !isDeadZoneFallback {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.caption2)
                            Text("Best route for your area")
                                .font(.caption)
                        }
                        .foregroundColor(.mintGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.mintGreen.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Action buttons
                HStack(spacing: 10) {
                    // v1.6.45: Only show Next and +1 buttons once we have 2+ routes
                    if totalRoutes > 1 {
                        // Next button — lavenderMist
                        Button(action: onShuffle) {
                            HStack(spacing: 6) {
                                Image(systemName: "shuffle")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text("Next")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.mintGreen)
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .background(Color.mintGreen.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        
                        // v2.1.10: +1 button — softAmber, generate one additional route on demand
                        Button(action: onGenerateAdditional) {
                            Group {
                                if isGeneratingAdditional {
                                    ProgressView()
                                        .tint(.softAmber)
                                } else {
                                    Text("+1")
                                        .font(.title3)
                                        .fontWeight(.bold)
                                }
                            }
                            .foregroundColor(canGenerateAdditional ? .softAmber : .gray)
                            .frame(width: 48, height: 48)
                            .background((canGenerateAdditional ? Color.softAmber : Color.gray).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canGenerateAdditional)
                    }
                    
                    // v1.6.28: Simplified - start walk immediately (no permission gates)
                    Button {
                        onStartWalk()
                    } label: {
                        HStack {
                            Image(systemName: primaryButtonIcon)
                            Text(primaryButtonText)
                            if isStartingWalk {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(color: primaryButtonColor))
                    .disabled(isStartingWalk)
                    .opacity(isStartingWalk ? 0.7 : 1.0)
                }
            }
            .padding(20)
            .cardStyle()
        }
    }
}

struct DurationOptionButton: View {
    @Environment(\.colorScheme) var colorScheme
    let duration: Int
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Text("\(duration)")
                    .font(.titleMedium)
                    .fontWeight(.bold)
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text("min")
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.tealAccent : (colorScheme == .dark ? Color.darkCardBackground : Color.white.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DifficultyOptionButton: View {
    let title: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color : color.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RouteInfoItem: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.tealAccent)
            
            Text(value)
                .font(.bodyLarge)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Route Filters
struct RouteFilters: View {
    @Binding var selectedDifficulty: RouteDifficulty?
    @Binding var showIndoorOnly: Bool
    @Binding var showAccessibleOnly: Bool
    @State private var hasScrolled = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 8) {
            // Filter label with swipe hint
            HStack {
                Text("Filter routes")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !hasScrolled {
                    HStack(spacing: 4) {
                        Text("Swipe for more")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.tealAccent)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 4)
            .animation(.easeInOut, value: hasScrolled)
            
            // Scrollable filters with gradient fade
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // Indoor filter - show first for discoverability
                        FilterChip(
                            title: "Indoor",
                            icon: "building.2",
                            isSelected: showIndoorOnly,
                            color: .tealAccent
                        ) {
                            withAnimation {
                                showIndoorOnly.toggle()
                            }
                        }
                        
                        // Accessible filter
                        FilterChip(
                            title: "Accessible",
                            icon: "figure.roll",
                            isSelected: showAccessibleOnly,
                            color: .lavenderMist
                        ) {
                            withAnimation {
                                showAccessibleOnly.toggle()
                            }
                        }
                        
                        Divider()
                            .frame(height: 24)
                        
                        // Difficulty filters
                        ForEach(RouteDifficulty.allCases, id: \.self) { difficulty in
                            FilterChip(
                                title: difficulty.rawValue,
                                icon: difficulty.icon,
                                isSelected: selectedDifficulty == difficulty,
                                color: difficulty.color
                            ) {
                                withAnimation {
                                    if selectedDifficulty == difficulty {
                                        selectedDifficulty = nil
                                    } else {
                                        selectedDifficulty = difficulty
                                    }
                                }
                            }
                        }
                        
                        // Extra padding at end to ensure last item is fully visible
                        Color.clear.frame(width: 20)
                    }
                    .padding(.horizontal, 4)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onChange(of: geo.frame(in: .global).minX) { oldValue, newValue in
                                    if newValue < oldValue && !hasScrolled {
                                        withAnimation {
                                            hasScrolled = true
                                        }
                                    }
                                }
                        }
                    )
                }
                
                // Fade gradient on right edge to hint at more content
                if !hasScrolled {
                    LinearGradient(
                        colors: [
                            Color.clear,
                            colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.8)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? .white : color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(0.1))
            )
        }
    }
}

// MARK: - Route Card
struct RouteCard: View {
    let route: WalkingRoute
    let isRecommended: Bool
    let isTooLong: Bool
    let onSelect: () -> Void
    
    @State private var isExpanded = false
    @State private var showMapPreview = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    HStack {
                        ZStack {
                            Circle()
                                .fill(route.color.opacity(0.15))
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: route.icon)
                                .font(.title3)
                                .foregroundColor(route.color)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(route.name)
                                    .font(.bodyLarge)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                if route.isCurated {
                                    HStack(spacing: 2) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.tealAccent)
                                    .clipShape(Capsule())
                                    .fixedSize()
                                }
                                
                                if isRecommended {
                                    HStack(spacing: 2) {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                        Text("BEST")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.mintGreen)
                                    .clipShape(Capsule())
                                    .fixedSize()
                                }
                                
                                if isTooLong {
                                    Text("TOO LONG")
                                        .font(.micro)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.coralPink)
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text(route.description)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(isExpanded ? nil : 2)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    
                    // Stats row
                    HStack(spacing: 16) {
                        StatBadge(icon: "clock", value: "\(route.durationMinutes)", unit: "min")
                        StatBadge(icon: "figure.walk", value: "\(route.estimatedSteps)", unit: "steps")
                        StatBadge(icon: "mappin.circle.fill", value: "\(route.qrMarkers.count)", unit: "spots")
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            if route.isIndoor {
                                Image(systemName: "building.2")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            if route.isAccessible {
                                Image(systemName: "figure.roll")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    
                    // Landmarks
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Route highlights")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .textCase(.uppercase)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(Array(route.landmarks.enumerated()), id: \.offset) { index, landmark in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(route.color)
                                            .frame(width: 8, height: 8)
                                        
                                        Text(landmark)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    
                                    if index < route.landmarks.count - 1 {
                                        Rectangle()
                                            .fill(route.color.opacity(0.3))
                                            .frame(width: 20, height: 2)
                                            .padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Discovery spots
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(.mintGreen)
                            Text("\(route.qrMarkers.count) Discovery Spots")
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textCase(.uppercase)
                        }
                        
                        Text("Walk to these locations and the app will automatically unlock wellbeing content:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        FlowLayout(spacing: 8) {
                            ForEach(route.qrMarkers) { marker in
                                HStack(spacing: 4) {
                                    Image(systemName: marker.content.icon)
                                        .font(.caption2)
                                    Text(marker.name)
                                        .font(.caption)
                                }
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.mintGreen.opacity(0.15))
                                .clipShape(Capsule())
                            }
                        }
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: { showMapPreview = true }) {
                            HStack {
                                Image(systemName: "map")
                                Text("View Map")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(color: .tealAccent))
                        
                        Button(action: onSelect) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Start Route")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(color: isTooLong ? .secondary : route.color))
                        .disabled(isTooLong)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .cardStyle()
        .sheet(isPresented: $showMapPreview) {
            RouteMapPreviewSheet(route: route)
        }
        .opacity(isTooLong ? 0.7 : 1)
    }
}

// MARK: - Route Map Preview Sheet
struct RouteMapPreviewSheet: View {
    let route: WalkingRoute
    @Environment(\.dismiss) private var dismiss
    
    // Clinic location (Longley Centre, Sheffield - S5 7JT)
    static let longleyCentre = CLLocationCoordinate2D(latitude: 53.4108891, longitude: -1.4603237)
    
    var startCoordinate: CLLocationCoordinate2D {
        route.waypoints.first ?? Self.longleyCentre
    }
    
    var body: some View {
        NavigationStack {
            if route.isIndoor {
                // Indoor route - show landmark list instead of map
                IndoorRoutePreview(route: route)
            } else {
                // Outdoor route - show map with polyline
                Map {
                    // Start/End marker (Longley Centre) — stable id
                    Annotation("Start/End", coordinate: startCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.coralPink)
                                .frame(width: 44, height: 44)
                            Image(systemName: "cross.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        .id("startEnd")
                    }
                    
                    // Route polyline — show only real walking polylines, not OSRM or synthetic
                    if route.hasPolyline && !route.usedOSRMRouting && route.routePath.count >= 10 {
                        MapPolyline(coordinates: route.routePath)
                            .stroke(route.color, lineWidth: 4)
                    }
                    
                    // Discovery markers — stable id per marker
                    // Name rendered as part of view so it's always visible
                    ForEach(route.qrMarkers) { marker in
                        Annotation("", coordinate: marker.coordinate) {
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle()
                                        .fill(Color.mintGreen)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "mappin")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                Text(marker.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                    )
                            }
                            .id(marker.id)
                        }
                    }
                }
                .mapStyle(.standard)
                .overlay(alignment: .bottom) {
                    // Route info overlay
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(route.name)
                                        .font(.titleMedium)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    
                                    if route.isCurated {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                    }
                                }
                                
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.caption2)
                                    Text("Circular route • \(route.qrMarkers.count) discovery spots")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(route.durationMinutes) min")
                                    .font(.bodyLarge)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.tealAccent)
                                Text("\(route.distanceMeters)m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Legend
                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.coralPink)
                                    .frame(width: 12, height: 12)
                                Text("Start/End")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.mintGreen)
                                    .frame(width: 12, height: 12)
                                Text("Discovery Spot")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(route.color)
                                    .frame(width: 16, height: 4)
                                Text("Route")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                }
            }
        }
        .navigationTitle(route.isIndoor ? "Indoor Route" : "Route Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Indoor Route Preview (No Map)
struct IndoorRoutePreview: View {
    let route: WalkingRoute
    
    var body: some View {
        ZStack {
            AnimatedGradientBackground()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(route.color.opacity(0.2))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: route.icon)
                                .font(.system(size: 36))
                                .foregroundColor(route.color)
                        }
                        
                        Text(route.name)
                            .font(.titleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text("\(route.durationMinutes) min")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                Text("\(route.distanceMeters)m")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "mappin")
                                Text("\(route.qrMarkers.count) spots")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    
                    // Indoor navigation notice
                    HStack(spacing: 12) {
                        Image(systemName: "building.2.fill")
                            .font(.title2)
                            .foregroundColor(.lavenderMist)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Indoor Route")
                                .font(.bodyMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Text("Follow the coloured floor lines and hospital signage. GPS doesn't work indoors, so discovery spots will activate based on timing.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(16)
                    .cardStyle()
                    
                    // Landmarks / Route steps
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Route")
                            .font(.bodyLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        ForEach(Array(route.landmarks.enumerated()), id: \.offset) { index, landmark in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(route.color)
                                        .frame(width: 32, height: 32)
                                    
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                                
                                Text(landmark)
                                    .font(.bodyMedium)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if index < route.landmarks.count - 1 {
                                    Image(systemName: "arrow.down")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Image(systemName: "flag.checkered")
                                        .font(.caption)
                                        .foregroundColor(.mintGreen)
                                }
                            }
                            
                            if index < route.landmarks.count - 1 {
                                Rectangle()
                                    .fill(route.color.opacity(0.3))
                                    .frame(width: 2, height: 20)
                                    .padding(.leading, 15)
                            }
                        }
                    }
                    .padding(20)
                    .cardStyle()
                    
                    // Discovery spots
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.mintGreen)
                            Text("Discovery Spots")
                                .font(.bodyLarge)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                        }
                        
                        Text("These wellbeing activities will unlock as you walk:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(route.qrMarkers) { marker in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.mintGreen.opacity(0.2))
                                        .frame(width: 40, height: 40)
                                    
                                    Image(systemName: marker.content.icon)
                                        .font(.body)
                                        .foregroundColor(.mintGreen)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.name)
                                        .font(.bodyMedium)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    
                                    Text(marker.location)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Text("+\(marker.pointsValue)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.softAmber)
                            }
                            .padding(12)
                            .background(Color.mintGreen.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(20)
                    .cardStyle()
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct StatBadge: View {
    let icon: String
    let value: String
    let unit: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.primary)
            
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            if !unit.isEmpty {
                Text(unit)
                    .font(.micro)
                    .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - Active Walk View
// MARK: - v2.1.6: Walking Alert Overlay
/// Which action is primary (green, top) for 50%/80% alerts. Drives button order and prominence.
enum PrimaryAlertAction {
    case headBack   // Head back on top (when time is tight)
    case keepWalking // Keep walking on top (when plenty of time left)
}

/// Custom overlay alert that doesn't dismiss the underlying map view
/// Dark mode: black card to match walk UI. Light mode: white card with subtle shadow.
struct WalkingAlertOverlay: View {
    let title: String
    let message: String
    let onOK: () -> Void
    let onStopAlerts: (() -> Void)?
    var showStopButton: Bool = true
    var primaryLabel: String = "OK"
    var secondaryLabel: String = "Stop Alerts"
    /// Option B: when true, top = Head back or Keep walking (see primaryHalfwayAction), bottom = the other + Stop Alerts
    var showHeadBackButton: Bool = false
    var headBackLabel: String = "Head back"
    var onHeadBack: (() -> Void)? = nil
    /// When showHeadBackButton is true: .headBack = Head back green on top; .keepWalking = Keep walking green on top.
    var primaryHalfwayAction: PrimaryAlertAction = .headBack
    
    @Environment(\.colorScheme) var colorScheme
    
    private var cardBackground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var titleColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var messageColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary.opacity(0.85)
    }
    
    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.08)
    }
    
    private var stopAlertsButtonBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.red.opacity(0.08)
    }
    
    private var secondaryButtonBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : Color.gray.opacity(0.15)
    }
    
    private var dimmedBackdrop: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.35)
    }
    
    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.5) : .black.opacity(0.15)
    }
    
    var body: some View {
        ZStack {
            dimmedBackdrop
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(titleColor)
                }
                
                Text(message)
                    .font(.body)
                    .foregroundColor(messageColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                
                if showHeadBackButton, let onHeadBack = onHeadBack {
                    // Primary action on top (green), other + Stop Alerts below
                    VStack(spacing: 12) {
                        if primaryHalfwayAction == .headBack {
                            Button(action: onHeadBack) {
                                Text(headBackLabel)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.green)
                                    .cornerRadius(10)
                            }
                            HStack(spacing: 12) {
                                Button(action: onOK) {
                                    Text(primaryLabel)
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(secondaryButtonBackground)
                                        .cornerRadius(10)
                                }
                                if let onStopAlerts = onStopAlerts {
                                    Button(action: onStopAlerts) {
                                        Text(secondaryLabel)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.red)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(stopAlertsButtonBackground)
                                            .cornerRadius(10)
                                    }
                                }
                            }
                        } else {
                            // Keep walking primary (green on top), then Head back + Stop Alerts
                            Button(action: onOK) {
                                Text(primaryLabel)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.green)
                                    .cornerRadius(10)
                            }
                            HStack(spacing: 12) {
                                Button(action: onHeadBack) {
                                    Text(headBackLabel)
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(secondaryButtonBackground)
                                        .cornerRadius(10)
                                }
                                if let onStopAlerts = onStopAlerts {
                                    Button(action: onStopAlerts) {
                                        Text(secondaryLabel)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.red)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(stopAlertsButtonBackground)
                                            .cornerRadius(10)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Original: HStack [ Stop Alerts ] [ OK ]
                    HStack(spacing: 12) {
                        if let onStopAlerts = onStopAlerts, showStopButton {
                            Button(action: onStopAlerts) {
                                Text(secondaryLabel)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(stopAlertsButtonBackground)
                                    .cornerRadius(10)
                            }
                        }
                        
                        Button(action: onOK) {
                            Text(primaryLabel)
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green)
                                .cornerRadius(10)
                        }
                    }
                }
            }
            .padding(24)
            .background(cardBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(cardBorder, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 20, x: 0, y: 10)
            .padding(.horizontal, 40)
        }
    }
}

struct ActiveWalkView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @ObservedObject var locationService: LocationService  // v1.9.63: Observe directly for responsive direction updates
    var isPresented: Binding<Bool>? = nil  // v1.9.28: Optional - only needed when shown in a sheet
    @State private var showAllDirections: Bool = false
    @State private var showEndConfirmation: Bool = false
    @State private var showMotionExplainer: Bool = false  // Bottom "Track Steps" pill presents motion explainer
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        // v1.9.28: Immersive full-screen - no navigation wrapper
        VStack(spacing: 0) {
            // Compact header with route info
            if let route = viewModel.walkSession.currentRoute {
                // Compact header - show route name only if no directions (otherwise directions banner serves as header)
                if route.walkingDirections.isEmpty || route.isIndoor {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.isIndoor ? route.name : "\(route.name): loading directions")
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            Text("\(Int(locationService.distanceWalked))m walked")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        Spacer()
                        
                        // Static clinic delay OR walk duration (if no clinician selected)
                        VStack(alignment: .trailing, spacing: 1) {
                            if viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable {
                                Text("\(viewModel.waitTimeInfo.estimatedMinutes)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                                Text("mins delay")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Text("\(route.durationMinutes)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                                Text("min walk")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                            
                            if viewModel.walkSession.halfwayAlertSent {
                            Text("↩︎")
                                .font(.title2)
                                    .foregroundColor(.softAmber)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(route.color)
                }
                
                // Walking directions banner (only for non-indoor routes with directions)
                // This serves as the main header when directions are available
                // v1.9.15: Use cached directions (return route if returning, original otherwise)
                let directionsToShow: [WalkingDirection] = {
                    if viewModel.isUsingReturnDirections && !viewModel.cachedReturnDirections.isEmpty {
                        return viewModel.cachedReturnDirections
                    } else if !viewModel.cachedOriginalDirections.isEmpty {
                        return viewModel.cachedOriginalDirections
                    } else {
                        return route.walkingDirections
                    }
                }()
                
                if !route.isIndoor && !directionsToShow.isEmpty {
                    // v1.9.15: Clamp direction index to prevent out-of-bounds when switching directions
                    // v1.9.63: Use locationService directly (now observed) for responsive updates
                    let clampedIndex = Binding(
                        get: { 
                            let idx = locationService.currentDirectionIndex
                            let clamped = min(max(0, idx), directionsToShow.count - 1)
                            return clamped
                        },
                        set: { newValue in
                            let clamped = min(max(0, newValue), directionsToShow.count - 1)
                            locationService.currentDirectionIndex = clamped
                        }
                    )
                    
                    WalkingDirectionsBanner(
                        directions: directionsToShow,
                        currentIndex: clampedIndex,
                        showAllDirections: $showAllDirections,
                        delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                        walkDurationMinutes: route.durationMinutes,
                        hasClinicianSelected: viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable && !viewModel.isClinicEnded && viewModel.waitTimeInfo.clinicianName != "Select your clinician",
                        distanceWalked: Int(locationService.distanceWalked),
                        halfwayAlert: viewModel.walkSession.halfwayAlertSent,
                        estimatedSeenTime: viewModel.waitTimeInfo.formattedEstimatedTimeToBeSeen
                    )
                }
            }
            
            // Map with expanded directions overlay
            ZStack {
                // Embedded Map - always present
                EmbeddedWalkMapView(viewModel: viewModel, showMotionExplainer: $showMotionExplainer)
                    .frame(maxHeight: .infinity)
                
                // Expanded directions overlay - covers map when shown
                // v1.9.15: Use cached directions (return route if returning, original otherwise)
                if showAllDirections, let route = viewModel.walkSession.currentRoute {
                    let directionsToShow: [WalkingDirection] = {
                        if viewModel.isUsingReturnDirections && !viewModel.cachedReturnDirections.isEmpty {
                            return viewModel.cachedReturnDirections
                        } else if !viewModel.cachedOriginalDirections.isEmpty {
                            return viewModel.cachedOriginalDirections
                        } else {
                            return route.walkingDirections
                        }
                    }()
                    
                    ExpandedDirectionsList(
                        directions: directionsToShow,
                        currentIndex: Binding(
                            get: { locationService.currentDirectionIndex },
                            set: { locationService.currentDirectionIndex = $0 }
                        ),
                        showAllDirections: $showAllDirections
                    )
                    .transition(.opacity)
                }
            }
            
            // Bottom section with stats and end button
            VStack(spacing: 12) {
                // Compact stats row (v1.6.13: removed delay badge - now shown in top banner)
                // When steps not enabled, first pill is tappable "Track Steps" and presents motion explainer
                HStack(spacing: 8) {
                    if viewModel.stepTrackingWasEnabled && viewModel.healthKitService.isMotionAuthorized {
                        CompactStatPill(icon: "figure.walk", value: "\(viewModel.walkSession.stepsThisSession)", label: "steps")
                    } else {
                        Button(action: { showMotionExplainer = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.caption)
                                    .foregroundColor(.tealAccent)
                                Text("Track Steps")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Image(systemName: "hand.tap.fill")
                                    .font(.caption2)
                                    .foregroundColor(.tealAccent.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    CompactStatPill(icon: "star.fill", value: "\(viewModel.userProgress.totalPoints)", label: "pts")
                    CompactStatPill(icon: "mappin", value: "\(viewModel.walkSession.markersScanned.count)", label: "spots")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // End walk button
                Button(action: { showEndConfirmation = true }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("End Walk")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(color: .coralPink))
                .padding(.horizontal, 40)
                .padding(.bottom, 40)  // v1.9.36: Increased from 12 to 40 for home indicator clearance
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)  // v1.9.28: Extend to bottom edge only (preserve status bar)
        .confirmationDialog("End Walk?", isPresented: $showEndConfirmation) {
            Button("End & Save Progress") {
                viewModel.endWalk(completed: true)
                // v1.9.28: Dismiss fullscreen cover after ending walk
                if let isPresented = isPresented {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isPresented.wrappedValue = false
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your steps and progress will be saved.")
        }
        // v1.9.52: Present marker arrival sheet from within fullScreenCover
        // iOS doesn't allow presenting sheets from parent view when child is in fullScreenCover
        .sheet(isPresented: Binding(
            get: { viewModel.showMarkerArrivalPrompt },
            set: { viewModel.showMarkerArrivalPrompt = $0 }
        )) {
            MarkerArrivalSheet(viewModel: viewModel)
        }
        // v1.9.52: Present home arrival sheet from within fullScreenCover
        .sheet(isPresented: Binding(
            get: { viewModel.showHomeArrivalPrompt },
            set: { viewModel.showHomeArrivalPrompt = $0 }
        )) {
            HomeArrivalSheet(viewModel: viewModel, isPresented: isPresented)
        }
        // v2.1.6: Overlay-based alerts that don't dismiss the map
        .overlay(alignment: .center) {
            if viewModel.showHalfwayAlert {
                let _ = print("[HALFWAY] overlay rendering")
                WalkingAlertOverlay(
                    title: "Halfway Point! 🚶",
                    message: viewModel.halfwayAlertMessage,
                    onOK: {
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.showHalfwayAlert = false
                    },
                    onStopAlerts: {
                        viewModel.disableWalkingAlerts()
                        viewModel.showHalfwayAlert = false
                    },
                    primaryLabel: "Keep walking",
                    secondaryLabel: "Stop Alerts",
                    showHeadBackButton: true,
                    headBackLabel: "Head back",
                    onHeadBack: {
                        viewModel.userTappedHeadBack()
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.showHalfwayAlert = false
                    },
                    primaryHalfwayAction: viewModel.halfwayAlertSuggestHeadBack ? .headBack : .keepWalking
                )
            } else if viewModel.showReturnNowAlert {
                WalkingAlertOverlay(
                    title: "Time to Head Back 🏥",
                    message: viewModel.returnNowAlertMessage,
                    onOK: {
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.showReturnNowAlert = false
                    },
                    onStopAlerts: {
                        viewModel.disableWalkingAlerts()
                        viewModel.showReturnNowAlert = false
                    },
                    primaryLabel: "Keep walking",
                    secondaryLabel: "Stop Alerts",
                    showHeadBackButton: true,
                    headBackLabel: "Head back",
                    onHeadBack: {
                        viewModel.userTappedHeadBack()
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.showReturnNowAlert = false
                    },
                    primaryHalfwayAction: viewModel.returnNowAlertSuggestHeadBack ? .headBack : .keepWalking
                )
            } else if viewModel.showWalkCompleteAlert {
                WalkingAlertOverlay(
                    title: "Walk Complete! 🎉",
                    message: "Great job completing your walk! Head back to the waiting area when ready.",
                    onOK: {
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.showWalkCompleteAlert = false
                    },
                    onStopAlerts: nil,
                    showStopButton: false,
                    primaryLabel: "Keep walking",
                    showHeadBackButton: true,
                    headBackLabel: "End walk",
                    onHeadBack: {
                        viewModel.cancelAlertAutoDismissTimer()
                        viewModel.endWalk(completed: true)
                        viewModel.showWalkCompleteAlert = false
                        if let isPresented = isPresented {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                isPresented.wrappedValue = false
                            }
                        }
                    }
                )
            } else if viewModel.showAdjustRouteAlert {
                WalkingAlertOverlay(
                    title: "Route over your selected time",
                    message: "We've noticed we are past your selected time – want me to adjust your route?",
                    onOK: {
                        viewModel.acceptAdjustedRoute()
                    },
                    onStopAlerts: {
                        viewModel.declineAdjustedRoute()
                    },
                    primaryLabel: "Adjust",
                    secondaryLabel: "Keep current"
                )
            }
        }
    }
    
    func formatElapsedTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    func formatSeconds(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Walking Directions Banner
struct WalkingDirectionsBanner: View {
    let directions: [WalkingDirection]
    @Binding var currentIndex: Int
    @Binding var showAllDirections: Bool
    var delayMinutes: Int = 0
    var walkDurationMinutes: Int = 0  // Used when no clinician selected
    var hasClinicianSelected: Bool = true
    var distanceWalked: Int = 0
    var halfwayAlert: Bool = false
    var estimatedSeenTime: String? = nil  // v1.9.56: Optional appointment-based estimated time
    
    @Environment(\.colorScheme) var colorScheme
    
    // v2.1.7: Dynamic banner color - black in dark mode, vibrant teal in light mode
    private var bannerColor: Color {
        colorScheme == .dark ? Color.black : Color.tealAccent
    }
    
    // v1.9.15: Split instruction into main and destination parts
    private func splitInstruction(_ instruction: String) -> (main: String, destination: String?) {
        // Look for common patterns that indicate destination info
        let destinationPatterns = [
            "Destination will be",
            "Destination is",
            "Your destination",
            "The destination"
        ]
        
        // Check if instruction contains destination info
        for pattern in destinationPatterns {
            if let range = instruction.range(of: pattern, options: .caseInsensitive) {
                let mainPart = String(instruction[..<range.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                let destinationPart = String(instruction[range.lowerBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                
                return (mainPart, destinationPart)
            }
        }
        
        // Also check for comma-separated instructions (common pattern)
        if let commaIndex = instruction.firstIndex(of: ",") {
            let beforeComma = String(instruction[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            let afterComma = String(instruction[instruction.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            
            // If the part after comma looks like destination info, split it
            let lowercasedAfter = afterComma.lowercased()
            if lowercasedAfter.contains("destination") || 
               lowercasedAfter.contains("will be") ||
               lowercasedAfter.contains("on your") ||
               lowercasedAfter.contains("on the") {
                return (beforeComma, afterComma)
            }
        }
        
        // No split needed - return full instruction
        return (instruction, nil)
    }
    
    var body: some View {
        // Single compact banner with direction + timer (always visible at same position)
        if currentIndex < directions.count {
            let direction = directions[currentIndex]
            let instructionParts = splitInstruction(direction.instruction) // v1.9.15: Compute outside view builder
            
            Button(action: { 
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAllDirections.toggle() 
                }
            }) {
                HStack(spacing: 12) {
                    // v1.9.0: Enhanced directional arrow (larger, more prominent)
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 56, height: 56)
                        
                        // Large directional arrow matching turn direction
                        Image(systemName: turnArrowIcon(for: direction.maneuver))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    // Direction text - instruction with "(current) in Xm" so distance-to-turn is clear
                    VStack(alignment: .leading, spacing: 3) {
                        // Main instruction + (current) in Xm - e.g. "Turn left onto Hawthorne Close (current) in 32m"
                        Text("\(instructionParts.main) (current) in \(direction.distance.replacingOccurrences(of: " m", with: "m").replacingOccurrences(of: " km", with: "km"))")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7) // v2.1.7: Scale down to fit without truncation
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        
                        // v1.9.15: Destination info on separate line if present (expands banner)
                        if let destinationInfo = instructionParts.destination {
                            Text(destinationInfo)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(2)
                                .minimumScaleFactor(0.7) // v2.1.7: Scale down to fit without truncation
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        
                        // Compact info row: total walked (distance-to-turn now in instruction line)
                        HStack(spacing: 6) {
                            Text("\(distanceWalked)m walked")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            if halfwayAlert {
                                Text("• Head back!")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.softAmber)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Static clinic delay (only show if clinician selected, otherwise blank)
                    if hasClinicianSelected {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(delayMinutes)")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                            Text("mins delay")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            
                            // v1.9.56: Show estimated time to be seen if appointment time set
                            if let seenTime = estimatedSeenTime {
                                Text("~\(seenTime)")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.softAmber)
                            }
                        }
                    }
                    
                    // Expand button
                    Image(systemName: showAllDirections ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(bannerColor)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // v1.9.0: Helper to get large directional arrow icon for turn
    private func turnArrowIcon(for maneuver: String?) -> String {
        guard let maneuver = maneuver else { return "arrow.up" }
        
        switch maneuver {
        case "turn-left": return "arrow.left"
        case "turn-right": return "arrow.right"
        case "turn-slight-left": return "arrow.up.left"
        case "turn-slight-right": return "arrow.up.right"
        case "turn-sharp-left": return "arrow.turn.left.down"
        case "turn-sharp-right": return "arrow.turn.right.down"
        case "straight": return "arrow.up"
        case "uturn": return "arrow.uturn.backward"
        default: return "arrow.up"
        }
    }
}

// MARK: - Expanded Directions List (Overlay)
struct ExpandedDirectionsList: View {
    let directions: [WalkingDirection]
    @Binding var currentIndex: Int
    @Binding var showAllDirections: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    // v2.1.7: Dynamic accent color - black in dark mode, vibrant teal in light mode
    private var accentColor: Color {
        colorScheme == .dark ? Color.black : Color.tealAccent
    }
    
    // v1.9.15: Split instruction into main and destination parts
    private func splitInstruction(_ instruction: String) -> (main: String, destination: String?) {
        // Look for common patterns that indicate destination info
        let destinationPatterns = [
            "Destination will be",
            "Destination is",
            "Your destination",
            "The destination"
        ]
        
        // Check if instruction contains destination info
        for pattern in destinationPatterns {
            if let range = instruction.range(of: pattern, options: .caseInsensitive) {
                let mainPart = String(instruction[..<range.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                let destinationPart = String(instruction[range.lowerBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                
                return (mainPart, destinationPart)
            }
        }
        
            // Also check for comma-separated instructions (common pattern)
        if let commaIndex = instruction.firstIndex(of: ",") {
            let beforeComma = String(instruction[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            let afterComma = String(instruction[instruction.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            
            // If the part after comma looks like destination info, split it
            let lowercasedAfter = afterComma.lowercased()
            if lowercasedAfter.contains("destination") || 
               lowercasedAfter.contains("will be") ||
               lowercasedAfter.contains("on your") ||
               lowercasedAfter.contains("on the") {
                return (beforeComma, afterComma)
            }
        }
        
        // No split needed - return full instruction
        return (instruction, nil)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Close button header
            HStack {
                Text("All Directions")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: { 
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllDirections = false 
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(directions.enumerated()), id: \.element.id) { index, direction in
                        // v1.9.15: Compute instruction split outside view builder
                        let instructionParts = splitInstruction(direction.instruction)
                        
                        Button(action: {
                            currentIndex = index
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAllDirections = false
                            }
                        }) {
                            HStack(spacing: 12) {
                                // Step number with checkmark for completed
                                ZStack {
                                    Circle()
                                        .fill(index < currentIndex ? accentColor : 
                                              (index == currentIndex ? accentColor : (colorScheme == .dark ? Color.white.opacity(0.2) : Color.gray.opacity(0.2))))
                                        .frame(width: 32, height: 32)
                                    
                                    if index < currentIndex {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                    } else {
                                        Text("\(index + 1)")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                            .foregroundColor(index == currentIndex ? .white : .primary)
                                    }
                                }
                                
                                // Direction icon
                                Image(systemName: direction.icon)
                                    .font(.body)
                                    .foregroundColor(index == currentIndex ? (colorScheme == .dark ? .white : accentColor) : .secondary)
                                    .frame(width: 24)
                                
                                // Instruction
                                VStack(alignment: .leading, spacing: 3) {
                                    // Main instruction - allow 2 lines with dynamic scaling
                                    Text(instructionParts.main)
                                        .font(.subheadline)
                                        .foregroundColor(index == currentIndex ? .primary : .secondary)
                                        .lineLimit(2) // v2.1.7: Allow 2 lines instead of 1
                                        .minimumScaleFactor(0.7) // v2.1.7: Scale down to fit without truncation
                                        .multilineTextAlignment(.leading)
                                    
                                    // v1.9.15: Destination info on separate line if present
                                    if let destinationInfo = instructionParts.destination {
                                        Text(destinationInfo)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundColor(index == currentIndex ? .primary.opacity(0.9) : .secondary.opacity(0.9))
                                            .lineLimit(2) // v2.1.7: Allow 2 lines instead of 1
                                            .minimumScaleFactor(0.7) // v2.1.7: Scale down to fit without truncation
                                            .multilineTextAlignment(.leading)
                                    }
                                    
                                    Text(direction.distance.replacingOccurrences(of: " m", with: "m").replacingOccurrences(of: " km", with: "km"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                // Current indicator
                                if index == currentIndex {
                                    Text("NOW")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(index == currentIndex ? accentColor.opacity(0.1) : Color.clear)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if index < directions.count - 1 {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemBackground))
    }
}

struct WalkStatCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.titleLarge)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.primary)
                
                Spacer()
            }
        }
        .padding(16)
        .cardStyle()
    }
}

// MARK: - Marker Arrival Sheet
struct MarkerArrivalSheet: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @StateObject private var photoStorage = PhotoStorageService.shared
    @State private var showImagePicker = false
    @State private var showPhotoOptions = false
    @State private var capturedImage: UIImage?
    @State private var useCamera = false
    @State private var showBreathingExercise = false
    @State private var selectedExerciseForSheet: WellbeingContent? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Celebration header
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.mintGreen.opacity(0.2))
                                    .frame(width: 100, height: 100)
                                
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.mintGreen)
                            }
                            
                            Text("You've Arrived! 🎉")
                                .font(.titleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            if let marker = viewModel.currentMarker {
                                Text(marker.name)
                                    .font(.titleMedium)
                                    .foregroundColor(.primary)
                                
                                Text(marker.location)
                                    .font(.bodyMedium)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 20)
                        
                        // Points earned
                        if let marker = viewModel.currentMarker {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.softAmber)
                                Text("+\(marker.pointsValue) points")
                                    .font(.bodyLarge)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.softAmber)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.softAmber.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        
                        // v1.9.9: Swipeable breathing exercise carousel on arrival card
                        if let marker = viewModel.currentMarker, marker.contentType == .breathingExercise {
                            BreathingExerciseCarousel(
                                exercises: WellbeingContent.breathingExercises,
                                initialExercise: marker.content,
                                onTapExercise: { exercise in
                                    selectedExerciseForSheet = exercise
                                    showBreathingExercise = true
                                }
                            )
                        }
                        
                        // Photo prompt
                        VStack(spacing: 16) {
                            Image(systemName: "camera.fill")
                                .font(.title)
                                .foregroundColor(.tealAccent)
                            
                            Text("Capture This Moment")
                                .font(.bodyLarge)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Text("Take a photo of something that catches your eye. Your photos are saved in the Nature tab.")
                                .font(.bodyMedium)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                            
                            Button(action: {
                                showPhotoOptions = true
                            }) {
                                HStack {
                                    Image(systemName: "camera.fill")
                                    Text("Take Photo")
                                }
                                .font(.bodyMedium)
                                .fontWeight(.semibold)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            
                            Button("Skip for Now") {
                                viewModel.dismissMarkerPrompt()
                                dismiss()
                            }
                            .font(.bodyMedium)
                            .foregroundColor(.secondary)
                        }
                        .padding(20)
                        .cardStyle()
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Marker Discovered")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let marker = viewModel.currentMarker {
                    DebugLogger.shared.log("MarkerArrivalSheet onAppear: marker='\(marker.name)' contentType=\(marker.contentType.rawValue) (breathing carousel shown=\(marker.contentType == .breathingExercise))", category: "ARRIVAL")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        viewModel.dismissMarkerPrompt()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Take a Photo", isPresented: $showPhotoOptions) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        useCamera = true
                        showImagePicker = true
                    }
                }
                Button("Choose from Library") {
                    useCamera = false
                    showImagePicker = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Capture something beautiful from this spot")
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(image: $capturedImage, useCamera: useCamera)
            }
            .onChange(of: capturedImage) { oldValue, newValue in
                if let image = newValue {
                    photoStorage.savePhoto(image)
                    // Mark digital skill complete
                    viewModel.markDigitalSkillCompleted("take_photo")
                    capturedImage = nil
                    
                    // Dismiss after short delay to show save
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.dismissMarkerPrompt()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showBreathingExercise) {
                if let exercise = selectedExerciseForSheet {
                    BreathingExerciseSheet(
                        exercise: exercise,
                        onDismiss: {
                            // Just close the breathing exercise sheet, don't auto-close marker arrival sheet
                            showBreathingExercise = false
                        },
                        onComplete: {
                            // Track completion
                            viewModel.userProgress.breathingExercisesCompleted += 1
                            viewModel.userProgress.todayBreathingExercises += 1
                            viewModel.userProgress.addPoints(15)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Home Arrival Sheet (v1.9.13)
struct HomeArrivalSheet: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    var isPresented: Binding<Bool>? = nil  // v1.9.52: Binding to dismiss fullScreenCover
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Celebration header
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.tealAccent.opacity(0.2))
                                    .frame(width: 100, height: 100)
                                
                                // Black and white chequered flag
                                ZStack {
                                    // White background
                                    Rectangle()
                                        .fill(Color.white)
                                        .frame(width: 50, height: 35)
                                    
                                    // Black squares pattern
                                    HStack(spacing: 0) {
                                        VStack(spacing: 0) {
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                        }
                                        VStack(spacing: 0) {
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                        }
                                        VStack(spacing: 0) {
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                        }
                                        VStack(spacing: 0) {
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.white).frame(width: 12.5, height: 8.75)
                                            Rectangle().fill(Color.black).frame(width: 12.5, height: 8.75)
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            
                            Text("Welcome Back!")
                                .font(.titleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text("You've completed your walk")
                                .font(.titleMedium)
                                .foregroundColor(.primary)
                            
                            if let route = viewModel.selectedRoute {
                                Text(route.name)
                                    .font(.bodyMedium)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 20)
                        
                        // Walk summary
                        VStack(spacing: 16) {
                            HStack {
                                Image(systemName: "figure.walk")
                                    .foregroundColor(.tealAccent)
                                Text("\(viewModel.walkSession.stepsThisSession) steps")
                                    .font(.bodyLarge)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                            }
                            
                            let elapsed = viewModel.walkSession.elapsedSeconds
                            if elapsed > 0 {
                                HStack {
                                    Image(systemName: "clock.fill")
                                        .foregroundColor(.tealAccent)
                                    Text(formatTime(TimeInterval(elapsed)))
                                        .font(.bodyLarge)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                }
                            }
                            
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.softAmber)
                                Text("\(viewModel.userProgress.totalPoints) total points")
                                    .font(.bodyLarge)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.softAmber)
                            }
                        }
                        .padding(20)
                        .cardStyle()
                        
                        // End walk button - same action as "End & Save Progress"
                        Button(action: {
                            // Calls endWalk(completed: true) - same as "End & Save Progress" button
                            viewModel.endWalk(completed: true)
                            viewModel.dismissHomeArrivalPrompt()
                            dismiss()
                            // v1.9.52: Dismiss fullScreenCover after ending walk
                            if let isPresented = isPresented {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    isPresented.wrappedValue = false
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("End Walk")
                            }
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                        }
                        .buttonStyle(PrimaryButtonStyle(color: .tealAccent))
                        .padding(.horizontal, 40)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .onAppear {
                DebugLogger.shared.log("HomeArrivalSheet onAppear - walk complete screen shown", category: "HOME")
            }
            .navigationTitle("Walk Complete")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}

// MARK: - Breathing Exercise Carousel (v1.9.9)
/// Swipeable carousel of breathing exercises for the arrival card
struct BreathingExerciseCarousel: View {
    let exercises: [WellbeingContent]
    let initialExercise: WellbeingContent?
    let onTapExercise: (WellbeingContent) -> Void
    
    @State private var selectedIndex: Int = 0
    
    private var initialIndex: Int {
        if let initial = initialExercise,
           let index = exercises.firstIndex(where: { $0.title == initial.title }) {
            return index
        }
        return 0
    }
    
    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selectedIndex) {
                ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                    Button(action: {
                        onTapExercise(exercise)
                    }) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: exercise.icon)
                                    .font(.title3)
                                    .foregroundColor(.lavenderMist)
                                
                                Text(exercise.title)
                                    .font(.bodyMedium)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.lavenderMist)
                            }
                            
                            Text(exercise.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            
                            if let steps = exercise.steps, !steps.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(steps.enumerated()), id: \.offset) { stepIndex, step in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("\(stepIndex + 1)")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                                .frame(width: 16, height: 16)
                                                .background(Circle().fill(Color.lavenderMist))
                                            
                                            Text(step)
                                                .font(.caption2)
                                                .foregroundColor(.primary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                            
                            Text("Tap to start exercise")
                                .font(.caption2)
                                .foregroundColor(.lavenderMist)
                                .padding(.top, 2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .tag(index)
                    .id(exercise.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 240)
            
            // Custom page indicator
            HStack(spacing: 6) {
                ForEach(0..<exercises.count, id: \.self) { index in
                    Circle()
                        .fill(index == selectedIndex ? Color.lavenderMist : Color.lavenderMist.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 4)
        }
        .onAppear {
            selectedIndex = initialIndex
        }
    }
}

// MARK: - Route Exploration Loading View (v1.8.2, updated v1.8.5)
/// Shows a live map with animated route attempts during generation
/// v1.8.5: Stages complete sequentially with minimum display time for polished UX
struct RouteExplorationLoadingView: View {
    let userLocation: CLLocationCoordinate2D?
    let currentAttempt: GoogleMapsService.RouteAttempt?
    let attemptCount: Int
    let statusText: String
    let isComplete: Bool  // v1.8.5: Signal that route is ready
    let onAnimationComplete: () -> Void  // v1.8.5: Callback when all stages animated
    
    // Notification service for permission request
    @StateObject private var notificationService = NotificationService.shared
    
    // Animation state for polylines and POI markers
    @State private var visiblePolylines: [(id: UUID, coordinates: [CLLocationCoordinate2D], opacity: Double, isValid: Bool, poiName: String)] = []
    @State private var visiblePOIMarkers: [(id: UUID, coordinate: CLLocationCoordinate2D, name: String, opacity: Double)] = []
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    
    // v1.8.9: Stage display state - advances based on actual progress with minimum gaps
    @State private var displayedStageIndex: Int = 0  // 0-4 = stages active, 5 = all complete
    @State private var lastStageAdvanceTime: Date = Date()
    @State private var hasCompletedAllStages: Bool = false
    @State private var notificationPermissionRequested: Bool = false
    
    // Stage-specific animation states
    @State private var radarPulseScale: CGFloat = 1.0  // Stage 0: Radar pulse
    @State private var poiIconsVisible: [Int] = []      // Stage 0: POI icons popping in
    @State private var footstepAngle: Double = 0        // Stage 2: Footstep walking angle
    @State private var showFootsteps: Bool = false      // Stage 2: Footstep visibility
    @State private var showSparkles: Bool = false       // Stage 3: Sparkle burst
    @State private var sparklePositions: [(id: UUID, offset: CGSize, opacity: Double, scale: CGFloat)] = []
    @State private var sparkleOrbitAngle: Double = 0    // Stage 3: Orbiting sparkles
    
    // Countdown timer for stage 2 (Calculating routes)
    @State private var countdownSeconds: Int = 60
    @State private var countdownExpired: Bool = false
    
    // POI icons for the "finding places" animation
    private let poiIcons = ["☕", "🏪", "⛪", "🏛️", "🌳", "🎭"]
    
    private let minStageDisplayTime: TimeInterval = 1.2  // Minimum time to show each stage
    private let stageAdvanceDelay: TimeInterval = 0.5   // Delay between stage advances
    private let postCompletionDelay: TimeInterval = 0.3  // Reduced: Pause after stage 4 before preview
    
    // v1.8.10: Dynamic help text based on current stage
    // v1.9.22: Use actual status text if available (state-driven)
    private var loadingHelpText: String {
        // If we have actual status text, use it (more accurate)
        if !statusText.isEmpty && statusText != "Finding the best route..." {
            return statusText
        }
        
        // Otherwise use stage-based text
        switch displayedStageIndex {
        case 0: return "Get updates on walking status and clinic delays."
        case 1: return "Scanning the area around you..."
        case 2: 
            if countdownExpired {
                return "Taking longer than expected. Please wait..."
            } else {
                return "This may take up to a minute..."
            }
        case 3: return "Almost there! Getting walking directions..."
        case 4: return "Adding the finishing touches..."
        default: return "Your route is ready!"
        }
    }
    
    var body: some View {
        ZStack {
            // Real map centered on user location
            if let location = userLocation {
                Map(position: $mapCameraPosition) {
                    // User location marker with stage-specific animations (stable id)
                    Annotation("You", coordinate: location) {
                        userLocationMarkerView
                            .id("you")
                    }
                    
                    // Animated route polylines
                    ForEach(visiblePolylines, id: \.id) { polyline in
                        MapPolyline(coordinates: polyline.coordinates)
                            .stroke(
                                (polyline.isValid ? Color.green : Color.tealAccent).opacity(polyline.opacity),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                            )
                    }
                    
                    // Animated POI markers (no labels - just icons) — stable id per marker
                    ForEach(visiblePOIMarkers, id: \.id) { marker in
                        Annotation("", coordinate: marker.coordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                                .opacity(marker.opacity)
                                .id(marker.id)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .onAppear {
                    // Set initial camera position
                    mapCameraPosition = .region(MKCoordinateRegion(
                        center: location,
                        latitudinalMeters: 1500,
                        longitudinalMeters: 1500
                    ))
                }
            } else {
                // Fallback if no location
                Color(.systemGray5)
            }
            
            // Stage 3: Sparkle burst animation overlay
            sparkleOverlayView
            
            // Overlay gradient at bottom for text readability
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, Color(.systemBackground).opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
            }
            
            // Status overlay with stage-based progress
            VStack {
                Spacer()
                
                VStack(spacing: 16) {
                    // Stage progress card - v1.8.5: Sequential stage animation
                    VStack(alignment: .leading, spacing: 12) {
                        // Stage 0: Enabling notifications
                        stageRow(
                            icon: "bell.badge",
                            title: "Enabling notifications",
                            isComplete: displayedStageIndex >= 1,
                            isActive: displayedStageIndex == 0,
                            activeColor: .orange
                        )
                        
                        // Stage 1: Finding places
                        stageRow(
                            icon: "mappin.and.ellipse",
                            title: "Finding places nearby",
                            isComplete: displayedStageIndex >= 2,
                            isActive: displayedStageIndex == 1
                        )
                        
                        // Stage 2: Calculating routes
                        stageRow(
                            icon: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath",
                            title: "Calculating routes",
                            isComplete: displayedStageIndex >= 3,
                            isActive: displayedStageIndex == 2,
                            subtitle: displayedStageIndex == 2 ? (countdownExpired ? "Sorry for the delay..." : "\(countdownSeconds)s remaining") : nil
                        )
                        
                        // Stage 3: Getting directions
                        stageRow(
                            icon: "arrow.triangle.turn.up.right.diamond",
                            title: "Getting directions",
                            isComplete: displayedStageIndex >= 4,
                            isActive: displayedStageIndex == 3
                        )
                        
                        // Stage 4: Naming route
                        stageRow(
                            icon: "sparkles",
                            title: "Naming your route",
                            isComplete: displayedStageIndex >= 5,
                            isActive: displayedStageIndex == 4
                        )
                    }
                    .padding(20)
                    .background(Color(.systemBackground).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                    .animation(.easeInOut(duration: 0.25), value: displayedStageIndex)
                    
                    // Dynamic status text per stage
                    Text(loadingHelpText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .animation(.easeInOut(duration: 0.3), value: displayedStageIndex)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // v1.8.9: Initialize stage tracking
            displayedStageIndex = 0
            lastStageAdvanceTime = Date()
            hasCompletedAllStages = false
            poiIconsVisible = []
            showFootsteps = false
            countdownSeconds = 60
            countdownExpired = false
            notificationPermissionRequested = false
            print("🎬 Loading view appeared - starting at stage 0 (Enabling notifications)")
            
            // IMPORTANT: Route generation (stages 1-4) runs independently in the background.
            // It started when generateRoute() was called and continues regardless of notification permission.
            // This view only displays progress - it does NOT control when route generation happens.
            
            // Check notification authorization status
            notificationService.checkAuthorization()
            
            // If already authorized, quickly advance past Stage 0
            if notificationService.isAuthorized {
                print("🔔 Notifications already authorized - skipping Stage 0")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if displayedStageIndex == 0 && !hasCompletedAllStages {
                        advanceToStageWithMinDelay(1)
                        startPOIIconsAnimation()
                        startRadarPulseAnimation()
                    }
                }
            } else {
                // Request notification permission when Stage 0 is active
                // NOTE: This does NOT block route generation - it runs in a separate Task
                requestNotificationPermissionIfNeeded()
            }
            
            // Start radar pulse animation for Stage 1 (Finding places)
            startRadarPulseAnimation()
            
            // Stages advance based on actual progress, not time
            // Stage 0→1: After notifications enabled (or already authorized) - UI only, doesn't block route gen
            // Stage 1→2: After POI fetch starts or timeout (triggered by attemptCount change or 5s timeout) - route gen already running
            // Stage 2→3: When route attempts complete - route gen already running
            // Stage 3→4: When route is complete and directions fetched - route gen already running
            // Stage 4→5: When naming is complete - route gen already running
            
            // Add timeout for Stage 1: If POI fetch takes too long, advance to Stage 2 anyway
            // This prevents Stage 1 from staying active for 15-20 seconds when OSM is slow
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if displayedStageIndex == 1 && !hasCompletedAllStages && attemptCount == 0 {
                    print("🎬 Stage 1 timeout (5s) - POI fetch still in progress, advancing to Stage 2")
                    advanceToStageWithMinDelay(2)
                }
            }
        }
        .onChange(of: displayedStageIndex) { oldValue, newValue in
            let stageNames = ["Enabling notifications", "Finding places", "Calculating routes", "Getting directions", "Naming your route", "Complete"]
            let stageName = newValue < stageNames.count ? stageNames[newValue] : "Unknown"
            print("🎬 Stage changed: \(oldValue) → \(newValue) (\(stageName))")
            
            // Trigger stage-specific animations
            if newValue == 0 {
                // Stage 0: Enabling notifications - request permission if needed
                requestNotificationPermissionIfNeeded()
            }
            if newValue == 1 {
                // Stage 1: POI icons pop in
                startPOIIconsAnimation()
            }
            if newValue == 2 {
                // Stage 2: Route calculation spinning rings
                startRouteCalculationAnimation()
            }
            if newValue == 3 {
                // Stage 3: Footsteps walking
                startFootstepAnimation()
            }
            if newValue == 4 {
                // Stage 4: Sparkle burst with orbiting
                triggerSparkleAnimation()
            }
        }
        .onChange(of: attemptCount) { oldValue, newValue in
            // When route attempts start, POI fetch is done → advance to stage 2 (Calculating routes)
            // Stage 2 shows "This may take up to a minute..." during the long MapKit wait
            // We DON'T advance to stage 3 here - that happens when route is complete
            
            // Advance to Stage 2 when route attempts start
            if newValue > 0 && displayedStageIndex == 1 && !hasCompletedAllStages {
                print("🎬 Route attempts started (count: \(newValue)) - advancing to Stage 2")
                advanceToStageWithMinDelay(2)
            }
            
            // Add polyline animation with POI marker (visual feedback during calculation)
            if let attempt = currentAttempt, !attempt.polylineCoordinates.isEmpty {
                addAnimatedPolyline(coordinates: attempt.polylineCoordinates, isValid: attempt.isValid, poiName: attempt.poiName)
            }
        }
        .onChange(of: isComplete) { _, newValue in
            // v1.9.22: When route is ready, advance through remaining stages with minimum gaps
            // Only advance if we're actually complete (state-driven, not time-driven)
            if newValue && !hasCompletedAllStages {
                print("🎬 Route complete → advancing through remaining stages")
                advanceToCompletionWithMinGaps()
            }
        }
        .onChange(of: statusText) { oldValue, newValue in
            // v1.9.22: Update displayed stage based on actual work status
            // If status indicates we're in a specific stage, ensure UI reflects it
            if newValue.contains("Loading routes") && displayedStageIndex < 2 {
                // Still in Stage 2 (Calculating routes)
                if displayedStageIndex != 2 {
                    advanceToStageWithMinDelay(2)
                }
            }
        }
        .onChange(of: notificationService.isAuthorized) { oldValue, newValue in
            // When notification permission is granted, advance to Stage 1
            if newValue && displayedStageIndex == 0 && !hasCompletedAllStages {
                print("🔔 Notification permission granted - advancing to Stage 1")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    advanceToStageWithMinDelay(1)
                    startPOIIconsAnimation()
                }
            }
        }
    }
    
    // MARK: - Notification Permission Request
    
    /// Requests notification permission if needed. This runs independently and does NOT block route generation.
    /// Route generation (stages 1-4: Finding places, Calculating routes, etc.) continues in the background
    /// regardless of whether the user has responded to the notification permission dialog.
    private func requestNotificationPermissionIfNeeded() {
        // Only request once
        guard !notificationPermissionRequested else { return }
        
        // Check current authorization status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    // Permission not yet requested - request it now
                    // NOTE: This Task runs independently - route generation continues in background
                    self.notificationPermissionRequested = true
                    print("🔔 Requesting notification permission...")
                    
                    Task {
                        let granted = await self.notificationService.requestAuthorization()
                        print("🔔 Notification permission result: \(granted ? "granted" : "denied")")
                        // The onChange handler will advance to Stage 1 if granted
                        // Route generation (stages 1-4) continues regardless of this result
                    }
                } else if settings.authorizationStatus == .authorized {
                    // Already authorized - advance immediately
                    print("🔔 Notifications already authorized")
                    if self.displayedStageIndex == 0 && !self.hasCompletedAllStages {
                        self.advanceToStageWithMinDelay(1)
                        self.startPOIIconsAnimation()
                    }
                } else {
                    // Denied or other status - still advance after delay (user can enable later)
                    // Route generation continues in background during this delay
                    print("🔔 Notification permission denied or unavailable - advancing anyway")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if self.displayedStageIndex == 0 && !self.hasCompletedAllStages {
                            self.advanceToStageWithMinDelay(1)
                            self.startPOIIconsAnimation()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Stage Row Helper
    
    @ViewBuilder
    private func stageRow(icon: String, title: String, isComplete: Bool, isActive: Bool, subtitle: String? = nil, activeColor: Color = .tealAccent) -> some View {
        HStack(spacing: 12) {
            // Status indicator (checkmark or spinner)
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else if isActive {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(activeColor)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.title3)
            }
            
            // Stage icon
            Image(systemName: icon)
                .foregroundColor(isComplete ? .green : (isActive ? activeColor : .secondary.opacity(0.5)))
                .font(.subheadline)
                .frame(width: 20)
            
            // Title and subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundColor(isComplete ? .secondary : (isActive ? .primary : .secondary))
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Stage Animation Logic (v1.8.9)
    
    /// Advance to a target stage, respecting minimum display time for current stage
    private func advanceToStageWithMinDelay(_ targetStage: Int) {
        guard targetStage > displayedStageIndex else { return }
        
        let timeSinceLastAdvance = Date().timeIntervalSince(lastStageAdvanceTime)
        let remainingDelay = max(0, minStageDisplayTime - timeSinceLastAdvance)
        
        print("🎬 Scheduling stage \(targetStage) in \(String(format: "%.2f", remainingDelay))s")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) { [targetStage] in
            guard displayedStageIndex < targetStage else {
                print("🎬 Stage \(targetStage) already passed")
                return
            }
            
            print("🎬 → Stage \(targetStage)")
            withAnimation(.easeInOut(duration: 0.25)) {
                displayedStageIndex = targetStage
            }
            lastStageAdvanceTime = Date()
        }
    }
    
    /// Advance through all remaining stages when route is complete
    private func advanceToCompletionWithMinGaps() {
        hasCompletedAllStages = true
        let currentStage = displayedStageIndex
        let timeSinceLastAdvance = Date().timeIntervalSince(lastStageAdvanceTime)
        
        print("🏁 ═══════════════════════════════════════════════════")
        print("🏁 ROUTE COMPLETE - Starting stage sequence")
        print("🏁 Current stage: \(currentStage)")
        print("🏁 Time since last advance: \(String(format: "%.2f", timeSinceLastAdvance))s")
        print("🏁 Min stage display time: \(minStageDisplayTime)s")
        print("🏁 Stage advance delay: \(stageAdvanceDelay)s")
        
        // Calculate cumulative delays for remaining stages
        var cumulativeDelay: TimeInterval = 0
        
        // First, respect the minimum time for current stage
        cumulativeDelay = max(0, minStageDisplayTime - timeSinceLastAdvance)
        print("🏁 Initial delay (current stage remaining): \(String(format: "%.2f", cumulativeDelay))s")
        
        // Schedule each remaining stage with explicit timing
        // Must go through stages 3, 4, 5 regardless of current stage
        let stagesToSchedule: [Int]
        if currentStage < 3 {
            stagesToSchedule = [3, 4, 5]  // From stage 0, 1, or 2, go through 3, 4, 5
        } else if currentStage < 4 {
            stagesToSchedule = [4, 5]      // From stage 3, go through 4, 5
        } else if currentStage < 5 {
            stagesToSchedule = [5]          // From stage 4, just show 5
        } else {
            stagesToSchedule = []           // Already at 5
        }
        print("🏁 Stages to schedule: \(stagesToSchedule) (from current stage \(currentStage))")
        
        for targetStage in stagesToSchedule {
            let delay = cumulativeDelay
            let stageNames = ["Enabling notifications", "Finding places", "Calculating routes", "Getting directions", "Naming your route", "Complete"]
            let stageName = targetStage < stageNames.count ? stageNames[targetStage] : "Unknown"
            
            print("🏁 Stage \(targetStage) (\(stageName)) scheduled at +\(String(format: "%.2f", delay))s")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [targetStage, stageName] in
                print("🏁 ✓ Stage \(targetStage) (\(stageName)) NOW VISIBLE at \(Date())")
                withAnimation(.easeInOut(duration: 0.25)) {
                    displayedStageIndex = targetStage
                }
                lastStageAdvanceTime = Date()  // Update time for next stage calculation
            }
            
            // Add minimum display time + stage advance delay between stages
            cumulativeDelay += minStageDisplayTime + stageAdvanceDelay
        }
        
        // After stage 4, wait for postCompletionDelay then show preview
        let finalDelay = cumulativeDelay + postCompletionDelay
        print("🏁 Preview scheduled at +\(String(format: "%.2f", finalDelay))s (stages done at +\(String(format: "%.2f", cumulativeDelay))s + \(postCompletionDelay)s pause)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + finalDelay) {
            print("🏁 ✅ onAnimationComplete()")
            onAnimationComplete()
        }
    }
    
    /// Add a polyline that fades in and then fades out, with POI marker
    private func addAnimatedPolyline(coordinates: [CLLocationCoordinate2D], isValid: Bool, poiName: String = "") {
        let id = UUID()
        let newPolyline = (id: id, coordinates: coordinates, opacity: 0.0, isValid: isValid, poiName: poiName)
        
        // Add polyline
        withAnimation(.easeIn(duration: 0.3)) {
            visiblePolylines.append(newPolyline)
            // Update opacity to full
            if let index = visiblePolylines.firstIndex(where: { $0.id == id }) {
                visiblePolylines[index].opacity = isValid ? 1.0 : 0.7
            }
        }
        
        // Add POI marker at the furthest point from origin (approximate waypoint location)
        if coordinates.count > 2, !poiName.isEmpty {
            // Find the point furthest from origin (usually the main waypoint)
            let midIndex = coordinates.count / 2
            let markerCoord = coordinates[midIndex]
            let markerId = UUID()
            
            withAnimation(.easeIn(duration: 0.3)) {
                visiblePOIMarkers.append((id: markerId, coordinate: markerCoord, name: poiName, opacity: 1.0))
            }
            
            // Keep only last 3 POI markers
            if visiblePOIMarkers.count > 3 {
                let oldMarkerId = visiblePOIMarkers[0].id
                withAnimation(.easeOut(duration: 0.3)) {
                    visiblePOIMarkers.removeAll { $0.id == oldMarkerId }
                }
            }
            
            // Fade out marker after delay if not valid
            if !isValid {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        if let index = visiblePOIMarkers.firstIndex(where: { $0.id == markerId }) {
                            visiblePOIMarkers[index].opacity = 0.3
                        }
                    }
                }
            }
        }
        
        // Keep only last 3 polylines to avoid clutter
        if visiblePolylines.count > 3 {
            let oldId = visiblePolylines[0].id
            withAnimation(.easeOut(duration: 0.3)) {
                visiblePolylines.removeAll { $0.id == oldId }
            }
        }
        
        // Fade out non-valid polylines after delay
        if !isValid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.5)) {
                    if let index = visiblePolylines.firstIndex(where: { $0.id == id }) {
                        visiblePolylines[index].opacity = 0.2
                    }
                }
            }
        }
    }
    
    // MARK: - Extracted Subviews (for compiler performance)
    
    /// User location marker with radar pulse and POI icons
    @ViewBuilder
    private var userLocationMarkerView: some View {
        ZStack {
            // Radar pulse rings (Stage 0: Finding places)
            if displayedStageIndex == 0 {
                radarPulseView
                poiIconsView
            }
            
            // Route calculation animation (Stage 1 - Calculating routes)
            // Shows expanding/contracting rings to indicate processing
            if displayedStageIndex == 2 {
                routeCalculationView
            }
            
            // Footstep animation (Stage 3 - Getting directions)
            if displayedStageIndex == 3 && showFootsteps {
                footstepsView
            }
            
            // User location dot
            Circle()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 40, height: 40)
            Circle()
                .fill(Color.blue)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
        }
    }
    
    /// Route calculation animation - active scanning effect during MapKit wait
    @ViewBuilder
    private var routeCalculationView: some View {
        // Multiple rotating dashed rings at different speeds
        Circle()
            .stroke(style: StrokeStyle(lineWidth: 3, dash: [12, 6]))
            .foregroundColor(.tealAccent)
            .frame(width: 80, height: 80)
            .rotationEffect(.radians(footstepAngle))
        
        Circle()
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
            .foregroundColor(.orange.opacity(0.7))
            .frame(width: 120, height: 120)
            .rotationEffect(.radians(-footstepAngle * 1.3))
        
        Circle()
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 10]))
            .foregroundColor(.tealAccent.opacity(0.5))
            .frame(width: 160, height: 160)
            .rotationEffect(.radians(footstepAngle * 0.7))
        
        // Pulsing center glow
        Circle()
            .fill(Color.tealAccent.opacity(0.2))
            .frame(width: 60, height: 60)
            .scaleEffect(1.0 + sin(footstepAngle * 2) * 0.15)
        
        // Scanning line that sweeps around
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .tealAccent.opacity(0.6), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 4, height: 80)
            .offset(y: -40)
            .rotationEffect(.radians(footstepAngle * 2))
    }
    
    /// Radar pulse circles
    @ViewBuilder
    private var radarPulseView: some View {
        Circle()
            .stroke(Color.tealAccent.opacity(0.6), lineWidth: 2)
            .frame(width: 80, height: 80)
            .scaleEffect(radarPulseScale)
            .opacity(2.0 - radarPulseScale)
        
        Circle()
            .stroke(Color.tealAccent.opacity(0.4), lineWidth: 1.5)
            .frame(width: 120, height: 120)
            .scaleEffect(radarPulseScale * 0.8)
            .opacity(2.0 - radarPulseScale)
    }
    
    /// POI icons popping in around radar
    @ViewBuilder
    private var poiIconsView: some View {
        ForEach(0..<6, id: \.self) { index in
            poiIconAt(index: index)
        }
    }
    
    /// Single POI icon at index
    @ViewBuilder
    private func poiIconAt(index: Int) -> some View {
        let iconAngle = Double(index) * (2.0 * .pi / 6.0) - .pi / 2.0
        let iconRadius: CGFloat = 100
        let icon = poiIcons[index]
        let isVisible = poiIconsVisible.contains(index)
        
        Text(icon)
            .font(.system(size: 22))
            .offset(
                x: CGFloat(cos(iconAngle)) * iconRadius,
                y: CGFloat(sin(iconAngle)) * iconRadius
            )
            .scaleEffect(isVisible ? 1.0 : 0.0)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isVisible)
    }
    
    /// Walking footsteps animation
    @ViewBuilder
    private var footstepsView: some View {
        ForEach(0..<3, id: \.self) { index in
            footstepAt(index: index)
        }
    }
    
    /// Single footstep at index
    @ViewBuilder
    private func footstepAt(index: Int) -> some View {
        let stepAngle = footstepAngle + Double(index) * (2.0 * .pi / 3.0)
        let stepRadius: CGFloat = 60
        
        Image(systemName: "shoeprints.fill")
            .font(.system(size: 16))
            .foregroundColor(.tealAccent)
            .rotationEffect(.radians(stepAngle + .pi / 2.0))
            .offset(
                x: CGFloat(cos(stepAngle)) * stepRadius,
                y: CGFloat(sin(stepAngle)) * stepRadius
            )
            .opacity(0.8)
    }
    
    /// Sparkle overlay for stage 3
    @ViewBuilder
    private var sparkleOverlayView: some View {
        if showSparkles {
            // Central burst sparkles
            ForEach(sparklePositions, id: \.id) { sparkle in
                Image(systemName: "sparkle")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow)
                    .opacity(sparkle.opacity)
                    .scaleEffect(sparkle.scale)
                    .offset(sparkle.offset)
            }
            
            // Orbiting sparkles
            ForEach(0..<4, id: \.self) { index in
                orbitingSparkleAt(index: index)
            }
        }
    }
    
    /// Single orbiting sparkle
    @ViewBuilder
    private func orbitingSparkleAt(index: Int) -> some View {
        let orbitAngle = sparkleOrbitAngle + Double(index) * (.pi / 2.0)
        let orbitRadius: CGFloat = 50
        
        Image(systemName: "sparkle")
            .font(.system(size: 16))
            .foregroundColor(.yellow.opacity(0.8))
            .offset(
                x: CGFloat(cos(orbitAngle)) * orbitRadius,
                y: CGFloat(sin(orbitAngle)) * orbitRadius - 100
            )
    }
    
    // MARK: - Stage-Specific Animations
    
    /// Start the radar pulse animation for Stage 0 (Finding places)
    private func startRadarPulseAnimation() {
        // Repeating pulse animation
        func pulse() {
            guard displayedStageIndex == 0 else { return }
            
            withAnimation(.easeOut(duration: 1.5)) {
                radarPulseScale = 2.0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                radarPulseScale = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    pulse()
                }
            }
        }
        pulse()
    }
    
    /// Start POI icons appearing one by one for Stage 0
    private func startPOIIconsAnimation() {
        poiIconsVisible = []
        
        // Pop in each icon with staggered delay
        for index in 0..<poiIcons.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
                guard displayedStageIndex == 0 else { return }
                poiIconsVisible.append(index)
            }
        }
    }
    
    /// Start route calculation animation for Stage 2 (Calculating routes)
    private func startRouteCalculationAnimation() {
        footstepAngle = 0  // Reusing footstepAngle for rotation
        countdownSeconds = 60  // Reset countdown
        countdownExpired = false
        
        // Continuous rotation animation - faster for more active feel
        func rotate() {
            guard displayedStageIndex == 2 else { return }
            
            withAnimation(.linear(duration: 2.0)) {
                footstepAngle += 2 * .pi
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                rotate()
            }
        }
        rotate()
        
        // Start countdown timer
        startCountdownTimer()
    }
    
    /// Countdown timer for stage 2 (Calculating routes)
    private func startCountdownTimer() {
        func tick() {
            guard displayedStageIndex == 2 && !hasCompletedAllStages else { return }
            
            if countdownSeconds > 0 {
                countdownSeconds -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    tick()
                }
            } else {
                // Countdown expired
                countdownExpired = true
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            tick()
        }
    }
    
    /// Start footstep walking animation for Stage 2 (Getting directions)
    private func startFootstepAnimation() {
        showFootsteps = true
        footstepAngle = 0
        
        // Continuous rotation animation
        func rotate() {
            guard displayedStageIndex == 3 else {
                showFootsteps = false
                return
            }
            
            withAnimation(.linear(duration: 2.0)) {
                footstepAngle += 2 * .pi
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                rotate()
            }
        }
        rotate()
    }
    
    /// Trigger sparkle burst animation for Stage 3 (Naming your route)
    private func triggerSparkleAnimation() {
        showSparkles = true
        sparklePositions = []
        sparkleOrbitAngle = 0
        
        // Create central burst sparkles
        let sparkleCount = 8
        for _ in 0..<sparkleCount {
            let offset = CGSize(width: 0, height: -100)  // Start at center
            sparklePositions.append((id: UUID(), offset: offset, opacity: 0.0, scale: 0.5))
        }
        
        // Animate sparkles bursting outward with pulse
        for (index, _) in sparklePositions.enumerated() {
            let angle = Double(index) * (2 * .pi / Double(sparkleCount))
            let delay = Double(index) * 0.05
            
            // Burst outward
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard showSparkles else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    if index < sparklePositions.count {
                        let distance: CGFloat = 80
                        sparklePositions[index].offset = CGSize(
                            width: cos(angle) * distance,
                            height: sin(angle) * distance - 100
                        )
                        sparklePositions[index].opacity = 1.0
                        sparklePositions[index].scale = 1.2
                    }
                }
            }
            
            // Pulse smaller
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) {
                guard showSparkles else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].scale = 0.8
                    }
                }
            }
            
            // Pulse larger again
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.7) {
                guard showSparkles else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].scale = 1.0
                    }
                }
            }
            
            // Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.2) {
                guard showSparkles else { return }
                withAnimation(.easeIn(duration: 0.4)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].opacity = 0.0
                    }
                }
            }
        }
        
        // Start orbiting animation
        startSparkleOrbit()
        
        // Hide sparkles before onAnimationComplete runs (~2s after stage 4), so we never mutate state after the loading view is dismissed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showSparkles = false
        }
    }
    
    /// Animate sparkles orbiting around center
    private func startSparkleOrbit() {
        func orbit() {
            guard showSparkles else { return }
            
            withAnimation(.linear(duration: 3.0)) {
                sparkleOrbitAngle += 2 * .pi
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                orbit()
            }
        }
        orbit()
    }
}

// MARK: - View Extensions for Modifiers
extension View {
    @ViewBuilder
    func addSheets(
        showHelpSheet: Binding<Bool>,
        showLocalRoutePicker: Binding<Bool>,
        viewModel: WaitingRoomViewModel,
        locationService: LocationService,
        localRouteDuration: Binding<Int>,
        localRouteUseCustom: Binding<Bool>,
        showActiveWalk: Binding<Bool>  // v1.9.28: Show fullscreen ActiveWalkView
        // v1.9.36: pendingActiveWalk now in viewModel for iOS 17 compatibility
    ) -> some View {
        self
            .sheet(isPresented: showHelpSheet) {
                HelpView()
            }
            .sheet(isPresented: showLocalRoutePicker) {
                LocalRoutePickerSheet(
                    viewModel: viewModel,
                    locationService: locationService,
                    selectedDuration: localRouteDuration,
                    useCustomTime: localRouteUseCustom,
                    isPresented: showLocalRoutePicker,
                    showActiveWalk: showActiveWalk
                )
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showMarkerArrivalPrompt },
                set: { viewModel.showMarkerArrivalPrompt = $0 }
            )) {
                MarkerArrivalSheet(viewModel: viewModel)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showHomeArrivalPrompt },
                set: { viewModel.showHomeArrivalPrompt = $0 }
            )) {
                HomeArrivalSheet(viewModel: viewModel, isPresented: showActiveWalk)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showPreWalkWellbeing },
                set: { 
                    let timestamp = Date()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss.SSS"
                    let timeString = formatter.string(from: timestamp)
                    print("🔍 [PRE-WALK] [\(timeString)] 📋 showPreWalkWellbeing binding changed to: \($0)")
                    viewModel.showPreWalkWellbeing = $0
                }
            ), onDismiss: {
                // v1.9.36: Show map after pre-walk anxiety check completes (iOS 17 compatible)
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                print("🔍 [iOS17 DEBUG] [\(timeString)] ========== PRE-WALK SHEET ONDISMISS ==========")
                print("🔍 [iOS17 DEBUG] [\(timeString)] viewModel.pendingActiveWalk: \(viewModel.pendingActiveWalk)")
                print("🔍 [iOS17 DEBUG] [\(timeString)] showActiveWalk.wrappedValue: \(showActiveWalk.wrappedValue)")
                print("🔍 [iOS17 DEBUG] [\(timeString)] viewModel.walkSession.isActive: \(viewModel.walkSession.isActive)")
                
                if viewModel.pendingActiveWalk {
                    print("🔍 [iOS17 DEBUG] [\(timeString)] ✅ Condition TRUE - will show map")
                    viewModel.pendingActiveWalk = false
                    print("🔍 [iOS17 DEBUG] [\(timeString)] Set pendingActiveWalk = false")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let afterTimestamp = Date()
                        let afterTimeString = formatter.string(from: afterTimestamp)
                        print("🔍 [iOS17 DEBUG] [\(afterTimeString)] About to set showActiveWalk = true")
                        showActiveWalk.wrappedValue = true
                        print("🔍 [iOS17 DEBUG] [\(afterTimeString)] showActiveWalk is now: \(showActiveWalk.wrappedValue)")
                    }
                } else {
                    print("🔍 [iOS17 DEBUG] [\(timeString)] ❌ Condition FALSE - NOT showing map")
                    print("🔍 [iOS17 DEBUG] [\(timeString)] This is the iOS 17 bug - pendingActiveWalk was not propagated!")
                }
            }) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: Binding(
                    get: { viewModel.showPreWalkWellbeing },
                    set: { viewModel.showPreWalkWellbeing = $0 }
                ), isPostWalk: false)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showPostWalkWellbeing },
                set: { viewModel.showPostWalkWellbeing = $0 }
            ), onDismiss: {
                let timestamp = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: timestamp)
                
                let hasDeclinedOffer = UserDefaults.standard.bool(forKey: "healthKitSyncOfferDeclined")
                let stepTrackingWasEnabled = viewModel.stepTrackingWasEnabled
                let motionWasAuthorizedAtWalkStart = viewModel.motionWasAuthorizedAtWalkStart
                let isMotionAuthorized = viewModel.healthKitService.isMotionAuthorized
                let isMotionDenied = viewModel.healthKitService.isMotionDenied
                let isHealthKitAuthorized = viewModel.healthKitService.isAuthorized
                
                print("🔍 [POST-WALK] [\(timeString)] Anxiety check sheet dismissed")
                print("🔍 [POST-WALK] [\(timeString)]   stepTrackingWasEnabled: \(stepTrackingWasEnabled)")
                print("🔍 [POST-WALK] [\(timeString)]   motionWasAuthorizedAtWalkStart: \(motionWasAuthorizedAtWalkStart)")
                print("🔍 [POST-WALK] [\(timeString)]   isMotionAuthorized: \(isMotionAuthorized)")
                print("🔍 [POST-WALK] [\(timeString)]   isMotionDenied: \(isMotionDenied)")
                print("🔍 [POST-WALK] [\(timeString)]   isHealthKitAuthorized: \(isHealthKitAuthorized)")
                print("🔍 [POST-WALK] [\(timeString)]   hasDeclinedOffer: \(hasDeclinedOffer)")
                
                // v1.9.34: Permission flow after anxiety check:
                // Flow 2, Walk 1: User didn't enable steps, Motion not authorized → request Motion
                // Flow 1 or Flow 2 Walk 2: Motion authorized → show HealthKit offer
                
                if !stepTrackingWasEnabled && !isMotionAuthorized && !isMotionDenied {
                    // Flow 2, Walk 1: Absent-minded user - request Motion permission
                    print("🔍 [POST-WALK] [\(timeString)]   📲 Requesting Motion permission (Flow 2, Walk 1)")
                    viewModel.healthKitService.requestMotionAuthorization { authorized in
                        print("🔍 [POST-WALK] Motion authorization result: \(authorized ? "authorized" : "denied")")
                    }
                } else if (stepTrackingWasEnabled || motionWasAuthorizedAtWalkStart) && !isHealthKitAuthorized && !hasDeclinedOffer {
                    // Flow 1 or Flow 2 Walk 2: Motion is authorized → show HealthKit offer
                    print("🔍 [POST-WALK] [\(timeString)]   ✅ Showing HealthKit sync offer")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.showHealthKitSyncOffer = true
                    }
                } else {
                    print("🔍 [POST-WALK] [\(timeString)]   ❌ No permission dialog needed")
                }
            }) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: Binding(
                    get: { viewModel.showPostWalkWellbeing },
                    set: { viewModel.showPostWalkWellbeing = $0 }
                ), isPostWalk: true, isWalkActivity: true)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showHealthKitSyncOffer },
                set: { viewModel.showHealthKitSyncOffer = $0 }
            )) {
                HealthKitSyncOfferSheet(
                    healthKitService: viewModel.healthKitService,
                    isPresented: Binding(
                        get: { viewModel.showHealthKitSyncOffer },
                        set: { viewModel.showHealthKitSyncOffer = $0 }
                    )
                )
            }
    }
    
    // v2.1.6: Alerts are now handled by overlays in ActiveWalkView
    // Removed system alerts here to prevent them from closing the map
    func addAlerts(viewModel: WaitingRoomViewModel) -> some View {
        self
        // Alerts are now shown as overlays in ActiveWalkView, not system alerts
        // This prevents the map from being dismissed when alerts appear
    }
}

#Preview {
    RouteSelectionView(viewModel: WaitingRoomViewModel())
}



