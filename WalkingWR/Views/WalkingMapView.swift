//
//  WalkingMapView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import MapKit

struct WalkingMapView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var route: MKRoute?
    @State private var isLoadingRoute = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    // Clinic location (Longley Centre, Sheffield - S5 7JT)
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4148, longitude: -1.4685)
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Map
                Map(position: $cameraPosition) {
                    // User location
                    UserAnnotation()
                    
                    // Clinic marker
                    Annotation("Clinic", coordinate: clinicCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.coralPink)
                                .frame(width: 44, height: 44)
                            Image(systemName: "cross.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Next waypoint marker (if on a route)
                    if let route = viewModel.selectedRoute,
                       let nextWaypoint = nextWaypointCoordinate(for: route) {
                        Annotation("Next Stop", coordinate: nextWaypoint) {
                            ZStack {
                                Circle()
                                    .fill(Color.tealAccent)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    
                    // Discovery markers along the route
                    ForEach(viewModel.selectedRoute?.qrMarkers ?? [], id: \.id) { marker in
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
                    
                    // Show route polyline if available
                    if let route = route {
                        MapPolyline(route.polyline)
                            .stroke(Color.tealAccent, lineWidth: 5)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapUserLocationButton()
                    MapScaleView()
                }
                
                // Bottom info card
                VStack {
                    Spacer()
                    
                    WalkingInfoCard(
                        viewModel: viewModel,
                        route: route,
                        isLoadingRoute: isLoadingRoute,
                        onGetDirections: calculateRoute
                    )
                    .padding()
                }
            }
            .navigationTitle("Walking Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .onAppear {
                // Request location and calculate initial route
                viewModel.locationService.requestPermission()
                if viewModel.selectedRoute != nil {
                    calculateRoute()
                }
            }
        }
    }
    
    // Get the next waypoint coordinate based on current progress
    private func nextWaypointCoordinate(for route: WalkingRoute) -> CLLocationCoordinate2D? {
        guard !route.qrMarkers.isEmpty else { return nil }
        
        // For now, return the first unvisited marker or the clinic if all visited
        let visitedCount = viewModel.userProgress.qrScansCompleted
        if visitedCount < route.qrMarkers.count {
            return route.qrMarkers[visitedCount].coordinate
        }
        return clinicCoordinate // Head back to clinic
    }
    
    // Calculate walking route to next destination
    private func calculateRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation else {
            return
        }
        
        let destination: CLLocationCoordinate2D
        if let selectedRoute = viewModel.selectedRoute,
           let nextWaypoint = nextWaypointCoordinate(for: selectedRoute) {
            destination = nextWaypoint
        } else {
            destination = clinicCoordinate
        }
        
        isLoadingRoute = true
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            isLoadingRoute = false
            if let route = response?.routes.first {
                self.route = route
                
                // Adjust camera to show the route
                let rect = route.polyline.boundingMapRect
                cameraPosition = .rect(rect)
            }
        }
    }
}

// MARK: - Walking Info Card
struct WalkingInfoCard: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    let route: MKRoute?
    let isLoadingRoute: Bool
    let onGetDirections: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 16) {
            // Route info header
            HStack {
                if let selectedRoute = viewModel.selectedRoute {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedRoute.name)
                            .font(.titleMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("\(selectedRoute.distanceMeters)m • \(selectedRoute.durationMinutes) min")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                } else {
                    Text("No route selected")
                        .font(.titleMedium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Distance walked
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(viewModel.locationService.distanceWalked))m")
                        .font(.titleLarge)
                        .fontWeight(.bold)
                        .foregroundColor(.tealAccent)
                    Text("walked")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }
            
            Divider()
            
            // Directions to next point
            if let route = route {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.title)
                        .foregroundColor(.tealAccent)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next waypoint")
                            .font(.caption)
                            .foregroundColor(.primary)
                        Text("\(Int(route.distance))m away")
                            .font(.bodyMedium)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("~\(Int(route.expectedTravelTime / 60)) min walk")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button(action: onGetDirections) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.tealAccent)
                    }
                }
            } else if isLoadingRoute {
                HStack {
                    ProgressView()
                    Text("Calculating route...")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            } else {
                Button(action: onGetDirections) {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("Get Directions")
                    }
                    .font(.bodyMedium)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.tealAccent)
                    .cornerRadius(25)
                }
            }
            
            // v1.6.10: Prominent delay display with urgency colors
            DelayBanner(
                delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                walkStartTime: viewModel.walkSession.startTime
            )
            .padding(.top, 8)
        }
        .padding(20)
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 10, y: 5)
    }
}

// MARK: - Embedded Walk Map View (for inline display)
struct EmbeddedWalkMapView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var route: MKRoute?
    @State private var returnRoute: MKRoute?  // Route back to starting point
    @State private var isShowingReturnRoute: Bool = false  // Whether we're showing return directions
    @State private var hasPlayedIntro: Bool = false
    @State private var showingIntroOverlay: Bool = false
    @State private var introPhase: IntroPhase = .showingFirstWaypoint
    @State private var userInteractedWithMap: Bool = false  // Cancels intro animation
    @Environment(\.colorScheme) var colorScheme
    
    // v1.6.28: Opt-in step tracking state
    // Initialize to true if user has previously opted in and Motion is authorized
    @State private var isStepTrackingEnabled: Bool = false
    @State private var showMotionExplainer: Bool = false
    
    private var shouldAutoEnableSteps: Bool {
        viewModel.healthKitService.isMotionAuthorized && 
        UserDefaults.standard.bool(forKey: "stepTrackingAutoEnabled")
    }
    
    enum IntroPhase: String {
        case showingFirstWaypoint = "Your first destination"
        case showingFullRoute = "Your route"
        case followingUser = ""
    }
    
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4084, longitude: -1.4350)
    
    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                // Custom user location with heading arrow
                if let location = viewModel.locationService.currentLocation {
                    Annotation("You", coordinate: location.coordinate) {
                        ZStack {
                            // Outer glow
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 60, height: 60)
                            
                            // Direction arrow
                            Image(systemName: "location.north.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(viewModel.locationService.headingDegrees))
                            
                            // Center dot
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                } else {
                    UserAnnotation()
                }
                
                // Start/End marker (user's starting position or clinic)
                if let currentRoute = viewModel.walkSession.currentRoute,
                   let startPoint = currentRoute.routePath.first {
                    Annotation("Start/End", coordinate: startPoint) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                        }
                    }
                }
                
                // Route polyline from Google Directions
                if let currentRoute = viewModel.walkSession.currentRoute,
                   currentRoute.routePath.count >= 2 {
                    MapPolyline(coordinates: currentRoute.routePath)
                        .stroke(currentRoute.color, lineWidth: 4)
                }
                
                // ALL waypoint markers with NEXT one prominent
                if let currentRoute = viewModel.walkSession.currentRoute {
                    let visitedIds = viewModel.visitedMarkerIds
                    let markers = currentRoute.qrMarkers
                    
                    ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                        let isVisited = visitedIds.contains(marker.id)
                        let isNext = !isVisited && !markers.prefix(index).contains(where: { !visitedIds.contains($0.id) })
                        
                        Annotation(marker.name, coordinate: marker.coordinate) {
                            WaypointMarkerView(
                                name: marker.name,
                                index: index + 1,
                                isNext: isNext,
                                isVisited: isVisited
                            )
                        }
                    }
                }
                
                // Fallback: MKRoute polyline (for calculated routes)
                if let route = route {
                    MapPolyline(route.polyline)
                        .stroke(Color.tealAccent.opacity(0.5), lineWidth: 3)
                }
                
                // Return route polyline (directions back to start)
                if isShowingReturnRoute, let returnRoute = returnRoute {
                    MapPolyline(returnRoute.polyline)
                        .stroke(Color.blue, lineWidth: 5)
                }
            }
            .mapStyle(.standard)
            .mapControls {
                // Empty - we'll add custom controls in the overlay
            }
            
            // v1.6.20: Delay banner + compass in same row to save vertical space
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    // Delay banner on the left (doesn't fill entire width)
                    DelayBanner(
                        delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                        walkStartTime: viewModel.walkSession.startTime
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer()
                    
                    // Location button at far right
                    Button(action: {
                        withAnimation {
                            cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
                        }
                    }) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.tealAccent)
                            .frame(width: 44, height: 44)
                            .background(Color.darkCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.top, 8)
                
                // v1.6.28: Opt-in Steps Card
                StepsCard(
                    healthKitService: viewModel.healthKitService,
                    isStepTrackingEnabled: $isStepTrackingEnabled,
                    showMotionExplainer: $showMotionExplainer,
                    walkStartTime: viewModel.walkSession.startTime
                )
                .padding(.horizontal, 12)
                
                Spacer()
            }
            
            // Next waypoint info overlay - tappable and swipeable
            VStack {
                Spacer()
                
                if let currentRoute = viewModel.walkSession.currentRoute {
                    WaypointCarousel(
                        markers: currentRoute.qrMarkers,
                        visitedIds: viewModel.visitedMarkerIds,
                        startLocation: currentRoute.routePath.first,
                        onTapWaypoint: { coordinate in
                            zoomToWaypoint(coordinate)
                        },
                        onSelectReturnToStart: {
                            calculateReturnRoute()
                        },
                        colorScheme: colorScheme
                    )
                }
            }
            
            // v1.6.11: Delay change overlay
            if viewModel.showDelayChangeOverlay {
                DelayChangeOverlay(
                    oldMinutes: viewModel.waitTimeChangeInfo?.oldMinutes ?? 0,
                    newMinutes: viewModel.waitTimeChangeInfo?.newMinutes ?? viewModel.waitTimeInfo.estimatedMinutes,
                    isIncrease: viewModel.waitTimeChangeInfo?.isIncrease ?? false,
                    onDismiss: {
                        viewModel.showDelayChangeOverlay = false
                    },
                    onReturnNow: {
                        viewModel.showDelayChangeOverlay = false
                        calculateReturnRoute()
                    }
                )
            }
            
            // v1.6.28: Motion permission explainer (v1.6.29: Fixed dismissal)
            if showMotionExplainer {
                MotionPermissionExplainer(
                    onEnable: {
                        // v1.6.29: Dismiss first, then request permission
                        withAnimation(.easeOut(duration: 0.2)) {
                            showMotionExplainer = false
                        }
                        // Request Motion permission after a brief delay for smooth UX
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            viewModel.healthKitService.requestMotionAuthorization { granted in
                                DispatchQueue.main.async {
                                    if granted {
                                        isStepTrackingEnabled = true
                                        // Mark that step tracking was enabled for post-walk HealthKit offer
                                        viewModel.stepTrackingWasEnabled = true
                                        // Remember preference for future walks
                                        UserDefaults.standard.set(true, forKey: "stepTrackingAutoEnabled")
                                        // Start step tracking
                                        if let startTime = viewModel.walkSession.startTime {
                                            viewModel.healthKitService.startObservingSteps(from: startTime)
                                        }
                                    }
                                }
                            }
                        }
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showMotionExplainer = false
                        }
                    }
                )
                .transition(.opacity)
            }
            
            // Intro overlay during camera animation
            if showingIntroOverlay {
                VStack {
                    Spacer()
                    
                    HStack {
                        Image(systemName: introPhase == .showingFirstWaypoint ? "1.circle.fill" : 
                              introPhase == .showingFullRoute ? "map.fill" : "location.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                        
                        Text(introPhase.rawValue)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                }
                .transition(.opacity)
                .animation(.easeInOut, value: introPhase)
            }
        }
        .onAppear {
            if !hasPlayedIntro {
                playIntroAnimation()
            } else {
                calculateRoute()
            }
            
            // v1.6.28: Auto-enable step tracking if user has previously opted in
            if shouldAutoEnableSteps {
                isStepTrackingEnabled = true
            }
        }
    }
    
    /// Play the intro camera animation sequence with very smooth, slow transitions
    private func playIntroAnimation() {
        guard let currentRoute = viewModel.walkSession.currentRoute,
              let firstWaypoint = currentRoute.qrMarkers.first?.coordinate,
              let userLocation = viewModel.locationService.currentLocation?.coordinate else {
            // No waypoints or location, skip intro
            hasPlayedIntro = true
            cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            calculateRoute()
            return
        }
        
        hasPlayedIntro = true
        showingIntroOverlay = true
        
        // Very slow, ultra-smooth easeInOut animation
        let verySlowAnimation = Animation.easeInOut(duration: 2.5)
        
        // Phase 1: Slowly zoom to first waypoint
        introPhase = .showingFirstWaypoint
        withAnimation(verySlowAnimation) {
            cameraPosition = .region(MKCoordinateRegion(
                center: firstWaypoint,
                latitudinalMeters: 100,
                longitudinalMeters: 100
            ))
        }
        
        // Phase 2: Slowly zoom out to show full route (after 4 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard !userInteractedWithMap else { return }  // Skip if user interacted
            introPhase = .showingFullRoute
            
            // Calculate bounds for full route
            let allPoints = currentRoute.routePath
            if allPoints.count >= 2 {
                let lats = allPoints.map { $0.latitude }
                let lngs = allPoints.map { $0.longitude }
                let center = CLLocationCoordinate2D(
                    latitude: (lats.min()! + lats.max()!) / 2,
                    longitude: (lngs.min()! + lngs.max()!) / 2
                )
                let latSpan = (lats.max()! - lats.min()!) * 1.5
                let lngSpan = (lngs.max()! - lngs.min()!) * 1.5
                
                withAnimation(verySlowAnimation) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: max(0.01, latSpan), longitudeDelta: max(0.01, lngSpan))
                    ))
                }
            }
        }
        
        // Phase 3: Slowly ZOOM IN to user's current location (after 8 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            guard !userInteractedWithMap else { return }  // Skip if user interacted
            introPhase = .followingUser
            
            // ZOOMED IN view of current location (100m x 100m area)
            withAnimation(verySlowAnimation) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: userLocation,
                    latitudinalMeters: 100,
                    longitudinalMeters: 100
                ))
            }
        }
        
        // Phase 4: Hide overlay (after 11 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            withAnimation(.easeOut(duration: 1.0)) {
                showingIntroOverlay = false
            }
            if !userInteractedWithMap {
                calculateRoute()
            }
        }
    }
    
    /// Zoom to a specific waypoint (stays there until user interacts)
    func zoomToWaypoint(_ coordinate: CLLocationCoordinate2D) {
        // Cancel any ongoing intro animation
        userInteractedWithMap = true
        showingIntroOverlay = false
        
        let smoothAnimation = Animation.easeInOut(duration: 1.5)
        withAnimation(smoothAnimation) {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 150,
                longitudinalMeters: 150
            ))
        }
    }
    
    private func calculateRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation else { return }
        
        let destination: CLLocationCoordinate2D
        if let selectedRoute = viewModel.selectedRoute,
           !selectedRoute.qrMarkers.isEmpty {
            let visitedCount = viewModel.userProgress.qrScansCompleted
            if visitedCount < selectedRoute.qrMarkers.count {
                destination = selectedRoute.qrMarkers[visitedCount].coordinate
            } else {
                destination = clinicCoordinate
            }
        } else {
            destination = clinicCoordinate
        }
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                self.route = route
            }
        }
    }
    
    /// Calculate walking directions from current location back to starting point
    private func calculateReturnRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation,
              let currentRoute = viewModel.walkSession.currentRoute,
              let startPoint = currentRoute.routePath.first else {
            print("📍 Cannot calculate return route - missing location or start point")
            return
        }
        
        print("📍 Calculating return directions to start point...")
        isShowingReturnRoute = true
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let error = error {
                print("❌ Return directions error: \(error.localizedDescription)")
                return
            }
            
            if let route = response?.routes.first {
                self.returnRoute = route
                print("✅ Return route calculated: \(route.expectedTravelTime / 60) min, \(route.distance) meters")
            }
        }
    }
}

// MARK: - Compact Stat Pill
struct CompactStatPill: View {
    let icon: String
    let value: String
    let label: String
    var highlightColor: Color? = nil  // Optional highlight color for icon
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(highlightColor ?? .tealAccent)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(highlightColor ?? .primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 2)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Waypoint Carousel (Swipeable)
struct WaypointCarousel: View {
    let markers: [QRMarker]
    let visitedIds: Set<UUID>
    let startLocation: CLLocationCoordinate2D?
    let onTapWaypoint: (CLLocationCoordinate2D) -> Void
    let onSelectReturnToStart: (() -> Void)?  // Called when Return to Start is selected
    let colorScheme: ColorScheme
    
    @State private var selectedIndex: Int = 0
    
    // Get unvisited markers for display
    var unvisitedMarkers: [(index: Int, marker: QRMarker)] {
        markers.enumerated().compactMap { index, marker in
            visitedIds.contains(marker.id) ? nil : (index: index, marker: marker)
        }
    }
    
    // Total cards = waypoints + 1 (for return to start)
    var totalCards: Int {
        unvisitedMarkers.count + 1
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Swipe indicator dots (including Return to Start)
            if totalCards > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalCards, id: \.self) { i in
                        Circle()
                            .fill(i == selectedIndex ? (i == totalCards - 1 ? Color.blue : Color.orange) : Color.gray.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            
            // Swipeable cards
            TabView(selection: $selectedIndex) {
                // Waypoint cards
                ForEach(Array(unvisitedMarkers.enumerated()), id: \.element.marker.id) { cardIndex, item in
                    WaypointCard(
                        marker: item.marker,
                        waypointNumber: item.index + 1,
                        totalWaypoints: markers.count,
                        visitedCount: visitedIds.count,
                        isNext: cardIndex == 0,
                        isLast: false,
                        onTap: {
                            onTapWaypoint(item.marker.coordinate)
                        },
                        colorScheme: colorScheme
                    )
                    .tag(cardIndex)
                }
                
                // Return to Start card (final)
                ReturnToStartCard(
                    totalWaypoints: markers.count,
                    onTap: {
                        if let start = startLocation {
                            onTapWaypoint(start)
                        }
                        // Trigger return directions calculation
                        onSelectReturnToStart?()
                    },
                    colorScheme: colorScheme
                )
                .tag(unvisitedMarkers.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 90)
            .onChange(of: selectedIndex) { _, newIndex in
                // When swiping to a new waypoint, animate camera to it
                if newIndex < unvisitedMarkers.count {
                    let marker = unvisitedMarkers[newIndex].marker
                    onTapWaypoint(marker.coordinate)
                } else if newIndex == unvisitedMarkers.count, let start = startLocation {
                    // Return to Start card - calculate directions
                    onTapWaypoint(start)
                    onSelectReturnToStart?()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Return to Start Card
struct ReturnToStartCard: View {
    let totalWaypoints: Int
    let onTap: () -> Void
    let colorScheme: ColorScheme
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Finish indicator
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "flag.checkered")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Final destination")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    Text("Return to Start")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        Text("Back where you began")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Completion indicator
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    Text("finish")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(.systemGray6) : Color.white)
                    .shadow(color: .blue.opacity(0.2), radius: 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}

// MARK: - Waypoint Card (Individual)
struct WaypointCard: View {
    let marker: QRMarker
    let waypointNumber: Int
    let totalWaypoints: Int
    let visitedCount: Int
    let isNext: Bool
    let isLast: Bool  // Kept for compatibility but not used since we have ReturnToStartCard
    let onTap: () -> Void
    let colorScheme: ColorScheme
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Waypoint indicator
                ZStack {
                    Circle()
                        .fill(isNext ? Color.orange : Color.mintGreen)
                        .frame(width: 44, height: 44)
                    
                    VStack(spacing: 0) {
                        if isNext {
                            Image(systemName: "arrow.up")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        Text("\(waypointNumber)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNext ? "Next stop" : "Upcoming")
                        .font(.caption)
                        .foregroundColor(isNext ? .orange : .secondary)
                    
                    Text(marker.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text("\(waypointNumber) of \(totalWaypoints)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("Tap to view")
                            .font(.caption2)
                            .foregroundColor(.tealAccent)
                    }
                }
                
                Spacer()
                
                // Progress or swipe hint
                VStack(alignment: .trailing, spacing: 2) {
                    if isNext {
                        Text("\(visitedCount)/\(totalWaypoints)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                        
                        Text("visited")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "chevron.left.chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("swipe")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
            .cornerRadius(12)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 5)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Waypoint Marker View
struct WaypointMarkerView: View {
    let name: String
    let index: Int
    let isNext: Bool
    let isVisited: Bool
    
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            // Pulsing outer ring for NEXT waypoint
            if isNext {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 56, height: 56)
                    .scaleEffect(isPulsing ? 1.2 : 1.0)
                    .opacity(isPulsing ? 0.5 : 0.8)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear { isPulsing = true }
            }
            
            // Main marker circle
            Circle()
                .fill(markerColor)
                .frame(width: isNext ? 44 : 32, height: isNext ? 44 : 32)
                .shadow(color: isNext ? .orange.opacity(0.5) : .black.opacity(0.2), radius: isNext ? 6 : 2)
            
            // Icon or number
            if isVisited {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            } else if isNext {
                VStack(spacing: 0) {
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                        .fontWeight(.bold)
                    Text("\(index)")
                        .font(.caption2)
                        .fontWeight(.bold)
                }
                .foregroundColor(.white)
            } else {
                Text("\(index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
        }
    }
    
    var markerColor: Color {
        if isVisited {
            return .gray
        } else if isNext {
            return .orange
        } else {
            return .mintGreen
        }
    }
}

// MARK: - Preview
// MARK: - Delay Banner (v1.6.10)
/// Prominent delay display with color-coded urgency and progress bar
/// Uses TimelineView to guarantee updates every second
struct DelayBanner: View {
    let delayMinutes: Int
    let walkStartTime: Date?
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        // TimelineView guarantees refresh every second
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            DelayBannerContent(
                delayMinutes: delayMinutes,
                walkStartTime: walkStartTime,
                currentDate: context.date,
                colorScheme: colorScheme
            )
        }
        .onAppear {
            print("⏱️ DelayBanner appeared: \(delayMinutes)min delay, start: \(walkStartTime?.description ?? "nil")")
        }
    }
}

/// Inner content view for DelayBanner - receives currentDate from TimelineView
private struct DelayBannerContent: View {
    let delayMinutes: Int
    let walkStartTime: Date?
    let currentDate: Date
    let colorScheme: ColorScheme
    
    /// Time remaining until delay expires (in minutes)
    var timeRemaining: Int {
        guard let start = walkStartTime else { return delayMinutes }
        let elapsedSeconds = currentDate.timeIntervalSince(start)
        let elapsedMinutes = Int(elapsedSeconds / 60)
        return max(0, delayMinutes - elapsedMinutes)
    }
    
    /// Progress showing TIME REMAINING (1.0 = full time left, 0.0 = time's up)
    var progress: Double {
        guard delayMinutes > 0, let start = walkStartTime else { return 1.0 }
        let totalSeconds = Double(delayMinutes * 60)
        let elapsedSeconds = currentDate.timeIntervalSince(start)
        return max(0, 1.0 - (elapsedSeconds / totalSeconds))
    }
    
    /// Urgency level based on time remaining
    enum Urgency {
        case relaxed      // > 20 min
        case gentle       // 10-20 min
        case warning      // 5-10 min
        case urgent       // < 5 min
    }
    
    var urgency: Urgency {
        switch timeRemaining {
        case 21...: return .relaxed
        case 10...20: return .gentle
        case 5...9: return .warning
        default: return .urgent
        }
    }
    
    var urgencyColor: Color {
        switch urgency {
        case .relaxed: return .green
        case .gentle: return .softAmber
        case .warning: return .orange
        case .urgent: return .red
        }
    }
    
    var urgencyIcon: String {
        switch urgency {
        case .relaxed: return "clock.fill"
        case .gentle: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent: return "bell.badge.fill"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Urgency icon with pulse animation for urgent
            Image(systemName: urgencyIcon)
                .font(.title3)
                .foregroundColor(urgencyColor)
                .symbolEffect(.pulse, isActive: urgency == .urgent)
            
            // Time remaining
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(timeRemaining)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)
                Text("min remaining")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            // Compact progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(urgencyColor)
                        .frame(width: geo.size.width * progress, height: 6)
                }
            }
            .frame(width: 80, height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.darkCardBackground)
                .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
        )
    }
}

// MARK: - Delay Change Overlay (v1.6.11)
/// Full-screen overlay shown when delay changes mid-walk
struct DelayChangeOverlay: View {
    let oldMinutes: Int
    let newMinutes: Int
    let isIncrease: Bool
    let onDismiss: () -> Void
    let onReturnNow: () -> Void
    
    @State private var isAnimating = false
    
    var difference: Int {
        abs(newMinutes - oldMinutes)
    }
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            // Content card
            VStack(spacing: 24) {
                // Icon with animation
                ZStack {
                    Circle()
                        .fill(isIncrease ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .frame(width: 80, height: 80)
                        .scaleEffect(isAnimating ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
                    
                    Image(systemName: isIncrease ? "clock.badge.checkmark.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(isIncrease ? .green : .orange)
                }
                
                // Title
                Text(isIncrease ? "More Time!" : "Delay Shortened")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                // Time change visualization
                HStack(spacing: 16) {
                    VStack {
                        Text("\(oldMinutes)")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(.secondary)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: "arrow.right")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    VStack {
                        Text("\(newMinutes)")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(isIncrease ? .green : .orange)
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Difference badge
                HStack(spacing: 4) {
                    Image(systemName: isIncrease ? "plus" : "minus")
                    Text("\(difference) minutes")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isIncrease ? Color.green : Color.orange)
                .clipShape(Capsule())
                
                // Message
                Text(isIncrease 
                     ? "You have more time to explore. Enjoy your walk!"
                     : "The clinic is ready sooner. Consider heading back.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                // Action buttons
                VStack(spacing: 12) {
                    if !isIncrease {
                        // Show "Take Me Back" for decrease
                        Button(action: onReturnNow) {
                            HStack {
                                Image(systemName: "arrow.uturn.backward")
                                Text("Take Me Back")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.orange)
                            .cornerRadius(12)
                        }
                    }
                    
                    Button(action: onDismiss) {
                        Text(isIncrease ? "Got it!" : "Keep Walking")
                            .font(.headline)
                            .foregroundColor(isIncrease ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(isIncrease ? Color.green : Color.gray.opacity(0.2))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.systemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
            )
            .padding(.horizontal, 32)
        }
        .onAppear {
            isAnimating = true
            // Haptic feedback for delay change
            let impact = UIImpactFeedbackGenerator(style: isIncrease ? .medium : .heavy)
            impact.impactOccurred()
            
            // Additional notification sound for decrease (more urgent)
            if !isIncrease {
                let notification = UINotificationFeedbackGenerator()
                notification.notificationOccurred(.warning)
            }
        }
    }
}

// MARK: - Steps Card (v1.6.28, updated v1.6.29)
/// Opt-in step tracking card - disabled by default, requests Motion permission when tapped
/// v1.6.29: Added pulsing animation to draw attention when disabled
struct StepsCard: View {
    @ObservedObject var healthKitService: HealthKitService
    @Binding var isStepTrackingEnabled: Bool
    @Binding var showMotionExplainer: Bool
    let walkStartTime: Date?
    
    @Environment(\.colorScheme) var colorScheme
    
    // v1.6.29: Pulsing animation for disabled state
    @State private var isPulsing: Bool = false
    
    /// Current state of step tracking
    private var stepTrackingState: StepTrackingState {
        if !healthKitService.isPedometerAvailable {
            return .unavailable
        } else if healthKitService.isMotionDenied {
            return .denied
        } else if isStepTrackingEnabled && healthKitService.isMotionAuthorized {
            return .tracking
        } else {
            return .disabled
        }
    }
    
    enum StepTrackingState {
        case disabled    // User hasn't opted in yet
        case tracking    // Actively counting steps
        case denied      // User denied Motion permission
        case unavailable // Device doesn't support step counting
    }
    
    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconBackground)
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                
                // Content
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(titleColor)
                    
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Step count or action indicator
                if stepTrackingState == .tracking {
                    Text("\(healthKitService.stepCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.tealAccent)
                        .monospacedDigit()
                } else if stepTrackingState == .disabled {
                    // v1.6.29: "Tap" badge to draw attention
                    Text("Tap")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.tealAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tealAccent.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
            // v1.6.29: Pulsing opacity effect when disabled to draw attention
            .opacity(stepTrackingState == .disabled ? (isPulsing ? 0.7 : 1.0) : 1.0)
            .animation(
                stepTrackingState == .disabled
                    ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
        }
        .buttonStyle(.plain)
        .disabled(stepTrackingState == .unavailable)
        .onAppear {
            // Start pulsing animation if disabled
            if stepTrackingState == .disabled {
                isPulsing = true
            }
        }
        .onChange(of: stepTrackingState) { newState in
            // Stop pulsing when state changes from disabled
            isPulsing = newState == .disabled
        }
    }
    
    private func handleTap() {
        switch stepTrackingState {
        case .disabled:
            // Show explainer modal before requesting permission
            showMotionExplainer = true
        case .tracking:
            // Already tracking - could show more details
            break
        case .denied:
            // Open Settings
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .unavailable:
            break
        }
    }
    
    // MARK: - Appearance
    
    private var iconName: String {
        switch stepTrackingState {
        case .disabled: return "figure.walk"
        case .tracking: return "figure.walk.motion"
        case .denied: return "xmark.circle"
        case .unavailable: return "figure.walk"
        }
    }
    
    private var iconBackground: Color {
        switch stepTrackingState {
        case .disabled: return Color.gray.opacity(0.2)
        case .tracking: return Color.tealAccent.opacity(0.2)
        case .denied: return Color.orange.opacity(0.2)
        case .unavailable: return Color.gray.opacity(0.1)
        }
    }
    
    private var iconColor: Color {
        switch stepTrackingState {
        case .disabled: return .secondary
        case .tracking: return .tealAccent
        case .denied: return .orange
        case .unavailable: return .gray
        }
    }
    
    private var titleText: String {
        switch stepTrackingState {
        case .disabled: return "Steps"
        case .tracking: return "Steps"
        case .denied: return "Steps unavailable"
        case .unavailable: return "Steps not available"
        }
    }
    
    private var subtitleText: String {
        switch stepTrackingState {
        case .disabled: return "Tap to enable steps"
        case .tracking: return "Tracking your walk"
        case .denied: return "Enable Motion in Settings"
        case .unavailable: return "Device doesn't support step tracking"
        }
    }
    
    private var titleColor: Color {
        switch stepTrackingState {
        case .disabled: return .primary
        case .tracking: return .primary
        case .denied: return .orange
        case .unavailable: return .gray
        }
    }
    
    private var cardBackground: Color {
        colorScheme == .dark ? Color.darkCardBackground : Color.white
    }
}

// MARK: - Motion Permission Explainer (v1.6.28)
/// In-app explainer shown before requesting Motion permission
struct MotionPermissionExplainer: View {
    let onEnable: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            
            VStack(spacing: 20) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.tealAccent.opacity(0.15))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.tealAccent)
                }
                
                // Title
                Text("Track Your Steps")
                    .font(.title2)
                    .fontWeight(.bold)
                
                // Description
                Text("We use Motion & Fitness to count steps during your walk. This data stays on your device.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Privacy note
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.tealAccent)
                    
                    Text("Step data is processed locally")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.tealAccent.opacity(0.1))
                .clipShape(Capsule())
                
                // Buttons
                VStack(spacing: 12) {
                    Button(action: onEnable) {
                        Text("Enable Step Tracking")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.tealAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    
                    Button(action: onCancel) {
                        Text("Not now")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.systemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - HealthKit Sync Offer Sheet (v1.6.28)
/// Post-walk opt-in for HealthKit read/write access
struct HealthKitSyncOfferSheet: View {
    @ObservedObject var healthKitService: HealthKitService
    @Binding var isPresented: Bool
    
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Handle bar
            Capsule()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
            
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "heart.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.red)
            }
            
            // Title
            Text("Sync with Apple Health?")
                .font(.title2)
                .fontWeight(.bold)
            
            // Description
            VStack(spacing: 12) {
                Text("This lets us save your steps and read your step history so your walks are more accurate and consistent across sessions.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("You can change this anytime in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            // Benefits
            VStack(alignment: .leading, spacing: 12) {
                benefitRow(icon: "arrow.up.arrow.down", text: "Sync steps with Apple Health")
                benefitRow(icon: "clock.arrow.circlepath", text: "Track your step history")
                benefitRow(icon: "chart.line.uptrend.xyaxis", text: "Improve walk accuracy")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            
            Spacer()
            
            // Buttons
            VStack(spacing: 12) {
                Button(action: syncWithHealthKit) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Sync with Apple Health")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                }
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(isLoading)
                
                Button(action: declineOffer) {
                    Text("Not now")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
    
    private func declineOffer() {
        // Remember that user declined so we don't re-prompt
        UserDefaults.standard.set(true, forKey: "healthKitSyncOfferDeclined")
        isPresented = false
    }
    
    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.red)
                .frame(width: 24)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
    
    private func syncWithHealthKit() {
        isLoading = true
        Task {
            let granted = await healthKitService.requestAuthorization()
            await MainActor.run {
                isLoading = false
                if granted {
                    // Mark as synced - future walks will auto-save
                    UserDefaults.standard.set(true, forKey: "healthKitSyncEnabled")
                }
                isPresented = false
            }
        }
    }
}

#Preview {
    WalkingMapView(viewModel: WaitingRoomViewModel())
}

