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
                    if let nextWaypoint = nextWaypointCoordinate() {
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
    // When walk is active, use walkSession.currentRoute and visitedMarkerIds
    // Otherwise, use selectedRoute and userProgress.qrScansCompleted
    private func nextWaypointCoordinate() -> CLLocationCoordinate2D? {
        // If walk is active, use currentRoute and visitedMarkerIds
        if viewModel.walkSession.isActive,
           let currentRoute = viewModel.walkSession.currentRoute {
            let visitedIds = viewModel.visitedMarkerIds
            // Find first unvisited waypoint
            if let nextMarker = currentRoute.qrMarkers.first(where: { !visitedIds.contains($0.id) }) {
                return nextMarker.coordinate
            }
            // All waypoints visited - return to start
            return viewModel.walkSession.startLocation ?? currentRoute.routePath.first
        }
        
        // Walk not active - use selectedRoute
        guard let selectedRoute = viewModel.selectedRoute,
              !selectedRoute.qrMarkers.isEmpty else {
            return nil
        }
        
        let visitedCount = viewModel.userProgress.qrScansCompleted
        if visitedCount < selectedRoute.qrMarkers.count {
            return selectedRoute.qrMarkers[visitedCount].coordinate
        }
        return clinicCoordinate // Head back to clinic
    }
    
    // Calculate walking route to next destination
    private func calculateRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation else {
            return
        }
        
        let destination: CLLocationCoordinate2D
        if let nextWaypoint = nextWaypointCoordinate() {
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
    @State private var waypointRoutePolyline: [CLLocationCoordinate2D]?  // Route segment to specific waypoint (extracted from Google routePath)
    @State private var isShowingReturnRoute: Bool = false  // Whether we're showing return directions
    @State private var hasPlayedIntro: Bool = false
    @State private var showingIntroOverlay: Bool = false
    @State private var introPhase: IntroPhase = .showingFirstWaypoint
    @Environment(\.colorScheme) var colorScheme
    
    // v1.6.28: Opt-in step tracking state
    // Initialize to true if user has previously opted in and Motion is authorized
    @State private var isStepTrackingEnabled: Bool = false
    @State private var showMotionExplainer: Bool = false
    
    // v1.9.0: Turn navigation enhancements
    @State private var isApproachingTurn: Bool = false
    @State private var distanceToNextTurn: Double? = nil
    
    // v1.9.13: Active zoom management
    @State private var lastZoomUpdate: Date = Date()
    
    // v1.9.16: Diagnostic tracking (kept for compatibility)
    @State private var isProgrammaticCameraUpdate: Bool = false
    @State private var lastProgrammaticUpdateTime: Date?
    @State private var lastLocationWhenInteracted: CLLocation?
    @State private var sustainedSpeedStartTime: Date?
    @State private var lastAutoResumeTime: Date?
    
    // v1.9.16: Diagnostic tracking struct
    struct CameraChangeEvent {
        let timestamp: Date
        let centerDelta: Double
        let headingDelta: Double
        let distanceDelta: Double
        let wasProgrammatic: Bool
        let wasDetectedAsUserInteraction: Bool
        let reason: String
    }
    @State private var recentCameraChanges: [CameraChangeEvent] = []
    
    // v1.9.13: Cache current leg polyline to prevent re-rendering on location updates
    @State private var cachedCurrentLegPolyline: [CLLocationCoordinate2D]?
    @State private var cachedLegPolylineForWaypoint: UUID? // Track which waypoint this polyline is for
    @State private var viewingWaypointId: UUID? // Track which waypoint user is viewing in carousel (nil = not viewing, UUID = viewing that waypoint, special UUID = viewing Return to Start)
    @State private var previousViewingWaypointId: UUID? // Track previous waypoint for change detection
    private static let returnToStartWaypointId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    
    // MARK: - State Variables (Cleaner names)
    @State private var resumeTimer: Timer?
    @State private var lastInteraction: Date?
    @State private var lastLocation: CLLocationCoordinate2D?
    @State private var justResumed: Bool = false
    
    // Cleaner state variable names
    @State private var userInteracting: Bool = false
    @State private var currentCamera: MapCamera?
    @State private var currentZoom: Double = 150.0
    
    // Legacy state variables (kept for compatibility with existing code)
    @State private var autoFollowResumeTimer: Timer? {
        didSet { resumeTimer = autoFollowResumeTimer }
    }
    @State private var lastInteractionTime: Date? {
        didSet { lastInteraction = lastInteractionTime }
    }
    @State private var lastCameraUpdateLocation: CLLocationCoordinate2D? {
        didSet { lastLocation = lastCameraUpdateLocation }
    }
    @State private var userInteractedWithMap: Bool = false {
        didSet { userInteracting = userInteractedWithMap }
    }
    @State private var currentCameraState: MapCamera? {
        didSet { currentCamera = currentCameraState }
    }
    @State private var currentZoomLevel: Double = 150.0 {
        didSet { currentZoom = currentZoomLevel }
    }
    @State private var justResumedAutoFollow: Bool = false {
        didSet { justResumed = justResumedAutoFollow }
    }
    
    // MARK: - Constants
    private let gpsGrace: TimeInterval = 0.3
    private let autoResumeDelay: TimeInterval = 5.0
    private let postResumeCooldown: TimeInterval = 0.3
    
    // Legacy constants (kept for compatibility)
    private let interactionGracePeriod: TimeInterval = 0.3
    
    private var inInteractionGrace: Bool {
        guard let last = lastInteraction ?? lastInteractionTime else { return false }
        return Date().timeIntervalSince(last) < gpsGrace
    }
    
    private var isInInteractionGracePeriod: Bool {
        inInteractionGrace
    }
    
    /// Check if user previously opted into step tracking
    /// We trust the UserDefaults flag - if permission was revoked, we'll handle it when pedometer fails
    private var shouldAutoEnableSteps: Bool {
        UserDefaults.standard.bool(forKey: "stepTrackingAutoEnabled")
    }
    
    enum IntroPhase: String {
        case showingFirstWaypoint = "Your first destination"
        case showingFullRoute = "Your route"
        case followingUser = "Your location"
    }
    
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4084, longitude: -1.4350)
    
    // -------------------------------
    // Optimized Computed Properties
    // -------------------------------
    
    // Active route polyline (simplified)
    // Computed property for active route polyline
    // Automatically handles both MapKit routes and Google Directions API polylines
    // Google polylines are decoded via WalkingRoute.routePath (uses PolylineDecoder)
    private var polylineToShow: [CLLocationCoordinate2D] {
        guard let currentRoute = viewModel.walkSession.currentRoute,
              currentRoute.routePath.count >= 2,
              !isShowingReturnRoute else { return [] }
        
        // If viewing a waypoint in carousel, show route segment
        if let viewingId = viewingWaypointId,
           viewingId != Self.returnToStartWaypointId,
           let waypointPolyline = waypointRoutePolyline,
           !waypointPolyline.isEmpty {
            return waypointPolyline
        }
        
        // Normal route display
        // routePath automatically decodes Google encoded polylines if encodedPolyline is set
        // Falls back to marker coordinates if no polyline available
        if introPhase == .followingUser {
            let nextWaypointId = getNextWaypointId(markers: currentRoute.qrMarkers, visitedIds: viewModel.visitedMarkerIds)
            if let cached = cachedCurrentLegPolyline,
               cachedLegPolylineForWaypoint == nextWaypointId {
                return cached
            } else {
                if viewModel.visitedMarkerIds.count == currentRoute.qrMarkers.count && currentRoute.qrMarkers.count > 0 {
                    return []
                } else {
                    return calculateStaticLegPolyline(
                        fullPath: currentRoute.routePath,  // Works with Google polylines (already decoded)
                        markers: currentRoute.qrMarkers,
                        visitedIds: viewModel.visitedMarkerIds,
                        startLocation: viewModel.walkSession.startLocation
                    )
                }
            }
        } else {
            // Full route display - routePath handles Google polyline decoding automatically
            return currentRoute.routePath
        }
    }
    
    // Active route markers
    private var markers: [QRMarker] {
        viewModel.walkSession.currentRoute?.qrMarkers ?? []
    }
    
    private var visitedIds: Set<UUID> {
        viewModel.visitedMarkerIds
    }
    
    // Return route segment
    // Works with both MapKit routes and Google Directions polylines
    // Google polylines are decoded via currentRoute.routePath
    private var returnSegment: [CLLocationCoordinate2D] {
        guard isShowingReturnRoute || viewingWaypointId == Self.returnToStartWaypointId,
              let currentRoute = viewModel.walkSession.currentRoute,
              let lastWaypoint = currentRoute.qrMarkers.last,
              let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first else {
            return []
        }
        
        // Extract return segment from route path (works with Google polylines)
        // currentRoute.routePath automatically decodes Google encoded polylines
        let segment = extractReturnSegmentFromRoutePath(
            routePath: currentRoute.routePath,  // Already decoded if Google polyline
            fromWaypoint: lastWaypoint.coordinate,
            toStart: startLocation
        )
        
        if !segment.isEmpty && segment.count >= 2 {
            return segment
        } else if let returnRoute = returnRoute {
            // Fallback: Extract from MapKit MKRoute polyline
            let polyline = returnRoute.polyline
            let pointCount = polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            return coords
        } else if viewModel.hasCachedReturnRoute && !viewModel.cachedReturnRoutePolyline.isEmpty {
            // Fallback: Use cached return route polyline
            return viewModel.cachedReturnRoutePolyline
        }
        
        return []
    }
    
    // Cached route for preview (fallback to selectedRoute if cachedRoute doesn't exist)
    private var cachedRoute: WalkingRoute? {
        viewModel.selectedRoute
    }
    
    // Cached POIs for preview
    private var cachedPOIs: [OptimizedMarker]? {
        guard let previewRoute = viewModel.selectedRoute,
              viewModel.walkSession.currentRoute == nil else {
            return nil
        }
        
        return previewRoute.qrMarkers.enumerated().map { index, marker in
            OptimizedMarker(
                id: marker.id.uuidString,
                name: marker.name,
                coordinate: marker.coordinate,
                index: index + 1
            )
        }
    }
    
    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                // User Location
                if let location = viewModel.locationService.currentLocation {
                    Annotation("You", coordinate: location.coordinate) {
                        PulsatingLocationDot()
                    }
                } else {
                    UserAnnotation()
                }
                
                // Start/End Marker
                if let startPoint = viewModel.walkSession.startLocation ?? viewModel.walkSession.currentRoute?.routePath.first {
                    Annotation("Start/End", coordinate: startPoint) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 28, height: 28)
                            Circle().fill(Color.white).frame(width: 12, height: 12)
                        }
                    }
                }
                
                // Active Route Polyline
                if let currentRoute = viewModel.walkSession.currentRoute,
                   currentRoute.routePath.count >= 2,
                   !isShowingReturnRoute {
                    MapPolyline(coordinates: polylineToShow)
                        .stroke(currentRoute.color, lineWidth: 4)
                }
                
                // Waypoints
                if !markers.isEmpty {
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
                
                // Return Route Polyline
                if isShowingReturnRoute || viewingWaypointId == Self.returnToStartWaypointId {
                    MapPolyline(coordinates: returnSegment)
                        .stroke(Color.blue, lineWidth: 5)
                }
                
                // Cached Route Preview (passive)
                if let previewRoute = cachedRoute,
                   viewModel.walkSession.currentRoute == nil,
                   !previewRoute.routePath.isEmpty {
                    MapPolyline(coordinates: previewRoute.routePath)
                        .stroke(previewRoute.color, lineWidth: 4)
                }
                
                // Cached POIs (passive)
                if let cachedMarkers = cachedPOIs,
                   viewModel.walkSession.currentRoute == nil {
                    ForEach(cachedMarkers, id: \.id) { marker in
                        Annotation(marker.name, coordinate: marker.coordinate) {
                            WaypointMarkerView(
                                name: marker.name,
                                index: marker.index,
                                isNext: false,
                                isVisited: false
                            )
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .mapControls { }
            .simultaneousGesture(
                // Pan
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startInteraction() }
                    .onEnded { _ in endInteraction() }
            )
            .simultaneousGesture(
                // Pinch Zoom
                MagnificationGesture()
                    .onChanged { _ in startInteraction() }
                    .onEnded { _ in endInteraction() }
            )
            .simultaneousGesture(
                // Rotate
                RotationGesture()
                    .onChanged { _ in startInteraction() }
                    .onEnded { _ in endInteraction() }
            )
            .onMapCameraChange { context in
                let now = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timeString = formatter.string(from: now)
                
                // Check if this is a programmatic update (within 1.0 seconds of our update)
                // v1.9.16: Increased grace period from 0.5s to 1.0s to prevent false positives
                let isRecentProgrammaticUpdate = lastProgrammaticUpdateTime != nil &&
                    now.timeIntervalSince(lastProgrammaticUpdateTime!) < 1.0
                
                // Calculate camera change details
                let cameraCenter = context.camera.centerCoordinate
                let cameraHeading = context.camera.heading
                let cameraDistance = context.camera.distance
                let previousCenter = currentCameraState?.centerCoordinate
                let previousHeading = currentCameraState?.heading ?? 0
                let previousDistance = currentCameraState?.distance ?? 0
                
                // Get user's current location for direction detection
                let userLocation = viewModel.locationService.currentLocation?.coordinate
                
                // Calculate change deltas
                let centerDelta: Double = {
                    guard let prev = previousCenter else { return 999 }
                    let latDiff = abs(cameraCenter.latitude - prev.latitude)
                    let lonDiff = abs(cameraCenter.longitude - prev.longitude)
                    return sqrt(latDiff * latDiff + lonDiff * lonDiff) * 111000 // Convert to meters
                }()
                
                // v1.9.16: Detect if camera is moving AWAY from user location
                // Programmatic updates always move TOWARDS user location, so moving AWAY = user interaction
                let isMovingAwayFromUser: Bool = {
                    guard let userLoc = userLocation,
                          let prevCenter = previousCenter else { return false }
                    // Calculate distance from user to previous camera center
                    let prevDistFromUser = sqrt(
                        pow(prevCenter.latitude - userLoc.latitude, 2) +
                        pow(prevCenter.longitude - userLoc.longitude, 2)
                    ) * 111000
                    // Calculate distance from user to current camera center
                    let currentDistFromUser = sqrt(
                        pow(cameraCenter.latitude - userLoc.latitude, 2) +
                        pow(cameraCenter.longitude - userLoc.longitude, 2)
                    ) * 111000
                    // If current distance > previous distance by >10m, it's moving away
                    return (currentDistFromUser - prevDistFromUser) > 10.0
                }()
                let headingDelta = abs(cameraHeading - previousHeading)
                let normalizedHeadingDelta = min(headingDelta, 360 - headingDelta)
                let distanceDelta = abs(cameraDistance - previousDistance)
                
                // v1.9.16: DIAGNOSTIC - Flag large camera movements that might feel like snap-back
                
                // v1.9.16: In auto-follow mode, assume small/expected changes are programmatic
                // This prevents false positives from MapKit's internal camera adjustments
                // Only treat as user interaction if change is large AND unexpected
                // v1.9.16: Lowered thresholds - user pan gestures can be as small as 50m
                // v1.9.16: Pattern detection will override this for small movements that form a pattern
                let isInAutoFollowMode = !userInteractedWithMap && introPhase == .followingUser
                let isSmallExpectedChange = centerDelta < 50.0 && // Less than 50m movement (was 200m - too high!)
                                          normalizedHeadingDelta < 5.0 && // Less than 5° heading change (was 10°)
                                          distanceDelta < 50.0 // Less than 50m zoom change (was 100m)
                // Note: Pattern detection will be checked later and can override this
                let isLikelyProgrammaticInAutoFollow = isInAutoFollowMode && isSmallExpectedChange
                
                // Calculate time since last interaction
                let timeSinceLastInteraction: String = {
                    if let lastInteraction = lastInteractionTime {
                        let elapsed = now.timeIntervalSince(lastInteraction)
                        return String(format: "%.3f", elapsed) + "s"
                    }
                    return "N/A"
                }()
                
                
                // Track this camera change in diagnostic buffer
                let wasProgrammatic = isProgrammaticCameraUpdate || isRecentProgrammaticUpdate || isLikelyProgrammaticInAutoFollow
                let willBeDetectedAsUserInteraction = introPhase == .followingUser &&
                    !userInteractedWithMap &&
                    !isProgrammaticCameraUpdate &&
                    !isRecentProgrammaticUpdate &&
                    !isLikelyProgrammaticInAutoFollow
                
                // Add to diagnostic buffer (keep last 20 events)
                recentCameraChanges.append(CameraChangeEvent(
                    timestamp: now,
                    centerDelta: centerDelta,
                    headingDelta: normalizedHeadingDelta,
                    distanceDelta: distanceDelta,
                    wasProgrammatic: wasProgrammatic,
                    wasDetectedAsUserInteraction: willBeDetectedAsUserInteraction,
                    reason: wasProgrammatic ? "programmatic" : (willBeDetectedAsUserInteraction ? "USER_INTERACTION" : "unknown")
                ))
                if recentCameraChanges.count > 20 {
                    recentCameraChanges.removeFirst()
                }
                
                // Check if we're in "vulnerability window" (within 3 seconds of auto-resume)
                let isInVulnerabilityWindow = lastAutoResumeTime != nil &&
                    now.timeIntervalSince(lastAutoResumeTime!) < 3.0
                
                // v1.9.16: Pattern detection for small user movements
                // If there are multiple small movements in quick succession, it's likely user interaction
                // This helps detect small pan gestures that would otherwise be filtered as programmatic
                // Check pattern BEFORE calculating wasProgrammatic to avoid circular dependency
                let hasPatternOfSmallMovements: Bool = {
                    guard isInAutoFollowMode && !isProgrammaticCameraUpdate && !isRecentProgrammaticUpdate else { return false }
                    // Look at last 5 events within 2 seconds
                    let recentEvents = recentCameraChanges.suffix(5)
                    let twoSecondsAgo = now.addingTimeInterval(-2.0)
                    // Check for small movements that weren't clearly programmatic
                    // We check the raw events, not the wasProgrammatic flag (which might be wrong)
                    let recentSmallMovements = recentEvents.filter { event in
                        event.timestamp >= twoSecondsAgo &&
                        event.centerDelta < 50.0 && // Small movements
                        event.centerDelta > 10.0 && // But not tiny (filter noise)
                        event.centerDelta > 0.0 // Actually moved
                    }
                    // If 2+ small movements in last 2 seconds, it's likely a pattern of user interaction
                    // (programmatic updates are usually single, not repeated small movements)
                    return recentSmallMovements.count >= 2
                }()
                
                // v1.9.16: Detect "suspicious" changes - borderline cases that might be false positives
                // These are changes that are larger than "small" but not clearly user-initiated
                // v1.9.16: Updated thresholds to match new detection thresholds
                let isSuspiciousChange = isInAutoFollowMode &&
                    !wasProgrammatic &&
                    centerDelta >= 50.0 && centerDelta < 300.0 && // Medium movement (50-300m, was 100-500m)
                    normalizedHeadingDelta < 20.0 && // Not a large rotation (was 30°)
                    distanceDelta < 100.0 // Not a large zoom (was 200m)
                
                // Detect user interaction with map (pan, zoom, rotation)
                // Only detect if we're in following mode, not during intro, and not a programmatic update
                // v1.9.16: In auto-follow mode, also ignore small/expected changes (likely MapKit internal adjustments)
                // v1.9.16: In vulnerability window, be extra cautious - require larger changes to detect as user interaction
                // v1.9.16: Updated thresholds - but make them reasonable (not too strict)
                // After auto-resume, we want to detect user interactions, just be slightly more cautious
                // v1.9.17: FIXED - Changed from OR to AND logic!
                // The OR logic was blocking legitimate pan gestures because heading/distance are usually 0 for pans
                // Now only blocks if change is small in ALL dimensions (truly programmatic-looking)
                // Only block very small movements in vulnerability window to prevent animation false positives
                let requiresLargerChangeInVulnerabilityWindow = isInVulnerabilityWindow && 
                    centerDelta < 50.0 &&  // Small center movement
                    normalizedHeadingDelta < 10.0 &&  // Small heading change
                    distanceDelta < 50.0  // Small zoom change
                
                
                // v1.9.16: Pattern detection override - if there's a pattern of small movements, treat as user interaction
                // This helps detect small pan gestures that would otherwise be filtered
                // v1.9.17: IMPROVED - Moving away from user now works for ALL movement sizes (not just 10-50m)
                // If camera is moving AWAY from user location, it's definitely a user interaction
                // Programmatic updates always move TOWARDS user location
                let shouldOverrideProgrammaticCheck = hasPatternOfSmallMovements && centerDelta >= 10.0 && centerDelta < 50.0
                
                // v1.9.17: Separate check for "moving away" - this is a strong signal of user interaction
                // regardless of movement size, and should override vulnerability window too
                let isDefinitelyUserInteraction = isMovingAwayFromUser && centerDelta >= 10.0
                
                // v1.9.17: Main detection condition
                // isDefinitelyUserInteraction (moving away from user) can override ALL checks except the direct programmatic flags
                // This is because moving away is a 100% reliable signal - programmatic updates never move away from user
                let passesStandardChecks = introPhase == .followingUser && 
                   !userInteractedWithMap && 
                   !isProgrammaticCameraUpdate && 
                   !isRecentProgrammaticUpdate &&
                   (!isLikelyProgrammaticInAutoFollow || shouldOverrideProgrammaticCheck) &&
                   !requiresLargerChangeInVulnerabilityWindow
                
                // v1.9.17: When camera is moving AWAY from user, override isRecentProgrammaticUpdate too
                // The "moving away" signal is so strong that it overrides the time-based heuristic
                // Only keep isProgrammaticCameraUpdate check (if flag is set, we're mid-update)
                let passesWithMovingAwayOverride = introPhase == .followingUser && 
                   !userInteractedWithMap && 
                   !isProgrammaticCameraUpdate &&  // Keep: if flag is set, we're mid-programmatic update
                   // NOTE: Removed !isRecentProgrammaticUpdate - "moving away" overrides this time-based heuristic
                   isDefinitelyUserInteraction  // Moving away overrides other heuristics including isRecentProgrammaticUpdate
                
                if passesStandardChecks || passesWithMovingAwayOverride {
                    // This is a user interaction - record the time and handle it
                    
                    lastInteractionTime = now
                    handleMapInteraction()
                } else if introPhase == .followingUser && 
                          userInteractedWithMap && 
                          !isProgrammaticCameraUpdate && 
                          !isRecentProgrammaticUpdate {
                    // User is continuing to interact - update the timestamp to reset the timer
                    // This prevents auto-resume while user is still actively interacting
                    // v1.9.16: More lenient detection for continuing interactions - don't filter by isLikelyProgrammaticInAutoFollow
                    // because once user is interacting, any camera change (even small) likely means they're still interacting
                    lastInteractionTime = now
                } else {
                    let reason: String = {
                        if introPhase != .followingUser {
                            return "introPhase != .followingUser"
                        } else if userInteractedWithMap {
                            return "userInteractedWithMap=true"
                        } else if isProgrammaticCameraUpdate {
                            return "isProgrammaticCameraUpdate=true"
                        } else if isRecentProgrammaticUpdate {
                            return "isRecentProgrammaticUpdate=true (within grace period)"
                        } else if isLikelyProgrammaticInAutoFollow {
                            return "isLikelyProgrammaticInAutoFollow=true (small change in auto-follow mode)"
                        } else if requiresLargerChangeInVulnerabilityWindow {
                            return "requiresLargerChangeInVulnerabilityWindow=true (in vulnerability window, change too small)"
                        } else {
                            return "unknown"
                        }
                    }()
                }
                
                // Update current camera state for next comparison
                currentCameraState = context.camera
                
                // Reset flag after checking (but keep timestamp for a bit longer)
                isProgrammaticCameraUpdate = false
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
                        onSwipeToWaypoint: { waypointId in
                            // Check if user is viewing a different waypoint
                            // Trigger animation if:
                            // 1. We're switching from one waypoint to another (both non-nil and different)
                            // 2. We're switching from nil to a waypoint (first selection should also show context)
                            let wasViewingDifferentLocation = viewingWaypointId != waypointId && 
                                                               (viewingWaypointId != nil || waypointId != nil)
                            
                            previousViewingWaypointId = viewingWaypointId
                            viewingWaypointId = waypointId
                            
                            if waypointId == Self.returnToStartWaypointId {
                                isShowingReturnRoute = true
                                waypointRoutePolyline = nil  // Clear waypoint route
                                
                                // If viewing different location, zoom out to route then in to start
                                if wasViewingDifferentLocation,
                                   let currentRoute = viewModel.walkSession.currentRoute,
                                   let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first {
                                    zoomToRouteThenWaypoint(startLocation, route: currentRoute)
                                } else if let currentRoute = viewModel.walkSession.currentRoute,
                                          let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first {
                                    // First selection of return to start - just zoom directly
                                    zoomToWaypoint(startLocation)
                                }
                                
                                // Switch to return directions
                                if !viewModel.isUsingReturnDirections {
                                    // Only switch if we have return directions available
                                    if !viewModel.cachedReturnDirections.isEmpty, let currentRoute = viewModel.walkSession.currentRoute {
                                        viewModel.isUsingReturnDirections = true
                                        // v1.9.16: Capture main actor-isolated property before nonisolated context
                                        let cachedPolyline = viewModel.cachedReturnRoutePolyline
                                        viewModel.locationService.startDirectionMonitoring(
                                            directions: viewModel.cachedReturnDirections,
                                            routePath: cachedPolyline.isEmpty ? currentRoute.routePath : cachedPolyline
                                        )
                                        print("📍 Switched to return route directions")
                                    }
                                }
                                
                                // Try to extract from routePath first, then check if we need MapKit fallback
                                if let currentRoute = viewModel.walkSession.currentRoute,
                                   let lastWaypoint = currentRoute.qrMarkers.last,
                                   let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first {
                                    let returnSegment = extractReturnSegmentFromRoutePath(
                                        routePath: currentRoute.routePath,
                                        fromWaypoint: lastWaypoint.coordinate,
                                        toStart: startLocation
                                    )
                                    
                                    // Check if extraction was successful
                                    if returnSegment.isEmpty || returnSegment.count < 2 {
                                        print("⚠️ Failed to extract return route from routePath, falling back to MapKit...")
                                        // Fallback: Calculate with MapKit
                                        calculateReturnRouteFromLastWaypoint()
                                    } else {
                                        print("✅ Successfully extracted return route from routePath")
                                    }
                                } else {
                                    // Missing data - use MapKit fallback
                                    calculateReturnRouteFromLastWaypoint()
                                }
                            } else if let waypointId = waypointId,
                                      let currentRoute = viewModel.walkSession.currentRoute,
                                      let targetMarker = currentRoute.qrMarkers.first(where: { $0.id == waypointId }) {
                                isShowingReturnRoute = false
                                
                                // If viewing different location, zoom out to route then in to waypoint
                                if wasViewingDifferentLocation {
                                    zoomToRouteThenWaypoint(targetMarker.coordinate, route: currentRoute)
                                } else {
                                    // First selection or same waypoint - just zoom directly
                                    zoomToWaypoint(targetMarker.coordinate)
                                }
                                
                                // Reset to original outgoing directions when viewing a regular waypoint
                                if viewModel.isUsingReturnDirections {
                                    viewModel.isUsingReturnDirections = false
                                    // Restore original directions monitoring
                                    if !viewModel.cachedOriginalDirections.isEmpty {
                                        viewModel.locationService.startDirectionMonitoring(
                                            directions: viewModel.cachedOriginalDirections,
                                            routePath: currentRoute.routePath
                                        )
                                        print("📍 Switched back to original outgoing directions")
                                    }
                                }
                                // Extract route segment from already-loaded routePath
                                extractRouteSegmentToWaypoint(targetMarker: targetMarker, markers: currentRoute.qrMarkers, routePath: currentRoute.routePath)
                            } else {
                                isShowingReturnRoute = false
                                waypointRoutePolyline = nil
                                // Reset to original directions if viewingWaypointId is cleared
                                if viewModel.isUsingReturnDirections {
                                    viewModel.isUsingReturnDirections = false
                                    if let currentRoute = viewModel.walkSession.currentRoute,
                                       !viewModel.cachedOriginalDirections.isEmpty {
                                        viewModel.locationService.startDirectionMonitoring(
                                            directions: viewModel.cachedOriginalDirections,
                                            routePath: currentRoute.routePath
                                        )
                                        print("📍 Switched back to original outgoing directions")
                                    }
                                }
                            }
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
        }
        // ----------------------
        // Overlay (non-blocking)
        // ----------------------
        // Non-blocking overlay
        .overlay(
            showingIntroOverlay ? IntroOverlayView(introPhase: introPhase).opacity(1).allowsHitTesting(false) : nil
        )
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
            
            // v1.9.13: Initialize cache on appear to avoid state modification during view update
            if let currentRoute = viewModel.walkSession.currentRoute,
               introPhase == .followingUser,
               cachedCurrentLegPolyline == nil {
                let nextWaypointId = getNextWaypointId(
                    markers: currentRoute.qrMarkers,
                    visitedIds: viewModel.visitedMarkerIds
                )
                
                let polyline: [CLLocationCoordinate2D]
                if viewModel.visitedMarkerIds.count == currentRoute.qrMarkers.count && currentRoute.qrMarkers.count > 0 {
                    polyline = []
                } else {
                    polyline = calculateStaticLegPolyline(
                        fullPath: currentRoute.routePath,
                        markers: currentRoute.qrMarkers,
                        visitedIds: viewModel.visitedMarkerIds,
                        startLocation: viewModel.walkSession.startLocation
                    )
                }
                
                cachedCurrentLegPolyline = polyline
                cachedLegPolylineForWaypoint = nextWaypointId
            }
        }
        // ----------------------
        // Remove simultaneousGesture completely
        // ----------------------
        // Interaction detection handled via onMapCameraChange only
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
                // Return to active zoom after passing turn
                if !userInteractedWithMap && introPhase == .followingUser {
                    startActiveZoom()
                }
            }
        }
        // MARK: - Location & Heading Handlers
        .onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            handleLocation(location)
        }
        .onChange(of: viewModel.locationService.heading) { _, newHeading in
            guard let heading = newHeading?.trueHeading else { return }
            handleHeading(heading)
        }
        // v1.9.13: Update cached leg polyline when waypoint changes (not during view rendering)
        .onChange(of: viewModel.visitedMarkerIds.count) { _, _ in
            // Waypoint count changed - update cache
            guard let currentRoute = viewModel.walkSession.currentRoute,
                  introPhase == .followingUser else { return }
            
            let nextWaypointId = getNextWaypointId(
                markers: currentRoute.qrMarkers,
                visitedIds: viewModel.visitedMarkerIds
            )
            
            // Only update if waypoint actually changed
            if cachedLegPolylineForWaypoint != nextWaypointId {
                // Calculate polyline
                let polyline: [CLLocationCoordinate2D]
                if viewModel.visitedMarkerIds.count == currentRoute.qrMarkers.count && currentRoute.qrMarkers.count > 0 {
                    // All waypoints visited - return empty (return route shown separately)
                    polyline = []
                } else {
                    // Calculate static polyline from leg start to waypoint
                    polyline = calculateStaticLegPolyline(
                        fullPath: currentRoute.routePath,
                        markers: currentRoute.qrMarkers,
                        visitedIds: viewModel.visitedMarkerIds,
                        startLocation: viewModel.walkSession.startLocation
                    )
                }
                
                // Update cache
                cachedCurrentLegPolyline = polyline
                cachedLegPolylineForWaypoint = nextWaypointId
                
                // If all waypoints are visited, trigger return route calculation
                if viewModel.visitedMarkerIds.count == currentRoute.qrMarkers.count && currentRoute.qrMarkers.count > 0 {
                    if !isShowingReturnRoute {
                        isShowingReturnRoute = true
                    }
                    if returnRoute == nil {
                        calculateReturnRoute()
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
        
        // Phase 3: Switch to auto-follow user location with active zoom (after 8 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            guard !userInteractedWithMap else {
                return // Skip if user interacted
            }
            
            // v1.9.13: Animate transition to user location smoothly
            withAnimation(verySlowAnimation) {
                introPhase = .followingUser
                
                // Set initial active zoom state
                currentZoomLevel = 150.0
                if let currentLocation = viewModel.locationService.currentLocation {
                    let heading: CLLocationDirection = {
                        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                            return trueHeading
                        } else if currentLocation.course >= 0 {
                            return currentLocation.course
                        } else {
                            return 0
                        }
                    }()
                    
                    
                    let newCamera = MapCamera(
                        centerCoordinate: currentLocation.coordinate,
                        distance: 150.0,
                        heading: heading,
                        pitch: 0
                    )
                    currentCameraState = newCamera
                    isProgrammaticCameraUpdate = true
                    lastProgrammaticUpdateTime = Date()
                    cameraPosition = .camera(newCamera)
                    
                }
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
        
        // Use camera mode to maintain heading following capability
        guard let currentLocation = viewModel.locationService.currentLocation else { return }
        
        let heading: CLLocationDirection = {
            if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                return trueHeading
            } else if currentLocation.course >= 0 {
                return currentLocation.course
            } else if let camera = currentCameraState {
                return camera.heading
            } else {
                return 0
            }
        }()
        
        let smoothAnimation = Animation.easeInOut(duration: 1.5)
        let newCamera = MapCamera(
            centerCoordinate: coordinate,
            distance: 150.0,
            heading: heading,
            pitch: 0
        )
        currentCameraState = newCamera
        isProgrammaticCameraUpdate = true
        lastProgrammaticUpdateTime = Date()
        withAnimation(smoothAnimation) {
            cameraPosition = .camera(newCamera)
        }
    }
    
    /// Zoom out to show whole route, then zoom in to selected waypoint
    /// Provides context before focusing on specific waypoint
    private func zoomToRouteThenWaypoint(_ waypointCoordinate: CLLocationCoordinate2D, route: WalkingRoute) {
        guard let currentLocation = viewModel.locationService.currentLocation else { return }
        
        // Calculate bounding box of entire route
        let routePath = route.routePath
        guard !routePath.isEmpty else {
            // Fallback: just zoom to waypoint
            zoomToWaypoint(waypointCoordinate)
            return
        }
        
        // Calculate center and bounds of route
        let latitudes = routePath.map { $0.latitude }
        let longitudes = routePath.map { $0.longitude }
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            zoomToWaypoint(waypointCoordinate)
            return
        }
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let routeCenter = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        
        // Calculate distance to fit entire route
        let latDelta = maxLat - minLat
        let lonDelta = maxLon - minLon
        let maxDelta = max(latDelta, lonDelta)
        let routeDistance = maxDelta * 111_000 // Convert to meters
        let overviewZoom = max(300.0, min(1000.0, routeDistance * 1.3)) // Fit with padding
        
        // Get current heading
        let heading: CLLocationDirection = {
            if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                return trueHeading
            } else if currentLocation.course >= 0 {
                return currentLocation.course
            } else if let camera = currentCameraState {
                return camera.heading
            } else {
                return 0
            }
        }()
        
        // Step 1: Zoom out to show whole route
        let overviewCamera = MapCamera(
            centerCoordinate: routeCenter,
            distance: overviewZoom,
            heading: heading,
            pitch: 0
        )
        
        currentCameraState = overviewCamera
        isProgrammaticCameraUpdate = true
        lastProgrammaticUpdateTime = Date()
        
        withAnimation(.easeInOut(duration: 1.0)) {
            cameraPosition = .camera(overviewCamera)
        }
        
        // Step 2: After showing route, zoom in to waypoint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let waypointCamera = MapCamera(
                centerCoordinate: waypointCoordinate,
                distance: 150.0,
                heading: heading,
                pitch: 0
            )
            
            self.currentCameraState = waypointCamera
            self.isProgrammaticCameraUpdate = true
            self.lastProgrammaticUpdateTime = Date()
            
            withAnimation(.easeInOut(duration: 1.0)) {
                self.cameraPosition = .camera(waypointCamera)
            }
        }
    }
    
    /// v1.9.10: Show full route overview briefly, then return to camera-following mode
    private func showFullRouteThenFollow() {
        // v1.9.16: Clear user interaction flag and reset timer state when compass button is pressed
        // This ensures we can zoom back to current position after showing full route
        // CRITICAL: Cancel auto-resume timer FIRST to prevent race conditions
        let wasInteracting = userInteractedWithMap
        if wasInteracting {
            autoFollowResumeTimer?.invalidate()
            autoFollowResumeTimer = nil
        }
        
        // Clear interaction state completely
        userInteractedWithMap = false
        lastInteractionTime = nil  // v1.9.16: Clear this too to prevent stale timer data
        lastLocationWhenInteracted = nil
        
        guard let currentRoute = viewModel.walkSession.currentRoute else {
            // No route, just follow user
            isProgrammaticCameraUpdate = true
            lastProgrammaticUpdateTime = Date()
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
            
            isProgrammaticCameraUpdate = true
            lastProgrammaticUpdateTime = Date()
            withAnimation(.easeInOut(duration: 1.0)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: max(0.01, latSpan), longitudeDelta: max(0.01, lngSpan))
                ))
            }
        }
        
        // Step 2: After 2.0 seconds, return to active zoom mode with smooth animation
        // v1.9.16: Always resume after showing full route (compass button should always return to following)
        // v1.9.16: Ensure no auto-resume timer interferes with this manual resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // v1.9.16: Double-check timer is cancelled (defensive programming)
            if autoFollowResumeTimer != nil {
                autoFollowResumeTimer?.invalidate()
                autoFollowResumeTimer = nil
            }
            if introPhase == .followingUser {
                resumeAutoFollow()
            }
        }
    }
    
    // v1.9.0: Auto-zoom to turn intersection when approaching
    private func zoomToTurn(_ coordinate: CLLocationCoordinate2D) {
        // Don't zoom if user has manually interacted with map
        guard !userInteractedWithMap else { return }
        
        // Use camera mode to maintain heading following capability
        guard let currentLocation = viewModel.locationService.currentLocation else { return }
        
        let heading: CLLocationDirection = {
            if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                return trueHeading
            } else if currentLocation.course >= 0 {
                return currentLocation.course
            } else if let camera = currentCameraState {
                return camera.heading
            } else {
                return 0
            }
        }()
        
        let smoothAnimation = Animation.easeInOut(duration: 1.0)
        let newCamera = MapCamera(
            centerCoordinate: coordinate,
            distance: 100.0,
            heading: heading,
            pitch: 0
        )
        currentCameraState = newCamera
        isProgrammaticCameraUpdate = true
        lastProgrammaticUpdateTime = Date()
        withAnimation(smoothAnimation) {
            cameraPosition = .camera(newCamera)
        }
    }
    
    // v1.9.13: Start active zoom mode - uses camera with heading for smooth rotation + custom zoom
    // v1.9.16: Don't start active zoom if user has interacted (prevents unwanted snap-back)
    private func startActiveZoom() {
        // CRITICAL: Don't move camera if user has interacted with map
        guard !userInteractedWithMap else {
            return
        }
        
        guard let currentLocation = viewModel.locationService.currentLocation else {
            // Fallback to default if no location
            cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            return
        }
        
        currentZoomLevel = 150.0 // Default zoom level in meters
        // Get heading from location service or location course
        let heading: CLLocationDirection = {
            if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                return trueHeading
            } else if currentLocation.course >= 0 {
                return currentLocation.course
            } else {
                return 0
            }
        }()
        
        
        // Use camera with heading for smooth rotation + custom zoom
        // Set without animation initially for immediate response
        let newCamera = MapCamera(
            centerCoordinate: currentLocation.coordinate,
            distance: currentZoomLevel,
            heading: heading,
            pitch: 0
        )
        currentCameraState = newCamera
        isProgrammaticCameraUpdate = true
        lastProgrammaticUpdateTime = Date()
        cameraPosition = .camera(newCamera)
        
    }
    
    // v1.9.13: Update active zoom based on distance to next waypoint
    private func updateActiveZoom(for location: CLLocation) {
        guard !userInteractedWithMap,
              introPhase == .followingUser,
              let currentRoute = viewModel.walkSession.currentRoute else {
            return
        }
        
        // Find next unvisited waypoint or start point
        let visitedIds = viewModel.visitedMarkerIds
        let nextWaypoint: CLLocationCoordinate2D?
        
        if let nextMarker = currentRoute.qrMarkers.first(where: { !visitedIds.contains($0.id) }) {
            nextWaypoint = nextMarker.coordinate
        } else if let start = viewModel.walkSession.startLocation ?? currentRoute.routePath.first {
            nextWaypoint = start // Returning to start
        } else {
            nextWaypoint = nil
        }
        
        guard let waypoint = nextWaypoint else {
            // No waypoint, use default zoom
            if currentZoomLevel != 150.0 {
                currentZoomLevel = 150.0
                updateCameraZoom()
            }
            return
        }
        
        let waypointLocation = CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude)
        let distance = location.distance(from: waypointLocation)
        
        // Adjust zoom based on distance to next waypoint
        // Closer = zoom in more, farther = zoom out slightly
        let newZoom: Double
        if distance < 50 {
            newZoom = 100.0 // Very close, zoom in
        } else if distance < 200 {
            newZoom = 120.0 // Close, medium zoom
        } else if distance < 500 {
            newZoom = 150.0 // Medium distance, default zoom
        } else {
            newZoom = 200.0 // Far, zoom out slightly to show more context
        }
        
        // Only update if zoom level changed significantly (avoid constant updates)
        if abs(newZoom - currentZoomLevel) > 20.0 {
            currentZoomLevel = newZoom
            updateCameraZoom()
        }
    }
    
    // -------------------------------
    // 196-style updateCameraZoom
    // -------------------------------
    private func updateCameraZoom() {
        guard !userInteractedWithMap else { return }
        guard let location = viewModel.locationService.currentLocation else { return }
        
        let heading = viewModel.locationService.heading?.trueHeading ?? currentCameraState?.heading ?? 0
        let camera = MapCamera(
            centerCoordinate: location.coordinate,
            distance: currentZoomLevel,
            heading: heading,
            pitch: currentCameraState?.pitch ?? 0
        )
        
        currentCameraState = camera
        
        withAnimation(.easeInOut(duration: 1.5)) {
            cameraPosition = .camera(camera)
        }
    }
    
    // MARK: - Camera Updates
    private func handleLocation(_ location: CLLocation) {
        guard introPhase == .followingUser else { return }
        guard !userInteracting, !inInteractionGrace, !justResumed else { return }
        
        if let last = lastLocation,
           abs(last.latitude - location.coordinate.latitude) < 0.00001 &&
           abs(last.longitude - location.coordinate.longitude) < 0.00001 {
            return
        }
        lastLocation = location.coordinate
        lastCameraUpdateLocation = location.coordinate
        
        currentZoom = calculateSmartZoom(for: location)
        currentZoomLevel = currentZoom
        
        updateCamera(to: location.coordinate)
    }
    
    private func handleHeading(_ newHeading: CLLocationDirection) {
        // --- Safety checks ---
        guard introPhase == .followingUser, !userInteracting, !justResumed else { return }
        guard let current = currentCamera else { return }

        var currentHeading = current.heading

        // --- Normalize difference to [-180, +180] for wrap-around ---
        var delta = newHeading - currentHeading
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        // --- Adaptive smoothing ---
        let absDelta = abs(delta)
        let filteredHeading: CLLocationDirection

        if absDelta < 5 {
            // Small change: heavy smoothing (reduce jitter)
            filteredHeading = currentHeading + delta * 0.2
        } else if absDelta < 30 {
            // Medium change: moderate smoothing
            filteredHeading = currentHeading + delta * 0.5
        } else {
            // Large change: direct update (user is turning)
            filteredHeading = currentHeading + delta
        }

        // --- Ensure heading stays in [0, 360] ---
        let normalizedHeading = (filteredHeading + 360).truncatingRemainder(dividingBy: 360)

        // --- Update camera ---
        let camera = MapCamera(
            centerCoordinate: current.centerCoordinate,
            distance: current.distance,
            heading: normalizedHeading,
            pitch: current.pitch
        )

        currentCamera = camera
        currentCameraState = camera

        // --- Animation optimization: only animate for medium/large changes ---
        // Tiny changes (<5°) update directly to reduce animation overhead
        if absDelta >= 5 {
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.2)) {
                cameraPosition = .camera(camera)
            }
        } else {
            // Tiny changes: direct update (no animation overhead)
            cameraPosition = .camera(camera)
        }
    }
    
    private func updateCamera(to coordinate: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
        guard !userInteracting else { return }
        
        let existing = currentCamera ?? currentCameraState
        let targetHeading = heading ?? viewModel.locationService.heading?.trueHeading ?? existing?.heading ?? 0
        
        let camera = MapCamera(
            centerCoordinate: coordinate,
            distance: currentZoom,
            heading: targetHeading,
            pitch: existing?.pitch ?? 0
        )
        
        currentCamera = camera
        currentCameraState = camera
        
        let largeChange = existing == nil ||
            abs(camera.heading - (existing?.heading ?? 0)) > 15 ||
            (existing != nil && sqrt(pow(camera.centerCoordinate.latitude - existing!.centerCoordinate.latitude, 2) +
                                     pow(camera.centerCoordinate.longitude - existing!.centerCoordinate.longitude, 2)) * 111000 > 20)
        
        withAnimation(largeChange ? .linear(duration: 0.08)
                                 : .interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.25)) {
            cameraPosition = .camera(camera)
        }
    }
    
    // Legacy function name (kept for compatibility)
    private func updateCamera(location: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
        updateCamera(to: location, heading: heading)
    }
    
    // MARK: - Smart Dynamic Zoom
    private func calculateSmartZoom(for location: CLLocation) -> Double {
        var zoom: Double = 150.0
        
        // --- Speed-based zoom
        if location.speed > 0 {
            switch location.speed {
            case 0..<1: zoom = 150
            case 1..<2: zoom = 170
            default: zoom = 200
            }
        }
        
        // --- Fit upcoming route points (up to 3)
        // Works with both MapKit routes and Google Directions polylines
        // routePath automatically decodes Google encoded polylines via PolylineDecoder
        if let route = viewModel.walkSession.currentRoute, !route.routePath.isEmpty {
            let upcoming = route.routePath.prefix(3)
            var minLat = location.coordinate.latitude
            var maxLat = location.coordinate.latitude
            var minLon = location.coordinate.longitude
            var maxLon = location.coordinate.longitude
            
            for pt in upcoming {
                minLat = min(minLat, pt.latitude)
                maxLat = max(maxLat, pt.latitude)
                minLon = min(minLon, pt.longitude)
                maxLon = max(maxLon, pt.longitude)
            }
            
            let latDelta = maxLat - minLat
            let lonDelta = maxLon - minLon
            let distance = max(latDelta, lonDelta) * 111_000
            zoom = max(zoom, min(250, distance * 1.5))
        }
        
        // --- Fit cached route preview
        // Also works with Google polylines (cached routes store encoded polyline strings)
        if let cachedRoute = cachedRoute, viewModel.walkSession.currentRoute == nil, !cachedRoute.routePath.isEmpty {
            let coords = cachedRoute.routePath
            let latitudes = coords.map { $0.latitude }
            let longitudes = coords.map { $0.longitude }
            if let minLat = latitudes.min(), let maxLat = latitudes.max(),
               let minLon = longitudes.min(), let maxLon = longitudes.max() {
                let latDelta = maxLat - minLat
                let lonDelta = maxLon - minLon
                let distance = max(latDelta, lonDelta) * 111_000
                zoom = max(zoom, min(250, distance * 1.5))
            }
        }
        
        return zoom
    }
    
    // v1.9.13: Helper to update camera center smoothly
    private func updateCameraCenter(to coordinate: CLLocationCoordinate2D) {
        updateCamera(location: coordinate)
    }
    
    // v1.9.13: Helper to update camera heading smoothly
    private func updateCameraHeading(to heading: CLLocationDirection, at coordinate: CLLocationCoordinate2D) {
        updateCamera(location: coordinate, heading: heading)
    }
    
    // MARK: - Interaction
    private func startInteraction() {
        userInteracting = true
        lastInteraction = Date()
        
        // Update legacy variables for compatibility
        userInteractedWithMap = true
        lastInteractionTime = Date()
        
        resumeTimer?.invalidate()
        autoFollowResumeTimer?.invalidate()
    }
    
    private func endInteraction() {
        lastInteraction = Date()
        lastInteractionTime = Date()
        scheduleAutoResume()
    }
    
    private func scheduleAutoResume() {
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            guard let last = lastInteraction else { timer.invalidate(); return }
            if Date().timeIntervalSince(last) >= autoResumeDelay {
                timer.invalidate()
                autoResumeFollow()
            }
        }
        
        // Update legacy timer for compatibility
        autoFollowResumeTimer = resumeTimer
    }
    
    // Legacy function name (kept for compatibility)
    private func handleMapInteraction() {
        startInteraction()
    }
    
    // MARK: - Auto-Resume
    private func autoResumeFollow() {
        guard introPhase == .followingUser,
              let location = viewModel.locationService.currentLocation else { return }
        
        userInteracting = false
        lastInteraction = nil
        justResumed = true
        
        // Update legacy variables for compatibility
        userInteractedWithMap = false
        lastInteractionTime = nil
        justResumedAutoFollow = true
        
        currentZoom = calculateSmartZoom(for: location)
        currentZoomLevel = currentZoom
        
        let heading = viewModel.locationService.heading?.trueHeading ?? currentCamera?.heading ?? 0
        let camera = MapCamera(
            centerCoordinate: location.coordinate,
            distance: currentZoom,
            heading: heading,
            pitch: currentCamera?.pitch ?? 0
        )
        
        currentCamera = camera
        currentCameraState = camera
        
        withAnimation(.easeInOut(duration: 1.5)) {
            cameraPosition = .camera(camera)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + postResumeCooldown) {
            justResumed = false
            justResumedAutoFollow = false
        }
    }
    
    // Legacy function name (kept for compatibility)
    private func resumeAutoFollow() {
        autoResumeFollow()
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
    
    /// Extract route segment from Google routePath to a specific waypoint
    /// This maintains consistency with the original Google-generated route
    private func extractRouteSegmentToWaypoint(targetMarker: QRMarker, markers: [QRMarker], routePath: [CLLocationCoordinate2D]) {
        guard routePath.count >= 2 else {
            print("⚠️ Route path too short to extract segment")
            return
        }
        
        // Find the previous waypoint (or start location if this is the first waypoint)
        let sourceCoordinate: CLLocationCoordinate2D
        if let targetIndex = markers.firstIndex(where: { $0.id == targetMarker.id }) {
            if targetIndex > 0 {
                // Use previous waypoint
                sourceCoordinate = markers[targetIndex - 1].coordinate
            } else {
                // First waypoint - use start location
                sourceCoordinate = viewModel.walkSession.startLocation ?? routePath.first ?? targetMarker.coordinate
            }
        } else {
            // Fallback to start location
            sourceCoordinate = viewModel.walkSession.startLocation ?? routePath.first ?? targetMarker.coordinate
        }
        
        print("📍 Extracting route segment from Google routePath to \(targetMarker.name)...")
        
        // Find closest point on routePath to source coordinate
        var closestIndexToSource = 0
        var closestDistanceToSource = Double.greatestFiniteMagnitude
        for (index, point) in routePath.enumerated() {
            let distance = distanceBetween(sourceCoordinate, point)
            if distance < closestDistanceToSource {
                closestDistanceToSource = distance
                closestIndexToSource = index
            }
        }
        
        // Find closest point on routePath to target waypoint
        var closestIndexToTarget = routePath.count - 1
        var closestDistanceToTarget = Double.greatestFiniteMagnitude
        for (index, point) in routePath.enumerated() {
            let distance = distanceBetween(targetMarker.coordinate, point)
            if distance < closestDistanceToTarget {
                closestDistanceToTarget = distance
                closestIndexToTarget = index
            }
        }
        
        // Extract segment from source to target
        let startIndex = min(closestIndexToSource, closestIndexToTarget)
        let endIndex = max(closestIndexToSource, closestIndexToTarget)
        
        guard startIndex < endIndex else {
            // Fallback: just show direct line
            waypointRoutePolyline = [sourceCoordinate, targetMarker.coordinate]
            return
        }
        
        // Build segment: source → routePath segment → target
        var segment: [CLLocationCoordinate2D] = [sourceCoordinate]
        segment.append(contentsOf: Array(routePath[startIndex...endIndex]))
        segment.append(targetMarker.coordinate)
        
        print("✅ Extracted route segment to \(targetMarker.name): \(segment.count) points")
        waypointRoutePolyline = segment
    }
    
    /// Extract return segment from already-loaded routePath (last waypoint → start)
    /// Returns empty array if extraction fails (will trigger MapKit fallback)
    private func extractReturnSegmentFromRoutePath(
        routePath: [CLLocationCoordinate2D],
        fromWaypoint: CLLocationCoordinate2D,
        toStart: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        guard routePath.count >= 2 else {
            print("⚠️ Route path too short to extract return segment")
            return []
        }
        
        print("📍 Attempting to extract return segment from already-loaded routePath (last waypoint → start)...")
        
        // Find closest point on routePath to last waypoint
        var closestIndexToWaypoint = routePath.count - 1
        var closestDistanceToWaypoint = Double.greatestFiniteMagnitude
        for (index, point) in routePath.enumerated() {
            let distance = distanceBetween(fromWaypoint, point)
            if distance < closestDistanceToWaypoint {
                closestDistanceToWaypoint = distance
                closestIndexToWaypoint = index
            }
        }
        
        // Find closest point on routePath to start location
        var closestIndexToStart = 0
        var closestDistanceToStart = Double.greatestFiniteMagnitude
        for (index, point) in routePath.enumerated() {
            let distance = distanceBetween(toStart, point)
            if distance < closestDistanceToStart {
                closestDistanceToStart = distance
                closestIndexToStart = index
            }
        }
        
        // Check if we found reasonable matches (within 50 meters)
        let waypointMatchThreshold: Double = 50.0 // meters
        let startMatchThreshold: Double = 50.0 // meters
        
        if closestDistanceToWaypoint > waypointMatchThreshold {
            print("⚠️ Last waypoint too far from routePath (\(Int(closestDistanceToWaypoint))m) - extraction may be inaccurate")
        }
        
        if closestDistanceToStart > startMatchThreshold {
            print("⚠️ Start location too far from routePath (\(Int(closestDistanceToStart))m) - extraction may be inaccurate")
        }
        
        // Extract segment from last waypoint to start
        // For circular routes, the return segment is typically at the end of the routePath
        let startIndex: Int
        let endIndex: Int
        
        if closestIndexToWaypoint < closestIndexToStart {
            // Normal case: waypoint comes before start in the path
            startIndex = closestIndexToWaypoint
            endIndex = closestIndexToStart
        } else if closestIndexToWaypoint > closestIndexToStart {
            // Waypoint is after start - this is the return segment
            // Take from waypoint to end of path, then from beginning to start
            startIndex = closestIndexToWaypoint
            endIndex = routePath.count - 1
        } else {
            // Same index - invalid, return empty to trigger fallback
            print("⚠️ Waypoint and start have same index in routePath - cannot extract")
            return []
        }
        
        guard startIndex < routePath.count && endIndex < routePath.count && startIndex <= endIndex else {
            print("⚠️ Invalid indices for segment extraction")
            return []
        }
        
        // Build segment: last waypoint → routePath segment → start
        var segment: [CLLocationCoordinate2D] = [fromWaypoint]
        segment.append(contentsOf: Array(routePath[startIndex...endIndex]))
        segment.append(toStart)
        
        // Validate the segment has reasonable length
        if segment.count < 2 {
            print("⚠️ Extracted segment too short (\(segment.count) points)")
            return []
        }
        
        print("✅ Successfully extracted return segment: \(segment.count) points")
        return segment
    }
    
    /// Calculate return route from last waypoint to start using MapKit (fallback)
    /// Only called if extraction from routePath fails
    private func calculateReturnRouteFromLastWaypoint() {
        guard let currentRoute = viewModel.walkSession.currentRoute,
              let lastWaypoint = currentRoute.qrMarkers.last,
              let startPoint = viewModel.walkSession.startLocation ?? currentRoute.routePath.first else {
            print("📍 Cannot calculate return route - missing waypoint or start point")
            return
        }
        
        // Don't recalculate if we already have this route
        if returnRoute != nil {
            print("📍 Return route already calculated, using existing")
            return
        }
        
        print("📍 Fallback: Calculating return route from last waypoint to start using MapKit...")
        isShowingReturnRoute = true
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: lastWaypoint.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        // v1.9.16: Capture main actor-isolated properties before Sendable closure
        let hasCachedReturnRoute = viewModel.hasCachedReturnRoute
        let cachedReturnRoutePolyline = viewModel.cachedReturnRoutePolyline
        directions.calculate { [self] response, error in
            if let error = error {
                print("⚠️ Return route calculation failed: \(error.localizedDescription)")
                // Fallback to cached route if available
                if hasCachedReturnRoute && !cachedReturnRoutePolyline.isEmpty {
                    print("✅ Falling back to cached return route")
                }
                return
            }
            
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    print("✅ Return route calculated via MapKit: \(route.expectedTravelTime / 60) min, \(route.distance) meters")
                    self.returnRoute = route
                }
            }
        }
    }
    
    /// Calculate walking directions from current location back to starting point
    /// v1.9.16: Calculate return route with offline fallback
    /// Strategy: Show cached route immediately, then try fresh calculation if online
    private func calculateReturnRoute() {
        // Don't recalculate if we already have a return route
        guard returnRoute == nil else {
            print("📍 Return route already calculated, skipping...")
            return
        }
        
        guard let currentLocation = viewModel.locationService.currentLocation,
              let currentRoute = viewModel.walkSession.currentRoute,
              let startPoint = currentRoute.routePath.first else {
            print("📍 Cannot calculate return route - missing location or start point")
            return
        }
        
        print("📍 Calculating return route to start point...")
        isShowingReturnRoute = true
        
        // STEP 1: If we have a cached return route, show it immediately (works offline)
        if viewModel.hasCachedReturnRoute && !viewModel.cachedReturnRoutePolyline.isEmpty {
            print("📍 Using cached return route (showing immediately)")
            applyCachedReturnRoute()
        }
        
        // STEP 2: Try to recalculate from actual location (if online, more accurate)
        print("📍 Attempting fresh return route calculation from actual location...")
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        // v1.9.16: Capture main actor-isolated properties before Sendable closure
        let hasCachedRoute = viewModel.hasCachedReturnRoute
        directions.calculate { response, error in
            
            if let error = error {
                print("⚠️ Fresh return route calculation failed: \(error.localizedDescription)")
                // If we don't have cached route, show error
                if !hasCachedRoute {
                    print("❌ No cached route available - return route unavailable")
                } else {
                    print("✅ Falling back to cached return route (offline mode)")
                }
                return
            }
            
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    print("✅ Fresh return route calculated: \(route.expectedTravelTime / 60) min, \(route.distance) meters")
                    
                    // Use the fresh route (more accurate from actual location)
                    self.returnRoute = route
                    
                    // Extract directions and polyline
                    let returnDirections = self.extractDirectionsFromMKRoute(route)
                    self.viewModel.cachedReturnDirections = returnDirections
                    
                    let polyline = route.polyline
                    let pointCount = polyline.pointCount
                    var returnPath = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                    polyline.getCoordinates(&returnPath, range: NSRange(location: 0, length: pointCount))
                    
                    // Update cache with fresh route
                    self.viewModel.cachedReturnRoutePolyline = returnPath
                    self.viewModel.hasCachedReturnRoute = true
                    
                    // Switch to return route directions
                    if !returnDirections.isEmpty {
                        self.viewModel.isUsingReturnDirections = true
                        self.viewModel.locationService.startDirectionMonitoring(
                            directions: returnDirections,
                            routePath: returnPath
                        )
                        print("📍 Switched to fresh return route directions: \(returnDirections.count) steps")
                    }
                }
            }
        }
    }
    
    /// v1.9.16: Apply cached return route (for immediate display)
    private func applyCachedReturnRoute() {
        guard viewModel.hasCachedReturnRoute,
              !viewModel.cachedReturnRoutePolyline.isEmpty,
              !viewModel.cachedReturnDirections.isEmpty else {
            print("⚠️ Cannot apply cached return route - cache incomplete")
            return
        }
        
        // Apply cached directions and start monitoring
        viewModel.isUsingReturnDirections = true
        viewModel.locationService.startDirectionMonitoring(
            directions: viewModel.cachedReturnDirections,
            routePath: viewModel.cachedReturnRoutePolyline
        )
        
        print("✅ Applied cached return route: \(viewModel.cachedReturnDirections.count) steps, \(viewModel.cachedReturnRoutePolyline.count) points")
        
        // Note: The polyline will be rendered from cachedReturnRoutePolyline in the map view
        // When a fresh route is calculated, it will replace this cached display
    }
    
    /// v1.9.15: Extract walking directions from MKRoute steps
    private func extractDirectionsFromMKRoute(_ route: MKRoute) -> [WalkingDirection] {
        var directions: [WalkingDirection] = []
        
        // Find the last step with instructions (to mark it as "arrive")
        let lastStepWithInstructions = route.steps.lastIndex(where: { !$0.instructions.isEmpty })
        
        for (index, step) in route.steps.enumerated() {
            // Skip steps with no instructions (usually the first "depart" step)
            guard !step.instructions.isEmpty else { continue }
            
            let stepDistance = Int(step.distance)
            // Estimate duration based on walking speed (~80m/min)
            let stepDurationSeconds = max(60, stepDistance / 80 * 60)
            let durationText = stepDurationSeconds >= 60 ? "\(stepDurationSeconds / 60) min" : "\(stepDurationSeconds) sec"
            
            // Format distance
            let distanceText: String
            if stepDistance < 1000 {
                distanceText = "\(stepDistance) m"
            } else {
                distanceText = String(format: "%.1f km", Double(stepDistance) / 1000.0)
            }
            
            // Extract maneuver type from instructions
            let maneuver = extractManeuverType(from: step.instructions)
            
            // Keep all actual directions - don't replace with "Return to starting point"
            // The last step will naturally be an "arrive" instruction from MapKit
            let isLastStep = index == lastStepWithInstructions
            
            let direction = WalkingDirection(
                instruction: step.instructions,  // Keep the actual instruction
                distance: distanceText,
                distanceMeters: stepDistance,
                duration: durationText,
                maneuver: isLastStep ? "arrive" : maneuver
            )
            directions.append(direction)
        }
        
        return directions
    }
    
    /// Pulsating dot for user location
    private struct PulsatingLocationDot: View {
        @State private var pulseScale: CGFloat = 1.0
        
        var body: some View {
            ZStack {
                // Outer pulsating ring
                Circle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .scaleEffect(pulseScale)
                    .opacity(2.0 - pulseScale)
                
                // Middle ring
                Circle()
                    .fill(Color.blue.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .scaleEffect(pulseScale * 0.8)
                    .opacity(1.5 - pulseScale * 0.5)
                
                // Center dot
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    pulseScale = 1.5
                }
            }
        }
    }
    
    /// v1.9.15: Extract maneuver type from instruction text
    private func extractManeuverType(from instruction: String) -> String {
        let lowercased = instruction.lowercased()
        if lowercased.contains("turn left") { return "turn-left" }
        if lowercased.contains("turn right") { return "turn-right" }
        if lowercased.contains("slight left") { return "turn-slight-left" }
        if lowercased.contains("slight right") { return "turn-slight-right" }
        if lowercased.contains("continue") || lowercased.contains("straight") { return "straight" }
        if lowercased.contains("arrive") || lowercased.contains("destination") { return "arrive" }
        if lowercased.contains("u-turn") { return "uturn" }
        return "straight"
    }
    
    // v1.9.13: Get next waypoint ID for caching
    private func getNextWaypointId(markers: [QRMarker], visitedIds: Set<UUID>) -> UUID? {
        if let nextMarker = markers.first(where: { !visitedIds.contains($0.id) }) {
            return nextMarker.id
        }
        // If all waypoints visited, return a special UUID for "return to start"
        return UUID(uuidString: "00000000-0000-0000-0000-000000000001") // Special ID for return to start
    }
    
    
    // v1.9.13: Calculate static leg polyline from leg start to waypoint
    // This doesn't include current location, so it stays fixed
    private func calculateStaticLegPolyline(
        fullPath: [CLLocationCoordinate2D],
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
        
        // Find the leg start point - use start location or first point of route
        let legStart = startLocation ?? fullPath.first ?? fullPath[0]
        
        // Find the closest point on the polyline to leg start
        var closestIndexToStart = 0
        var closestDistanceToStart = Double.greatestFiniteMagnitude
        
        for (index, point) in fullPath.enumerated() {
            let distance = distanceBetween(legStart, point)
            if distance < closestDistanceToStart {
                closestDistanceToStart = distance
                closestIndexToStart = index
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
        
        // Extract segment from leg start to waypoint
        let startIndex = min(closestIndexToStart, closestIndexToWaypoint)
        let endIndex = max(closestIndexToStart, closestIndexToWaypoint)
        
        // Ensure we have at least 2 points
        guard startIndex < endIndex else {
            return [legStart, nextWaypoint]
        }
        
        // Build static segment: leg start → path segment → next waypoint
        // Don't include current location - this keeps it static
        var segment: [CLLocationCoordinate2D] = [legStart]
        segment.append(contentsOf: Array(fullPath[startIndex...endIndex]))
        segment.append(nextWaypoint)
        
        return segment
    }
    
    // Calculate route segment to a specific waypoint (for carousel viewing)
    // Shows route from previous waypoint to target waypoint
    private func calculateRouteSegmentToWaypoint(
        fullPath: [CLLocationCoordinate2D],
        targetWaypoint: CLLocationCoordinate2D,
        markers: [QRMarker],
        visitedIds: Set<UUID>,
        fromWaypoint: CLLocationCoordinate2D? = nil
    ) -> [CLLocationCoordinate2D] {
        guard fullPath.count >= 2 else { return fullPath }
        
        // Find which waypoint we're targeting
        let targetMarkerIndex = markers.firstIndex(where: {
            abs($0.coordinate.latitude - targetWaypoint.latitude) < 0.0001 &&
            abs($0.coordinate.longitude - targetWaypoint.longitude) < 0.0001
        })
        
        // Determine segment start point
        let segmentStart: CLLocationCoordinate2D
        if let fromWaypoint = fromWaypoint {
            // Explicitly provided start point (for return route)
            segmentStart = fromWaypoint
        } else if let targetIndex = targetMarkerIndex, targetIndex > 0 {
            // Target is a waypoint - use previous waypoint
            segmentStart = markers[targetIndex - 1].coordinate
        } else if let targetIndex = targetMarkerIndex, targetIndex == 0 {
            // Target is first waypoint - use start location
            segmentStart = viewModel.walkSession.startLocation ?? fullPath.first ?? fullPath[0]
        } else {
            // Target not found in markers - use start location
            segmentStart = viewModel.walkSession.startLocation ?? fullPath.first ?? fullPath[0]
        }
        
        // Find closest point on polyline to segment start
        var closestIndexToStart = 0
        var closestDistanceToStart = Double.greatestFiniteMagnitude
        for (index, point) in fullPath.enumerated() {
            let distance = distanceBetween(segmentStart, point)
            if distance < closestDistanceToStart {
                closestDistanceToStart = distance
                closestIndexToStart = index
            }
        }
        
        // Find closest point on polyline to target waypoint
        var closestIndexToTarget = fullPath.count - 1
        var closestDistanceToTarget = Double.greatestFiniteMagnitude
        for (index, point) in fullPath.enumerated() {
            let distance = distanceBetween(targetWaypoint, point)
            if distance < closestDistanceToTarget {
                closestDistanceToTarget = distance
                closestIndexToTarget = index
            }
        }
        
        // Extract segment
        let startIndex = min(closestIndexToStart, closestIndexToTarget)
        let endIndex = max(closestIndexToStart, closestIndexToTarget)
        
        guard startIndex < endIndex else {
            return [segmentStart, targetWaypoint]
        }
        
        // Build segment: segment start → path segment → target waypoint
        var segment: [CLLocationCoordinate2D] = [segmentStart]
        segment.append(contentsOf: Array(fullPath[startIndex...endIndex]))
        segment.append(targetWaypoint)
        
        return segment
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
    let onSwipeToWaypoint: ((UUID?) -> Void)? // Called when swiping to a waypoint
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
                    onSwipeToWaypoint?(marker.id)
                } else if newIndex == unvisitedMarkers.count, let start = startLocation {
                    // Return to Start card
                    let returnToStartId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                    onSwipeToWaypoint?(returnToStartId)
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

// MARK: - Optimized Marker Model
struct OptimizedMarker: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let index: Int
    
    static func == (lhs: OptimizedMarker, rhs: OptimizedMarker) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.index == rhs.index
    }
}

// MARK: - Intro Overlay View
struct IntroOverlayView: View {
    let introPhase: EmbeddedWalkMapView.IntroPhase
    
    var body: some View {
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
    
    /// v1.9.18: Always show the pill during active walk (shows walk time remaining)
    /// Previously hid when no clinic + steps enabled, but users want to see time remaining
    private var shouldHidePill: Bool {
        false  // Always show the pill
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

