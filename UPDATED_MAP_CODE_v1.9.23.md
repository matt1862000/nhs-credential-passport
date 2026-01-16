# Updated Map Code - v1.9.23 (Build 197)

## Map Body Structure

```swift
var body: some View {
    ZStack {
        Map(position: $cameraPosition) {
            // ----------------------
            // User Location
            // ----------------------
            if let location = viewModel.locationService.currentLocation {
                Annotation("You", coordinate: location.coordinate) {
                    PulsatingLocationDot()
                }
            } else {
                UserAnnotation()
            }
            
            // ----------------------
            // Start/End Marker
            // ----------------------
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
            
            // ----------------------
            // Active Route Polyline
            // ----------------------
            if let currentRoute = viewModel.walkSession.currentRoute,
               currentRoute.routePath.count >= 2,
               !isShowingReturnRoute {
                // If viewing a waypoint in carousel, show route segment from Google routePath
                if let viewingId = viewingWaypointId,
                   viewingId != Self.returnToStartWaypointId,
                   let waypointPolyline = waypointRoutePolyline,
                   !waypointPolyline.isEmpty {
                    MapPolyline(coordinates: waypointPolyline)
                        .stroke(currentRoute.color, lineWidth: 4)
                } else {
                    // Normal route display (full route or current leg)
                    let polylineToShow: [CLLocationCoordinate2D] = {
                        if introPhase == .followingUser {
                            // Use cached polyline if available and still valid
                            let nextWaypointId = getNextWaypointId(markers: currentRoute.qrMarkers, visitedIds: viewModel.visitedMarkerIds)
                            if let cached = cachedCurrentLegPolyline,
                               cachedLegPolylineForWaypoint == nextWaypointId {
                                return cached
                            } else {
                                // Return calculated polyline - cache will be updated via onChange handler
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
                    }()
                    
                    MapPolyline(coordinates: polylineToShow)
                        .stroke(currentRoute.color, lineWidth: 4)
                }
            }
            
            // ----------------------
            // Waypoints
            // ----------------------
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
            
            // ----------------------
            // Return Route Polyline
            // ----------------------
            if isShowingReturnRoute || viewingWaypointId == Self.returnToStartWaypointId {
                if let currentRoute = viewModel.walkSession.currentRoute,
                   let lastWaypoint = currentRoute.qrMarkers.last,
                   let startLocation = viewModel.walkSession.startLocation ?? currentRoute.routePath.first {
                    let returnSegment = extractReturnSegmentFromRoutePath(
                        routePath: currentRoute.routePath,
                        fromWaypoint: lastWaypoint.coordinate,
                        toStart: startLocation
                    )
                    
                    if !returnSegment.isEmpty && returnSegment.count >= 2 {
                        MapPolyline(coordinates: returnSegment)
                            .stroke(Color.blue, lineWidth: 5)
                    } else if let returnRoute = returnRoute {
                        MapPolyline(returnRoute.polyline)
                            .stroke(Color.blue, lineWidth: 5)
                    } else if viewModel.hasCachedReturnRoute && !viewModel.cachedReturnRoutePolyline.isEmpty {
                        MapPolyline(coordinates: viewModel.cachedReturnRoutePolyline)
                            .stroke(Color.blue, lineWidth: 5)
                    }
                }
            }
            
            // ----------------------
            // Preview Cached Route / POIs (PASSIVE, NO CAMERA UPDATES)
            // ----------------------
            if let previewRoute = viewModel.selectedRoute,
               viewModel.walkSession.currentRoute == nil,
               !previewRoute.routePath.isEmpty {
                MapPolyline(coordinates: previewRoute.routePath)
                    .stroke(previewRoute.color, lineWidth: 4)
            }
            
            if let previewRoute = viewModel.selectedRoute,
               viewModel.walkSession.currentRoute == nil {
                ForEach(Array(previewRoute.qrMarkers.enumerated()), id: \.element.id) { index, marker in
                    Annotation(marker.name, coordinate: marker.coordinate) {
                        WaypointMarkerView(
                            name: marker.name,
                            index: index + 1,
                            isNext: false,
                            isVisited: false
                        )
                    }
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            // Empty, custom controls in overlay
        }
        .onMapCameraChange { context in
            // Interaction detection logic remains
            // (user pan/zoom sets userInteractedWithMap via onMapCameraChange)
        }
        // ----------------------
        // Remove simultaneousGesture completely
        // ----------------------
        // Interaction detection handled via onMapCameraChange only
    }
    // ----------------------
    // Overlay (non-blocking)
    // ----------------------
    .overlay(
        showingIntroOverlay ? IntroOverlayView(introPhase: introPhase).allowsHitTesting(false) : nil
    )
}
```

## Intro Overlay View

```swift
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
```

## Key Changes in v1.9.23

### 1. **Organized Structure**
- Clear section headers with `// ----------------------` dividers
- Logical grouping: User Location → Start/End → Active Route → Waypoints → Return Route → Preview

### 2. **Preview Cached Route/POIs** (NEW)
- Shows `selectedRoute` when no active walk session (`walkSession.currentRoute == nil`)
- Displays route polyline and waypoint markers
- **Passive display only** - no camera updates triggered
- Helps users preview routes before starting a walk

### 3. **Removed simultaneousGesture**
- No longer using `DragGesture` for interaction detection
- Interaction detection handled **only** via `onMapCameraChange`
- Prevents gesture conflicts with Map's built-in pan/zoom

### 4. **Separate Overlay Modifier**
- Intro overlay moved to `.overlay()` modifier
- Added `.allowsHitTesting(false)` to prevent blocking gestures
- Created `IntroOverlayView` struct for cleaner code

## Map Content Sections

1. **User Location**: PulsatingLocationDot or UserAnnotation
2. **Start/End Marker**: Blue circle with white center
3. **Active Route Polyline**: Current route being walked (with caching and waypoint segment support)
4. **Waypoints**: All waypoint markers with next one prominent
5. **Return Route Polyline**: Route back to start (with fallbacks)
6. **Preview Route/POIs**: Selected route preview when no active walk

## Interaction Detection

- **Method**: `onMapCameraChange` only
- **No gestures**: `simultaneousGesture` removed
- **Grace period**: 0.3s after interaction to prevent snap-back
- **Hard-block**: `updateCamera()` blocks all updates when `userInteractedWithMap` is true
