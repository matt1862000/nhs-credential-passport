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
            
            // v1.6.10: Prominent delay display with urgency colors (static, no countdown)
            // Shows "X mins delay" if clinician selected, "X min walk" otherwise
            DelayBanner(
                delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                walkDurationMinutes: viewModel.selectedRoute?.durationMinutes ?? 0,
                hasClinicianSelected: viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable
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
    
    // v1.9.0: Turn navigation enhancements
    @State private var isApproachingTurn: Bool = false
    @State private var distanceToNextTurn: Double? = nil
    
    /// Check if user previously opted into step tracking
    /// We trust the UserDefaults flag - if permission was revoked, we'll handle it when pedometer fails
    private var shouldAutoEnableSteps: Bool {
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
                
                // Start/End marker (user's actual GPS position when walk started)
                // v1.6.48: Use walkSession.startLocation to avoid GPS drift between route generation and walk start
                if let startPoint = viewModel.walkSession.startLocation ?? viewModel.walkSession.currentRoute?.routePath.first {
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
                
                // Route polyline from Google Directions (primary)
                // v1.9.5: Show only current leg segment once walk has truly started
                if let currentRoute = viewModel.walkSession.currentRoute,
                   currentRoute.routePath.count >= 2 {
                    // Show full route during intro phases, current leg when actively walking
                    let polylineToShow: [CLLocationCoordinate2D] = {
                        if introPhase == .followingUser,
                           let currentLocation = viewModel.locationService.currentLocation {
                            return currentLegPolyline(
                                fullPath: currentRoute.routePath,
                                currentLocation: currentLocation.coordinate,
                                markers: currentRoute.qrMarkers,
                                visitedIds: viewModel.visitedMarkerIds,
                                startLocation: viewModel.walkSession.startLocation
                            )
                        } else {
                            return currentRoute.routePath
                        }
                    }()
                    
                    MapPolyline(coordinates: polylineToShow)
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
                
                // Fallback: MKRoute polyline (ONLY if Google Directions routePath is NOT available)
                // v1.9.1: Fixed to prevent duplicate polylines when Google Directions is used
                // Only show MKRoute if we don't have Google Directions data
                if let route = route {
                    let hasGoogleDirections = viewModel.walkSession.currentRoute?.routePath.count ?? 0 >= 2
                    if !hasGoogleDirections {
                        MapPolyline(route.polyline)
                            .stroke(Color.tealAccent.opacity(0.5), lineWidth: 3)
                    }
                }
                
                // Return route polyline (directions back to start)
                if isShowingReturnRoute, let returnRoute = returnRoute {
                    MapPolyline(returnRoute.polyline)
                        .stroke(Color.blue, lineWidth: 5)
                }
                
                // v1.9.5: Removed turn arrow annotations - current leg polyline makes direction clear
            }
            .mapStyle(.standard)
            .mapControls {
                // Empty - we'll add custom controls in the overlay
            }
            
            // v1.6.31: Compact status ring in top-left corner (saves vertical space)
            // ROLLBACK: Comment out this VStack and uncomment the one below to restore banner
            VStack {
                HStack(alignment: .top) {
                    // Compact activity ring showing delay/steps (top-left)
                    CompactStatusRing(
                        walkDurationMinutes: viewModel.walkSession.currentRoute?.durationMinutes ?? 15,
                        walkStartTime: viewModel.walkSession.startTime,
                        healthKitService: viewModel.healthKitService,
                        isStepTrackingEnabled: $isStepTrackingEnabled,
                        showMotionExplainer: $showMotionExplainer,
                        hasClinicianSelected: viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable  // v1.6.45
                    )
                    
                    Spacer()
                    
                    // Location button (top-right)
                    // v1.9.10: Shows full route overview first, then returns to following
                    Button(action: {
                        showFullRouteThenFollow()
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
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                Spacer()
            }
            
            /* ROLLBACK: Uncomment this to restore the banner layout
            // v1.6.30: Combined status banner (delay + steps) to save vertical space
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    // Combined delay + steps banner on the left
                    CombinedStatusBanner(
                        delayMinutes: viewModel.waitTimeInfo.estimatedMinutes,
                        healthKitService: viewModel.healthKitService,
                        isStepTrackingEnabled: $isStepTrackingEnabled,
                        showMotionExplainer: $showMotionExplainer
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
                
                Spacer()
            }
            */
            
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
        // v1.9.0: Auto-zoom when approaching turn (within 30m)
        .onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
            guard let location = newLocation,
                  let nextTurnCoord = viewModel.locationService.nextTurnCoordinate else {
                isApproachingTurn = false
                distanceToNextTurn = nil
                return
            }
            
            let distance = location.distance(from: CLLocation(latitude: nextTurnCoord.latitude, longitude: nextTurnCoord.longitude))
            distanceToNextTurn = distance
            
            // Auto-zoom when within 30m of turn
            if distance <= 30 && !isApproachingTurn {
                isApproachingTurn = true
                zoomToTurn(nextTurnCoord)
            } else if distance > 30 && isApproachingTurn {
                isApproachingTurn = false
                // Return to normal zoom after passing turn
                if !userInteractedWithMap {
                    withAnimation(.easeInOut(duration: 1.0)) {
                        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
                    }
                }
            }
        }
        // v1.6.30: Motion permission explainer as fullScreenCover for reliable dismissal
        .fullScreenCover(isPresented: $showMotionExplainer) {
            MotionPermissionExplainerSheet(
                onEnable: {
                    print("🔵 Enable tapped - setting all step tracking flags immediately")
                    
                    // Set ALL flags immediately for instant UI feedback
                    // The iOS permission dialog can interrupt callbacks, so we trust user intent
                                    isStepTrackingEnabled = true
                                    viewModel.stepTrackingWasEnabled = true
                                    UserDefaults.standard.set(true, forKey: "stepTrackingAutoEnabled")
                    showMotionExplainer = false
                    
                    // Start observing steps immediately (this will trigger permission if needed)
                                    if let startTime = viewModel.walkSession.startTime {
                                        viewModel.healthKitService.startObservingSteps(from: startTime)
                                    }
                    
                    print("🔵 All flags set: isStepTrackingEnabled=true, stepTrackingWasEnabled=true, UserDefaults saved")
                },
                onCancel: {
                    print("🔵 Cancel tapped")
                    showMotionExplainer = false
                }
            )
        }
    }
    
    /// Play the intro camera animation sequence with very smooth, slow transitions
    private func playIntroAnimation() {
        guard let currentRoute = viewModel.walkSession.currentRoute,
              let firstWaypoint = currentRoute.qrMarkers.first?.coordinate,
              viewModel.locationService.currentLocation != nil else {
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
        
        // Phase 3: Switch to auto-follow user location (after 8 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            guard !userInteractedWithMap else { return }  // Skip if user interacted
            introPhase = .followingUser
            
            // v1.9.8: Use auto-follow mode to keep user centered during walk
            withAnimation(verySlowAnimation) {
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
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
    
    /// v1.9.10: Show full route overview briefly, then return to camera-following mode
    private func showFullRouteThenFollow() {
        guard let currentRoute = viewModel.walkSession.currentRoute else {
            // No route, just follow user
            withAnimation {
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            }
            return
        }
        
        // Step 1: Zoom out to show full route
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
            
            withAnimation(.easeInOut(duration: 1.0)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: max(0.01, latSpan), longitudeDelta: max(0.01, lngSpan))
                ))
            }
        }
        
        // Step 2: After 2.5 seconds, return to following user
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 1.5)) {
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            }
        }
    }
    
    // v1.9.0: Auto-zoom to turn intersection when approaching
    private func zoomToTurn(_ coordinate: CLLocationCoordinate2D) {
        // Don't zoom if user has manually interacted with map
        guard !userInteractedWithMap else { return }
        
        let smoothAnimation = Animation.easeInOut(duration: 1.0)
        withAnimation(smoothAnimation) {
            // Zoom to intersection view (100m x 100m for clear turn visibility)
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 100,
                longitudinalMeters: 100
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
    
    /// v1.9.5: Extract polyline segment for current leg only
    /// Shows path from current location to the next unvisited waypoint (or back to start if all visited)
    private func currentLegPolyline(
        fullPath: [CLLocationCoordinate2D],
        currentLocation: CLLocationCoordinate2D,
        markers: [QRMarker],
        visitedIds: Set<UUID>,
        startLocation: CLLocationCoordinate2D?
    ) -> [CLLocationCoordinate2D] {
        guard fullPath.count >= 2 else { return fullPath }
        
        // Find next unvisited waypoint
        let nextWaypoint: CLLocationCoordinate2D
        if let nextMarker = markers.first(where: { !visitedIds.contains($0.id) }) {
            nextWaypoint = nextMarker.coordinate
        } else if let start = startLocation ?? fullPath.first {
            // All waypoints visited - heading back to start
            nextWaypoint = start
        } else {
            return fullPath
        }
        
        // Find the closest point on the polyline to current location
        var closestIndexToUser = 0
        var closestDistanceToUser = Double.greatestFiniteMagnitude
        
        for (index, point) in fullPath.enumerated() {
            let distance = distanceBetween(currentLocation, point)
            if distance < closestDistanceToUser {
                closestDistanceToUser = distance
                closestIndexToUser = index
            }
        }
        
        // Find the closest point on the polyline to next waypoint
        var closestIndexToWaypoint = fullPath.count - 1
        var closestDistanceToWaypoint = Double.greatestFiniteMagnitude
        
        for (index, point) in fullPath.enumerated() {
            let distance = distanceBetween(nextWaypoint, point)
            if distance < closestDistanceToWaypoint {
                closestDistanceToWaypoint = distance
                closestIndexToWaypoint = index
            }
        }
        
        // Extract segment (handle both directions along the route)
        let startIndex = min(closestIndexToUser, closestIndexToWaypoint)
        let endIndex = max(closestIndexToUser, closestIndexToWaypoint)
        
        // Ensure we have at least 2 points
        guard startIndex < endIndex else {
            // Include current location and waypoint for minimal segment
            return [currentLocation, nextWaypoint]
        }
        
        // Build segment: current location → path segment → next waypoint
        var segment: [CLLocationCoordinate2D] = [currentLocation]
        segment.append(contentsOf: Array(fullPath[startIndex...endIndex]))
        segment.append(nextWaypoint)
        
        return segment
    }
    
    /// Helper: Calculate distance between two coordinates in meters
    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
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
// MARK: - Combined Status Banner (v1.6.30)
/// Combined delay + steps banner that saves vertical space
/// - When steps NOT enabled: alternates between delay info and "Tap to enable steps"
/// - When steps enabled: only shows delay info (static, no countdown)
/// - Shows "X min walk" instead of "X mins delay" when no clinician selected
struct CombinedStatusBanner: View {
    let delayMinutes: Int
    var walkDurationMinutes: Int = 0  // Used when no clinician selected
    var hasClinicianSelected: Bool = true
    @ObservedObject var healthKitService: HealthKitService
    @Binding var isStepTrackingEnabled: Bool
    @Binding var showMotionExplainer: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    /// Whether we should show alternating content (steps not yet enabled)
    private var shouldAlternate: Bool {
        !isStepTrackingEnabled && healthKitService.isPedometerAvailable && !healthKitService.isMotionDenied
    }
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.0)) { _ in
            CombinedStatusBannerContent(
                delayMinutes: delayMinutes,
                walkDurationMinutes: walkDurationMinutes,
                hasClinicianSelected: hasClinicianSelected,
                colorScheme: colorScheme,
                shouldAlternate: shouldAlternate,
                onTapSteps: {
                    showMotionExplainer = true
                }
            )
        }
    }
}

/// Inner content view for CombinedStatusBanner
private struct CombinedStatusBannerContent: View {
    let delayMinutes: Int
    var walkDurationMinutes: Int = 0
    var hasClinicianSelected: Bool = true
    let colorScheme: ColorScheme
    let shouldAlternate: Bool
    let onTapSteps: () -> Void
    
    /// Value to display (delay or walk duration)
    private var displayMinutes: Int {
        hasClinicianSelected ? delayMinutes : walkDurationMinutes
    }
    
    /// Label to display
    private var displayLabel: String {
        hasClinicianSelected ? "mins delay" : "min walk"
    }
    
    /// Toggle between delay and steps display (changes every 3 seconds)
    private var showingStepsPrompt: Bool {
        guard shouldAlternate else { return false }
        // Use the current second to determine which view to show
        let seconds = Int(Date().timeIntervalSince1970)
        return (seconds / 3) % 2 == 1
    }
    
    /// Urgency level based on static delay value (only applies when clinician selected)
    enum Urgency {
        case relaxed      // > 20 min
        case gentle       // 10-20 min
        case warning      // 5-10 min
        case urgent       // < 5 min
        case walkMode     // No clinician - neutral color
    }
    
    var urgency: Urgency {
        guard hasClinicianSelected else { return .walkMode }
        switch delayMinutes {
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
        case .walkMode: return .tealAccent
        }
    }
    
    var urgencyIcon: String {
        switch urgency {
        case .relaxed: return "clock.fill"
        case .gentle: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent: return "bell.badge.fill"
        case .walkMode: return "figure.walk"
        }
    }
    
    var body: some View {
        ZStack {
            // Delay info view
            delayView
                .opacity(showingStepsPrompt ? 0 : 1)
            
            // Steps prompt view (only when alternating)
            if shouldAlternate {
                stepsPromptView
                    .opacity(showingStepsPrompt ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showingStepsPrompt)
    }
    
    private var delayView: some View {
        HStack(spacing: 12) {
            // Urgency icon (or walk icon)
            Image(systemName: urgencyIcon)
                .font(.title3)
                .foregroundColor(urgencyColor)
            
            // Static delay/walk display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(displayMinutes)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)
                Text(displayLabel)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.darkCardBackground)
                .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
        )
    }
    
    private var stepsPromptView: some View {
        Button(action: onTapSteps) {
            HStack(spacing: 12) {
                // Walking icon
                ZStack {
                    Circle()
                        .fill(Color.tealAccent.opacity(0.3))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "figure.walk")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.tealAccent)
                }
                
                // Text
                Text("Tap to enable step tracking")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                Spacer()
                
                // Chevron to indicate tappable
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.darkCardBackground)
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Status Ring (v1.6.31)
/// Compact pill showing walk time remaining (delay shown in top banner)
/// Alternates with steps prompt when steps not enabled
struct CompactStatusRing: View {
    let walkDurationMinutes: Int
    let walkStartTime: Date?
    @ObservedObject var healthKitService: HealthKitService
    @Binding var isStepTrackingEnabled: Bool
    @Binding var showMotionExplainer: Bool
    var hasClinicianSelected: Bool = true  // v1.6.45: Hide time when no clinic
    
    /// Whether we should show alternating content (steps not yet enabled)
    private var shouldAlternate: Bool {
        !isStepTrackingEnabled && healthKitService.isPedometerAvailable && !healthKitService.isMotionDenied
    }
    
    /// v1.6.45: Whether to show steps prompt only (no time countdown)
    private var showStepsOnly: Bool {
        !hasClinicianSelected && shouldAlternate
    }
    
    /// v1.6.45: Hide pill entirely when no clinic and steps already enabled
    private var shouldHidePill: Bool {
        !hasClinicianSelected && !shouldAlternate
    }
    
    var body: some View {
        if shouldHidePill {
            // No clinic + steps enabled = nothing to show
            EmptyView()
        } else {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                CompactStatusPillContent(
                    walkDurationMinutes: walkDurationMinutes,
                    walkStartTime: walkStartTime,
                    currentDate: context.date,
                    shouldAlternate: shouldAlternate,
                    showStepsOnly: showStepsOnly,  // v1.6.45
                    isStepsEnabled: isStepTrackingEnabled,  // v1.8.6: For tap behavior
                    onTapSteps: {
                        showMotionExplainer = true
                    }
                )
            }
        }
    }
}

/// Inner content for CompactStatusRing - shows walk time remaining (delay in top banner)
private struct CompactStatusPillContent: View {
    let walkDurationMinutes: Int
    let walkStartTime: Date?
    let currentDate: Date
    let shouldAlternate: Bool
    var showStepsOnly: Bool = false  // v1.6.45: When no clinic, only show steps prompt
    var isStepsEnabled: Bool = false  // v1.8.6: Track if steps are enabled for tap behavior
    let onTapSteps: () -> Void
    
    /// Toggle between info and steps display (changes every 5 seconds)
    private var showingStepsPrompt: Bool {
        // v1.6.45: Always show steps prompt when no clinic
        if showStepsOnly { return true }
        guard shouldAlternate else { return false }
        let seconds = Int(currentDate.timeIntervalSince1970)
        return (seconds / 5) % 2 == 1
    }
    
    /// Walk time remaining (in minutes)
    var walkRemaining: Int {
        guard let start = walkStartTime else { return walkDurationMinutes }
        let elapsedSeconds = currentDate.timeIntervalSince(start)
        let elapsedMinutes = Int(elapsedSeconds / 60)
        return max(0, walkDurationMinutes - elapsedMinutes)
    }
    
    /// Urgency based on walk time remaining
    var urgencyColor: Color {
        switch walkRemaining {
        case 11...: return .tealAccent
        case 5...10: return .softAmber
        case 2...4: return .orange
        default: return .red
        }
    }
    
    var body: some View {
        ZStack {
            // Main info pill (delay + walk time)
            infoPillView
                .opacity(showingStepsPrompt ? 0 : 1)
                .scaleEffect(showingStepsPrompt ? 0.95 : 1.0)
            
            // Steps prompt pill (only when alternating)
            if shouldAlternate {
                stepsPillView
                    .opacity(showingStepsPrompt ? 1 : 0)
                    .scaleEffect(showingStepsPrompt ? 1.0 : 0.95)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: showingStepsPrompt)
    }
    
    /// Main pill showing walk time remaining (delay shown in top banner)
    /// v1.8.6: Tappable when steps not enabled - opens motion permission menu
    private var infoPillView: some View {
        Group {
            if isStepsEnabled {
                // Steps enabled - pill is just informational, not tappable
                infoPillContent
            } else {
                // Steps not enabled - tapping opens motion permission menu
                Button(action: onTapSteps) {
                    infoPillContent
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    /// The visual content of the info pill (shared between tappable and non-tappable versions)
    private var infoPillContent: some View {
        HStack(spacing: 6) {
            // Walking icon
            Image(systemName: "figure.walk")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(urgencyColor)
            
            Text("\(walkRemaining)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(urgencyColor)
                .monospacedDigit()
            
            Text("mins left")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.darkCardBackground)
                .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
        )
    }
    
    /// Steps prompt pill
    private var stepsPillView: some View {
        Button(action: onTapSteps) {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.tealAccent)
                
                Text("Track steps?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.tealAccent)
                
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.tealAccent.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.darkCardBackground)
                    .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Delay Banner (v1.6.10) - Legacy, kept for reference
/// Static delay display with color-coded urgency (no countdown)
/// Shows "X mins delay" if clinician selected, "X min walk" otherwise
struct DelayBanner: View {
    let delayMinutes: Int
    var walkDurationMinutes: Int = 0  // Used when no clinician selected
    var hasClinicianSelected: Bool = true
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        DelayBannerContent(
            delayMinutes: delayMinutes,
            walkDurationMinutes: walkDurationMinutes,
            hasClinicianSelected: hasClinicianSelected,
            colorScheme: colorScheme
        )
    }
}

/// Inner content view for DelayBanner - shows static delay value
/// Shows "X mins delay" if clinician selected, "X min walk" otherwise
private struct DelayBannerContent: View {
    let delayMinutes: Int
    var walkDurationMinutes: Int = 0
    var hasClinicianSelected: Bool = true
    let colorScheme: ColorScheme
    
    /// Value to display (delay or walk duration)
    private var displayMinutes: Int {
        hasClinicianSelected ? delayMinutes : walkDurationMinutes
    }
    
    /// Label to display
    private var displayLabel: String {
        hasClinicianSelected ? "mins delay" : "min walk"
    }
    
    /// Urgency level based on static delay value (only applies when clinician selected)
    enum Urgency {
        case relaxed      // > 20 min
        case gentle       // 10-20 min
        case warning      // 5-10 min
        case urgent       // < 5 min
        case walkMode     // No clinician - neutral color
    }
    
    var urgency: Urgency {
        guard hasClinicianSelected else { return .walkMode }
        switch delayMinutes {
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
        case .walkMode: return .tealAccent
        }
    }
    
    var urgencyIcon: String {
        switch urgency {
        case .relaxed: return "clock.fill"
        case .gentle: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent: return "bell.badge.fill"
        case .walkMode: return "figure.walk"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Urgency icon (or walk icon)
            Image(systemName: urgencyIcon)
                .font(.title3)
                .foregroundColor(urgencyColor)
            
            // Static delay/walk display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(displayMinutes)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(urgencyColor)
                Text(displayLabel)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
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
                    .fixedSize(horizontal: false, vertical: true)  // Allow text to wrap fully
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
        let state: StepTrackingState
        if !healthKitService.isPedometerAvailable {
            state = .unavailable
        } else if healthKitService.isMotionDenied {
            state = .denied
        } else if isStepTrackingEnabled && healthKitService.isMotionAuthorized {
            state = .tracking
        } else {
            state = .disabled
        }
        print("🟢 StepsCard state: \(state), isStepTrackingEnabled=\(isStepTrackingEnabled), isMotionAuthorized=\(healthKitService.isMotionAuthorized), isPedometerAvailable=\(healthKitService.isPedometerAvailable)")
        return state
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
        .onChange(of: stepTrackingState) { _, newState in
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

// MARK: - Motion Permission Explainer Sheet (v1.6.29c)
/// Sheet version of the Motion permission explainer for reliable presentation/dismissal
struct MotionPermissionExplainerSheet: View {
    let onEnable: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        ZStack {
            // Background
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.tealAccent.opacity(0.15))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.tealAccent)
                }
                
                // Title
                Text("Track Your Steps")
                    .font(.title)
                    .fontWeight(.bold)
                
                // Description
                Text("We use Motion & Fitness to count steps during your walk. This data stays on your device.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                // Privacy note
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundColor(.tealAccent)
                    
                    Text("Step data is processed locally")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.tealAccent.opacity(0.1))
                .clipShape(Capsule())
                
                Spacer()
                
                // Buttons
                VStack(spacing: 16) {
                    Button(action: onEnable) {
                        Text("Enable Step Tracking")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.tealAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    
                    Button(action: onCancel) {
                        Text("Not now")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
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
        VStack(spacing: 16) {
            // Icon with title inline
            HStack(spacing: 12) {
            ZStack {
                Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 50, height: 50)
                
                Image(systemName: "heart.fill")
                        .font(.system(size: 24))
                    .foregroundColor(.red)
            }
            
            Text("Sync with Apple Health?")
                    .font(.title3)
                .fontWeight(.bold)
            
                Spacer()
            }
            .padding(.top, 20)
            
            // Description - compact
            Text("Sync your steps for more accurate walk tracking.")
                .font(.subheadline)
                    .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Benefits - compact
            VStack(alignment: .leading, spacing: 8) {
                benefitRow(icon: "arrow.up.arrow.down", text: "Sync steps with Apple Health")
                benefitRow(icon: "clock.arrow.circlepath", text: "Track your step history")
                benefitRow(icon: "chart.line.uptrend.xyaxis", text: "Improve walk accuracy")
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            
            Spacer()
            
            // Buttons
            VStack(spacing: 10) {
                Button(action: syncWithHealthKit) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Sync with Apple Health")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                }
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(isLoading)
                
                Button(action: declineOffer) {
                    Text("Not now")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
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

// MARK: - Turn Arrow View (v1.9.0)
/// Large animated arrow showing turn direction on map
struct TurnArrowView: View {
    let maneuver: String?
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            // Pulsing outer ring
            Circle()
                .fill(Color.tealAccent.opacity(0.2))
                .frame(width: 80, height: 80)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.3 : 0.5)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)
            
            // Main arrow circle
            Circle()
                .fill(Color.tealAccent)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            
            // Directional arrow icon
            Image(systemName: turnArrowIcon(for: maneuver))
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
        }
        .onAppear {
            isPulsing = true
        }
    }
    
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

#Preview {
    WalkingMapView(viewModel: WaitingRoomViewModel())
}

