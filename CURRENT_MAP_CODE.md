# Current Map Code - v1.9.22 (Build 196)

## Key Features

### 1. Interaction Grace Period (v1.9.22)
```swift
// Post-interaction grace period to prevent immediate snap-back
// Absorbs heading bursts and animation completion callbacks after finger lift
private let interactionGracePeriod: TimeInterval = 0.3

private var isInInteractionGracePeriod: Bool {
    guard let last = lastInteractionTime else { return false }
    return Date().timeIntervalSince(last) < interactionGracePeriod
}
```

### 2. Gesture-Based Interaction Detection
```swift
.simultaneousGesture(
    DragGesture(minimumDistance: 0)
        .onChanged { _ in
            if !userInteractedWithMap {
                handleMapInteraction()
            }
            lastInteractionTime = Date()
        }
)
```

### 3. Map View Structure
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
            // ... interaction detection logic ...
        }
    }
}
```

### 4. Hard-Block Camera Updates During Interaction
```swift
private func updateCamera(location: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
    // v1.9.22: CRITICAL FIX - Hard-block all camera updates during user interaction
    // This prevents snap-back even if interaction detection is late or heading/location updates fire
    guard !userInteractedWithMap else {
        print("🚫 updateCamera BLOCKED — user interacting")
        return
    }
    
    // ... rest of camera update logic ...
    
    // v1.9.22: Do NOT mark passive follow updates as "programmatic"
    // Only intentional recentering (resumeAutoFollow, intro animation, zoom-to-waypoint) should set these flags
    // This prevents passive updates from masking real user gestures in onMapCameraChange
    currentCameraState = camera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    // They are only set for intentional recentering actions
}
```

### 5. Grace Period in Location Updates
```swift
.onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
    // ... location update logic ...
    
    // v1.9.22: Grace period after interaction to prevent immediate snap-back
    // Absorbs heading bursts and animation completion callbacks after finger lift
    if isInInteractionGracePeriod {
        print("📍 [LOCATION UPDATE] ⏸ Grace period — skipping camera update (time since interaction: \(String(format: "%.2f", Date().timeIntervalSince(lastInteractionTime ?? Date())))s)")
        return
    }
    
    // ... continue with location update ...
}
```

### 6. Grace Period in Heading Updates
```swift
.onChange(of: viewModel.locationService.heading) { _, newHeading in
    // ... heading update logic ...
    
    // v1.9.22: Grace period after interaction to prevent immediate snap-back
    // Absorbs heading bursts and animation completion callbacks after finger lift
    if isInInteractionGracePeriod {
        print("⏸ Grace period — skipping camera update (time since interaction: \(String(format: "%.2f", Date().timeIntervalSince(lastInteractionTime ?? Date())))s)")
        return
    }
    
    // ... continue with heading update ...
}
```

### 7. Passive Zoom Updates (Not Marked as Programmatic)
```swift
private func updateCameraZoom() {
    // CRITICAL: Don't move camera if user has interacted with map
    guard !userInteractedWithMap else {
        return
    }
    
    // ... zoom update logic ...
    
    // v1.9.22: Do NOT mark passive zoom updates as "programmatic"
    let newCamera = MapCamera(...)
    currentCameraState = newCamera
    // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
    // They are only set for intentional recentering actions
    withAnimation(.easeInOut(duration: 1.5)) {
        cameraPosition = .camera(newCamera)
    }
}
```

## Key Changes from Previous Version

1. **Added Interaction Grace Period**: 0.3 second grace period after user interaction to prevent immediate snap-back from heading bursts or animation callbacks

2. **Gesture-Based Detection**: Added `simultaneousGesture` with `DragGesture` to detect user interactions directly

3. **Hard-Block in updateCamera()**: Added guard at the top of `updateCamera()` to block all updates when `userInteractedWithMap` is true

4. **Passive Updates Not Marked as Programmatic**: 
   - `updateCamera()` no longer sets `isProgrammaticCameraUpdate` or `lastProgrammaticUpdateTime`
   - `updateCameraZoom()` no longer sets these flags
   - Only intentional recentering actions (resumeAutoFollow, intro animation, zoom-to-waypoint) set these flags

5. **Grace Period Checks**: Added grace period checks in both location and heading `onChange` handlers to skip updates immediately after interaction

## State Variables

```swift
@State private var userInteractedWithMap: Bool = false
@State private var lastInteractionTime: Date?
@State private var isProgrammaticCameraUpdate: Bool = false
@State private var lastProgrammaticUpdateTime: Date?
@State private var lastAutoResumeTime: Date?

// Grace period
private let interactionGracePeriod: TimeInterval = 0.3
```

## Interaction Flow

1. User touches map → `simultaneousGesture` fires → `handleMapInteraction()` called → `userInteractedWithMap = true`, `lastInteractionTime = Date()`

2. Location/heading updates fire → Check `isInInteractionGracePeriod` → If true, skip update

3. `updateCamera()` called → Check `userInteractedWithMap` → If true, hard-block and return

4. After 5 seconds of no interaction → `resumeAutoFollow()` called → `userInteractedWithMap = false`, camera animates back to user

5. Grace period (0.3s) prevents immediate snap-back from animation callbacks or heading bursts after finger lift
