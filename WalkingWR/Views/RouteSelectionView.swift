//
//  RouteSelectionView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import MapKit
import CoreLocation

struct RouteSelectionView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var showLocalRoutePicker: Bool
    @State private var selectedDifficulty: RouteDifficulty? = nil
    @State private var showIndoorOnly = false
    @State private var showAccessibleOnly = false
    @State private var showActiveWalk = false
    @State private var showHelpSheet = false
    @State private var localRouteDuration: Int = 10
    @State private var localRouteUseCustom = false
    
    init(viewModel: WaitingRoomViewModel, showLocalRoutePicker: Binding<Bool> = .constant(false)) {
        self.viewModel = viewModel
        self._showLocalRoutePicker = showLocalRoutePicker
    }
    
    // Calculate recommended duration based on delay time (with 5 min buffer)
    private var recommendedDuration: Int {
        let availableTime = viewModel.waitTimeInfo.estimatedMinutes - 5
        let presetOptions = [10, 15, 20, 25, 30]
        
        // Find the best preset option that fits within available time
        if let bestOption = presetOptions.reversed().first(where: { $0 <= availableTime }) {
            return bestOption
        }
        return 10 // Default to minimum if delay is very short
    }
    
    // Whether custom time should be auto-selected (delay > 35 min, i.e., 30 min walk + 5 min buffer)
    private var shouldUseCustom: Bool {
        viewModel.waitTimeInfo.estimatedMinutes > 35
    }
    
    // Custom duration value based on delay (with 6 min buffer)
    private var customDurationForDelay: Int {
        max(5, viewModel.waitTimeInfo.estimatedMinutes - 6)
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
                            } else {
                                // No clinician selected - show different message
                                NoClinicianBanner()
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
            .sheet(isPresented: $showLocalRoutePicker) {
                LocalRoutePickerSheet(
                    viewModel: viewModel,
                    locationService: viewModel.locationService,
                    selectedDuration: $localRouteDuration,
                    useCustomTime: $localRouteUseCustom,
                    isPresented: $showLocalRoutePicker
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
                    FeatureTag(icon: "clock", text: "5-30 min")
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
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [.tealAccent.opacity(0.5), .mintGreen.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
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
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
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
                        .background(Color(.quaternarySystemFill))
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
                                        .background(Color(.quaternarySystemFill))
                                        .clipShape(Capsule())
                                }
                                if route.landmarks.count > 5 {
                                    Text("+\(route.landmarks.count - 5) more")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(.quaternarySystemFill))
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
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(10)
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
                colors: [.clear, Color(.tertiarySystemBackground).opacity(0.3)],
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
    @State private var isGenerating = false
    @State private var isShuffling = false  // Separate state for shuffle loading
    @State private var generatedRoute: WalkingRoute?
    @State private var generatedRouteData: GeneratedRoute?
    @State private var showMapPreview = false
    @State private var errorMessage: String?
    @State private var customTimeValue: Double = 10  // Minimum 10 min - 5 min routes are unreliable
    
    
    // Store last valid route for recycling when shuffle exhausts options
    @State private var lastValidRoute: WalkingRoute?
    @State private var lastValidRouteData: GeneratedRoute?
    @State private var isRecycledRoute = false  // Indicates shuffle fell back to previous route
    @State private var shownPlaceIdSets: [Set<String>] = []  // Track all shown route combinations
    
    // Pre-generated routes for instant shuffling
    @State private var allRoutes: [(route: WalkingRoute, data: GeneratedRoute)] = []
    @State private var currentRouteIndex: Int = 0
    @State private var isPreGeneratingRoutes = false
    @State private var preGenerationComplete = false
    @State private var viewedRouteIndices: Set<Int> = []  // Track which routes user has seen
    @State private var showPremiumUpsell = false  // Show upgrade message when all routes viewed
    @State private var showLocationLimitAlert = false  // Show when free tier location limit reached
    
    // v1.6.25: Route deduplication - track unique route signatures
    @State private var routeSignatures: Set<String> = []  // Unique signatures: "sortedPOIIds|distanceBucket"
    @State private var varietyExhausted = false  // True when no more unique routes possible
    
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
                
                // Show shuffle loading overlay (or error with retry)
                if isShuffling {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.tealAccent)
                        
                        Text(mapsService.retryStatus ?? "Finding new route...")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .animation(.easeInOut, value: mapsService.retryStatus)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                } else if let error = errorMessage, generatedRoute == nil, showMapPreview {
                    // Shuffle failed - show error with retry
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
                } else if let route = generatedRoute, showMapPreview {
                    // Stage 2: Show map preview - full screen with solid background
                    // v1.6.28: Simplified - no permission gates before walk
                    LocalRouteMapPreview(
                        route: route,
                        userLocation: locationService.currentLocation?.coordinate,
                        generatedData: generatedRouteData,
                        isRecycled: isRecycledRoute,
                        targetDurationMinutes: selectedDuration,
                        currentRouteIndex: currentRouteIndex + 1,  // 1-based for display
                        totalRoutes: allRoutes.count,
                        isLoadingMoreRoutes: isPreGeneratingRoutes,
                        showPremiumUpsell: showPremiumUpsell,
                        hasLimitedPOIs: mapsService.hasLimitedPOIs,  // v1.6.10
                        varietyExhausted: varietyExhausted,  // v1.6.25
                        onStartWalk: {
                            // Start walk immediately - no permission gates
                            viewModel.selectRoute(route)
                            viewModel.startWalk()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isPresented = false
                            }
                        },
                        onShuffle: {
                            shuffleToNextRoute()
                        },
                        onDelete: {
                            // Delete the current route from the array
                            guard !allRoutes.isEmpty else { return }
                            
                            // Remove the current route
                            allRoutes.remove(at: currentRouteIndex)
                            
                            if allRoutes.isEmpty {
                                // No routes left - go back to options
                                generatedRoute = nil
                                generatedRouteData = nil
                                lastValidRoute = nil
                                lastValidRouteData = nil
                                shownPlaceIdSets = []
                                allRoutes = []
                                currentRouteIndex = 0
                                preGenerationComplete = false
                                viewedRouteIndices = []
                                resetRouteSignatures()  // v1.6.25: Clear signatures
                                showPremiumUpsell = false
                                showMapPreview = false
                                errorMessage = nil
                                print("🗑️ Deleted last route - returning to options")
                            } else {
                                // Show next available route (or previous if at end)
                                if currentRouteIndex >= allRoutes.count {
                                    currentRouteIndex = allRoutes.count - 1
                                }
                                let nextRoute = allRoutes[currentRouteIndex]
                                generatedRoute = nextRoute.route
                                generatedRouteData = nextRoute.data
                                print("🗑️ Deleted route - now showing \(currentRouteIndex + 1) of \(allRoutes.count)")
                            }
                        }
                    )
                    .background(Color(.systemBackground))
                } else {
                    // Stage 1: Duration picker
                    ScrollView {
                        VStack(spacing: 24) {
                            // Header
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.tealAccent.opacity(0.2))
                                        .frame(width: 80, height: 80)
                                    
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 36))
                                        .foregroundColor(.tealAccent)
                                }
                                
                                Text("Create Local Route")
                                    .font(.titleLarge)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                
                                Text("We'll find nearby points of interest and create a walking route")
                                    .font(.bodyMedium)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 20)
                            
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
                                        
                                        Slider(value: $customTimeValue, in: 10...60, step: 1)
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
                            
                            // Route info preview
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.mintGreen)
                                    Text("Circular loop route")
                                        .font(.caption)
                                        .foregroundColor(.mintGreen)
                                }
                                
                                Text("Your route will include approximately:")
                                    .font(.bodyMedium)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                HStack(spacing: 20) {
                                    RouteInfoItem(icon: "figure.walk", value: "~\(estimatedSteps)", label: "steps")
                                    RouteInfoItem(icon: "arrow.triangle.swap", value: "~\(estimatedDistance)m", label: "distance")
                                }
                                
                                Text("Returns you to your starting point")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(20)
                            .cardStyle()
                            
                            
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
                                    
                                    // Debug test button with location picker
                                    Menu {
                                        Section("Individual Tests") {
                                            Button("📍 Current Location") {
                                                runRouteGenerationTest(at: nil)
                                            }
                                            Button("🏙️ S5 7AU (Firth Park)") {
                                                runRouteGenerationTest(at: CLLocationCoordinate2D(latitude: 53.4115, longitude: -1.4577))
                                            }
                                            Button("🏘️ S11 9BF (Ecclesall)") {
                                                runRouteGenerationTest(at: CLLocationCoordinate2D(latitude: 53.3631, longitude: -1.4989))
                                            }
                                            Button("🏠 S12 4QN (Hackenthorpe)") {
                                                runRouteGenerationTest(at: CLLocationCoordinate2D(latitude: 53.3447, longitude: -1.3633))
                                            }
                                            Button("🌳 S35 0JW (Chapeltown)") {
                                                runRouteGenerationTest(at: CLLocationCoordinate2D(latitude: 53.4633, longitude: -1.4667))
                                            }
                                        }
                                        Section("Batch Test") {
                                            Button("🧪 TEST ALL LOCATIONS") {
                                                runAllLocationTests()
                                            }
                                        }
                                    } label: {
                                        if isRunningRouteTest {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        } else {
                                            Image(systemName: "testtube.2")
                                        }
                                    }
                                    .frame(width: 50, height: 50)
                                    .background(Color.purple.opacity(0.8))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .disabled(isRunningRouteTest)
                                }
                            }
                            
                            Spacer(minLength: 40)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationTitle("Local Route")
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
                            } label: {
                                Image(systemName: "doc.on.doc")
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
        // Sort place IDs for consistent comparison regardless of visit order
        let sortedIds = places.map { $0.placeId }.sorted().joined(separator: ",")
        
        // Distance bucket (100m granularity) to catch near-identical routes
        let distanceBucket = (distanceMeters / 100) * 100
        
        return "\(sortedIds)|\(distanceBucket)"
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
    func createPermutedRoute(from route: WalkingRoute, data: GeneratedRoute) -> (route: WalkingRoute, data: GeneratedRoute)? {
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
        
        return (permutedRoute, permutedData)
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
        guard let userLocation = locationService.currentLocation else { return }
        
        // Check location limit before generating (only if not already cached)
        let cacheService = POICacheService.shared
        if cacheService.getCachedPOIs(near: userLocation.coordinate) == nil {
            // No cached POIs - would need a new slot
            if !cacheService.canAddLocation(at: userLocation.coordinate) {
                showLocationLimitAlert = true
                print("🔒 Location limit reached - showing upgrade prompt")
                return
            }
        }
        
        isGenerating = true
        errorMessage = nil
        
        if mapsService.hasAPIKey {
            // Use Google APIs for smart routing
            Task {
                // CHECK CACHE FIRST (with movement detection)
                let shouldUseCache: Bool
                if let preGenLocation = preGeneratedAtLocation {
                    let distanceMoved = distanceBetweenCoordinates(userLocation.coordinate, preGenLocation)
                    shouldUseCache = distanceMoved <= movementThresholdMeters
                    if !shouldUseCache {
                        print("📍 User moved \(Int(distanceMoved))m (>\(Int(movementThresholdMeters))m) - skipping cache, regenerating fresh")
                    }
                } else {
                    shouldUseCache = true  // No pre-gen location yet, check cache anyway
                }
                
                if shouldUseCache, let cachedRoutes = RouteCacheService.shared.getCachedRoutes(near: userLocation.coordinate, durationMinutes: selectedDuration), !cachedRoutes.isEmpty {
                    print("📦 Using cached route for \(selectedDuration)min (user hasn't moved significantly)")
                    let cached = cachedRoutes[0]
                    
                    // Create route from cached data
                    let markers = await MainActor.run {
                        createMarkersFromPlaces(cached.route.places, origin: userLocation.coordinate)
                    }
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: cached.route.legs)
                    }
                    
                    // v1.6.14: If no directions in cache, get them from Apple MapKit
                    if directions.isEmpty && !cached.route.places.isEmpty {
                        print("🍎 Cached route has no directions - getting from MapKit...")
                        let waypointCoords = cached.route.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
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
                        walkingDirections: directions
                    )
                    
                    await MainActor.run {
                        isGenerating = false
                        generatedRoute = localRoute
                        generatedRouteData = cached.route
                        lastValidRoute = localRoute
                        lastValidRouteData = cached.route
                        allRoutes = [(route: localRoute, data: cached.route)]
                        currentRouteIndex = 0
                        isRecycledRoute = false
                        viewedRouteIndices = [0]
                        shownPlaceIdSets = [Set(cached.route.places.map { $0.placeId })]
                        showMapPreview = true
                        
                        // Still pre-generate more routes for this duration
                        preGenerateRemainingRoutes()
                    }
                    return
                }
                
                do {
                    // Use pre-fetched POIs if available (faster!)
                    let poisToUse = prefetchedPOIs.isEmpty ? nil : prefetchedPOIs
                    if poisToUse != nil {
                        print("⚡ Using pre-fetched POIs for instant route generation")
                    }
                    
                    let result = try await mapsService.generateLocalRouteWithRetry(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        prefetchedPOIs: poisToUse
                    )
                    
                    // Validate result
                    guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                        await MainActor.run {
                            errorMessage = "Could not find suitable places nearby. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                        }
                        return
                    }
                    
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
                    
                    // Extract walking directions from OSRM/Google legs
                    var directions = await MainActor.run {
                        extractWalkingDirections(from: result.legs)
                    }
                    
                    // v1.6.14: If no directions (OSRM was used), get them from Apple MapKit
                    if directions.isEmpty && !result.places.isEmpty {
                        print("🍎 No directions from route - getting from MapKit...")
                        let waypointCoords = result.places.map { $0.coordinate }
                        directions = await mapsService.getMapKitDirectionsForRoute(
                            origin: userLocation.coordinate,
                            waypoints: waypointCoords,
                            destination: userLocation.coordinate
                        )
                    }
                    
                    // Determine difficulty based on duration
                    let routeDifficulty: RouteDifficulty = result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging)
                    
                    // Generate AI-powered name and description with rich waypoint info
                    let waypointInfos = result.places.map { place in
                        GeminiService.WaypointInfo(
                            name: place.name,
                            types: place.types ?? [],
                            vicinity: place.vicinity
                        )
                    }
                    // Generate route name and description (always succeeds with template fallback)
                    let aiContent = await GeminiService.shared.generateRouteContent(
                        waypoints: waypointInfos,
                        durationMinutes: result.durationMinutes,
                        distanceMeters: result.distanceMeters,
                        difficulty: nil
                    )
                    
                    let routeName = aiContent.name
                    let description = aiContent.description
                    
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
                        walkingDirections: directions
                    )
                    
                    await MainActor.run {
                        isGenerating = false
                        generatedRoute = localRoute
                        generatedRouteData = result
                        // Save as last valid for recycling on shuffle
                        lastValidRoute = localRoute
                        lastValidRouteData = result
                        // Initialize route array with first route
                        allRoutes = [(route: localRoute, data: result)]
                        currentRouteIndex = 0
                        preGenerationComplete = false
                        isRecycledRoute = false  // First route is never recycled
                        viewedRouteIndices = [0]  // Mark first route as viewed
                        // Track place IDs for this route
                        let placeIds = Set(result.places.map { $0.placeId })
                        shownPlaceIdSets = [placeIds]
                        showMapPreview = true
                        
                        // Start pre-generating more routes in background
                        preGenerateRemainingRoutes()
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                        errorMessage = "Could not find a route within time limit. Try different options."
                        print("🗺️ Smart routing error: \(error)")
                    }
                }
            }
        } else {
            // Use basic generation (fallback)
            generateBasicRoute(from: userLocation.coordinate)
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
                            walkingDirections: directions
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
    
    /// Handle shuffle button press - cycles through pre-generated routes or triggers generation
    func shuffleToNextRoute() {
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
            print("🔀 Showing route \(currentRouteIndex + 1) of \(allRoutes.count) (recycled: \(isRecycledRoute))")
        } else if preGenerationComplete && currentRouteIndex >= allRoutes.count - 1 {
            // All routes have been shown, cycle back to start
            currentRouteIndex = 0
            let firstRoute = allRoutes[0]
            generatedRoute = firstRoute.route
            generatedRouteData = firstRoute.data
            isRecycledRoute = true  // Always recycled when cycling back
            showPremiumUpsell = true  // Show upgrade message when all routes viewed
            print("🔄 Cycling back to route 1 of \(allRoutes.count) - showing premium upsell")
        } else {
            // First shuffle or still generating - trigger new route generation
            isShuffling = true
            generatedRoute = nil
            generatedRouteData = nil
            errorMessage = nil
            
            // Start pre-generation in background if not already running
            if !isPreGeneratingRoutes && !preGenerationComplete {
                preGenerateRemainingRoutes()
            }
            
            // Generate next route
            generateRouteForShuffle()
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
                    
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration,
                        difficulty: nil,
                        excludePlaceIds: excludedPlaceIds,
                        prefetchedPOIs: poisToUse
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
                        walkingDirections: directions
                    )
                    
                    await MainActor.run {
                        allRoutes.append((route: route, data: result))
                        
                        // v1.6.25: Register route signature for deduplication
                        registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                        let placeIds = Set(result.places.map { $0.placeId })
                        shownPlaceIdSets.append(placeIds)
                        
                        routesGenerated = allRoutes.count
                        consecutiveFailures = 0  // Reset on success
                        print("✅ Pre-generated route \(routesGenerated) (unique: \(routeSignatures.count))")
                        
                        // v1.6.26: Try waypoint permutation for 2+ waypoint routes
                        if result.places.count >= 2 {
                            if let permuted = createPermutedRoute(from: route, data: result) {
                                allRoutes.append(permuted)
                                registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                routesGenerated = allRoutes.count
                                print("🔄 Added permuted route (reversed waypoints) - now \(routesGenerated) routes")
                            }
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
                                allRoutes.append((route: route, data: result))
                                
                                // v1.6.25: Register route signature for deduplication
                                registerRouteSignature(places: result.places, distanceMeters: result.distanceMeters)
                                shownPlaceIdSets.append(newPlaceIds)
                                
                                googleRoutesGenerated += 1
                                googleFailures = 0
                                print("🌐 ✅ Generated route \(allRoutes.count) (unique: \(routeSignatures.count)) using Google POIs")
                                
                                // v1.6.26: Try waypoint permutation for 2+ waypoint routes
                                if result.places.count >= 2 {
                                    if let permuted = createPermutedRoute(from: route, data: result) {
                                        allRoutes.append(permuted)
                                        registerRouteSignature(places: permuted.data.places, distanceMeters: permuted.data.distanceMeters)
                                        print("🔄 Added permuted Google route - now \(allRoutes.count) routes")
                                    }
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
        let gapDurations = [5, 45, 60]
        
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
            generatedRoute = localRoute
            generatedRouteData = nil
            showMapPreview = true
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
    
    /// Fixed test locations for batch testing
    private let fixedTestLocations: [(name: String, coordinate: CLLocationCoordinate2D)] = [
        ("S5 7AU (Firth Park)", CLLocationCoordinate2D(latitude: 53.4115, longitude: -1.4577)),
        ("S11 9BF (Ecclesall)", CLLocationCoordinate2D(latitude: 53.3631, longitude: -1.4989)),
        ("S12 4QN (Hackenthorpe)", CLLocationCoordinate2D(latitude: 53.3447, longitude: -1.3633)),
        ("S35 0JW (Chapeltown)", CLLocationCoordinate2D(latitude: 53.4633, longitude: -1.4667))
    ]
    
    /// Run tests for ALL locations sequentially (includes current location + fixed locations)
    func runAllLocationTests() {
        isRunningRouteTest = true
        
        // Build test locations list - current location first if available
        var allTestLocations: [(name: String, coordinate: CLLocationCoordinate2D)] = []
        
        if let userLocation = locationService.currentLocation {
            allTestLocations.append(("📍 Current Location", userLocation.coordinate))
        }
        allTestLocations.append(contentsOf: fixedTestLocations)
        
        routeTestResults = "🧪🧪🧪 BATCH TEST - ALL LOCATIONS 🧪🧪🧪\n"
        routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        routeTestResults += "Testing \(allTestLocations.count) locations...\n\n"
        
        Task {
            var allLocationSummaries: [(name: String, avgAccuracy: Double, validRate: Double, avgSpeed: Double, poiCount: Int)] = []
            
            for (index, location) in allTestLocations.enumerated() {
                await MainActor.run {
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
                
                routeTestResults += "\n📈 OVERALL AVERAGES:\n"
                routeTestResults += "   Accuracy: \(String(format: "%.0f%%", overallAvgAccuracy))\n"
                routeTestResults += "   Valid rate: \(String(format: "%.0f%%", overallValidRate))\n"
                routeTestResults += "   Speed: \(String(format: "%.1fs", overallAvgSpeed)) per route\n"
                
                routeTestResults += "\n🏁 Batch test complete!\n"
                
                isRunningRouteTest = false
                showRouteTestResults = true
            }
        }
    }
    
    /// Run test for a single location and return summary stats
    func runSingleLocationTest(coordinate: CLLocationCoordinate2D, name: String) async -> (avgAccuracy: Double, validRate: Double, avgSpeed: Double, poiCount: Int) {
        let durations = stride(from: 5, through: 60, by: 5).map { $0 }
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
        
        await MainActor.run {
            routeTestResults += "📦 POIs: \(poiCount)\n"
        }
        
        for duration in durations {
            var excludedPlaceIds = Set<String>()
            var consecutiveFailures = 0
            var routesForDuration: [(actual: Int, accuracy: Double, waypoints: String, distance: Int)] = []
            
            await MainActor.run {
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
                        let isValid = accuracy >= 80 && accuracy <= 120
                        
                        allResults.append((accuracy: accuracy, time: elapsed, isValid: isValid))
                        
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
                        let icon = isValid ? "✅" : (accuracy < 80 ? "📉" : "📈")
                        await MainActor.run {
                            routeTestResults += "  \(icon) R\(routeNum): \(actualMin)min (\(Int(accuracy))%) \(route.distanceMeters)m\n"
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
            
            // Duration summary
            let validForDuration = routesForDuration.filter { $0.accuracy >= 80 && $0.accuracy <= 120 }.count
            await MainActor.run {
                routeTestResults += "  📊 \(validForDuration)/\(routesForDuration.count) valid\n"
            }
        }
        
        // Calculate summary stats
        let avgAccuracy = allResults.isEmpty ? 0 : allResults.map { $0.accuracy }.reduce(0, +) / Double(allResults.count)
        let validCount = allResults.filter { $0.isValid }.count
        let validRate = allResults.isEmpty ? 0 : Double(validCount) / Double(allResults.count) * 100
        let avgSpeed = allResults.isEmpty ? 0 : allResults.map { $0.time }.reduce(0, +) / Double(allResults.count)
        
        await MainActor.run {
            routeTestResults += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            routeTestResults += "📊 \(name) SUMMARY:\n"
            routeTestResults += "   Routes: \(allResults.count) | Avg accuracy: \(String(format: "%.0f%%", avgAccuracy))\n"
            routeTestResults += "   Valid (80-120%): \(validCount)/\(allResults.count) (\(String(format: "%.0f%%", validRate)))\n"
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
        routeTestResults = "🧪 FULL ROUTE GENERATION TEST\n"
        routeTestResults += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        
        Task {
            let durations = stride(from: 5, through: 60, by: 5).map { $0 }
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
            
            for duration in durations {
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
                                
                                if accuracy >= 80 && accuracy <= 120 {
                                    status = "✅"
                                } else if accuracy >= 70 && accuracy <= 130 {
                                    status = "⚠️"
                                } else if accuracy < 70 {
                                    status = "📉"
                                } else {
                                    status = "📈"
                                }
                            }
                            
                            consecutiveFailures = 0
                            totalRoutesGenerated += 1
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
                
                // v1.6.25: Improved summary with honest counts
                await MainActor.run {
                    let validRoutes = routesForThisDuration.filter { $0.status == "✅" || $0.status == "⚠️" }.count
                    let exhaustedIndicator = varietyExhausted ? " (variety exhausted)" : ""
                    routeTestResults += "  📊 \(uniqueRoutesFound) unique / \(validRoutes) valid\(exhaustedIndicator)\n"
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
                routeTestResults += "⚠️ Marginal (70-130%):  \(marginal)\n"
                routeTestResults += "📉 Too short (<70%):    \(tooShort)\n"
                routeTestResults += "📈 Too long (>130%):    \(tooLong)\n"
                routeTestResults += "❌ Failed/Error:        \(failed)\n"
                
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
                
                routeTestResults += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                routeTestResults += "🕐 Test completed: \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))\n"
                
                isRunningRouteTest = false
                showRouteTestResults = true
            }
        }
    }
    
    func createMarkersFromPlaces(_ places: [PlaceResult], origin: CLLocationCoordinate2D) -> [QRMarker] {
        let wellbeingContent: [WellbeingContent] = [
            WellbeingContent.breathingExercises[0],
            WellbeingContent.breathingExercises[1],
            WellbeingContent.gratitudePrompts[0],
            WellbeingContent(title: "Mindful Moment", description: "Take a moment to notice your surroundings.", icon: "eye", duration: 60, steps: ["Look around slowly", "Name 5 things you see", "Notice colors and shapes", "Appreciate the details"]),
            WellbeingContent(title: "Local Discovery", description: "You've found an interesting spot!", icon: "star.fill", duration: 30, steps: ["Take in your surroundings", "What makes this place special?", "Take a photo if you like", "Appreciate the moment"])
        ]
        
        return places.enumerated().map { index, place in
            QRMarker(
                code: "POI\(index + 1)",
                name: place.name,
                location: place.vicinity ?? "Local POI",
                coordinate: place.coordinate,
                contentType: index % 2 == 0 ? .breathingExercise : .gratitudePrompt,
                content: wellbeingContent[index % wellbeingContent.count],
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
        
        let wellbeingContent: [WellbeingContent] = [
            WellbeingContent.breathingExercises[0],
            WellbeingContent.breathingExercises[1],
            WellbeingContent.gratitudePrompts[0],
            WellbeingContent.gratitudePrompts[1],
            WellbeingContent(title: "Mindful Moment", description: "Take a moment to notice 5 things you can see around you.", icon: "eye", duration: 60, steps: ["Look around slowly", "Name 5 things you see", "Notice colors and shapes", "Appreciate the details"])
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
            let contentIndex = i % wellbeingContent.count
            
            let marker = QRMarker(
                code: "LOCAL\(i + 1)",
                name: markerNames[nameIndex].0,
                location: markerNames[nameIndex].1,
                coordinate: markerCoord,
                contentType: i % 2 == 0 ? .breathingExercise : .gratitudePrompt,
                content: wellbeingContent[contentIndex],
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
    
    // v1.6.28: Removed permission callbacks - permissions now requested during/after walk
    let onStartWalk: () -> Void          // Start the walk immediately
    let onShuffle: () -> Void            // Quick regenerate with same settings
    let onDelete: () -> Void             // Delete current route from cache
    
    // v1.6.28: Simplified - no permission gates before walk
    // Permissions are now requested DURING the walk (optional step tracking)
    // and AFTER the walk (HealthKit sync option)
    
    var primaryButtonText: String {
        "Let's Go!"
    }
    
    var primaryButtonIcon: String {
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
        let allPoints = route.routePath
        print("🗺️ Map preview: routePath has \(allPoints.count) points, polyline length: \(route.encodedPolyline?.count ?? 0) chars")
        guard !allPoints.isEmpty else {
            if let loc = userLocation {
                return .region(MKCoordinateRegion(center: loc, latitudinalMeters: 500, longitudinalMeters: 500))
            }
            return .automatic
        }
        
        // Calculate bounds of all points
        let lats = allPoints.map { $0.latitude }
        let lngs = allPoints.map { $0.longitude }
        
        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLng = lngs.min()!
        let maxLng = lngs.max()!
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        
        // Add 20% padding
        let latSpan = (maxLat - minLat) * 1.3
        let lngSpan = (maxLng - minLng) * 1.3
        
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: max(0.005, latSpan), longitudeDelta: max(0.005, lngSpan))
        )
        
        return .region(region)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Map - with explicit camera position to show full route
            Map(initialPosition: mapCameraPosition) {
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
                
                // Route index indicator with sparse area warning (v1.6.25)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(currentRouteIndex) of \(totalRoutes)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        if isLoadingMoreRoutes {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("finding more...")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    
                    // v1.6.25: Sparse area warning - shown when variety exhausted
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Action buttons
                HStack(spacing: 10) {
                    // Shuffle - quick regenerate with same settings
                    Button(action: onShuffle) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.title3)
                                .fontWeight(.medium)
                            if totalRoutes > 1 {
                                Text("Next")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        }
                        .foregroundColor(.tealAccent)
                        .padding(.horizontal, totalRoutes > 1 ? 16 : 12)
                        .frame(height: 48)
                        .background(Color.tealAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
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
                            Image(systemName: primaryButtonIcon)
                            Text(primaryButtonText)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(color: primaryButtonColor))
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
                        
                        // Static clinic delay
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(viewModel.waitTimeInfo.estimatedMinutes)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                            Text("mins delay")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
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
                if !route.isIndoor && !route.walkingDirections.isEmpty {
                    WalkingDirectionsBanner(
                        directions: route.walkingDirections,
                        currentIndex: Binding(
                            get: { viewModel.locationService.currentDirectionIndex },
                            set: { viewModel.locationService.currentDirectionIndex = $0 }
                        ),
                        showAllDirections: $showAllDirections,
                        delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
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
                if showAllDirections, let route = viewModel.walkSession.currentRoute {
                    ExpandedDirectionsList(
                        directions: route.walkingDirections,
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
                    // Direction icon
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: direction.icon)
                            .font(.title3)
                            .fontWeight(.bold)
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
                    
                    // Static clinic delay
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(delayMinutes)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                        Text("mins delay")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
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
                        
                        // Wellbeing content from marker
                        if let marker = viewModel.currentMarker {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: marker.content.icon)
                                        .font(.title2)
                                        .foregroundColor(.tealAccent)
                                    
                                    Text(marker.content.title)
                                        .font(.bodyLarge)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                }
                                
                                Text(marker.content.description)
                                    .font(.bodyMedium)
                                    .foregroundColor(.primary)
                                
                                if let steps = marker.content.steps, !steps.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                            HStack(alignment: .top, spacing: 10) {
                                                Text("\(index + 1)")
                                                    .font(.caption)
                                                    .fontWeight(.bold)
                                                    .foregroundColor(.white)
                                                    .frame(width: 20, height: 20)
                                                    .background(Circle().fill(Color.tealAccent))
                                                
                                                Text(step)
                                                    .font(.bodyMedium)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                    .padding(.top, 8)
                                }
                            }
                            .padding(20)
                            .cardStyle()
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
        }
    }
}

#Preview {
    RouteSelectionView(viewModel: WaitingRoomViewModel())
}



