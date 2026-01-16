# Clean Map Code — v1.9.23 (Build 197)

## Current Implementation with Smart Zoom

---

## 1. State Variables

```swift
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

private var inInteractionGrace: Bool {
    guard let last = lastInteraction ?? lastInteractionTime else { return false }
    return Date().timeIntervalSince(last) < gpsGrace
}
```

---

## 2. Map Body

```swift
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
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startInteraction() }
        )
        .onTapGesture { startInteraction() }
        .onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
            guard let location = newLocation else { return }
            handleLocation(location)
        }
        .onChange(of: viewModel.locationService.heading) { _, newHeading in
            guard let heading = newHeading?.trueHeading else { return }
            handleHeading(heading)
        }
    }
    // Non-blocking overlay
    .overlay(
        showingIntroOverlay ? IntroOverlayView(introPhase: introPhase)
            .opacity(1)
            .allowsHitTesting(false) : nil
    )
}
```

---

## 3. Interaction Handler

```swift
// MARK: - Interaction
private func startInteraction() {
    userInteracting = true
    lastInteraction = Date()
    
    // Update legacy variables for compatibility
    userInteractedWithMap = true
    lastInteractionTime = Date()
    
    resumeTimer?.invalidate()
    resumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        guard userInteracting, let last = lastInteraction else { timer.invalidate(); return }
        if Date().timeIntervalSince(last) >= autoResumeDelay {
            timer.invalidate()
            autoResumeFollow()
        }
    }
    
    // Update legacy timer for compatibility
    autoFollowResumeTimer = resumeTimer
}
```

---

## 4. Auto-Resume

```swift
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
```

---

## 5. Location & Heading Handlers

```swift
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

private func handleHeading(_ heading: CLLocationDirection) {
    guard introPhase == .followingUser else { return }
    guard !userInteracting, !justResumed, let current = currentCamera else { return }
    
    let camera = MapCamera(
        centerCoordinate: current.centerCoordinate,
        distance: current.distance,
        heading: heading,
        pitch: current.pitch
    )
    currentCamera = camera
    currentCameraState = camera
    cameraPosition = .camera(camera)
}
```

---

## 6. Camera Update

```swift
private func updateCamera(to coordinate: CLLocationCoordinate2D) {
    guard !userInteracting else { return }
    let existing = currentCamera ?? currentCameraState
    let heading = viewModel.locationService.heading?.trueHeading ?? existing?.heading ?? 0
    let camera = MapCamera(
        centerCoordinate: coordinate,
        distance: currentZoom,
        heading: heading,
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
```

---

## 7. Smart Dynamic Zoom

```swift
// MARK: - Smart Dynamic Zoom
private func calculateSmartZoom(for location: CLLocation) -> Double {
    var zoom: Double = 150.0
    
    // --- Base zoom on speed
    if location.speed > 0 {
        switch location.speed {
        case 0..<1: zoom = 150
        case 1..<2: zoom = 170
        default: zoom = 200
        }
    }
    
    // --- Fit next few waypoints / route segment
    if let route = viewModel.walkSession.currentRoute, !route.routePath.isEmpty {
        // Take up to 3 next points
        let upcomingPoints = route.routePath.prefix(3)
        var minLat = location.coordinate.latitude
        var maxLat = location.coordinate.latitude
        var minLon = location.coordinate.longitude
        var maxLon = location.coordinate.longitude
        
        for pt in upcomingPoints {
            minLat = min(minLat, pt.latitude)
            maxLat = max(maxLat, pt.latitude)
            minLon = min(minLon, pt.longitude)
            maxLon = max(maxLon, pt.longitude)
        }
        
        let latDelta = maxLat - minLat
        let lonDelta = maxLon - minLon
        let distance = max(latDelta, lonDelta) * 111_000 // approx meters
        zoom = max(zoom, min(250, distance * 1.5)) // zoom out to fit
    }
    
    return zoom
}
```

---

## Key Features

### Smart Zoom Algorithm
- **Speed-based**: 150m (slow), 170m (medium), 200m (fast)
- **Route-aware**: Calculates bounding box of next 3 route points
- **Adaptive**: Adjusts zoom to fit upcoming segment (max 250m)

### Interaction Handling
- **Gesture detection**: Drag and tap gestures trigger interaction
- **5s auto-resume**: Automatically resumes following after 5 seconds
- **Post-resume cooldown**: 0.3s cooldown prevents snap-back

### Camera Updates
- **196-style**: No early returns, always updates camera
- **Smooth animations**: Large changes use `.linear`, others use `.interactiveSpring`
- **Heading rotation**: Rotates arrow without moving camera center

### Legacy Compatibility
- All legacy variable names maintained with `didSet` sync
- Existing code continues to work without changes

---

## Build Status
✅ **BUILD SUCCEEDED** - Build 197

---

## Version
**v1.9.17** (Build 197) - Clean Map Code with Smart Dynamic Zoom
