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
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                if viewModel.walkSession.isActive {
                    ActiveWalkView(viewModel: viewModel)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Time remaining banner
                            TimeRemainingBanner(minutes: viewModel.waitTimeInfo.estimatedMinutes)
                            
                            // Filters
                            RouteFilters(
                                selectedDifficulty: $selectedDifficulty,
                                showIndoorOnly: $showIndoorOnly,
                                showAccessibleOnly: $showAccessibleOnly
                            )
                            
                            // Route cards
                            VStack(spacing: 16) {
                                ForEach(filteredRoutes) { route in
                                    RouteCard(
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
                            
                            // Local Route option
                            LocalRouteCard(
                                onTap: { showLocalRoutePicker = true },
                                locationService: viewModel.locationService
                            )
                            
                            // Safety note
                            SafetyNoteView()
                            
                            // Sheffield Health Walks
                            SheffieldHealthWalksCard()
                            
                            Spacer(minLength: 100)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationTitle("Choose a Route")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
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
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.tealAccent, .mintGreen],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: "location.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Local Route")
                            .font(.bodyLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("NEW")
                            .font(.micro)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.tealAccent)
                            .clipShape(Capsule())
                    }
                    
                    Text("Create a custom walk from your current location")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if locationService.currentLocation != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.mintGreen)
                            Text("Location available")
                                .font(.caption2)
                                .foregroundColor(.mintGreen)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "location.slash")
                                .font(.caption2)
                                .foregroundColor(.softAmber)
                            Text("Tap to enable location")
                                .font(.caption2)
                                .foregroundColor(.softAmber)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Local Route Picker Sheet
struct LocalRoutePickerSheet: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @ObservedObject var locationService: LocationService // Direct observation for reactivity
    @Binding var selectedDuration: Int
    @Binding var isPresented: Bool
    @State private var isGenerating = false
    @State private var generatedRoute: WalkingRoute?
    @State private var showMapPreview = false
    
    let durationOptions = [5, 10, 15, 20, 25, 30]
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                if let route = generatedRoute, showMapPreview {
                    // Stage 2: Show map preview
                    LocalRouteMapPreview(
                        route: route,
                        userLocation: locationService.currentLocation?.coordinate,
                        onStartWalk: {
                            viewModel.selectRoute(route)
                            viewModel.startWalk()
                            isPresented = false
                        },
                        onRegenerate: {
                            generatedRoute = nil
                            showMapPreview = false
                        }
                    )
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
                                
                                Text("We'll generate discovery spots near your current location")
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
                                RouteInfoItem(icon: "figure.walk", value: "\(estimatedSteps)", label: "steps")
                                RouteInfoItem(icon: "mappin", value: "\(numberOfMarkers)", label: "spots")
                                RouteInfoItem(icon: "arrow.triangle.swap", value: "\(estimatedDistance)m", label: "distance")
                            }
                            
                            Text("Returns you to your starting point")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(20)
                        .cardStyle()
                        
                        // Location permission prompt (only shown if not authorized)
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
                                        
                                        Text(isDenied ? "Enable location in Settings to generate a route" : "We need your location to create a personalised route")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                                
                                if isDenied {
                                    // Location was denied - need to go to Settings
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
                                    // Not determined yet - can request permission directly
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
                        
                        // Generate button - only shown when location is authorized
                        if locationService.isAuthorized {
                            let locationReady = locationService.currentLocation != nil
                            
                            Button(action: generateRoute) {
                                HStack {
                                    if isGenerating {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
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
                            .buttonStyle(PrimaryButtonStyle(color: locationReady ? .tealAccent : .gray))
                            .disabled(!locationReady || isGenerating)
                        }
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                }
                } // End of else (Stage 1)
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
                // Always request fresh location when sheet opens (clears cache)
                locationService.requestFreshLocation()
            }
        }
    }
    
    // MARK: - Route Calculations
    
    var estimatedSteps: Int {
        // ~100 steps per minute of walking
        selectedDuration * 100
    }
    
    var numberOfMarkers: Int {
        // 1 marker per 5 minutes, minimum 3
        max(3, selectedDuration / 5)
    }
    
    var estimatedDistance: Int {
        // ~80 meters per minute
        selectedDuration * 80
    }
    
    func generateRoute() {
        guard let userLocation = locationService.currentLocation else { return }
        
        isGenerating = true
        
        // Generate markers around user's location
        let markers = generateLocalMarkers(
            around: userLocation.coordinate,
            count: numberOfMarkers,
            radiusMeters: Double(estimatedDistance) / 2
        )
        
        // Create the route
        let localRoute = WalkingRoute(
            name: "Local Discovery",
            description: "A circular route around your current location with \(markers.count) discovery spots. Returns you to your starting point.",
            durationMinutes: selectedDuration,
            distanceMeters: estimatedDistance,
            difficulty: selectedDuration <= 10 ? .easy : (selectedDuration <= 20 ? .moderate : .challenging),
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Start"] + markers.map { $0.name } + ["Return to Start"],
            icon: "location.fill",
            color: .tealAccent,
            qrMarkers: markers
        )
        
        // Show map preview
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isGenerating = false
            generatedRoute = localRoute
            showMapPreview = true
        }
    }
    
    func generateLocalMarkers(around center: CLLocationCoordinate2D, count: Int, radiusMeters: Double) -> [QRMarker] {
        var markers: [QRMarker] = []
        
        let markerNames = [
            ("Sunny Spot", "Open Area"),
            ("Quiet Corner", "Peaceful Space"),
            ("Nature View", "Scenic Point"),
            ("Rest Point", "Bench Area"),
            ("Green Space", "Garden Area"),
            ("Tree Grove", "Shaded Path"),
            ("Bird Watch", "Wildlife Spot"),
            ("Flower Bed", "Garden View"),
            ("Water Feature", "Fountain Area"),
            ("Meditation Point", "Calm Space")
        ]
        
        let wellbeingContent: [WellbeingContent] = [
            WellbeingContent.breathingExercises[0],
            WellbeingContent.breathingExercises[1],
            WellbeingContent.gratitudePrompts[0],
            WellbeingContent.gratitudePrompts[1],
            WellbeingContent(title: "Mindful Moment", description: "Take a moment to notice 5 things you can see around you.", icon: "eye", duration: 60, steps: ["Look around slowly", "Name 5 things you see", "Notice colors and shapes", "Appreciate the details"]),
            WellbeingContent(title: "Nature Connection", description: "Connect with the natural world around you.", icon: "leaf.fill", duration: 45, steps: ["Find something natural nearby", "Touch it gently if safe", "Notice its texture", "Take 3 deep breaths"])
        ]
        
        for i in 0..<count {
            // Generate points in a rough circle around the center
            let angle = (Double(i) / Double(count)) * 2 * .pi
            let randomRadius = radiusMeters * Double.random(in: 0.5...1.0)
            
            // Convert to coordinate offset (rough approximation)
            let latOffset = (randomRadius / 111000) * cos(angle) // ~111km per degree latitude
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
    let onStartWalk: () -> Void
    let onRegenerate: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Map
            Map {
                // User's starting location
                if let userLoc = userLocation {
                    Annotation("You", coordinate: userLoc) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 20, height: 20)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                        }
                    }
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
            
            // Bottom info panel
            VStack(spacing: 16) {
                // Route summary
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.name)
                            .font(.titleMedium)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                            Text("Circular loop")
                                .font(.caption)
                        }
                        .foregroundColor(.mintGreen)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(route.durationMinutes) min")
                            .font(.titleMedium)
                            .fontWeight(.bold)
                            .foregroundColor(.tealAccent)
                        
                        Text("\(route.qrMarkers.count) spots")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 12, height: 12)
                        Text("Your location")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.mintGreen)
                            .frame(width: 12, height: 12)
                        Text("Discovery spot")
                            .font(.caption)
                            .foregroundColor(.primary)
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
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
                
                Divider()
                    .frame(height: 24)
                
                // Indoor filter
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
            }
            .padding(.horizontal, 4)
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
                                
                                if isRecommended {
                                    Text("RECOMMENDED")
                                        .font(.micro)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.mintGreen)
                                        .clipShape(Capsule())
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
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4148, longitude: -1.4685)
    
    var body: some View {
        NavigationStack {
            Map {
                // Clinic marker
                Annotation("Clinic", coordinate: clinicCoordinate) {
                    ZStack {
                        Circle()
                            .fill(Color.coralPink)
                            .frame(width: 40, height: 40)
                        Image(systemName: "cross.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
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
                            Text(route.name)
                                .font(.titleMedium)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text("\(route.qrMarkers.count) discovery spots along this route")
                                .font(.caption)
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
                            Text("Clinic")
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
                        Spacer()
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding()
            }
            .navigationTitle("Route Map")
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

// MARK: - Safety Note
struct SafetyNoteView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundColor(.mintGreen)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Stay Safe")
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("We'll notify you when it's time to return. Stay within the marked route and head back if you feel unwell.")
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
        .padding(16)
        .cardStyle()
    }
}

// MARK: - Sheffield Health Walks Card
struct SheffieldHealthWalksCard: View {
    var body: some View {
        Link(destination: URL(string: "https://www.stepoutsheffield.co.uk")!) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "figure.walk.diamond.fill")
                        .font(.title2)
                        .foregroundColor(.tealAccent)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sheffield Health Walks")
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Free group walks led by trained volunteers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.tealAccent)
                }
                
                Text("Discover walks across Sheffield, from gentle strolls to more active routes. All free, friendly and welcoming.")
                    .font(.bodyMedium)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(20)
            .cardStyle()
        }
    }
}

// MARK: - Active Walk View
struct ActiveWalkView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var showEndConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Compact header with route info
            if let route = viewModel.walkSession.currentRoute {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name)
                            .font(.titleMedium)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        HStack(spacing: 8) {
                            Text("\(viewModel.walkSession.stepsThisSession) steps")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("•")
                                .foregroundColor(.white.opacity(0.5))
                            
                            Text("\(Int(viewModel.locationService.distanceWalked))m walked")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    
                    Spacer()
                    
                    // Timer
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatSeconds(viewModel.walkSession.elapsedSeconds))
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                        
                        // Halfway alert
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
            
            // Embedded Map
            EmbeddedWalkMapView(viewModel: viewModel)
                .frame(height: 350)
            
            // Bottom section with stats and end button
            VStack(spacing: 16) {
                // Compact stats row
                HStack(spacing: 12) {
                    CompactStatPill(icon: "figure.walk", value: "\(viewModel.walkSession.stepsThisSession)", label: "steps")
                    CompactStatPill(icon: "star.fill", value: "\(viewModel.userProgress.totalPoints)", label: "pts")
                    CompactStatPill(icon: "mappin", value: "\(viewModel.walkSession.markersScanned.count)", label: "spots")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                
                // End walk button
                Button(action: { showEndConfirmation = true }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("End Walk")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(color: .coralPink))
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
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


