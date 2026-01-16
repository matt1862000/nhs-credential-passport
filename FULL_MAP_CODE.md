# Full Map Code - EmbeddedWalkMapView

## Map View Body (lines 528-570)

```swift
var body: some View {
    ZStack {
        Map(position: $cameraPosition) {
            // User location
            if let location = viewModel.locationService.currentLocation {
                Annotation("You", coordinate: location.coordinate) {
                    PulsatingLocationDot()
                }
            } else {
                UserAnnotation()
            }
            
            // Start/End marker
            if let startPoint = startPointCoordinate {
                Annotation("Start/End", coordinate: startPoint) {
                    StartEndMarkerView()
                }
            }
            
            // Current route polyline
            if shouldShowCurrentRoute {
                MapPolyline(coordinates: currentRoutePolyline)
                    .stroke(currentRouteColor, lineWidth: 4)
            }
            
            // Waypoint markers
            ForEach(currentWaypointMarkers, id: \.id) { markerData in
                Annotation(markerData.name, coordinate: markerData.coordinate) {
                    WaypointMarkerView(
                        name: markerData.name,
                        index: markerData.index,
                        isNext: markerData.isNext,
                        isVisited: markerData.isVisited
                    )
                }
            }
            
            // Return route polyline
            if shouldShowReturnRoute {
                MapPolyline(coordinates: returnRoutePolylineCoordinates)
                    .stroke(Color.blue, lineWidth: 5)
            }
        }
        .mapStyle(.standard)
        .mapControls {
            // Empty - we'll add custom controls in the overlay
        }
        .onMapCameraChange { context in
            // ... (see onMapCameraChange handler below)
        }
        
        // ... overlays and controls ...
    }
}
```

## Computed Properties for Map Content

### Route Display Logic

```swift
// v1.9.23: Computed properties to simplify complex Map view expressions
private var shouldShowSelectedRoute: Bool {
    viewModel.selectedRoute != nil && 
    viewModel.walkSession.currentRoute == nil &&
    !(viewModel.selectedRoute?.routePath.isEmpty ?? true)
}

private var selectedRoutePath: [CLLocationCoordinate2D] {
    viewModel.selectedRoute?.routePath ?? []
}

private var shouldShowSelectedRouteMarkers: Bool {
    viewModel.selectedRoute != nil && 
    viewModel.walkSession.currentRoute == nil
}

private var selectedRouteMarkers: [QRMarker] {
    viewModel.selectedRoute?.qrMarkers ?? []
}

// v1.9.23: Computed properties to simplify complex route polyline logic
private var shouldShowCurrentRoute: Bool {
    let hasRoute = viewModel.walkSession.currentRoute != nil
    let hasEnoughPoints = (viewModel.walkSession.currentRoute?.routePath.count ?? 0) >= 2
    let notShowingReturn = !isShowingReturnRoute
    let hasPolyline = !currentRoutePolyline.isEmpty
    return hasRoute && hasEnoughPoints && notShowingReturn && hasPolyline
}

private var currentRoutePolyline: [CLLocationCoordinate2D] {
    guard let currentRoute = viewModel.walkSession.currentRoute else { return [] }
    
    // If viewing a waypoint in carousel, show route segment
    if let viewingId = viewingWaypointId,
       viewingId != Self.returnToStartWaypointId,
       let waypointPolyline = waypointRoutePolyline,
       !waypointPolyline.isEmpty {
        return waypointPolyline
    }
    
    // Normal route display (full route or current leg)
    if introPhase == .followingUser {
        // Use cached polyline if available and still valid
        let nextWaypointId = getNextWaypointId(markers: currentRoute.qrMarkers, visitedIds: viewModel.visitedMarkerIds)
        if let cached = cachedCurrentLegPolyline,
           cachedLegPolylineForWaypoint == nextWaypointId {
            return cached
        } else {
            // Return calculated polyline
            if viewModel.visitedMarkerIds.count == currentRoute.qrMarkers.count && currentRoute.qrMarkers.count > 0 {
                // All waypoints visited - return empty (return route shown separately)
                return []
            } else {
                // Calculate static polyline from leg start to waypoint
                return calculateStaticLegPolyline(
                    fullPath: currentRoute.routePath,
                    markers: currentRoute.qrMarkers,
                    visitedIds: viewModel.visitedMarkerIds,
                    startLocation: viewModel.walkSession.startLocation
                )
            }
        }
    } else {
        return currentRoute.routePath
    }
}

private var currentRouteColor: Color {
    viewModel.walkSession.currentRoute?.color ?? .tealAccent
}

private var startPointCoordinate: CLLocationCoordinate2D? {
    viewModel.walkSession.startLocation ?? viewModel.walkSession.currentRoute?.routePath.first
}

// v1.9.23: Computed properties for return route polyline
private var shouldShowReturnRoute: Bool {
    let showingReturn = isShowingReturnRoute || viewingWaypointId == Self.returnToStartWaypointId
    let hasPolyline = !returnRoutePolylineCoordinates.isEmpty
    return showingReturn && hasPolyline
}

private var returnRoutePolylineCoordinates: [CLLocationCoordinate2D] {
    guard let currentRoute = viewModel.walkSession.currentRoute,
          let lastWaypoint = currentRoute.qrMarkers.last,
          let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first else {
        return []
    }
    
    let returnSegment = extractReturnSegmentFromRoutePath(
        routePath: currentRoute.routePath,
        fromWaypoint: lastWaypoint.coordinate,
        toStart: startLocation
    )
    
    if !returnSegment.isEmpty && returnSegment.count >= 2 {
        return returnSegment
    } else if viewModel.hasCachedReturnRoute && !viewModel.cachedReturnRoutePolyline.isEmpty {
        return viewModel.cachedReturnRoutePolyline
    }
    
    return []
}

private var hasReturnRoutePolyline: Bool {
    !returnRoutePolylineCoordinates.isEmpty
}

private var shouldShowFallbackRoute: Bool {
    route != nil && (viewModel.walkSession.currentRoute?.routePath.count ?? 0) < 2
}

// v1.9.23: Pre-computed waypoint markers to simplify Map builder
private var currentWaypointMarkers: [WaypointMarkerData] {
    guard let currentRoute = viewModel.walkSession.currentRoute else { return [] }
    return waypointMarkersData(currentRoute: currentRoute)
}
```

### Waypoint Marker Data Helper

```swift
// v1.9.23: Helper to compute waypoint marker data
private struct WaypointMarkerData {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let index: Int
    let isNext: Bool
    let isVisited: Bool
}

private func waypointMarkersData(currentRoute: WalkingRoute) -> [WaypointMarkerData] {
    let visitedIds = viewModel.visitedMarkerIds
    let markers = currentRoute.qrMarkers
    
    return markers.enumerated().map { index, marker in
        let isVisited = visitedIds.contains(marker.id)
        let isNext = !isVisited && !markers.prefix(index).contains(where: { !visitedIds.contains($0.id) })
        
        return WaypointMarkerData(
            id: marker.id,
            name: marker.name,
            coordinate: marker.coordinate,
            index: index + 1,
            isNext: isNext,
            isVisited: isVisited
        )
    }
}
```

## Camera Update Functions

### Main Camera Update Function

```swift
// v1.9.13: Unified camera update function that handles both location and heading
// This ensures updates happen reliably and camera state is always initialized
// Updates smoothly without throttling to prevent stuttering
// When approaching a turn, still follows user but may use different zoom
private func updateCamera(location: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
    // v1.9.22: CRITICAL FIX - Hard-block all camera updates during user interaction
    // This prevents snap-back even if interaction detection is late or heading/location updates fire
    guard !userInteractedWithMap else {
        print("🚫 updateCamera BLOCKED — user interacting")
        return
    }
    
    // Get current heading - prefer provided heading, then location service heading, then existing camera heading
    let targetHeading: CLLocationDirection = {
        if let providedHeading = heading, providedHeading >= 0 {
            return providedHeading
        } else if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            return trueHeading
        } else if let location = viewModel.locationService.currentLocation, location.course >= 0 {
            return location.course
        } else if let existingCamera = currentCameraState {
            return existingCamera.heading
        } else {
            return 0
        }
    }()
    
    // Get distance from existing camera or use current zoom level
    // When approaching turn, use closer zoom (100m) for better visibility
    let existingCamera = currentCameraState
    let baseDistance = existingCamera?.distance ?? currentZoomLevel
    
    // v1.9.23: Add speed-based dynamic zoom adjustment
    // Faster movement → zoom out slightly → see more context
    // Slower movement → zoom in → more detail
    let speedAdjustedDistance: Double = {
        if let location = viewModel.locationService.currentLocation,
           location.speed > 0 {
            // Speed is in m/s, adjust zoom: max(120, min(200, 150 + speed * 2))
            let speedZoom = max(120.0, min(200.0, 150.0 + location.speed * 2.0))
            return speedZoom
        }
        return baseDistance
    }()
    
    let distance = isApproachingTurn ? min(speedAdjustedDistance, 100.0) : speedAdjustedDistance
    
    // Calculate changes for smooth animation decision
    let existingHeading = existingCamera?.heading ?? 0
    let headingDiff = abs(targetHeading - existingHeading)
    
    // Normalize heading difference (handle 360° wrap-around)
    let normalizedHeadingDiff = min(headingDiff, 360 - headingDiff)
    
    // Calculate location change distance
    let locationChange: Double = {
        guard let existing = existingCamera?.centerCoordinate else { return 999 }
        let latDiff = abs(location.latitude - existing.latitude)
        let lonDiff = abs(location.longitude - existing.longitude)
        return sqrt(latDiff * latDiff + lonDiff * lonDiff) * 111000 // Convert to meters
    }()
    
    // v1.9.23: Throttle very small updates to prevent animation churn
    // Only skip if BOTH location and heading changes are very small
    if locationChange < 2.5 && normalizedHeadingDiff < 5.0 {
        return // Skip tiny updates
    }
    
    // v1.9.23: Interpolate heading smoothly to prevent 360° wrap-around jumps
    let interpolatedHeading: CLLocationDirection = {
        if normalizedHeadingDiff > 5.0 {
            // Large heading change - interpolate to prevent snapping
            let deltaHeading = targetHeading - existingHeading
            let shortestAngle = atan2(sin(deltaHeading * .pi/180), cos(deltaHeading * .pi/180)) * 180 / .pi
            return existingHeading + shortestAngle
        }
        return targetHeading
    }()
    
    // v1.9.23: Add pitch for turns (slight tilt to see more of path ahead)
    let pitch: Double = isApproachingTurn ? 25.0 : 0.0
    
    // Create new camera
    let newCamera = MapCamera(
        centerCoordinate: location,
        distance: distance,
        heading: interpolatedHeading,
        pitch: pitch
    )
    
    currentCameraState = newCamera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    // They are only set for intentional recentering actions (resumeAutoFollow, zoomToTurn, etc.)
    
    // v1.9.23: Use different animations based on change size
    // Large changes: smooth easeInOut
    // Medium changes: interactive spring
    // Small changes: instant (already filtered above)
    if locationChange > 100.0 || normalizedHeadingDiff > 30.0 {
        // Large change - smooth animation
        withAnimation(.easeInOut(duration: 0.1)) {
            cameraPosition = .camera(newCamera)
        }
    } else if locationChange > 10.0 || normalizedHeadingDiff > 10.0 {
        // Medium change - spring animation
        withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.25)) {
            cameraPosition = .camera(newCamera)
        }
    } else {
        // Small change - instant (no animation)
        cameraPosition = .camera(newCamera)
    }
}
```

### Camera Zoom Update

```swift
private func updateCameraZoom() {
    // CRITICAL: Don't move camera if user has interacted with map
    guard !userInteractedWithMap else {
        return
    }
    
    guard let currentLocation = viewModel.locationService.currentLocation else {
        return
    }
    
    // Get current heading from location service or location course
    let existingHeading = currentCameraState?.heading ?? 0
    
    let heading: CLLocationDirection = {
        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            return trueHeading
        } else if currentLocation.course >= 0 {
            return currentLocation.course
        } else {
            return existingHeading
        }
    }()
    
    // Update camera with new zoom level, using smooth animation
    // Only animate zoom changes, not heading (heading updates separately)
    // v1.9.22: Do NOT mark passive zoom updates as "programmatic"
    // v1.9.23: Use spring animation for natural zoom feel
    let newCamera = MapCamera(
        centerCoordinate: currentLocation.coordinate,
        distance: currentZoomLevel,
        heading: heading,
        pitch: currentCameraState?.pitch ?? 0
    )
    currentCameraState = newCamera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    // They are only set for intentional recentering actions
    withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.25)) {
        cameraPosition = .camera(newCamera)
    }
}
```

### Resume Auto-Follow

```swift
private func resumeAutoFollow() {
    guard introPhase == .followingUser,
          let currentLocation = viewModel.locationService.currentLocation else {
        return
    }
    
    // Clear interaction flag and location tracking
    userInteractedWithMap = false
    lastLocationWhenInteracted = nil
    sustainedSpeedStartTime = nil // Reset sustained speed tracking
    
    // v1.9.16: Track auto-resume time for vulnerability window detection
    // Set this here so it works regardless of where resumeAutoFollow() is called from
    let now = Date()
    lastAutoResumeTime = now
    
    // Clear old diagnostic history (keep last 5 for context)
    if recentCameraChanges.count > 5 {
        recentCameraChanges.removeFirst(recentCameraChanges.count - 5)
    }
    
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
    
    // Smoothly animate back to user location with camera follow, zoom, and heading
    let newCamera = MapCamera(
        centerCoordinate: currentLocation.coordinate,
        distance: currentZoomLevel,
        heading: heading,
        pitch: 0
    )
    let updateTime = Date()
    
    currentCameraState = newCamera
    isProgrammaticCameraUpdate = true
    lastProgrammaticUpdateTime = updateTime

    // v1.9.23: Improved auto-follow resume with gradual easing
    // Slow settle-in, then fast catch-up for natural feel
    withAnimation(.easeOut(duration: 0.5)) {
        cameraPosition = .camera(newCamera)
    }
    
    // After first phase, continue with linear animation for catch-up
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard !userInteractedWithMap else { return }
        let finalCamera = MapCamera(
            centerCoordinate: currentLocation.coordinate,
            distance: currentZoomLevel,
            heading: heading,
            pitch: 0
        )
        currentCameraState = finalCamera
        withAnimation(.linear(duration: 0.5)) {
            cameraPosition = .camera(finalCamera)
        }
    }
}
```

### Zoom to Turn

```swift
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
    
    // v1.9.23: Add pitch/tilt when zooming to turn for better visibility
    let smoothAnimation = Animation.easeInOut(duration: 1.0)
    let newCamera = MapCamera(
        centerCoordinate: coordinate,
        distance: 100.0,
        heading: heading,
        pitch: 25.0  // Slight tilt to see more of path ahead
    )
    currentCameraState = newCamera
    isProgrammaticCameraUpdate = true
    lastProgrammaticUpdateTime = Date()
    withAnimation(smoothAnimation) {
        cameraPosition = .camera(newCamera)
    }
}
```

### Safe Camera Initialization

```swift
// v1.9.23: Safe camera initialization helper
// Initializes camera with current location if available, otherwise uses fallback region
// This prevents nil camera position issues and allows panning even without location
private func initializeCameraSafely() {
    if let currentLocation = viewModel.locationService.currentLocation {
        // Normal camera follow with heading
        let heading = viewModel.locationService.heading?.trueHeading ?? currentLocation.course
        let camera = MapCamera(
            centerCoordinate: currentLocation.coordinate,
            distance: currentZoomLevel,
            heading: heading >= 0 ? heading : 0,
            pitch: 0
        )
        currentCameraState = camera
        cameraPosition = .camera(camera)
    } else {
        // No location yet — fallback region ensures panning is possible
        cameraPosition = .region(fallbackRegion)
    }
}
```

## Helper View Structs

### Start/End Marker View

```swift
struct StartEndMarkerView: View {
    var body: some View {
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
```

### Pulsating Location Dot

```swift
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
                pulseScale = 2.0
            }
        }
    }
}
```

### Waypoint Marker View

```swift
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
                    .foregroundColor(.white)
            } else {
                Text("\(index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
        }
    }
    
    private var markerColor: Color {
        if isVisited {
            return .gray
        } else if isNext {
            return .orange
        } else {
            return .tealAccent
        }
    }
}
```

## State Variables

```swift
@State private var cameraPosition: MapCameraPosition = .automatic
@State private var route: MKRoute?
@State private var returnRoute: MKRoute?
@State private var waypointRoutePolyline: [CLLocationCoordinate2D]?
@State private var isShowingReturnRoute: Bool = false
@State private var hasPlayedIntro: Bool = false
@State private var showingIntroOverlay: Bool = false
@State private var introPhase: IntroPhase = .showingFirstWaypoint
@State private var userInteractedWithMap: Bool = false
@State private var fallbackRegion: MKCoordinateRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 53.4148, longitude: -1.4685),
    latitudinalMeters: 500,
    longitudinalMeters: 500
)

// Zoom and camera state
@State private var lastZoomUpdate: Date = Date()
@State private var currentZoomLevel: Double = 150.0
@State private var currentCameraState: MapCamera?

// Polyline caching
@State private var cachedCurrentLegPolyline: [CLLocationCoordinate2D]?
@State private var cachedLegPolylineForWaypoint: UUID?
@State private var viewingWaypointId: UUID?

// Interaction tracking
@State private var autoFollowResumeTimer: Timer?
@State private var isProgrammaticCameraUpdate: Bool = false
@State private var lastProgrammaticUpdateTime: Date?
@State private var lastInteractionTime: Date?
@State private var lastLocationWhenInteracted: CLLocation?
@State private var sustainedSpeedStartTime: Date?
@State private var lastAutoResumeTime: Date?

// Turn navigation
@State private var isApproachingTurn: Bool = false
@State private var distanceToNextTurn: Double? = nil
```

## Key Features

1. **Simplified Map Builder**: Uses computed properties to break down complex expressions
2. **Hard-block during interaction**: `updateCamera()` blocks all updates when `userInteractedWithMap` is true
3. **Smooth animations**: Different animation types based on change size (large/medium/small)
4. **Speed-based zoom**: Dynamic zoom adjustment based on movement speed
5. **Heading interpolation**: Prevents 360° wrap-around jumps
6. **Turn anticipation**: Adds pitch/tilt when approaching turns
7. **Gradual auto-resume**: Two-phase animation (easeOut then linear) for natural feel
8. **Safe initialization**: Fallback region when location unavailable
9. **Throttling**: Skips very small updates (< 2.5m movement, < 5° heading change)
