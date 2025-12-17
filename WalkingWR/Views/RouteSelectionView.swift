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
    @State private var selectedDifficulty: RouteDifficulty? = nil
    @State private var showIndoorOnly = false
    @State private var showAccessibleOnly = false
    @State private var showActiveWalk = false
    @State private var showHelpSheet = false
    @State private var showLocalRoutePicker = false
    @State private var localRouteDuration: Int = 10
    @State private var showEndWalkConfirmation = false
    
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
                    ActiveWalkView(viewModel: viewModel, showEndConfirmation: $showEndWalkConfirmation)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Time remaining banner
                            TimeRemainingBanner(minutes: viewModel.waitTimeInfo.estimatedMinutes)
                            
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
                    isPresented: $showLocalRoutePicker
                )
            }
            .sheet(isPresented: $viewModel.showMarkerArrivalPrompt) {
                MarkerArrivalSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showPreWalkWellbeing) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $viewModel.showPreWalkWellbeing, isPostWalk: false)
            }
            .sheet(isPresented: $viewModel.showPostWalkWellbeing) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $viewModel.showPostWalkWellbeing, isPostWalk: true, isWalkActivity: true)
            }
            .alert("Time to Head Back!", isPresented: $viewModel.showHalfwayAlert) {
                Button("Got it") { }
            } message: {
                Text("You've reached the halfway point. Start heading back to reception.")
            }
            .alert("Return Now", isPresented: $viewModel.showReturnAlert) {
                Button("End Walk") {
                    viewModel.endWalk(completed: true)
                }
            } message: {
                Text("Your route is complete. Please return to the waiting area.")
            }
            .confirmationDialog("End Walk?", isPresented: $showEndWalkConfirmation) {
                Button("End & Save Progress") {
                    viewModel.endWalk(completed: true)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your steps and progress will be saved.")
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
    
    var body: some View {
        Button(action: onSelect) {
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
                
                // Go button
                Text("Go")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(route.color)
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
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
    @Binding var isPresented: Bool
    @State private var isGenerating = false
    @State private var generatedRoute: WalkingRoute?
    @State private var generatedRouteData: GeneratedRoute?
    @State private var showMapPreview = false
    @State private var errorMessage: String?
    
    let durationOptions = [5, 10, 15, 20, 25, 30]
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                if let route = generatedRoute, showMapPreview {
                    // Stage 2: Show map preview - full screen with solid background
                    LocalRouteMapPreview(
                        route: route,
                        userLocation: locationService.currentLocation?.coordinate,
                        generatedData: generatedRouteData,
                        onStartWalk: {
                            viewModel.selectRoute(route)
                            viewModel.startWalk()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isPresented = false
                            }
                        },
                        onRegenerate: {
                            generatedRoute = nil
                            generatedRouteData = nil
                            showMapPreview = false
                            errorMessage = nil
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
                                            isSelected: selectedDuration == duration,
                                            onSelect: { selectedDuration = duration }
                                        )
                                    }
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
                                
                                Text("Your route will include:")
                                    .font(.bodyMedium)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                HStack(spacing: 20) {
                                    RouteInfoItem(icon: "figure.walk", value: "~\(estimatedSteps)", label: "steps")
                                    RouteInfoItem(icon: "mappin", value: "\(numberOfMarkers)", label: "spots")
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
            }
        }
    }
    
    // MARK: - Route Calculations
    
    var estimatedSteps: Int {
        selectedDuration * 100
    }
    
    var numberOfMarkers: Int {
        max(2, min(4, selectedDuration / 5))
    }
    
    var estimatedDistance: Int {
        selectedDuration * 80
    }
    
    func generateRoute() {
        guard let userLocation = locationService.currentLocation else { return }
        
        isGenerating = true
        errorMessage = nil
        
        if mapsService.hasAPIKey {
            // Use Google APIs for smart routing
            Task {
                do {
                    let result = try await mapsService.generateLocalRoute(
                        from: userLocation.coordinate,
                        targetDurationMinutes: selectedDuration
                    )
                    
                    await MainActor.run {
                        // Validate result
                        guard !result.places.isEmpty, result.distanceMeters > 0, result.durationSeconds > 0 else {
                            errorMessage = "Could not find suitable places nearby. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                            return
                        }
                        
                        // Create markers from places
                        let markers = createMarkersFromPlaces(result.places, origin: userLocation.coordinate)
                        
                        // Ensure we have at least one marker
                        guard !markers.isEmpty else {
                            errorMessage = "No discovery spots could be created. Using basic route."
                            generateBasicRoute(from: userLocation.coordinate)
                            return
                        }
                        
                        // Extract walking directions from all legs
                        let directions = extractWalkingDirections(from: result.legs)
                        
                        // Create the walking route with actual polyline and directions
                        let localRoute = WalkingRoute(
                            name: "Local Discovery",
                            description: "A \(result.formattedDuration) walk passing \(result.places.count) local points of interest. Verified walking route.",
                            durationMinutes: max(1, result.durationMinutes), // Ensure at least 1 min
                            distanceMeters: result.distanceMeters,
                            difficulty: result.durationMinutes <= 10 ? .easy : (result.durationMinutes <= 20 ? .moderate : .challenging),
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
                        
                        isGenerating = false
                        generatedRoute = localRoute
                        generatedRouteData = result
                        showMapPreview = true
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                        let errorDesc = (error as? GoogleMapsError)?.errorDescription ?? error.localizedDescription
                        errorMessage = "Smart routing failed: \(errorDesc). Using basic route."
                        print("🗺️ Smart routing error: \(error)")
                        // Fall back to basic generation
                        generateBasicRoute(from: userLocation.coordinate)
                    }
                }
            }
        } else {
            // Use basic generation (fallback)
            generateBasicRoute(from: userLocation.coordinate)
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
        
        for leg in legs {
            guard let steps = leg.steps else { continue }
            
            for step in steps {
                guard let html = step.htmlInstructions else { continue }
                
                // Extract maneuver from HTML if present (e.g., "turn-left")
                let maneuver = extractManeuver(from: html)
                
                let direction = WalkingDirection.fromHTML(
                    html,
                    distance: step.distance.text,
                    distanceMeters: step.distance.value,
                    duration: step.duration.text,
                    maneuver: maneuver
                )
                
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
    let onStartWalk: () -> Void
    let onRegenerate: () -> Void
    
    var hasRealPolyline: Bool {
        route.encodedPolyline != nil && !route.encodedPolyline!.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Map
            Map {
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
                if hasRealPolyline, route.routePath.count >= 2 {
                    MapPolyline(coordinates: route.routePath)
                        .stroke(route.color, lineWidth: 4)
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
                            
                            if hasRealPolyline {
                                HStack(spacing: 2) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption2)
                                    Text("OK")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.mintGreen)
                                .clipShape(Capsule())
                                .fixedSize()
                            }
                        }
                        
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                            Text(hasRealPolyline ? "Walking route verified" : "Circular loop")
                                .font(.caption)
                        }
                        .foregroundColor(.mintGreen)
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
                
                // Action buttons
                HStack(spacing: 12) {
                    Button(action: onRegenerate) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Try Another")
                        }
                        .font(.bodyMedium)
                        .fontWeight(.medium)
                        .foregroundColor(.tealAccent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.tealAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onStartWalk) {
                        HStack {
                            Image(systemName: "figure.walk")
                            Text("Let's Go!")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
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
    @Binding var showEndConfirmation: Bool
    @State private var showAllDirections: Bool = false
    
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
                        
                        // Timer
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatSeconds(viewModel.walkSession.elapsedSeconds))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                            
                            if viewModel.walkSession.halfwayAlertSent {
                                Text("Head back!")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.softAmber)
                            }
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
                        elapsedTime: formatSeconds(viewModel.walkSession.elapsedSeconds),
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
                // Compact stats row
                HStack(spacing: 12) {
                    CompactStatPill(icon: "figure.walk", value: "\(viewModel.walkSession.stepsThisSession)", label: "steps")
                    CompactStatPill(icon: "star.fill", value: "\(viewModel.userProgress.totalPoints)", label: "pts")
                    CompactStatPill(icon: "mappin", value: "\(viewModel.walkSession.markersScanned.count)", label: "spots")
                }
                .padding(.horizontal, 20)
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
    var elapsedTime: String = ""
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
                    
                    // Timer on right
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(elapsedTime)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                        
                        // Step counter
                        Text("\(currentIndex + 1)/\(directions.count)")
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



