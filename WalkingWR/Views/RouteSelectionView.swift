//
//  RouteSelectionView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import MapKit
import CoreLocation

// v1.6.45: Pending batch test type
enum PendingBatchTest: Equatable {
    case none
    case allLocations
    case singleLocation(name: String, lat: Double, lon: Double)
}

struct RouteSelectionView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var showLocalRoutePicker: Bool
    @Environment(\.colorScheme) var colorScheme  // v1.9.0: Adaptive colors for light/dark mode
    @State private var selectedDifficulty: RouteDifficulty? = nil
    @State private var showIndoorOnly = false
    @State private var showAccessibleOnly = false
    @State private var showActiveWalk = false
    @State private var showHelpSheet = false
    @State private var localRouteDuration: Int = 10
    @State private var localRouteUseCustom = false
    @State private var pendingBatchTest: PendingBatchTest = .none  // v1.6.45: Auto-run test when sheet opens
    
    init(viewModel: WaitingRoomViewModel, showLocalRoutePicker: Binding<Bool> = .constant(false)) {
        self.viewModel = viewModel
        self._showLocalRoutePicker = showLocalRoutePicker
    }
    
    // Check if we have an active clinic delay to base suggestion on
    private var hasActiveClinicDelay: Bool {
        viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable
    }
    
    // Calculate recommended duration based on delay time (with 5 min buffer)
    // Defaults to 30 min if no clinic is active (free walk mode - best route reliability)
    private var recommendedDuration: Int {
        // If no active clinic, default to 30 min (most reliable routes)
        if !hasActiveClinicDelay {
            return 30
        }
        
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - 5
        let presetOptions = [10, 15, 20, 25, 30]
        
        // Find the best preset option that fits within available time
        if let bestOption = presetOptions.reversed().first(where: { $0 <= availableTime }) {
            return bestOption
        }
        return 10 // Default to minimum if delay is very short
    }
    
    // Whether custom time should be auto-selected (delay > 35 min, i.e., 30 min walk + 5 min buffer)
    // Only applies when a clinic is active - free walk mode uses preset 30 min
    private var shouldUseCustom: Bool {
        hasActiveClinicDelay && viewModel.waitTimeInfo.estimatedMinutes > 35
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                if viewModel.walkSession.isActive {
                    ActiveWalkView(viewModel: viewModel)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Time remaining banner - only show when clinician is selected
                            if viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable {
                                TimeRemainingBanner(minutes: viewModel.waitTimeInfo.estimatedMinutes)
                                    .padding(.top, 20)
                            } else {
                                // No clinician selected - show different message
                                NoClinicianBanner()
                                    .padding(.top, 20)
                            }
                            
                            // Featured: Local Route (most popular)
                            LocalRouteCard(
                                onTap: { showLocalRoutePicker = true },
                                locationService: viewModel.locationService
                            )
                            
                            // Collapsible sections for other routes
                            VStack(spacing: 12) {
                                // Curated Routes Section
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
                                
                                // Indoor Routes Section
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
                            
                            // Filters (moved lower, less prominent)
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
            }
            .navigationTitle(viewModel.walkSession.isActive ? "" : "Choose a Route")
            #if os(iOS)
            .navigationBarTitleDisplayMode(viewModel.walkSession.isActive ? .inline : .large)
            .navigationBarHidden(viewModel.walkSession.isActive)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showHelpSheet = true }) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.coralPink)
                    }
                }
            }
            .sheet(isPresented: $showHelpSheet) {
                HelpView()
            }
            .sheet(isPresented: $showLocalRoutePicker, onDismiss: {
                pendingBatchTest = .none  // Clear pending test when sheet closes
            }) {
                LocalRoutePickerSheet(
                    viewModel: viewModel,
                    locationService: viewModel.locationService,
                    selectedDuration: $localRouteDuration,
                    useCustomTime: $localRouteUseCustom,
                    isPresented: $showLocalRoutePicker,
                    pendingBatchTest: $pendingBatchTest  // v1.6.45: Pass pending test
                )
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
            .sheet(isPresented: $viewModel.showMarkerArrivalPrompt) {
                MarkerArrivalSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showHomeArrivalPrompt) {
                HomeArrivalSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showPreWalkWellbeing) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $viewModel.showPreWalkWellbeing, isPostWalk: false)
            }
            .sheet(isPresented: $viewModel.showPostWalkWellbeing, onDismiss: {
                // v1.6.28: Show HealthKit sync offer after post-walk wellbeing
                // Only if:
                // - Motion permission was granted (user opted into step tracking)
                // - HealthKit is not already authorized
                // - User hasn't previously declined the offer
                let hasDeclinedOffer = UserDefaults.standard.bool(forKey: "healthKitSyncOfferDeclined")
                print("🏥 Post-walk wellbeing dismissed - checking HealthKit offer conditions:")
                print("🏥   stepTrackingWasEnabled: \(viewModel.stepTrackingWasEnabled)")
                print("🏥   isAuthorized: \(viewModel.healthKitService.isAuthorized)")
                print("🏥   hasDeclinedOffer: \(hasDeclinedOffer)")
                print("🏥   stepTrackingAutoEnabled (UserDefaults): \(UserDefaults.standard.bool(forKey: "stepTrackingAutoEnabled"))")
                
                if viewModel.stepTrackingWasEnabled && !viewModel.healthKitService.isAuthorized && !hasDeclinedOffer {
                    print("🏥   ✅ All conditions met - showing HealthKit offer")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.showHealthKitSyncOffer = true
                    }
                } else {
                    print("🏥   ❌ Conditions not met - NOT showing HealthKit offer")
                }
            }) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $viewModel.showPostWalkWellbeing, isPostWalk: true, isWalkActivity: true)
            }
            // v1.6.28: HealthKit sync offer (after post-walk wellbeing, if Motion was granted)
            .sheet(isPresented: $viewModel.showHealthKitSyncOffer) {
                HealthKitSyncOfferSheet(
                    healthKitService: viewModel.healthKitService,
                    isPresented: $viewModel.showHealthKitSyncOffer
                )
            }
            .alert("Halfway Point! 🚶", isPresented: $viewModel.showHalfwayAlert) {
                Button("Got it") { }
            } message: {
                Text("You've completed half your walk. Check your clinic delay and consider heading back.")
            }
            .alert("Time to Head Back 🏥", isPresented: $viewModel.showReturnNowAlert) {
                Button("Got it") { }
            } message: {
                Text("You've completed 80% of your walk. Consider heading back to the clinic.")
            }
            .alert("Walk Complete! 🎉", isPresented: $viewModel.showWalkCompleteAlert) {
                Button("End Walk") {
                    viewModel.endWalk(completed: true)
                }
            } message: {
                Text("Great job completing your walk! Head back to the waiting area when ready.")
            }
            // v1.6.45: Listen for INTERNAL batch test notifications (after MainTabView switches tabs)
            .onReceive(NotificationCenter.default.publisher(for: .runBatchTestInternal)) { _ in
                print("📬 RouteSelectionView received runBatchTestInternal - opening sheet")
                pendingBatchTest = .allLocations
                showLocalRoutePicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .runSingleLocationTestInternal)) { notification in
                print("📬 RouteSelectionView received runSingleLocationTestInternal")
                if let userInfo = notification.userInfo,
                   let lat = userInfo["latitude"] as? Double,
                   let lon = userInfo["longitude"] as? Double {
                    let name = userInfo["locationName"] as? String ?? userInfo["name"] as? String ?? "Test Location"
                    pendingBatchTest = .singleLocation(name: name, lat: lat, lon: lon)
                    showLocalRoutePicker = true
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
            locationService.requestCurrentLocation()
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
                            Label("\(route.durationMinutes)m", systemImage: "clock")
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
                            Label("\(route.durationMinutes) minutes", systemImage: "clock.fill")
                                .font(.caption)
                                .foregroundColor(.primary)
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
                    
                    // Start button
                    Button(action: onSelect) {
                        HStack {
                            Image(systemName: "figure.walk")
                            Text("Start This Walk")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(route.color)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
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
            // Route polyline
            if route.routePath.count >= 2 {
                MapPolyline(coordinates: route.routePath)
                    .stroke(route.color, lineWidth: 3)
            }
            
            // Start marker
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
    @Binding var pendingBatchTest: PendingBatchTest  // v1.6.45: Auto-run test when sheet opens
    @State private var isGenerating = false  // Button shows spinner
    @State private var showLoadingScreen = false  // v1.8.3: Separate flag for loading screen transition
    @State private var routeGenerationComplete = false  // v1.8.5: Signals route is ready (triggers stage animation completion)
    @State private var isShuffling = false  // Separate state for shuffle loading
    @State private var isStartingWalk = false  // v1.6.45: Loading state for Let's Go button
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
    @State private var allRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool)] = []
    @State private var currentRouteIndex: Int = 0
    @State private var isPreGeneratingRoutes = false
    @State private var preGenerationComplete = false
    @State private var viewedRouteIndices: Set<Int> = []  // Track which routes user has seen
    @State private var showPremiumUpsell = false  // Show upgrade message when all routes viewed
    @State private var showLocationLimitAlert = false  // Show when free tier location limit reached
    
    // v1.6.25: Route deduplication - track unique route signatures
    @State private var routeSignatures: Set<String> = []  // Unique signatures: "sortedPOIIds|distanceBucket"
    @State private var varietyExhausted = false  // True when no more unique routes possible
    
    // v1.8.8: Store rejected short routes - may add ONE at end if ≤2 acceptable routes
    @State private var rejectedShortRoutes: [(route: WalkingRoute, data: GeneratedRoute)] = []
    
    // Pre-fetched POIs for faster route generation
    @State private var prefetchedPOIs: [PlaceResult] = []
    @State private var isPrefetchingPOIs = false
    @State private var prefetchedForLocation: CLLocationCoordinate2D?
    
    // Track where routes were pre-generated (for movement detection)
    @State private var preGeneratedAtLocation: CLLocationCoordinate2D?
    private let movementThresholdMeters: Double = 50  // Invalidate cache if moved >50m
    
    let durationOptions = [10, 15, 20, 25, 30]
    let maxRoutesToGenerate = 10  // Back to 10 - directions now use free Apple MapKit!
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                // v1.6.47: Batch test live progress overlay
                if testProgress.isActive {
                    batchTestProgressOverlay()
                }
                // Show map preview with optional shuffle overlay
                else if let route = generatedRoute, showMapPreview {
                    mapPreviewSection(route: route)
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
                                    let recommendedWalk = max(10, delayMinutes - 5)
                                    
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock.badge.checkmark")
                                            .font(.title2)
                                            .foregroundColor(.tealAccent)
                                        
                                        Text("Based on your **\(delayMinutes) min** wait, we recommend a **\(recommendedWalk) min** walk to get you back in time.")
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                            .multilineTextAlignment(.leading)
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
                                                Text("Finding places...")
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
            .onAppear {
                locationService.requestFreshLocation()
                // Sync customTimeValue with selectedDuration if in custom mode
                if useCustomTime {
                    customTimeValue = Double(selectedDuration)
                }
                // Pre-fetch POIs while user selects duration (speeds up Generate)
                prefetchPOIsIfNeeded()
                
                // v1.6.45: Auto-run pending batch test after short delay
                if pendingBatchTest != .none {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch pendingBatchTest {
                        case .allLocations:
                            print("🧪 Auto-starting batch test (all locations)")
                            runAllLocationTests()
                        case .singleLocation(let name, let lat, let lon):
                            print("🧪 Auto-starting single location test: \(name)")
                            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            runSingleTest(at: coordinate, name: name)
                        case .none:
                            break
                        }
                        pendingBatchTest = .none
                    }
                }
            }
            // Remove old notification listeners - now using pendingBatchTest binding
            .onReceive(NotificationCenter.default.publisher(for: .runBatchTestInternal)) { _ in
                // Legacy - keeping for backwards compatibility but not used
            }
            .onReceive(NotificationCenter.default.publisher(for: .runSingleLocationTestInternal)) { notification in
                // Legacy - keeping for backwards compatibility
                if let userInfo = notification.userInfo,
                   let name = userInfo["locationName"] as? String ?? userInfo["name"] as? String,
                   let lat = userInfo["latitude"] as? Double,
                   let lon = userInfo["longitude"] as? Double {
                    
                    // If "Current Location", use actual location
                    if name == "Current Location", let currentLoc = locationService.currentLocation {
                        runRouteGenerationTest(at: currentLoc.coordinate)
                    } else if lat != 0 && lon != 0 {
                        runRouteGenerationTest(at: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
            }
            .onChange(of: locationService.currentLocation) { _, newLocation in
                // Re-fetch POIs if location significantly changed
                if newLocation != nil, prefetchedPOIs.isEmpty {
                    prefetchPOIsIfNeeded()
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
            // Debug route test results sheet
            .sheet(isPresented: $showRouteTestResults) {
                NavigationStack {
                    ScrollView {
                        Text(routeTestResults)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle("Route Generation Test")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showRouteTestResults = false
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                UIPasteboard.general.string = routeTestResults
                                didCopyResults = true
                                // Reset after 2 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    didCopyResults = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: didCopyResults ? "checkmark" : "doc.on.doc")
                                    Text(didCopyResults ? "Copied!" : "Copy All")
                                        .font(.caption)
                                }
                                .foregroundColor(didCopyResults ? .green : .accentColor)
                            }
                        }
                    }
                }
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
    func registerRouteSignature(places: [PlaceResult], distanceMeters: Int) {
        let signature = generateRouteSignature(places: places, distanceMeters: distanceMeters)
        routeSignatures.insert(signature)
    }
    
    /// Reset route signatures when starting fresh
    func resetRouteSignatures() {
        routeSignatures.removeAll()
        varietyExhausted = false
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
    func createPermutedRoute(from route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool = false) -> (route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool)? {
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
            encodedPolyline: nil,  // Will need new directions
            walkingDirections: []  // Will need new directions
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
        return (permutedRoute, permutedData, isDeadZoneFallback)
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
        print("📍 Location: (\(String(format: "%.5f", userLocation.coordinate.latitude)), \(String(format: "%.5f", userLocation.coordinate.longitude)))")
        print("🔑 mapsService.hasAPIKey: \(mapsService.hasAPIKey)")
        
        // v1.8.14: Move all cache checks into async Task to prevent main thread blocking
        // This allows the button to show "Finding places..." immediately
        if mapsService.hasAPIKey {
            // Use Google APIs for smart routing
            print("🚀 Starting async Task for route generation...")
            Task {
                print("📥 Task started")
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
                
                // v1.8.7: Start loading screen Task IMMEDIATELY (before cache check)
                // This ensures loading screen shows even if cache check hangs
                _ = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                    await MainActor.run {
                        print("⏳ 300ms delay complete - checking if should show loading screen...")
                        print("   isGenerating: \(isGenerating), showMapPreview: \(showMapPreview)")
                        if isGenerating && !showMapPreview {  // Only show if still generating and not already showing preview
                            print("📺 SHOWING LOADING SCREEN")
                            showLoadingScreen = true
                        } else {
                            print("📺 NOT showing loading screen (already done or preview visible)")
                        }
                    }
                }
                
                // CHECK CACHE FIRST (with movement detection)
                print("🔍 Checking for cached routes...")
                let shouldUseCache: Bool
                if let preGenLocation = preGeneratedAtLocation {
                    let distanceMoved = distanceBetweenCoordinates(userLocation.coordinate, preGenLocation)
                    shouldUseCache = distanceMoved <= movementThresholdMeters
                    print("   preGeneratedAtLocation exists, distanceMoved: \(Int(distanceMoved))m")
                    if !shouldUseCache {
                        print("📍 User moved \(Int(distanceMoved))m (>\(Int(movementThresholdMeters))m) - skipping cache, regenerating fresh")
                    }
                } else {
                    shouldUseCache = true  // No pre-gen location yet, check cache anyway
                    print("   No preGeneratedAtLocation, will check cache")
                }
                
                print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Checking route cache...")
                
                if shouldUseCache, let cachedRoutes = RouteCacheService.shared.getCachedRoutes(near: userLocation.coordinate, durationMinutes: selectedDuration), !cachedRoutes.isEmpty {
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - CACHE HIT! Found \(cachedRoutes.count) cached routes")
                    print("📦 Using \(cachedRoutes.count) cached routes for \(selectedDuration)min")
                    
                    // v1.6.46: Show loading screen IMMEDIATELY for cache hits
                    // This ensures the stage animation plays before showing map preview
                    await MainActor.run {
                        showLoadingScreen = true
                        print("📺 SHOWING LOADING SCREEN (cache hit)")
                    }
                    
                    // v1.6.45: Load ALL cached routes, not just the first one
                    // v1.6.47: Include isDeadZoneFallback per-route for accurate warning display
                    var loadedRoutes: [(route: WalkingRoute, data: GeneratedRoute, isDeadZoneFallback: Bool)] = []
                    var loadedPlaceIdSets: [Set<String>] = []
                    
                    for (index, cached) in cachedRoutes.enumerated() {
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(cached.route.places, origin: userLocation.coordinate)
                    }
                        
                        // v1.6.45: Use cached directions if available (instant!)
                        var directions: [WalkingDirection] = []
                        if let cachedDirections = cached.directions, !cachedDirections.isEmpty {
                            directions = cachedDirections
                            if index == 0 {
                                print("⚡ Using cached directions - instant load!")
                            }
                        } else {
                            // Fallback: extract from legs
                            directions = await MainActor.run {
                        extractWalkingDirections(from: cached.route.legs)
                    }
                    
                            // Get MapKit directions if not in cache (only for first route to save time)
                            if directions.isEmpty && !cached.route.places.isEmpty && index == 0 {
                        print("🍎 Cached route has no directions - getting from MapKit...")
                        let waypointCoords = cached.route.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
                            }
                    }
                    
                    let routeDifficulty: RouteDifficulty = cached.route.durationMinutes <= 10 ? .easy : (cached.route.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    let localRoute = WalkingRoute(
                        name: cached.name ?? "Local Discovery",
                        description: cached.description ?? "A \(cached.route.formattedDuration) walk passing \(cached.route.places.count) local points of interest.",
                        durationMinutes: max(1, cached.route.durationMinutes),
                        distanceMeters: cached.route.distanceMeters,
                        difficulty: routeDifficulty,
                        isIndoor: false,
                        isAccessible: true,
                        landmarks: ["Start"] + cached.route.places.map { $0.name } + ["Return"],
                        icon: "location.fill",
                        color: .tealAccent,
                        qrMarkers: markers,
                        routeType: .local,
                        encodedPolyline: cached.route.polyline,
                            walkingDirections: directions,
                            usedOSRMRouting: cached.route.usedOSRM  // v1.7.1: Track OSRM usage for polyline refresh
                        )
                        
                        loadedRoutes.append((route: localRoute, data: cached.route, isDeadZoneFallback: cached.isDeadZoneFallback))
                        loadedPlaceIdSets.append(Set(cached.route.places.map { $0.placeId }))
                    }
                    
                    let firstRoute = loadedRoutes[0]
                    let firstCached = cachedRoutes[0]
                    
                    await MainActor.run {
                        isGenerating = false
                        routeGenerationComplete = true  // v1.8.5: Trigger stage animation completion
                        allRoutes = loadedRoutes
                        
                        // v1.6.45: Auto-advance to route 2 if available (skip template Route 1)
                        if loadedRoutes.count >= 2 {
                            currentRouteIndex = 1
                            let secondRoute = loadedRoutes[1]
                            generatedRoute = secondRoute.route
                            generatedRouteData = secondRoute.data
                            lastValidRoute = secondRoute.route
                            lastValidRouteData = secondRoute.data
                            viewedRouteIndices = [1]
                            print("🚀 Auto-advanced to route 2 (skipped template Route 1)")
                        } else {
                        currentRouteIndex = 0
                            generatedRoute = firstRoute.route
                            generatedRouteData = firstRoute.data
                            lastValidRoute = firstRoute.route
                            lastValidRouteData = firstRoute.data
                        viewedRouteIndices = [0]
                        }
                        
                        isRecycledRoute = false
                        isDeadZoneFallback = firstCached.isDeadZoneFallback
                        shownPlaceIdSets = loadedPlaceIdSets
                        preGenerationComplete = loadedRoutes.count >= maxRoutesToGenerate
                        
                        // v1.8.0: Register ALL cached route signatures to prevent duplicates!
                        for cachedRoute in cachedRoutes {
                            registerRouteSignature(places: cachedRoute.route.places, distanceMeters: cachedRoute.route.distanceMeters)
                        }
                        
                        // v1.8.13: Don't show map preview immediately - let stage animations complete first
                        // showMapPreview will be set to true when onAnimationComplete() is called
                        // showMapPreview = true  // REMOVED - this was causing stages to be skipped
                        
                        let totalTime = Date().timeIntervalSince(generateStartTime)
                        print("═══════════════════════════════════════════════════════════")
                        print("✅ CACHE LOADED - \(loadedRoutes.count) routes in \(String(format: "%.2f", totalTime))s (signatures: \(routeSignatures.count))")
                        print("   📍 Showing route \(currentRouteIndex + 1): \(generatedRouteData?.places.count ?? 0) POIs, \(generatedRouteData?.durationMinutes ?? 0)min")
                        print("═══════════════════════════════════════════════════════════")
                        
                        // Only pre-generate more if we don't have enough
                        if loadedRoutes.count < maxRoutesToGenerate {
                            print("📦 Only \(loadedRoutes.count)/\(maxRoutesToGenerate) routes cached - will pre-generate more")
                        preGenerateRemainingRoutes()
                        } else {
                            print("📦 All \(loadedRoutes.count) routes loaded from cache")
                            // v1.6.46: Background refresh - search for potentially better routes
                            backgroundRefreshRoutes(at: userLocation.coordinate, duration: selectedDuration)
                        }
                    }
                    return
                }
                
                print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - CACHE MISS - generating fresh route...")
                
                // v1.8.7: Loading screen Task already started at the beginning of Task block
                
                do {
                    // Use pre-fetched POIs if available (faster!)
                    let poisToUse = prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    if poisToUse != nil {
                        print("⚡ Using \(prefetchedPOIs.count) pre-fetched POIs for instant route generation")
                    } else {
                        print("⚠️ No pre-fetched POIs - will fetch during generation (slower)")
                    }
                    
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Starting route generation...")
                    let routeGenStartTime = Date()
                    
                    let result = try await mapsService.generateLocalRouteWithRetry(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        prefetchedPOIs: poisToUse
                    )
                    
                    let routeGenTime = Date().timeIntervalSince(routeGenStartTime)
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Route generated in \(String(format: "%.2f", routeGenTime))s")
                    
                    // Validate result
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        await MainActor.run {
                            errorMessage = "Could not find suitable places nearby. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                        }
                        return
                    }
                    
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Creating markers...")
                    
                    // Create markers from places (needs MainActor for some operations)
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                    }
                    
                    // Ensure we have at least one marker
                    guard !markers.isEmpty else {
                        await MainActor.run {
                            errorMessage = "No discovery spots could be created. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                        }
                        return
                    }
                    
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Extracting directions...")
                    
                    // Extract walking directions from OSRM/Google legs
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: result.legs)
                    }
                    
                    // v1.6.14: If no directions (OSRM was used), get them from Apple MapKit
                    if directions.isEmpty && !result.places.isEmpty {
                        print("🍎 No directions from route - getting from MapKit...")
                        let mapKitStartTime = Date()
                        let waypointCoords = result.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
                        print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - MapKit directions took \(String(format: "%.2f", Date().timeIntervalSince(mapKitStartTime)))s")
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    print("⏱️ +\(String(format: "%.2f", Date().timeIntervalSince(generateStartTime)))s - Generating route name (template)...")
                    
                    // v1.6.45: Use INSTANT template for Route 1 (saves 1-3 sec)
                    // AI naming happens for subsequent routes in background
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    // Use template directly - no network call, instant response
                    let templateContent = GeminiService.shared.generateTemplateContent(
                        waypoints: waypointInfos,
                        durationMinutes: result.durationMinutes,
                        distanceMeters: result.distanceMeters
                    )
                    print("⚡ Route 1: '\(templateContent.name)' (instant template)")
                    
                    let routeName = templateContent.name
                    let description = templateContent.description
                    
                    // Create the walking route with actual polyline and directions
                    let localRoute = WalkingRoute(
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
                        encodedPolyline: result.polyline,
                        walkingDirections: directions,
                        usedOSRMRouting: result.usedOSRM  // v1.7.1: Track OSRM usage for polyline refresh
                    )
                    
                    await MainActor.run {
                        isGenerating = false
                        routeGenerationComplete = true  // v1.8.5: Trigger stage animation completion
                        generatedRoute = localRoute
                        generatedRouteData = result
                        // Save as last valid for recycling on shuffle
                        lastValidRoute = localRoute
                        lastValidRouteData = result
                        
                        // v1.8.8: Check if initial route is too short (< 50% of target)
                        let minAcceptablePercent = 0.50
                        let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                        let isShortRoute = result.durationMinutes < minAcceptableDuration
                        if isShortRoute {
                            print("⚠️ Initial route is short fallback (\(result.durationMinutes)min < \(minAcceptableDuration)min target 50%)")
                        }
                        
                        // Initialize route array with first route
                        // v1.6.47: Include isDeadZoneFallback per-route
                        allRoutes = [(route: localRoute, data: result, isDeadZoneFallback: isShortRoute)]
                        currentRouteIndex = 0
                        preGenerationComplete = false
                        isRecycledRoute = false  // First route is never recycled
                        isDeadZoneFallback = isShortRoute  // v1.8.8: Mark if below 50%
                        rejectedShortRoutes = []  // v1.8.8: Clear any previous rejected routes
                        viewedRouteIndices = [0]  // Mark first route as viewed
                        // Track place IDs for this route
                        let placeIds = Set(result.places.map { $0.placeId })
                        shownPlaceIdSets = [placeIds]
                        
                        // v1.8.0: Register first route's signature to prevent duplicates!
                        registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                        
                        // v1.8.13: Don't show map preview immediately - let stage animations complete first
                        // showMapPreview = true  // REMOVED - this was causing stages to be skipped
                        
                        let totalTime = Date().timeIntervalSince(generateStartTime)
                        print("═══════════════════════════════════════════════════════════")
                        print("✅ ROUTE 1 READY - Total time: \(String(format: "%.2f", totalTime))s")
                        print("   📍 \(result.places.count) POIs, \(result.durationMinutes)min, \(result.distanceMeters)m")
                        print("═══════════════════════════════════════════════════════════")
                        
                        // Print comprehensive API call summary
                        print("")
                        print("═══════════════════════════════════════════════════════════")
                        print("📊 COMPREHENSIVE API CALL SUMMARY")
                        print("═══════════════════════════════════════════════════════════")
                        mapsService.printAPICallSummary()
                        GeminiService.shared.printAPICallSummary()
                        print("═══════════════════════════════════════════════════════════")
                        print("")
                        
                        // Start pre-generating more routes in background
                        preGenerateRemainingRoutes()
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                        showLoadingScreen = false  // Dismiss immediately on error
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
    
    /// v1.6.47: Live batch test progress overlay - shows on device during testing
    @ViewBuilder
    private func batchTestProgressOverlay() -> some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Header
            VStack(spacing: 8) {
                Image(systemName: "flask.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.tealAccent)
                    .symbolEffect(.pulse, options: .repeating)
                
                Text("Batch Test Running")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            
            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 10)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: testProgress.overallProgress)
                    .stroke(Color.tealAccent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: testProgress.overallProgress)
                
                VStack(spacing: 2) {
                    Text("\(Int(testProgress.overallProgress * 100))%")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text("\(testProgress.validCount)/\(testProgress.totalRoutes)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Current status
            VStack(spacing: 12) {
                // Location progress
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.coralPink)
                    Text(testProgress.currentLocationName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(testProgress.currentLocationIndex + 1)/\(testProgress.totalLocations)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                // Duration progress
                if testProgress.currentDuration > 0 {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(.softAmber)
                        Text("Testing \(testProgress.currentDuration) min routes")
                            .font(.subheadline)
                        Spacer()
                        Text("\(testProgress.currentDurationIndex + 1)/\(testProgress.totalDurations)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
                
                // Current action
                Text(testProgress.currentStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            }
            .padding()
            .background(Color(.systemBackground).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 4)
            .padding(.horizontal, 20)
            
            // Live valid rate
            VStack(spacing: 4) {
                Text("Current Valid Rate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(String(format: "%.0f%%", testProgress.validRate))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(testProgress.validRate >= 75 ? .green : (testProgress.validRate >= 50 ? .orange : .red))
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
    private func mapPreviewSection(route: WalkingRoute) -> some View {
        ZStack {
            LocalRouteMapPreview(
                route: route,
                userLocation: locationService.currentLocation?.coordinate,
                generatedData: generatedRouteData,
                isRecycled: isRecycledRoute,
                targetDurationMinutes: selectedDuration,
                currentRouteIndex: currentRouteIndex + 1,
                totalRoutes: allRoutes.count,
                isLoadingMoreRoutes: isPreGeneratingRoutes,
                showPremiumUpsell: showPremiumUpsell,
                hasLimitedPOIs: mapsService.hasLimitedPOIs,
                varietyExhausted: varietyExhausted,
                isDeadZoneFallback: isDeadZoneFallback,
                isStartingWalk: isStartingWalk,  // v1.6.45: Loading state
                onStartWalk: { handleStartWalk(route: route) },
                onShuffle: { shuffleToNextRoute() },
                onBack: { handleBackFromPreview() },
                onDelete: { handleDeleteRoute() }
            )
            // v1.6.47: Force re-render when route data changes - SwiftUI can optimize away re-renders
            .id("preview-\(allRoutes.count)-\(currentRouteIndex)-\(isPreGeneratingRoutes)")
            .background(Color(.systemBackground))
            .disabled(isShuffling)
            
            if isShuffling {
                shuffleLoadingOverlay()
            }
        }
    }
    
    private func handleStartWalk(route: WalkingRoute) {
        // v1.9.1: ALWAYS refresh route with Google Directions first (quality assurance)
        // Then fallback to Apple MapKit if Google quota is reached
        // This ensures best route quality and proper walking paths
        
        isStartingWalk = true
        print("🌐 Let's Go: Refreshing route with Google Directions first (quality assurance)...")
        
        Task {
            if let userLocation = locationService.currentLocation?.coordinate {
                // v1.8.9: Use Google Directions first (better quality), fallback to Apple
                let refreshedRoute = await mapsService.refreshRouteWithGoogleThenMapKit(
                    route: route,
                    userLocation: userLocation
                )
                await MainActor.run {
                    isStartingWalk = false
                    
                    // Print comprehensive route quality summary
                    print("")
                    print("╔═══════════════════════════════════════════════════════════╗")
                    print("║       🚶 ROUTE QUALITY SUMMARY (Copy & Paste)             ║")
                    print("╠═══════════════════════════════════════════════════════════╣")
                    print("║ Route: \(refreshedRoute.name.prefix(45))")
                    print("║ Duration: \(refreshedRoute.durationMinutes)min | Distance: \(refreshedRoute.distanceMeters)m")
                    print("║ Waypoints: \(refreshedRoute.qrMarkers.count)")
                    print("║ Directions: \(refreshedRoute.walkingDirections.count) steps")
                    
                    // Polyline quality
                    let polylinePoints = mapsService.decodePolyline(refreshedRoute.encodedPolyline ?? "")
                    let pointsPerKm = refreshedRoute.distanceMeters > 0 
                        ? Double(polylinePoints.count) / (Double(refreshedRoute.distanceMeters) / 1000.0) 
                        : 0
                    print("║ Polyline: \(polylinePoints.count) points (\(String(format: "%.1f", pointsPerKm)) pts/km)")
                    
                    if pointsPerKm < 20 {
                        print("║ ⚠️  LOW DENSITY - polyline may not follow roads")
                    } else if pointsPerKm < 50 {
                        print("║ ⚡ MEDIUM DENSITY - should follow main roads")
                    } else {
                        print("║ ✅ HIGH DENSITY - follows roads accurately")
                    }
                    
                    // First few direction steps
                    print("╠═══════════════════════════════════════════════════════════╣")
                    print("║ First 3 directions:")
                    for (i, dir) in refreshedRoute.walkingDirections.prefix(3).enumerated() {
                        let instruction = dir.instruction.prefix(50)
                        print("║   \(i+1). \(instruction)")
                    }
                    
                    print("╠═══════════════════════════════════════════════════════════╣")
                    print("║ API CALLS:")
                    mapsService.printAPICallSummary()
                    GeminiService.shared.printAPICallSummary()
                    print("╚═══════════════════════════════════════════════════════════╝")
                    print("")
                    
                    viewModel.selectRoute(refreshedRoute)
                    viewModel.startWalk()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isPresented = false
                    }
                }
            } else {
                // Fallback: use original route if no location
                await MainActor.run {
                    isStartingWalk = false
                    viewModel.selectRoute(route)
                    viewModel.startWalk()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isPresented = false
                    }
                }
            }
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
    
    /// Wrapper for shuffle that manages the shuffle loading state
    func generateRouteForShuffle() {
        guard let userLocation = locationService.currentLocation else {
            isShuffling = false
            return
        }
        
        if mapsService.hasAPIKey {
            Task {
                do {
                    // Flatten all previously shown place IDs to exclude from new route
                    let excludedPlaceIds = shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    
                    // Use pre-fetched POIs if available
                    let poisToUse = prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
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
                        extractWalkingDirections(from: result.legs)
                    }
                    
                    // v1.6.14: If no directions, get them from Apple MapKit
                    if directions.isEmpty && !result.places.isEmpty {
                        let waypointCoords = result.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    // Generate route name (always succeeds with template fallback)
                    let aiContent = await GeminiService.shared.generateRouteContent(
                        waypoints: waypointInfos,
                        durationMinutes: result.durationMinutes,
                        distanceMeters: result.distanceMeters,
                        difficulty: nil
                    )
                    
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
                            encodedPolyline: result.polyline,
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
    
    /// Handle shuffle button press - cycles through pre-generated routes
    func shuffleToNextRoute() {
        // v1.6.45: Only 1 route available - do nothing
        if allRoutes.count <= 1 {
            print("🔀 Only 1 route available - Next button disabled")
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
        
        // If we have more pre-generated routes to show, cycle to next
        if currentRouteIndex < allRoutes.count - 1 {
            // Show next pre-generated route instantly
            currentRouteIndex += 1
            let nextRoute = allRoutes[currentRouteIndex]
            generatedRoute = nextRoute.route
            generatedRouteData = nextRoute.data
            // Check if this route has been viewed before
            isRecycledRoute = viewedRouteIndices.contains(currentRouteIndex)
            viewedRouteIndices.insert(currentRouteIndex)  // Mark as viewed
            
            // v1.6.47: Use per-route flag instead of calculating (more accurate)
            isDeadZoneFallback = nextRoute.isDeadZoneFallback
            
            print("🔀 Showing route \(currentRouteIndex + 1) of \(allRoutes.count) (recycled: \(isRecycledRoute), fallback: \(isDeadZoneFallback))")
        } else {
            // v1.6.45: At last route - cycle back to route 1 (no dialog)
            currentRouteIndex = 0
            let firstRoute = allRoutes[0]
            generatedRoute = firstRoute.route
            generatedRouteData = firstRoute.data
            isRecycledRoute = true  // Always recycled when cycling back
            showPremiumUpsell = true  // Show upgrade message when all routes viewed
            
            // v1.6.47: Use per-route flag instead of calculating
            isDeadZoneFallback = firstRoute.isDeadZoneFallback
            
            print("🔄 Cycling back to route 1 of \(allRoutes.count)")
        }
    }
    
    /// Pre-generate remaining routes in background for instant shuffling
    func preGenerateRemainingRoutes() {
        guard let userLocation = locationService.currentLocation else { return }
        guard mapsService.hasAPIKey else { return }
        guard !isPreGeneratingRoutes else { return }
        
        isPreGeneratingRoutes = true
        varietyExhausted = false
        print("🚀 Starting background pre-generation of up to \(maxRoutesToGenerate) routes...")
        
        Task {
            var routesGenerated = allRoutes.count
            var consecutiveDuplicates = 0
            let maxConsecutiveDuplicates = 3  // Stop after 3 duplicates in a row - variety exhausted
            var consecutiveFailures = 0
            let maxConsecutiveFailures = 3  // Reduced from 5 - stop earlier if failing
            
            // Get pre-fetched POIs once for all iterations
            let poisToUse = await MainActor.run { prefetchedPOIs.isEmpty ? nil : prefetchedPOIs }
            
            while routesGenerated < maxRoutesToGenerate && consecutiveFailures < maxConsecutiveFailures && consecutiveDuplicates < maxConsecutiveDuplicates {
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
                    
                    // v1.8.15: Smart multi-waypoint - only for 30+ min routes where it helps
                    // For shorter routes (10-25min), multi-waypoint mode often produces WORSE results
                    // because the POI pool is smaller and falls back to suboptimal single-waypoint routes
                    let currentRouteCount = await MainActor.run { allRoutes.count }
                    let preferMulti = currentRouteCount >= 1 && currentRouteCount <= 3 && selectedDuration >= 30  // Routes 2-4, 30+ min only
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        prefetchedPOIs: poisToUse,
                        preferMultiWaypoint: preferMulti
                    )
                    
                    // Validate result
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        consecutiveFailures += 1
                        continue
                    }
                    
                    // v1.6.25: Use signature-based duplicate detection
                    // This catches routes with same POIs even if place ID sets differ slightly
                    let isUnique = await MainActor.run {
                        isRouteUnique(places: result.places, distanceMeters: result.distanceMeters)
                    }
                    
                    if !isUnique {
                        consecutiveDuplicates += 1
                        print("⚠️ Duplicate route detected (signature match) - \(consecutiveDuplicates)/\(maxConsecutiveDuplicates)")
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
                        extractWalkingDirections(from: result.legs)
                    }
                    
                    // v1.6.14: If no directions, get them from Apple MapKit
                    if directions.isEmpty && !result.places.isEmpty {
                        let waypointCoords = result.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    // Generate AI content
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    // Generate route name (always succeeds with template fallback)
                    let aiContent = await GeminiService.shared.generateRouteContent(
                        waypoints: waypointInfos,
                        durationMinutes: result.durationMinutes,
                        distanceMeters: result.distanceMeters,
                        difficulty: nil
                    )
                    
                    let routeName = aiContent.name
                    let description = aiContent.description
                    
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
                        encodedPolyline: result.polyline,
                        walkingDirections: directions,
                        usedOSRMRouting: result.usedOSRM  // v1.7.1: Track OSRM usage
                    )
                    
                    await MainActor.run {
                        // v1.8.8: Check if route is too short (< 50% of target)
                        // Short routes are stored but not added - may use ONE at end if needed
                        let minAcceptablePercent = 0.50
                        let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                        let routeDuration = result.durationMinutes
                        
                        if routeDuration < minAcceptableDuration {
                            // Store for potential use at end if we have ≤2 routes
                            rejectedShortRoutes.append((route: route, data: result))
                            print("📦 Stored short route (\(routeDuration)min < \(minAcceptableDuration)min) - may use later if needed")
                            consecutiveFailures += 1  // Count as failure for loop control
                            return
                        }
                        
                        // v1.6.47: Freshly generated routes are not dead zone fallbacks
                        allRoutes.append((route: route, data: result, isDeadZoneFallback: false))
                        
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
                        
                        // v1.6.26: Try waypoint permutation for 2+ waypoint routes
                        if result.places.count >= 2 {
                            if let permuted = createPermutedRoute(from: route, data: result) {
                                allRoutes.append(permuted)
                                registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                routesGenerated = allRoutes.count
                                print("🔄 Added permuted route (reversed waypoints) - now \(routesGenerated) routes")
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
            let currentRouteCount = await MainActor.run { allRoutes.count }
            var updatedPOIs = poisToUse
            
            if currentRouteCount <= 2 && mapsService.hasAPIKey {
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
                    
                    while googleRoutesGenerated < maxGoogleRoutes && googleFailures < 3 {
                        do {
                            let excludedPlaceIds = await MainActor.run {
                                shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                            }
                            
                            let result = try await mapsService.generateLocalRoute(
                                from: userLocation.coordinate,
                                targetDurationMinutes: selectedDuration,
                                difficulty: nil,
                                excludePlaceIds: excludedPlaceIds,
                                prefetchedPOIs: combinedPOIs
                            )
                            
                            guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                                googleFailures += 1
                                continue
                            }
                            
                            let newPlaceIds = Set(result.places.map { $0.placeId })
                            let isDuplicate = await MainActor.run { shownPlaceIdSets.contains(newPlaceIds) }
                            
                            if isDuplicate {
                                googleFailures += 1
                                continue
                            }
                            
                            let markers = await MainActor.run {
                                createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                            }
                            
                            guard !markers.isEmpty else {
                                googleFailures += 1
                                continue
                            }
                            
                            var directions = await MainActor.run {
                                extractWalkingDirections(from: result.legs)
                            }
                            
                            if directions.isEmpty && !result.places.isEmpty {
                                let waypointCoords = result.places.map { $0.coordinate }
                                directions = await mapsService.getMapKitDirectionsForRoute(
                                    origin: userLocation.coordinate,
                                    waypoints: waypointCoords,
                                    destination: userLocation.coordinate
                                )
                            }
                            
                            let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                            
                            let waypointInfos = result.places.map { place in
                                GeminiService.WaypointInfo(
                                    name: place.name,
                                    types: place.types ?? [],
                                    vicinity: place.vicinity
                                )
                            }
                            let aiContent = await GeminiService.shared.generateRouteContent(
                                waypoints: waypointInfos,
                                durationMinutes: result.durationMinutes,
                                distanceMeters: result.distanceMeters,
                                difficulty: nil
                            )
                            
                            let route = WalkingRoute(
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
                                encodedPolyline: result.polyline,
                                walkingDirections: directions
                            )
                            
                            await MainActor.run {
                                // v1.8.8: Check if route is too short (< 50% of target)
                                let minAcceptablePercent = 0.50
                                let minAcceptableDuration = Int(Double(selectedDuration) * minAcceptablePercent)
                                let routeDuration = result.durationMinutes
                                
                                if routeDuration < minAcceptableDuration {
                                    // Store for potential use at end if we have ≤2 routes
                                    rejectedShortRoutes.append((route: route, data: result))
                                    print("📦 Stored short Google route (\(routeDuration)min < \(minAcceptableDuration)min) - may use later")
                                    googleFailures += 1
                                    return
                                }
                                
                                // v1.6.47: Google fallback routes are not dead zone fallbacks
                                allRoutes.append((route: route, data: result, isDeadZoneFallback: false))
                                
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
                                    generatedRoute = newRoute.route
                                    generatedRouteData = newRoute.data
                                    viewedRouteIndices.insert(1)
                                    print("🚀 Auto-advanced to first AI-generated route (Google)")
                                }
                                
                                // v1.6.26: Try waypoint permutation for 2+ waypoint routes
                                if result.places.count >= 2 {
                                    if let permuted = createPermutedRoute(from: route, data: result) {
                                        allRoutes.append(permuted)
                                        registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                        print("🔄 Added permuted Google route - now \(allRoutes.count) routes")
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
                            googleFailures += 1
                        }
                        
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    print("🌐 Google fallback complete: +\(googleRoutesGenerated) routes")
                } else {
                    print("🌐 Google API returned no new POIs")
                }
            }
            
            await MainActor.run {
                isPreGeneratingRoutes = false
                preGenerationComplete = true
                
                // v1.8.8: Add ONE short fallback if we have ≤2 acceptable routes
                if allRoutes.count <= 2 && !rejectedShortRoutes.isEmpty {
                    // Pick the longest rejected route (closest to target)
                    let bestFallback = rejectedShortRoutes.max(by: { $0.data.durationMinutes < $1.data.durationMinutes })
                    if let fallback = bestFallback {
                        // v1.6.47: Mark this specific route as a dead zone fallback
                        allRoutes.append((route: fallback.route, data: fallback.data, isDeadZoneFallback: true))
                        isDeadZoneFallback = true  // Also update global state for current display
                        print("⚠️ Added 1 short fallback (\(fallback.data.durationMinutes)min) - only \(allRoutes.count - 1) acceptable routes available")
                    }
                }
                rejectedShortRoutes.removeAll()  // Clear the rejected list
                
                // v1.6.25: Log variety status
                let uniqueCount = routeSignatures.count
                if varietyExhausted {
                    print("🏁 Pre-generation complete for \(selectedDuration)min! \(uniqueCount) unique routes (variety exhausted)")
                } else {
                    print("🏁 Pre-generation complete for \(selectedDuration)min! \(allRoutes.count) routes generated")
                }
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
        let gapDurations = [45, 60]  // Removed 5 - minimum is now 10 min
        
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
        
        for duration in durationsToGenerate {
            // v1.6.33: Check rate limit - pause briefly if too high
            if await mapsService.shouldPauseBackgroundGeneration() {
                // Wait 5 seconds then continue (quota refreshes over time)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // Don't skip - just continue after brief pause
            }
            
            // Check if already cached
            if RouteCacheService.shared.getCachedRoutes(near: location, durationMinutes: duration) != nil {
                print("📦 \(duration)min already cached, skipping")
                continue
            }
            
            do {
                let result = try await mapsService.generateLocalRoute(
                    from: location,
                    targetDurationMinutes: duration,
                    difficulty: nil,
                    excludePlaceIds: [],
                    prefetchedPOIs: pois
                )
                
                // Validate and cache
                guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                    print("⚠️ \(duration)min generation failed validation")
                    continue
                }
                
                // Cache this route for future use
                RouteCacheService.shared.cacheRoutes([result], at: location, durationMinutes: duration)
                print("✅ Pre-generated and cached \(duration)min route (\(result.durationSeconds/60)min actual)")
                
                // v1.6.33: Reduced delay for faster pre-generation (0.5s instead of 1s)
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds between durations
                
            } catch {
                print("⚠️ \(duration)min pre-generation error: \(error.localizedDescription)")
            }
        }
        
        print("🏁 Other durations pre-generation complete!")
    }
    
    /// v1.6.46: Background refresh - search for new routes while using cached ones
    /// If a better route is found, it's merged into cache (replacing similar routes)
    func backgroundRefreshRoutes(at coordinate: CLLocationCoordinate2D, duration: Int) {
        Task {
            // Wait a bit before starting background refresh (let UI settle)
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            print("🔄 Background refresh: searching for new routes at \(duration)min...")
            
            // Try to generate 1-2 new routes
            var newRoutes: [(route: WalkingRoute, data: GeneratedRoute)] = []
            
            for attempt in 1...2 {
                do {
                    // v1.6.33: Check rate limit
                    if await mapsService.shouldPauseBackgroundGeneration() {
                        print("🔄 Background refresh: rate limited, stopping")
                        break
                    }
                    
                    let poisToUse = prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    let excludedPlaceIds = shownPlaceIdSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: coordinate,
                        targetDurationMinutes: duration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
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
                        
                        // Create waypoint infos for Gemini
                        let waypointInfos = result.places.map { place in
                            GeminiService.WaypointInfo(
                                name: place.name,
                                types: place.types ?? [],
                                vicinity: place.vicinity
                            )
                        }
                        
                        // Generate route name (always succeeds with template fallback)
                        let aiContent = await GeminiService.shared.generateRouteContent(
                            waypoints: waypointInfos,
                            durationMinutes: result.durationMinutes,
                            distanceMeters: result.distanceMeters,
                            difficulty: nil
                        )
                        
                        let directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: coordinate,
                            waypoints: result.places.map { $0.coordinate },
                            destination: coordinate
                        )
                        
                        let markers = await MainActor.run {
                            createMarkersFromPlaces(result.places, origin: coordinate)
                        }
                        let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                        
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
                            encodedPolyline: result.polyline,
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
        
        let localRoute = WalkingRoute(
            name: "Local Discovery",
            description: "A circular route around your current location with \(markers.count) discovery spots.",
            durationMinutes: max(1, selectedDuration), // Ensure at least 1 min
            distanceMeters: max(100, estimatedDistance), // Ensure at least 100m
            difficulty: selectedDuration <= 10 ? .easy : (selectedDuration <= 20 ? .moderate : .challenging),
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Start"] + markers.map { $0.name } + ["Return to Start"],
            icon: "location.fill",
            color: .tealAccent,
            qrMarkers: markers,
            routeType: .local,
            encodedPolyline: nil
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isGenerating = false
            routeGenerationComplete = true  // v1.8.5: Trigger stage animation completion
            generatedRoute = localRoute
            generatedRouteData = nil
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
    
    // MARK: - Debug Route Generation Test
    @State private var isRunningRouteTest = false
    @State private var routeTestResults: String = ""
    @State private var showRouteTestResults = false
    @State private var didCopyResults = false  // For "Copied!" feedback
    
    // v1.6.47: Live progress tracking for on-device feedback
    @State private var testProgress: BatchTestProgress = BatchTestProgress()
    
    struct BatchTestProgress {
        var isActive: Bool = false
        var currentLocationName: String = ""
        var currentLocationIndex: Int = 0
        var totalLocations: Int = 1
        var currentDuration: Int = 0
        var currentDurationIndex: Int = 0
        var totalDurations: Int = 11  // 10, 15, 20... 60
        var validCount: Int = 0
        var totalRoutes: Int = 0
        var currentStatus: String = "Starting..."
        
        var overallProgress: Double {
            let locationProgress = Double(currentLocationIndex) / Double(max(1, totalLocations))
            let durationProgress = Double(currentDurationIndex) / Double(max(1, totalDurations))
            // Weight: 90% location progress, 10% within-location progress
            return locationProgress + (durationProgress / Double(max(1, totalLocations)))
        }
        
        var validRate: Double {
            guard totalRoutes > 0 else { return 0 }
            return Double(validCount) / Double(totalRoutes) * 100
        }
    }
    
    /// v1.6.47: Calculate unified Route Score out of 100
    /// Components:
    /// - Valid Rate (50 points): % of routes within 75-125% of target
    /// - Accuracy (30 points): How close average is to 100% (penalty for deviation)
    /// - Variety (15 points): % of unique routes vs duplicates
    /// - Speed (5 points): Bonus for fast generation (<5s average)
    static func calculateRouteScore(
        validRate: Double,      // 0-100
        avgAccuracy: Double,    // 0-200+ (100 = perfect)
        varietyRate: Double,    // 0-100
        avgSpeed: Double        // seconds per route
    ) -> Int {
        // Valid Rate: 50 points max
        let validScore = (validRate / 100.0) * 50.0
        
        // Accuracy: 30 points max (perfect at 100%, loses points for deviation)
        // ±10% from 100% = full 30 points, drops linearly to 0 at ±30%
        let accuracyDeviation = abs(avgAccuracy - 100.0)
        let accuracyScore = max(0, (1.0 - accuracyDeviation / 30.0)) * 30.0
        
        // Variety: 15 points max
        let varietyScore = (varietyRate / 100.0) * 15.0
        
        // Speed: 5 points max (full points if <2s, drops to 0 at 10s)
        let speedScore = max(0, min(5.0, (10.0 - avgSpeed) / 8.0 * 5.0))
        
        let totalScore = validScore + accuracyScore + varietyScore + speedScore
        return min(100, max(0, Int(round(totalScore))))
    }
    
    /// v1.6.45: Run test for a single location by coordinate
    func runSingleTest(at coordinate: CLLocationCoordinate2D, name: String) {
        // If lat/lon are 0, use current location (with polling retry)
        if coordinate.latitude == 0 && coordinate.longitude == 0 {
            waitForLocationAndRunTest()
        } else {
            runRouteGenerationTest(at: coordinate)
        }
    }
    
    /// Wait for location with polling, fallback to cached POI location
    private func waitForLocationAndRunTest() {
        // First check: Do we already have a location?
        if let userLocation = locationService.currentLocation {
            print("🧪 Using existing location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
            runRouteGenerationTest(at: userLocation.coordinate)
            return
        }
        
        // Second check: Can we use a cached POI location?
        let cachedLocations = POICacheService.shared.getCachedLocationsInfo()
        if let firstCached = cachedLocations.first {
            print("🧪 Using cached POI location: \(firstCached.coordinate.latitude), \(firstCached.coordinate.longitude)")
            print("   (This location has \(firstCached.poiCount) cached POIs)")
            runRouteGenerationTest(at: firstCached.coordinate)
            return
        }
        
        // Last resort: Try to request and wait
        print("⏳ No cached location - requesting fresh GPS...")
        locationService.requestCurrentLocation()
        
        var attempts = 0
        let maxAttempts = 6  // 3 seconds total
        
        func checkLocation() {
            if let userLocation = locationService.currentLocation {
                print("🧪 Got fresh location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                runRouteGenerationTest(at: userLocation.coordinate)
            } else if attempts < maxAttempts {
                attempts += 1
                print("⏳ Attempt \(attempts)/\(maxAttempts)...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    checkLocation()
                }
            } else {
                print("❌ Could not get location")
                isRunningRouteTest = true
                routeTestResults = "❌ ERROR: No location available.\n\nPlease:\n1. Generate a route first (this caches your location)\n2. Or ensure location permissions are granted"
                showRouteTestResults = true
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checkLocation()
        }
    }
    
    /// Run tests for ALL CACHED locations (dynamic, not hardcoded)
    func runAllLocationTests() {
        isRunningRouteTest = true
        
        // Build test locations list from CACHED locations
        var allTestLocations: [(name: String, coordinate: CLLocationCoordinate2D)] = []
        
        // Add current location first if available
        if let userLocation = locationService.currentLocation {
            allTestLocations.append(("📍 Current Location", userLocation.coordinate))
        }
        
        // Add all cached locations
        let cachedLocations = POICacheService.shared.getCachedLocationsInfo()
        for (index, cached) in cachedLocations.enumerated() {
            // Skip if too close to current location (already added)
            if let userLocation = locationService.currentLocation {
                let distance = CLLocation(latitude: cached.coordinate.latitude, longitude: cached.coordinate.longitude)
                    .distance(from: CLLocation(latitude: userLocation.coordinate.latitude, longitude: userLocation.coordinate.longitude))
                if distance < 100 { continue }  // Skip duplicates within 100m
            }
            allTestLocations.append(("📦 Cached #\(index + 1) (\(cached.poiCount) POIs)", cached.coordinate))
        }
        
        // v1.6.47: Initialize live progress
        testProgress = BatchTestProgress()
        testProgress.isActive = true
        testProgress.totalLocations = allTestLocations.count
        testProgress.currentStatus = "Initializing..."
        
        // Get app version for batch test header
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        
        routeTestResults = "🧪🧪🧪 BATCH TEST - ALL LOCATIONS 🧪🧪🧪\n"
        routeTestResults += "📱 Version: \(appVersion) (Build \(buildNumber))\n"
        routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        routeTestResults += "Testing \(allTestLocations.count) locations...\n\n"
        
        Task {
            // v1.6.41: Track total test duration
            let batchStartTime = Date()
            
            var allLocationSummaries: [(name: String, avgAccuracy: Double, validRate: Double, avgSpeed: Double, poiCount: Int)] = []
            
            for (index, location) in allTestLocations.enumerated() {
                await MainActor.run {
                    // v1.6.47: Update live progress
                    testProgress.currentLocationIndex = index
                    testProgress.currentLocationName = location.name
                    testProgress.currentDurationIndex = 0
                    testProgress.currentDuration = 0
                    testProgress.currentStatus = "Testing \(location.name)..."
                    
                    routeTestResults += "\n\n"
                    routeTestResults += "╔══════════════════════════════════════════════════════════════╗\n"
                    routeTestResults += "║ 📍 LOCATION \(index + 1)/\(allTestLocations.count): \(location.name)\n"
                    routeTestResults += "╚══════════════════════════════════════════════════════════════╝\n"
                }
                
                // Run test for this location and collect summary
                let summary = await runSingleLocationTest(
                    coordinate: location.coordinate,
                    name: location.name
                )
                allLocationSummaries.append((
                    name: location.name,
                    avgAccuracy: summary.avgAccuracy,
                    validRate: summary.validRate,
                    avgSpeed: summary.avgSpeed,
                    poiCount: summary.poiCount
                ))
                
                // Small delay between locations to avoid rate limiting
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
            
            // Final comparison summary
            await MainActor.run {
                routeTestResults += "\n\n"
                routeTestResults += "╔══════════════════════════════════════════════════════════════╗\n"
                routeTestResults += "║ 📊 FINAL COMPARISON - ALL LOCATIONS                          ║\n"
                routeTestResults += "╚══════════════════════════════════════════════════════════════╝\n"
                routeTestResults += "┌────────────────────────┬────────┬─────────┬────────┬──────┐\n"
                routeTestResults += "│ Location               │ Avg Acc│ Valid % │ Speed  │ POIs │\n"
                routeTestResults += "├────────────────────────┼────────┼─────────┼────────┼──────┤\n"
                
                for summary in allLocationSummaries {
                    let shortName = String(summary.name.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
                    let acc = String(format: "%3.0f%%", summary.avgAccuracy).padding(toLength: 6, withPad: " ", startingAt: 0)
                    let valid = String(format: "%3.0f%%", summary.validRate).padding(toLength: 7, withPad: " ", startingAt: 0)
                    let speed = String(format: "%.1fs", summary.avgSpeed).padding(toLength: 6, withPad: " ", startingAt: 0)
                    let pois = String(summary.poiCount).padding(toLength: 4, withPad: " ", startingAt: 0)
                    routeTestResults += "│ \(shortName) │ \(acc) │ \(valid) │ \(speed) │ \(pois) │\n"
                }
                
                routeTestResults += "└────────────────────────┴────────┴─────────┴────────┴──────┘\n"
                
                // Overall averages
                let overallAvgAccuracy = allLocationSummaries.map { $0.avgAccuracy }.reduce(0, +) / Double(allLocationSummaries.count)
                let overallValidRate = allLocationSummaries.map { $0.validRate }.reduce(0, +) / Double(allLocationSummaries.count)
                let overallAvgSpeed = allLocationSummaries.map { $0.avgSpeed }.reduce(0, +) / Double(allLocationSummaries.count)
                
                // v1.6.47: Calculate variety rate (approximate from valid rate)
                let overallVarietyRate = min(100, overallValidRate * 1.1)  // Proxy based on valid rate
                
                // v1.6.47: Calculate Route Score
                let routeScore = Self.calculateRouteScore(
                    validRate: overallValidRate,
                    avgAccuracy: overallAvgAccuracy,
                    varietyRate: overallVarietyRate,
                    avgSpeed: overallAvgSpeed
                )
                
                routeTestResults += "\n🎯 ROUTE SCORE: \(routeScore)/100\n"
                routeTestResults += "   Components:\n"
                routeTestResults += "   • Valid Rate: \(String(format: "%.0f%%", overallValidRate)) → \(Int((overallValidRate / 100.0) * 50))/50 pts\n"
                routeTestResults += "   • Accuracy: \(String(format: "%.0f%%", overallAvgAccuracy)) → \(Int(max(0, (1.0 - abs(overallAvgAccuracy - 100.0) / 30.0)) * 30))/30 pts\n"
                routeTestResults += "   • Variety: \(String(format: "%.0f%%", overallVarietyRate)) → \(Int((overallVarietyRate / 100.0) * 15))/15 pts\n"
                routeTestResults += "   • Speed: \(String(format: "%.1fs", overallAvgSpeed)) → \(Int(max(0, min(5.0, (10.0 - overallAvgSpeed) / 8.0 * 5.0))))/5 pts\n"
                
                routeTestResults += "\n📈 OVERALL AVERAGES:\n"
                routeTestResults += "   Accuracy: \(String(format: "%.0f%%", overallAvgAccuracy))\n"
                routeTestResults += "   Valid rate: \(String(format: "%.0f%%", overallValidRate))\n"
                routeTestResults += "   Speed: \(String(format: "%.1fs", overallAvgSpeed)) per route\n"
                
                // v1.6.41: Show total test duration
                let totalDuration = Date().timeIntervalSince(batchStartTime)
                let totalMinutes = Int(totalDuration) / 60
                let totalSeconds = Int(totalDuration) % 60
                routeTestResults += "\n⏱️ Total time: \(totalMinutes)m \(totalSeconds)s\n"
                
                routeTestResults += "\n🏁 Batch test complete!\n"
                
                // Save to storage for later review
                BatchTestStorage.shared.saveTest(routeTestResults)
                
                // v1.6.47: Turn off live progress
                testProgress.isActive = false
                
                isRunningRouteTest = false
                showRouteTestResults = true
            }
        }
    }
    
    /// Run test for a single location and return summary stats
    func runSingleLocationTest(coordinate: CLLocationCoordinate2D, name: String) async -> (avgAccuracy: Double, validRate: Double, avgSpeed: Double, poiCount: Int) {
        let durations = stride(from: 10, through: 60, by: 5).map { $0 }  // v1.6.38: Start at 10min (no 5min)
        let maxRoutesPerDuration = 5
        var allResults: [(accuracy: Double, time: Double, isValid: Bool)] = []
        var poiCount = 0
        
        // Get POIs - for testing, use cache if available, otherwise fetch WITHOUT caching
        var pois: [PlaceResult]? = nil
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: coordinate), !cachedPOIs.isEmpty {
            pois = cachedPOIs
            print("🧪 [\(name)] Using \(cachedPOIs.count) CACHED POIs")
        } else {
            // For testing: fetch POIs but don't cache (bypass limit)
            print("🧪 [\(name)] Fetching fresh POIs (test mode - no cache)...")
            pois = try? await mapsService.findNearbyPlacesWithoutCaching(location: coordinate, radiusMeters: 2500)
        }
        
        poiCount = pois?.count ?? 0
        
        // v1.6.45: Enhanced logging - show POI sources
        let googlePOIs = pois?.filter { !$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") }.count ?? 0
        let applePOIs = pois?.filter { $0.placeId.hasPrefix("apple_") }.count ?? 0
        let osmPOIs = pois?.filter { $0.placeId.hasPrefix("osm_") }.count ?? 0
        
        await MainActor.run {
            routeTestResults += "📦 POIs: \(poiCount) (Google: \(googlePOIs), Apple: \(applePOIs), OSM: \(osmPOIs))\n"
        }
        
        for (durationIndex, duration) in durations.enumerated() {
            var excludedPlaceIds = Set<String>()
            var consecutiveFailures = 0
            var routesForDuration: [(actual: Int, accuracy: Double, waypoints: String, distance: Int)] = []
            
            await MainActor.run {
                // v1.6.47: Update live progress for this duration
                testProgress.currentDurationIndex = durationIndex
                testProgress.currentDuration = duration
                testProgress.currentStatus = "Testing \(duration)min routes..."
                
                routeTestResults += "\n📌 \(duration) MIN:\n"
            }
            
            for routeNum in 1...maxRoutesPerDuration {
                guard consecutiveFailures < 3 else { break }
                
                let startTime = Date()
                
                do {
                    let route = try await mapsService.generateLocalRoute(
                        from: coordinate,
                        targetDurationMinutes: duration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        prefetchedPOIs: pois
                    )
                    
                    if !route.places.isEmpty && route.durationSeconds > 0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let actualMin = route.durationSeconds / 60
                        let accuracy = Double(actualMin) / Double(duration) * 100
                        // v1.6.43: 75-125% acceptable (symmetric bounds)
                        // v1.6.44: 70-130% acceptable for 10 min walks only (more tolerance)
                        // 75-79% = short, 80-120% = valid, 121-125% = long
                        let lowerBound = duration == 10 ? 70.0 : 75.0
                        let upperBound = duration == 10 ? 130.0 : 125.0
                        let isAcceptable = accuracy >= lowerBound && accuracy <= upperBound
                        let isShort = accuracy >= lowerBound && accuracy < 80
                        let isLong = accuracy > 120 && accuracy <= upperBound
                        
                        allResults.append((accuracy: accuracy, time: elapsed, isValid: isAcceptable))
                        
                        // Build waypoint names string
                        let waypointNames = route.places.prefix(3).map { 
                            String($0.name.prefix(15)) 
                        }.joined(separator: " → ")
                        let moreCount = route.places.count > 3 ? " +\(route.places.count - 3)" : ""
                        
                        routesForDuration.append((
                            actual: actualMin,
                            accuracy: accuracy,
                            waypoints: waypointNames + moreCount,
                            distance: route.distanceMeters
                        ))
                        
                        // Output route details
                        // v1.6.43: ⚡ for short (75-79%), ✅ for valid (80-120%), 🔷 for long (121-125%)
                        // v1.6.45: Added generation time to logging
                        let icon = isShort ? "⚡" : (isLong ? "🔷" : (isAcceptable ? "✅" : (accuracy < 75 ? "📉" : "📈")))
                        let elapsedStr = String(format: "%.1fs", elapsed)
                        await MainActor.run {
                            // v1.6.47: Update live progress
                            testProgress.totalRoutes += 1
                            if isAcceptable {
                                testProgress.validCount += 1
                            }
                            testProgress.currentStatus = "\(duration)min R\(routeNum): \(actualMin)min (\(Int(accuracy))%)"
                            
                            routeTestResults += "  \(icon) R\(routeNum): \(actualMin)min (\(Int(accuracy))%) \(route.distanceMeters)m ⏱\(elapsedStr)\n"
                            routeTestResults += "     → \(waypointNames)\(moreCount)\n"
                        }
                        
                        // Add POIs to excluded list
                        for place in route.places {
                            excludedPlaceIds.insert(place.placeId)
                        }
                        consecutiveFailures = 0
                    } else {
                        consecutiveFailures += 1
                    }
                } catch {
                    consecutiveFailures += 1
                }
            }
            
            // Duration summary - v1.6.43: 75-125% acceptable (symmetric)
            let validForDuration = routesForDuration.filter { $0.accuracy >= 80 && $0.accuracy <= 120 }.count
            let shortForDuration = routesForDuration.filter { $0.accuracy >= 75 && $0.accuracy < 80 }.count
            let longForDuration = routesForDuration.filter { $0.accuracy > 120 && $0.accuracy <= 125 }.count
            let acceptableForDuration = validForDuration + shortForDuration + longForDuration
            await MainActor.run {
                if shortForDuration > 0 || longForDuration > 0 {
                    var breakdown = "\(validForDuration) valid"
                    if shortForDuration > 0 { breakdown += " + \(shortForDuration) short" }
                    if longForDuration > 0 { breakdown += " + \(longForDuration) long" }
                    routeTestResults += "  📊 \(acceptableForDuration)/\(routesForDuration.count) acceptable (\(breakdown))\n"
                } else {
                routeTestResults += "  📊 \(validForDuration)/\(routesForDuration.count) valid\n"
                }
            }
        }
        
        // Calculate summary stats - v1.6.43: track short (75-79%) and long (121-125%) separately
        let avgAccuracy = allResults.isEmpty ? 0 : allResults.map { $0.accuracy }.reduce(0, +) / Double(allResults.count)
        let acceptableCount = allResults.filter { $0.isValid }.count  // Now includes 75-125%
        let strictValidCount = allResults.filter { $0.accuracy >= 80 && $0.accuracy <= 120 }.count
        let shortCount = allResults.filter { $0.accuracy >= 75 && $0.accuracy < 80 }.count
        let longCount = allResults.filter { $0.accuracy > 120 && $0.accuracy <= 125 }.count
        let validRate = allResults.isEmpty ? 0 : Double(acceptableCount) / Double(allResults.count) * 100
        let avgSpeed = allResults.isEmpty ? 0 : allResults.map { $0.time }.reduce(0, +) / Double(allResults.count)
        
        await MainActor.run {
            routeTestResults += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            routeTestResults += "📊 \(name) SUMMARY:\n"
            routeTestResults += "   Routes: \(allResults.count) | Avg accuracy: \(String(format: "%.0f%%", avgAccuracy))\n"
            if shortCount > 0 || longCount > 0 {
                routeTestResults += "   Acceptable (75-125%): \(acceptableCount)/\(allResults.count) (\(String(format: "%.0f%%", validRate)))\n"
                routeTestResults += "   ├─ Valid (80-120%): \(strictValidCount)\n"
                if shortCount > 0 && longCount > 0 {
                    routeTestResults += "   ├─ Short (75-79%): \(shortCount)\n"
                    routeTestResults += "   └─ Long (121-125%): \(longCount)\n"
                } else if shortCount > 0 {
                    routeTestResults += "   └─ Short (75-79%): \(shortCount)\n"
                } else {
                    routeTestResults += "   └─ Long (121-125%): \(longCount)\n"
                }
            } else {
                routeTestResults += "   Valid (80-120%): \(acceptableCount)/\(allResults.count) (\(String(format: "%.0f%%", validRate)))\n"
            }
            routeTestResults += "   Avg speed: \(String(format: "%.1fs", avgSpeed))\n"
        }
        
        return (avgAccuracy: avgAccuracy, validRate: validRate, avgSpeed: avgSpeed, poiCount: poiCount)
    }
    
    /// Test route generation for all durations (5-60min) and report results
    func runRouteGenerationTest(at testLocation: CLLocationCoordinate2D? = nil) {
        // Use provided test location or current location
        let testCoordinate: CLLocationCoordinate2D
        let locationName: String
        
        if let provided = testLocation {
            testCoordinate = provided
            // Identify test location by coordinates
            if abs(provided.latitude - 53.4115) < 0.01 && abs(provided.longitude - (-1.4577)) < 0.01 {
                locationName = "S5 7AU (Firth Park)"
            } else if abs(provided.latitude - 53.3631) < 0.01 && abs(provided.longitude - (-1.4989)) < 0.01 {
                locationName = "S11 9BF (Ecclesall)"
            } else if abs(provided.latitude - 53.3447) < 0.01 && abs(provided.longitude - (-1.3633)) < 0.01 {
                locationName = "S12 4QN (Hackenthorpe)"
            } else if abs(provided.latitude - 53.4633) < 0.01 && abs(provided.longitude - (-1.4667)) < 0.01 {
                locationName = "S35 0JW (Chapeltown)"
            } else {
                locationName = "Test Location"
            }
        } else if let userLocation = locationService.currentLocation {
            testCoordinate = userLocation.coordinate
            locationName = "Current Location"
        } else {
            routeTestResults = "❌ No location available"
            showRouteTestResults = true
            return
        }
        
        isRunningRouteTest = true
        
        // v1.6.47: Initialize live progress for single location test
        testProgress = BatchTestProgress()
        testProgress.isActive = true
        testProgress.totalLocations = 1
        testProgress.currentLocationIndex = 0
        testProgress.currentLocationName = locationName
        testProgress.currentStatus = "Starting test..."
        
        // Get app version for test header
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        
        routeTestResults = "🧪 FULL ROUTE GENERATION TEST\n"
        routeTestResults += "📱 Version: \(appVersion) (Build \(buildNumber))\n"
        routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        
        Task {
            let durations = stride(from: 10, through: 60, by: 5).map { $0 }  // v1.6.38: Start at 10min (no 5min)
            let maxRoutesPerDuration = 5  // Try to generate up to 5 routes per duration
            var allResults: [(duration: Int, routeNum: Int, actual: Int, time: Double, accuracy: Double, status: String, waypoints: Int, distance: Int, routeKey: String, waypointNames: [String])] = []
            var seenRouteKeys = Set<String>()  // Track unique routes globally
            var totalRoutesGenerated = 0
            
            // Get POIs - check cache first, then prefetched, then fetch fresh
            var pois: [PlaceResult]? = nil
            
            // 1. Check POI cache for this location (FREE - no API call)
            if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: testCoordinate), !cachedPOIs.isEmpty {
                pois = cachedPOIs
                print("🧪 Using \(cachedPOIs.count) CACHED POIs (no API call)")
            }
            // 2. Use prefetched POIs if available and we're at current location
            else if testLocation == nil && !prefetchedPOIs.isEmpty {
                pois = prefetchedPOIs
                print("🧪 Using \(prefetchedPOIs.count) prefetched POIs")
            }
            // 3. Fetch fresh POIs without caching (bypass location limit for testing)
            else {
                print("🧪 ⚠️ Cache empty - fetching POIs WITHOUT caching (test mode)")
                pois = try? await mapsService.findNearbyPlacesWithoutCaching(location: testCoordinate, radiusMeters: 2500)
            }
            
            await MainActor.run {
                routeTestResults += "📍 \(locationName): (\(String(format: "%.4f", testCoordinate.latitude)), \(String(format: "%.4f", testCoordinate.longitude)))\n"
                routeTestResults += "📦 POIs available: \(pois?.count ?? 0)\n"
                routeTestResults += "🎯 Max routes per duration: \(maxRoutesPerDuration)\n"
                routeTestResults += "🕐 Test started: \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))\n"
                routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            }
            
            for (durationIndex, duration) in durations.enumerated() {
                var excludedPlaceIds = Set<String>()  // Reset for each duration
                var routesForThisDuration: [(routeNum: Int, actual: Int, time: Double, accuracy: Double, status: String, waypoints: Int, distance: Int, routeKey: String, waypointNames: [String])] = []
                var consecutiveFailures = 0
                
                // v1.6.25: Signature-based deduplication with early stopping
                var durationSignatures = Set<String>()  // Unique signatures for this duration
                var consecutiveDuplicates = 0
                let maxConsecutiveDuplicates = 3  // Stop when variety exhausted
                var varietyExhausted = false
                var uniqueRoutesFound = 0
                
                await MainActor.run {
                    // v1.6.47: Update live progress
                    testProgress.currentDurationIndex = durationIndex
                    testProgress.currentDuration = duration
                    testProgress.currentStatus = "Testing \(duration)min routes..."
                    
                    routeTestResults += "\n📌 \(duration) MINUTES\n"
                    routeTestResults += "───────────────────────────────────────\n"
                }
                
                for routeNum in 1...maxRoutesPerDuration {
                    guard consecutiveFailures < 3 else { break }  // Stop after 3 failures
                    guard !varietyExhausted else { break }  // v1.6.25: Stop when variety exhausted
                    
                    let startTime = Date()
                    var actualMin = 0
                    var accuracy: Double = 0
                    var status = ""
                    var waypoints = 0
                    var distance = 0
                    var routeKey = ""
                    var waypointNames: [String] = []
                    
                    do {
                        // Try to generate a route, excluding previously used POIs
                        let result = try await mapsService.generateLocalRoute(
                            from: testCoordinate,
                            targetDurationMinutes: duration,
                            difficulty: nil,
                            excludePlaceIds: excludedPlaceIds,
                            prefetchedPOIs: pois
                        )
                        
                        if !result.places.isEmpty && result.durationSeconds > 0 {
                            actualMin = result.durationSeconds / 60
                            waypoints = result.places.count
                            distance = result.distanceMeters
                            waypointNames = result.places.map { $0.name }
                            
                            // Add these POIs to exclusion list for next iteration
                            for place in result.places {
                                excludedPlaceIds.insert(place.placeId)
                            }
                            
                            // v1.6.25: Use signature-based duplicate detection (matches app behavior)
                            let sortedIds = result.places.map { $0.placeId }.sorted().joined(separator: ",")
                            let distanceBucket = (distance / 100) * 100
                            let signature = "\(sortedIds)|\(distanceBucket)"
                            
                            let isDuplicate = durationSignatures.contains(signature)
                            
                            // Also create legacy routeKey for global tracking
                            let firstPOI = result.places.first?.name.prefix(10) ?? "?"
                            routeKey = "\(distance)m_\(waypoints)wp_\(firstPOI)"
                            
                            // Calculate accuracy as percentage of target
                            accuracy = Double(actualMin) / Double(duration) * 100
                            
                            if isDuplicate {
                                // v1.6.25: Track consecutive duplicates for early stopping
                                consecutiveDuplicates += 1
                                status = "🔁"
                                
                                if consecutiveDuplicates >= maxConsecutiveDuplicates {
                                    varietyExhausted = true
                                }
                            } else {
                                // Unique route found
                                durationSignatures.insert(signature)
                                seenRouteKeys.insert(routeKey)
                                uniqueRoutesFound += 1
                                consecutiveDuplicates = 0  // Reset on unique find
                                
                                // v1.6.39: ⚡ for short (75-79%), ✅ for valid (80-120%)
                                if accuracy >= 80 && accuracy <= 120 {
                                    status = "✅"
                                } else if accuracy >= 75 && accuracy < 80 {
                                    status = "⚡"  // Short but acceptable
                                } else if accuracy > 120 && accuracy <= 130 {
                                    status = "⚠️"  // Marginal (over)
                                } else if accuracy < 75 {
                                    status = "📉"  // Too short
                                } else {
                                    status = "📈"  // Too long (>130%)
                                }
                            }
                            
                            consecutiveFailures = 0
                            totalRoutesGenerated += 1
                            
                            // v1.6.47: Update live progress
                            await MainActor.run {
                                testProgress.totalRoutes += 1
                                let isAcceptable = (accuracy >= 75 && accuracy <= 130) && status != "🔁"
                                if isAcceptable {
                                    testProgress.validCount += 1
                                }
                                testProgress.currentStatus = "\(duration)min R\(routeNum): \(actualMin)min (\(Int(accuracy))%)"
                            }
                        } else {
                            status = "❌"
                            consecutiveFailures += 1
                        }
                    } catch {
                        consecutiveFailures += 1
                        let errorMsg = error.localizedDescription
                        if errorMsg.contains("rate") || errorMsg.contains("Rate") {
                            status = "🚫"
                        } else if errorMsg.contains("No route") || errorMsg.contains("no route") {
                            status = "🔚"  // No more routes possible
                            break
                        } else {
                            status = "💥"
                        }
                    }
                    
                    let elapsed = Date().timeIntervalSince(startTime)
                    
                    if !waypointNames.isEmpty {
                        routesForThisDuration.append((routeNum: routeNum, actual: actualMin, time: elapsed, accuracy: accuracy, status: status, waypoints: waypoints, distance: distance, routeKey: routeKey, waypointNames: waypointNames))
                        allResults.append((duration: duration, routeNum: routeNum, actual: actualMin, time: elapsed, accuracy: accuracy, status: status, waypoints: waypoints, distance: distance, routeKey: routeKey, waypointNames: waypointNames))
                        
                        // Update UI in real-time
                        await MainActor.run {
                            let timeStr = elapsed < 1 ? String(format: "%dms", Int(elapsed * 1000)) : String(format: "%.1fs", elapsed)
                            let accStr = String(format: "%.0f%%", accuracy)
                            let namesShort = waypointNames.prefix(3).map { String($0.prefix(15)) }.joined(separator: " → ")
                            let moreIndicator = waypointNames.count > 3 ? " +\(waypointNames.count - 3)" : ""
                            
                            routeTestResults += "  \(status) Route \(routeNum): \(actualMin)min (\(accStr)) \(timeStr)\n"
                            routeTestResults += "     📍 \(namesShort)\(moreIndicator)\n"
                        }
                    }
                    
                    // Small delay between routes
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                
                // v1.6.39: Improved summary with short routes included
                await MainActor.run {
                    let validRoutes = routesForThisDuration.filter { $0.status == "✅" }.count
                    let shortRoutes = routesForThisDuration.filter { $0.status == "⚡" }.count
                    let acceptableRoutes = validRoutes + shortRoutes
                    let exhaustedIndicator = varietyExhausted ? " (variety exhausted)" : ""
                    if shortRoutes > 0 {
                        routeTestResults += "  📊 \(uniqueRoutesFound) unique / \(acceptableRoutes) acceptable (\(validRoutes)✅ + \(shortRoutes)⚡)\(exhaustedIndicator)\n"
                    } else {
                    routeTestResults += "  📊 \(uniqueRoutesFound) unique / \(validRoutes) valid\(exhaustedIndicator)\n"
                    }
                }
            }
            
            // Keep existing summary generation but update counts
            let results = allResults  // For compatibility with existing summary code
            
            // Generate detailed summary
            await MainActor.run {
                routeTestResults += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                routeTestResults += "📊 SUMMARY\n"
                routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                
                let successful = results.filter { $0.status == "✅" }.count
                let shortAcceptable = results.filter { $0.status == "⚡" }.count  // v1.6.39
                let marginal = results.filter { $0.status == "⚠️" }.count
                let tooShort = results.filter { $0.status == "📉" }.count
                let tooLong = results.filter { $0.status == "📈" }.count
                let duplicates = results.filter { $0.status == "🔁" }.count
                let failed = results.filter { $0.status == "❌" || $0.status == "💥" || $0.status == "🚫" }.count
                let uniqueRoutes = seenRouteKeys.count
                
                let validResults = results.filter { $0.accuracy > 0 }
                let avgAccuracy = validResults.isEmpty ? 0 : validResults.map { $0.accuracy }.reduce(0, +) / Double(validResults.count)
                let avgTime = results.map { $0.time }.reduce(0, +) / Double(results.count)
                
                // v1.6.25: Calculate per-duration unique counts
                var durationUniqueMap: [Int: Int] = [:]
                var currentDuration = 0
                var currentSignatures = Set<String>()
                for r in results {
                    if r.duration != currentDuration {
                        currentDuration = r.duration
                        currentSignatures.removeAll()
                    }
                    let signature = r.routeKey  // Use routeKey as signature proxy
                    if !currentSignatures.contains(signature) && r.status != "🔁" {
                        currentSignatures.insert(signature)
                        durationUniqueMap[r.duration, default: 0] += 1
                    }
                }
                
                let requestedTotal = 12 * maxRoutesPerDuration  // 12 durations × 5 routes
                let varietyRate = Double(uniqueRoutes) / Double(requestedTotal) * 100
                
                routeTestResults += "\n📊 ROUTE AVAILABILITY (v1.6.25 - honest counts)\n"
                routeTestResults += "───────────────────────────────────────\n"
                routeTestResults += "🎯 Requested: \(requestedTotal) routes (12 durations × \(maxRoutesPerDuration))\n"
                routeTestResults += "✅ Unique found: \(uniqueRoutes)\n"
                routeTestResults += "🔁 Duplicates stopped: \(duplicates)\n"
                routeTestResults += "📈 Variety rate: \(String(format: "%.0f", varietyRate))%\n\n"
                
                routeTestResults += "BY ACCURACY (unique routes only):\n"
                routeTestResults += "✅ On-target (80-120%): \(successful)\n"
                routeTestResults += "⚡ Short (75-79%):      \(shortAcceptable)\n"
                routeTestResults += "⚠️ Marginal (121-130%): \(marginal)\n"
                routeTestResults += "📉 Too short (<75%):    \(tooShort)\n"
                routeTestResults += "📈 Too long (>130%):    \(tooLong)\n"
                routeTestResults += "❌ Failed/Error:        \(failed)\n"
                let totalAcceptable = successful + shortAcceptable
                routeTestResults += "───────────────────────────────────────\n"
                routeTestResults += "📊 Total acceptable:    \(totalAcceptable) (\(successful) valid + \(shortAcceptable) short)\n"
                
                routeTestResults += "\n📈 ACCURACY STATS:\n"
                routeTestResults += "   Average: \(String(format: "%.0f", avgAccuracy))% of target\n"
                
                if !validResults.isEmpty {
                    let minAcc = validResults.map { $0.accuracy }.min() ?? 0
                    let maxAcc = validResults.map { $0.accuracy }.max() ?? 0
                    routeTestResults += "   Range: \(String(format: "%.0f", minAcc))% - \(String(format: "%.0f", maxAcc))%\n"
                }
                
                routeTestResults += "\n⏱️ SPEED STATS:\n"
                routeTestResults += "   Average: \(String(format: "%.1f", avgTime))s per route\n"
                
                let slowRoutes = results.filter { $0.time > 5 }
                if !slowRoutes.isEmpty {
                    routeTestResults += "   Slow (>5s): \(slowRoutes.map { "\($0.duration)min" }.joined(separator: ", "))\n"
                }
                
                let fastRoutes = results.filter { $0.time < 1 }
                if !fastRoutes.isEmpty {
                    routeTestResults += "   Fast (<1s): \(fastRoutes.map { "\($0.duration)min" }.joined(separator: ", "))\n"
                }
                
                // Show duplicates (routes reusing same path)
                let duplicateResults = results.filter { $0.status == "🔁" }
                if !duplicateResults.isEmpty {
                    routeTestResults += "\n🔁 DUPLICATE ROUTES (same path reused):\n"
                    for r in duplicateResults {
                        routeTestResults += "   \(r.duration)min is same as another route (\(r.distance)m, \(r.waypoints)wp)\n"
                    }
                }
                
                // Detailed breakdown for problematic routes
                let problematic = results.filter { ($0.status != "✅" && $0.status != "🔁") && $0.accuracy > 0 }
                if !problematic.isEmpty {
                    routeTestResults += "\n⚠️ ROUTES NEEDING ATTENTION:\n"
                    for r in problematic {
                        let diff = r.actual - r.duration
                        let diffStr = diff >= 0 ? "+\(diff)" : "\(diff)"
                        routeTestResults += "   \(r.duration)min → \(r.actual)min (\(diffStr)min, \(String(format: "%.0f", r.accuracy))%)\n"
                    }
                }
                
                // v1.6.47: Calculate and display Route Score
                let varietyRateForScore = Double(uniqueRoutes) / Double(max(1, results.count)) * 100
                let validRateForScore = Double(successful + shortAcceptable) / Double(max(1, uniqueRoutes)) * 100
                let routeScore = Self.calculateRouteScore(
                    validRate: validRateForScore,
                    avgAccuracy: avgAccuracy,
                    varietyRate: varietyRateForScore,
                    avgSpeed: avgTime
                )
                
                routeTestResults += "\n🎯 ROUTE SCORE: \(routeScore)/100\n"
                
                routeTestResults += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                routeTestResults += "🕐 Test completed: \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))\n"
                
                // v1.6.45: Save single location test results too
                BatchTestStorage.shared.saveTest(routeTestResults)
                print("💾 Single location test saved to storage")
                
                // v1.6.47: Turn off live progress
                testProgress.isActive = false
                
                isRunningRouteTest = false
                showRouteTestResults = true
            }
        }
    }
    
    func createMarkersFromPlaces(_ places: [PlaceResult], origin: CLLocationCoordinate2D) -> [QRMarker] {
        return places.enumerated().map { index, place in
            // Always use a random breathing exercise (one of the 3 available)
            let content = WellbeingContent.breathingExercises.randomElement() ?? WellbeingContent.breathingExercises[0]
            
            return QRMarker(
                code: "POI\(index + 1)",
                name: place.name,
                location: place.vicinity ?? "Local POI",
                coordinate: place.coordinate,
                contentType: .breathingExercise,
                content: content,
                pointsValue: 20 + (index * 5)
            )
        }
    }
    
    /// Extract walking directions from Google Directions API legs
    func extractWalkingDirections(from legs: [DirectionsLeg]) -> [WalkingDirection] {
        var directions: [WalkingDirection] = []
        
        for (legIndex, leg) in legs.enumerated() {
            guard let steps = leg.steps else { continue }
            let isLastLeg = legIndex == legs.count - 1
            
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
                
                // Replace the last step of the last leg with "Return to starting point"
                if isLastLeg && stepIndex == steps.count - 1 {
                    direction = WalkingDirection(
                        instruction: "Return to starting point",
                        distance: step.distance.text,
                        distanceMeters: step.distance.value,
                        duration: step.duration.text,
                        maneuver: "arrive"
                    )
                }
                
                directions.append(direction)
            }
        }
        
        return directions
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
    var isStartingWalk: Bool = false  // v1.6.45: Loading state for Let's Go button
    
    // v1.6.45: Track map loading state
    @State private var isMapLoading = true
    
    // v1.8.3: Camera position that updates when route changes
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    // v1.6.28: Removed permission callbacks - permissions now requested during/after walk
    let onStartWalk: () -> Void          // Start the walk immediately
    let onShuffle: () -> Void            // Quick regenerate with same settings
    let onBack: () -> Void               // Go back to duration picker
    let onDelete: () -> Void             // Delete current route from cache
    
    // v1.6.28: Simplified - no permission gates before walk
    // Permissions are now requested DURING the walk (optional step tracking)
    // and AFTER the walk (HealthKit sync option)
    
    var primaryButtonText: String {
        isStartingWalk ? "Starting..." : "Let's Go!"
    }
    
    var primaryButtonIcon: String {
        isStartingWalk ? "arrow.trianglehead.2.clockwise" : "figure.walk"
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
        route.encodedPolyline != nil && !route.encodedPolyline!.isEmpty
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
            let googleCount = data.places.filter { !$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") }.count
            let appleCount = data.places.filter { $0.placeId.hasPrefix("apple_") }.count
            let osmCount = data.places.filter { $0.placeId.hasPrefix("osm_") }.count
            print("🗺️ Route POIs: 🌐 Google: \(googleCount), 🍎 Apple: \(appleCount), 🗺️ OSM: \(osmCount)")
        }
        
        // Log TOTAL cached POIs for location
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: userLoc) {
            let totalGoogle = cachedPOIs.filter { !$0.placeId.hasPrefix("apple_") && !$0.placeId.hasPrefix("osm_") }.count
            let totalApple = cachedPOIs.filter { $0.placeId.hasPrefix("apple_") }.count
            let totalOSM = cachedPOIs.filter { $0.placeId.hasPrefix("osm_") }.count
            print("🗺️ TOTAL cached POIs: \(cachedPOIs.count) (🌐 Google: \(totalGoogle), 🍎 Apple: \(totalApple), 🗺️ OSM: \(totalOSM))")
        }
        
        // Debug: Check if polyline exists
        print("🗺️ Polyline: \(route.encodedPolyline != nil ? "✅ exists (\(route.routePath.count) points)" : "❌ missing")")
        print("🗺️ QR Markers: \(route.qrMarkers.count) markers")
        
        guard allPoints.count > 1 else {
            return .region(MKCoordinateRegion(center: userLoc, latitudinalMeters: 800, longitudinalMeters: 800))
        }
        
        // Calculate TRUE bounding box of all points
        let latitudes = allPoints.map { $0.latitude }
        let longitudes = allPoints.map { $0.longitude }
        
        let minLat = latitudes.min()!
        let maxLat = latitudes.max()!
        let minLng = longitudes.min()!
        let maxLng = longitudes.max()!
        
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
                // User's starting location
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
                    }
                }
                
                // Route polyline (if available from Google Directions)
                // Split into outbound (teal) and return leg (orange)
                if hasRealPolyline, route.routePath.count >= 2 {
                    let splitResult = splitRouteAtLastWaypoint()
                    
                    // Outbound leg (to waypoints) - teal
                    if splitResult.outbound.count >= 2 {
                        MapPolyline(coordinates: splitResult.outbound)
                            .stroke(Color.tealAccent, lineWidth: 4)
                    }
                    
                    // Return leg (back to start) - orange
                    if splitResult.returnLeg.count >= 2 {
                        MapPolyline(coordinates: splitResult.returnLeg)
                            .stroke(Color.orange.opacity(0.8), lineWidth: 4)
                    }
                }
                
                // Discovery markers (POIs)
                ForEach(route.qrMarkers) { marker in
                    Annotation(marker.name, coordinate: marker.coordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.mintGreen)
                                .frame(width: 32, height: 32)
                            Image(systemName: "mappin")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
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
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        if let data = generatedData {
                            Text(data.formattedDuration)
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.tealAccent)
                            
                            Text(data.formattedDistance)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(route.durationMinutes) min")
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.tealAccent)
                            
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
                if let data = generatedData, !data.places.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Places along your route:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(data.places) { place in
                                    HStack(spacing: 4) {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                        Text(place.name)
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
                        
                        if isLoadingMoreRoutes {
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
                    // v1.6.45: Only show Next button if there's more than 1 route
                    if totalRoutes > 1 {
                    Button(action: onShuffle) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.title3)
                                .fontWeight(.medium)
                                Text("Next")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                        }
                        .foregroundColor(.tealAccent)
                            .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(Color.tealAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    }
                    
                    // Delete - remove current route (replaces settings button)
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                            .frame(width: 48, height: 48)
                            .background(Color.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    // v1.6.28: Simplified - start walk immediately (no permission gates)
                    Button {
                        onStartWalk()
                    } label: {
                        HStack {
                            if isStartingWalk {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                            Image(systemName: primaryButtonIcon)
                            }
                            Text(primaryButtonText)
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
                    // Start/End marker (Longley Centre)
                    Annotation("Start/End", coordinate: startCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.coralPink)
                                .frame(width: 44, height: 44)
                            Image(systemName: "cross.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Route path line (follows actual walking route)
                    if route.routePath.count >= 2 {
                        MapPolyline(coordinates: route.routePath)
                            .stroke(route.color, lineWidth: 4)
                    }
                    
                    // Discovery markers
                    ForEach(route.qrMarkers) { marker in
                        Annotation(marker.name, coordinate: marker.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(Color.mintGreen)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "mappin")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
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
struct ActiveWalkView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var showAllDirections: Bool = false
    @State private var showEndConfirmation: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Compact header with route info
            if let route = viewModel.walkSession.currentRoute {
                // Compact header - show route name only if no directions (otherwise directions banner serves as header)
                if route.walkingDirections.isEmpty || route.isIndoor {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name)
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            Text("\(Int(viewModel.locationService.distanceWalked))m walked")
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
                    let clampedIndex = Binding(
                        get: { 
                            let idx = viewModel.locationService.currentDirectionIndex
                            return min(max(0, idx), directionsToShow.count - 1)
                        },
                        set: { newValue in
                            let clamped = min(max(0, newValue), directionsToShow.count - 1)
                            viewModel.locationService.currentDirectionIndex = clamped
                        }
                    )
                    
                    WalkingDirectionsBanner(
                        directions: directionsToShow,
                        currentIndex: clampedIndex,
                        showAllDirections: $showAllDirections,
                        delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                        walkDurationMinutes: route.durationMinutes,
                        hasClinicianSelected: viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable,
                        distanceWalked: Int(viewModel.locationService.distanceWalked),
                        halfwayAlert: viewModel.walkSession.halfwayAlertSent
                    )
                }
            }
            
            // Map with expanded directions overlay
            ZStack {
                // Embedded Map - always present
                EmbeddedWalkMapView(viewModel: viewModel)
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
                            get: { viewModel.locationService.currentDirectionIndex },
                            set: { viewModel.locationService.currentDirectionIndex = $0 }
                        ),
                        showAllDirections: $showAllDirections
                    )
                    .transition(.opacity)
                }
            }
            
            // Bottom section with stats and end button
            VStack(spacing: 12) {
                // Compact stats row (v1.6.13: removed delay badge - now shown in top banner)
                HStack(spacing: 8) {
                    CompactStatPill(icon: "figure.walk", value: "\(viewModel.walkSession.stepsThisSession)", label: "steps")
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
                .padding(.bottom, 12)
            }
        }
        .confirmationDialog("End Walk?", isPresented: $showEndConfirmation) {
            Button("End & Save Progress") {
                viewModel.endWalk(completed: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your steps and progress will be saved.")
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
    
    // Darker forest green color
    private let bannerColor = Color(red: 0.13, green: 0.55, blue: 0.45)
    
    var body: some View {
        // Single compact banner with direction + timer (always visible at same position)
        if currentIndex < directions.count {
            let direction = directions[currentIndex]
            
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
                    
                    // Direction text - more room for full instruction
                    VStack(alignment: .leading, spacing: 3) {
                        Text(direction.instruction)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        
                        // Compact info row
                        HStack(spacing: 6) {
                            Text(direction.distance)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))
                            
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
                    
                    // Static clinic delay OR walk duration (if no clinician selected)
                    VStack(alignment: .trailing, spacing: 0) {
                        if hasClinicianSelected {
                            Text("\(delayMinutes)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                            Text("mins delay")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                        } else {
                            Text("\(walkDurationMinutes)")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                            Text("min walk")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
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
    
    // Darker forest green color
    private let accentColor = Color(red: 0.13, green: 0.55, blue: 0.45)
    
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
                                              (index == currentIndex ? accentColor : Color.gray.opacity(0.2)))
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
                                    .foregroundColor(index == currentIndex ? accentColor : .secondary)
                                    .frame(width: 24)
                                
                                // Instruction
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(direction.instruction)
                                        .font(.subheadline)
                                        .foregroundColor(index == currentIndex ? .primary : .secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Text(direction.distance)
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
    
    // Animation state for polylines and POI markers
    @State private var visiblePolylines: [(id: UUID, coordinates: [CLLocationCoordinate2D], opacity: Double, isValid: Bool, poiName: String)] = []
    @State private var visiblePOIMarkers: [(id: UUID, coordinate: CLLocationCoordinate2D, name: String, opacity: Double)] = []
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    
    // v1.8.9: Stage display state - advances based on actual progress with minimum gaps
    @State private var displayedStageIndex: Int = 0  // 0 = none complete, 1-4 = stages complete
    @State private var lastStageAdvanceTime: Date = Date()
    @State private var hasCompletedAllStages: Bool = false
    
    // Stage-specific animation states
    @State private var radarPulseScale: CGFloat = 1.0  // Stage 0: Radar pulse
    @State private var poiIconsVisible: [Int] = []      // Stage 0: POI icons popping in
    @State private var footstepAngle: Double = 0        // Stage 2: Footstep walking angle
    @State private var showFootsteps: Bool = false      // Stage 2: Footstep visibility
    @State private var showSparkles: Bool = false       // Stage 3: Sparkle burst
    @State private var sparklePositions: [(id: UUID, offset: CGSize, opacity: Double, scale: CGFloat)] = []
    @State private var sparkleOrbitAngle: Double = 0    // Stage 3: Orbiting sparkles
    
    // Countdown timer for stage 1
    @State private var countdownSeconds: Int = 60
    @State private var countdownExpired: Bool = false
    
    // POI icons for the "finding places" animation
    private let poiIcons = ["☕", "🏪", "⛪", "🏛️", "🌳", "🎭"]
    
    private let minStageDisplayTime: TimeInterval = 1.2  // Minimum time to show each stage
    private let stageAdvanceDelay: TimeInterval = 0.5   // Delay between stage advances
    private let postCompletionDelay: TimeInterval = 0.3  // Reduced: Pause after stage 4 before preview
    
    // v1.8.10: Dynamic help text based on current stage
    private var loadingHelpText: String {
        switch displayedStageIndex {
        case 0: return "Scanning the area around you..."
        case 1: 
            if countdownExpired {
                return "Taking longer than expected. Please wait..."
            } else {
                return "This may take up to a minute..."
            }
        case 2: return "Almost there! Getting walking directions..."
        case 3: return "Adding the finishing touches..."
        default: return "Your route is ready!"
        }
    }
    
    var body: some View {
        ZStack {
            // Real map centered on user location
            if let location = userLocation {
                Map(position: $mapCameraPosition) {
                    // User location marker with stage-specific animations
                    Annotation("You", coordinate: location) {
                        userLocationMarkerView
                    }
                    
                    // Animated route polylines
                    ForEach(visiblePolylines, id: \.id) { polyline in
                        MapPolyline(coordinates: polyline.coordinates)
                            .stroke(
                                (polyline.isValid ? Color.green : Color.tealAccent).opacity(polyline.opacity),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                            )
                    }
                    
                    // Animated POI markers (no labels - just icons)
                    ForEach(visiblePOIMarkers, id: \.id) { marker in
                        Annotation("", coordinate: marker.coordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                                .opacity(marker.opacity)
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
                        // Stage 1: Finding places
                        stageRow(
                            icon: "mappin.and.ellipse",
                            title: "Finding places nearby",
                            isComplete: displayedStageIndex >= 1,
                            isActive: displayedStageIndex == 0
                        )
                        
                        // Stage 2: Calculating routes
                        stageRow(
                            icon: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath",
                            title: "Calculating routes",
                            isComplete: displayedStageIndex >= 2,
                            isActive: displayedStageIndex == 1,
                            subtitle: displayedStageIndex == 1 ? (countdownExpired ? "Sorry for the delay..." : "\(countdownSeconds)s remaining") : nil
                        )
                        
                        // Stage 3: Getting directions
                        stageRow(
                            icon: "arrow.triangle.turn.up.right.diamond",
                            title: "Getting directions",
                            isComplete: displayedStageIndex >= 3,
                            isActive: displayedStageIndex == 2
                        )
                        
                        // Stage 4: Naming route
                        stageRow(
                            icon: "sparkles",
                            title: "Naming your route",
                            isComplete: displayedStageIndex >= 4,
                            isActive: displayedStageIndex == 3
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
            print("🎬 Loading view appeared - starting at stage 0")
            
            // Start radar pulse animation for Stage 0
            startRadarPulseAnimation()
            // Start POI icons popping in for Stage 0
            startPOIIconsAnimation()
            
            // After minimum time, advance to stage 1
            advanceToStageWithMinDelay(1)
            
            // Stages advance based on actual progress, not time
            // Stage 0→1: After POI fetch (initial delay to show radar animation)
            // Stage 1→2: When route attempts start (triggered by attemptCount change)
            // Stage 2→3: When route is complete and directions fetched
            // Stage 3→4: When naming is complete
            
            // Initial advance from stage 0 to 1 after radar animation
            DispatchQueue.main.asyncAfter(deadline: .now() + minStageDisplayTime) {
                if displayedStageIndex == 0 && !hasCompletedAllStages {
                    print("🎬 Stage 0 → 1 (POI fetch assumed complete)")
                    advanceToStageWithMinDelay(1)
                }
            }
        }
        .onChange(of: displayedStageIndex) { oldValue, newValue in
            let stageNames = ["Finding places", "Calculating routes", "Getting directions", "Naming your route", "Complete"]
            let stageName = newValue < stageNames.count ? stageNames[newValue] : "Unknown"
            print("🎬 Stage changed: \(oldValue) → \(newValue) (\(stageName))")
            
            // Trigger stage-specific animations
            if newValue == 0 {
                // Stage 0: POI icons pop in
                startPOIIconsAnimation()
            }
            if newValue == 1 {
                // Stage 1: Route calculation spinning rings
                startRouteCalculationAnimation()
            }
            if newValue == 2 {
                // Stage 2: Footsteps walking
                startFootstepAnimation()
            }
            if newValue == 3 {
                // Stage 3: Sparkle burst with orbiting
                triggerSparkleAnimation()
            }
        }
        .onChange(of: attemptCount) { oldValue, newValue in
            // When route attempts start, POI fetch is done → stay on stage 1 (Calculating routes)
            // Stage 1 shows "This may take up to a minute..." during the long MapKit wait
            // We DON'T advance to stage 2 here - that happens when route is complete
            
            // Add polyline animation with POI marker (visual feedback during calculation)
            if let attempt = currentAttempt, !attempt.polylineCoordinates.isEmpty {
                addAnimatedPolyline(coordinates: attempt.polylineCoordinates, isValid: attempt.isValid, poiName: attempt.poiName)
            }
        }
        .onChange(of: isComplete) { _, newValue in
            // v1.8.9: When route is ready, advance through remaining stages with minimum gaps
            if newValue && !hasCompletedAllStages {
                print("🎬 Route complete → advancing through remaining stages")
                advanceToCompletionWithMinGaps()
            }
        }
    }
    
    // MARK: - Stage Row Helper
    
    @ViewBuilder
    private func stageRow(icon: String, title: String, isComplete: Bool, isActive: Bool, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            // Status indicator (checkmark or spinner)
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else if isActive {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.tealAccent)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.title3)
            }
            
            // Stage icon
            Image(systemName: icon)
                .foregroundColor(isComplete ? .green : (isActive ? .tealAccent : .secondary.opacity(0.5)))
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
        // Must go through stages 2, 3, 4 regardless of current stage
        let stagesToSchedule: [Int]
        if currentStage < 2 {
            stagesToSchedule = [2, 3, 4]  // From stage 0 or 1, go through 2, 3, 4
        } else if currentStage < 3 {
            stagesToSchedule = [3, 4]      // From stage 2, go through 3, 4
        } else if currentStage < 4 {
            stagesToSchedule = [4]          // From stage 3, just show 4
        } else {
            stagesToSchedule = []           // Already at 4
        }
        print("🏁 Stages to schedule: \(stagesToSchedule) (from current stage \(currentStage))")
        
        for targetStage in stagesToSchedule {
            let delay = cumulativeDelay
            let stageNames = ["Finding places", "Calculating routes", "Getting directions", "Naming your route", "Complete"]
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
            if displayedStageIndex == 1 {
                routeCalculationView
            }
            
            // Footstep animation (Stage 2 - Getting directions)
            if displayedStageIndex == 2 && showFootsteps {
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
    
    /// Start route calculation animation for Stage 1 (Calculating routes)
    private func startRouteCalculationAnimation() {
        footstepAngle = 0  // Reusing footstepAngle for rotation
        countdownSeconds = 60  // Reset countdown
        countdownExpired = false
        
        // Continuous rotation animation - faster for more active feel
        func rotate() {
            guard displayedStageIndex == 1 else { return }
            
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
    
    /// Countdown timer for stage 1
    private func startCountdownTimer() {
        func tick() {
            guard displayedStageIndex == 1 && !hasCompletedAllStages else { return }
            
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
            guard displayedStageIndex == 2 else {
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
                withAnimation(.easeInOut(duration: 0.3)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].scale = 0.8
                    }
                }
            }
            
            // Pulse larger again
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.7) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].scale = 1.0
                    }
                }
            }
            
            // Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.2) {
                withAnimation(.easeIn(duration: 0.4)) {
                    if index < sparklePositions.count {
                        sparklePositions[index].opacity = 0.0
                    }
                }
            }
        }
        
        // Start orbiting animation
        startSparkleOrbit()
        
        // Hide sparkles container after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
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

#Preview {
    RouteSelectionView(viewModel: WaitingRoomViewModel())
}



