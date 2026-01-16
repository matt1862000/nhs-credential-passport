# Current Map Code - EmbeddedWalkMapView

## Map View Body (lines 370-1220)

```swift
var body: some View {
    ZStack {
        Map(position: $cameraPosition) {
            // Custom user location with pulsating dot
            if let location = viewModel.locationService.currentLocation {
                Annotation("You", coordinate: location.coordinate) {
                    PulsatingLocationDot()
                }
            } else {
                UserAnnotation()
            }
            
            // Start/End marker
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
            
            // Route polyline (with caching and waypoint segment support)
            if let currentRoute = viewModel.walkSession.currentRoute,
               currentRoute.routePath.count >= 2,
               !isShowingReturnRoute {
                // Shows full route during intro, current leg when walking
                // Supports waypoint carousel viewing with route segments
                MapPolyline(coordinates: polylineToShow)
                    .stroke(currentRoute.color, lineWidth: 4)
            }
            
            // Waypoint markers
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
            
            // Return route polyline
            if isShowingReturnRoute || viewingWaypointId == Self.returnToStartWaypointId {
                MapPolyline(coordinates: returnSegment)
                    .stroke(Color.blue, lineWidth: 5)
            }
        }
        .mapStyle(.standard)
        .mapControls {
            // Empty - we'll add custom controls in the overlay
        }
        .onMapCameraChange { context in
            // ... extensive interaction detection logic ...
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !userInteractedWithMap {
                        handleMapInteraction()
                    }
                    lastInteractionTime = Date()
                }
        )
        .onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
            // ... location update logic with grace period ...
        }
        .onChange(of: viewModel.locationService.heading) { _, newHeading in
            // ... heading update logic with grace period ...
        }
    }
}
```

## Key State Variables

```swift
@State private var cameraPosition: MapCameraPosition = .automatic
@State private var userInteractedWithMap: Bool = false
@State private var lastInteractionTime: Date?
@State private var isProgrammaticCameraUpdate: Bool = false
@State private var lastProgrammaticUpdateTime: Date?
@State private var lastAutoResumeTime: Date?
@State private var currentCameraState: MapCamera?
@State private var currentZoomLevel: Double = 150.0

// Grace period
private let interactionGracePeriod: TimeInterval = 0.3

private var isInInteractionGracePeriod: Bool {
    guard let last = lastInteractionTime else { return false }
    return Date().timeIntervalSince(last) < interactionGracePeriod
}
```

## updateCamera() Function (lines 1874-1965)

```swift
private func updateCamera(location: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
    // v1.9.22: CRITICAL FIX - Hard-block all camera updates during user interaction
    guard !userInteractedWithMap else {
        print("🚫 updateCamera BLOCKED — user interacting")
        return
    }
    
    // Get current heading
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
    
    // Get distance (closer zoom when approaching turn)
    let existingCamera = currentCameraState
    let baseDistance = existingCamera?.distance ?? currentZoomLevel
    let distance = isApproachingTurn ? min(baseDistance, 100.0) : baseDistance
    
    // Calculate changes for animation decision
    let existingHeading = existingCamera?.heading ?? 0
    let headingDiff = abs(targetHeading - existingHeading)
    let normalizedHeadingDiff = min(headingDiff, 360 - headingDiff)
    
    let locationChange: Double = {
        guard let existing = existingCamera else { return 100 }
        let latDiff = existing.centerCoordinate.latitude - location.latitude
        let lonDiff = existing.centerCoordinate.longitude - location.longitude
        return sqrt(latDiff * latDiff + lonDiff * lonDiff) * 111000
    }()
    
    // Create new camera
    let camera = MapCamera(
        centerCoordinate: location,
        distance: distance,
        heading: targetHeading,
        pitch: existingCamera?.pitch ?? 0
    )
    
    // v1.9.22: Do NOT mark passive follow updates as "programmatic"
    currentCameraState = camera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    
    // Update strategy: no animation for small changes, short animation for large changes
    if normalizedHeadingDiff > 15 || locationChange > 20 {
        withAnimation(.linear(duration: 0.08)) {
            cameraPosition = .camera(camera)
        }
    } else {
        cameraPosition = .camera(camera)
    }
}
```

## updateCameraZoom() Function (lines 1829-1868)

```swift
private func updateCameraZoom() {
    // CRITICAL: Don't move camera if user has interacted with map
    guard !userInteractedWithMap else {
        return
    }
    
    guard let currentLocation = viewModel.locationService.currentLocation else {
        return
    }
    
    // Get current heading
    let heading: CLLocationDirection = {
        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            return trueHeading
        } else if currentLocation.course >= 0 {
            return currentLocation.course
        } else {
            return currentCameraState?.heading ?? 0
        }
    }()
    
    // v1.9.22: Do NOT mark passive zoom updates as "programmatic"
    let newCamera = MapCamera(
        centerCoordinate: currentLocation.coordinate,
        distance: currentZoomLevel,
        heading: heading,
        pitch: 0
    )
    currentCameraState = newCamera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    
    withAnimation(.easeInOut(duration: 1.5)) {
        cameraPosition = .camera(newCamera)
    }
}
```

## handleMapInteraction() Function (lines 1980-2143)

```swift
private func handleMapInteraction() {
    let now = Date()
    
    // Set interaction flag
    userInteractedWithMap = true
    lastLocationWhenInteracted = viewModel.locationService.currentLocation
    
    // Cancel any existing resume timer
    autoFollowResumeTimer?.invalidate()
    
    // Create new auto-resume timer (checks every 0.5s, resumes after 5s)
    let timer = Timer(timeInterval: 0.5, repeats: true) { [self] timer in
        let now = Date()
        
        guard userInteractedWithMap && introPhase == .followingUser else {
            timer.invalidate()
            return
        }
        
        guard let lastInteraction = lastInteractionTime else {
            timer.invalidate()
            return
        }
        
        let timeSinceLastInteraction = now.timeIntervalSince(lastInteraction)
        
        guard timeSinceLastInteraction >= 5.0 else {
            return // User still interacting
        }
        
        // User stopped interacting for 5 seconds - auto-resume
        timer.invalidate()
        resumeAutoFollow()
    }
    
    RunLoop.main.add(timer, forMode: .common)
    autoFollowResumeTimer = timer
}
```

## resumeAutoFollow() Function (lines 2145-2211)

```swift
private func resumeAutoFollow() {
    guard introPhase == .followingUser,
          let currentLocation = viewModel.locationService.currentLocation else {
        return
    }
    
    // Clear interaction flag
    userInteractedWithMap = false
    lastLocationWhenInteracted = nil
    lastAutoResumeTime = Date() // Track for vulnerability window
    
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
    
    // Smoothly animate back to user location
    let newCamera = MapCamera(
        centerCoordinate: currentLocation.coordinate,
        distance: currentZoomLevel,
        heading: heading,
        pitch: 0
    )
    
    currentCameraState = newCamera
    isProgrammaticCameraUpdate = true
    lastProgrammaticUpdateTime = Date()
    
    withAnimation(.easeInOut(duration: 1.5)) {
        cameraPosition = .camera(newCamera)
    }
}
```

## Location Update Handler with Grace Period (lines 1219-1280)

```swift
.onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
    guard let location = newLocation else { return }
    guard introPhase == .followingUser else { return }
    
    // v1.9.22: Grace period after interaction to prevent immediate snap-back
    if isInInteractionGracePeriod {
        print("📍 [LOCATION UPDATE] ⏸ Grace period — skipping camera update")
        return
    }
    
    // Location updates blocked when user has interacted
    if userInteractedWithMap {
        // Safety reset if blocked for >10s
        if let lastInteraction = lastInteractionTime,
           now.timeIntervalSince(lastInteraction) > 10.0 {
            userInteractedWithMap = false
            lastInteractionTime = nil
            autoFollowResumeTimer?.invalidate()
        } else {
            return
        }
    }
    
    // Update camera to follow user
    updateCamera(location: location.coordinate)
    
    // Update zoom based on distance to next waypoint
    adjustZoomForWaypoint()
}
```

## Heading Update Handler with Grace Period (lines 1310-1380)

```swift
.onChange(of: viewModel.locationService.heading) { _, newHeading in
    guard let heading = newHeading else { return }
    guard introPhase == .followingUser else { return }
    
    // v1.9.22: Grace period after interaction to prevent immediate snap-back
    if isInInteractionGracePeriod {
        print("⏸ Grace period — skipping camera update")
        return
    }
    
    // Allow heading updates even when user has interacted - arrow should always rotate
    // Only block location updates when user has interacted
    guard let currentLocation = viewModel.locationService.currentLocation else { return }
    
    // Update camera heading
    updateCamera(location: currentLocation.coordinate, heading: heading.trueHeading)
}
```

## Key Features

1. **Hard-Block in updateCamera()**: Blocks all camera updates when `userInteractedWithMap` is true
2. **Gesture Detection**: `simultaneousGesture` with `DragGesture` detects interactions immediately
3. **Grace Period (0.3s)**: Prevents immediate snap-back after finger lift
4. **Passive Updates Not Programmatic**: `updateCamera()` and `updateCameraZoom()` don't set programmatic flags
5. **Auto-Resume Timer**: Checks every 0.5s, resumes after 5s of no interaction
6. **Vulnerability Window**: Tracks auto-resume time to detect false positives
