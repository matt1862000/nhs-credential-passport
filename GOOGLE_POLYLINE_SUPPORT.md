# Google Directions API Polyline Support

## Overview
The map view (`EmbeddedWalkMapView`) fully supports Google Directions API polylines alongside MapKit routes. Google polylines are automatically decoded and rendered exactly like MapKit routes.

---

## How It Works

### 1. Polyline Decoding
Google Directions API returns encoded polylines (string format). These are automatically decoded via:

**`PolylineDecoder.decode()`** (in `Models.swift`):
- Decodes Google's encoded polyline format
- Returns `[CLLocationCoordinate2D]` array
- Used automatically by `WalkingRoute.routePath`

### 2. Route Structure
**`WalkingRoute`** (in `Models.swift`):
```swift
struct WalkingRoute {
    let encodedPolyline: String?  // Google encoded polyline string
    // ... other properties
    
    /// Decoded route path coordinates for map display
    /// Uses Google's encoded polyline if available, otherwise falls back to marker coordinates
    var routePath: [CLLocationCoordinate2D] {
        if let polyline = encodedPolyline, !polyline.isEmpty {
            return PolylineDecoder.decode(polyline)  // ✅ Automatic decoding
        }
        // Fallback to marker coordinates if no polyline
        return qrMarkers.map { $0.coordinate }
    }
}
```

### 3. Route Assignment
When `GeneratedRoute` (from Google Directions) is converted to `WalkingRoute`:
```swift
let route = WalkingRoute(
    // ... other properties
    encodedPolyline: result.polyline,  // ✅ Google polyline assigned here
    walkingDirections: directions
)
```

The polyline is stored as an encoded string and decoded on-demand via `routePath`.

---

## Map Rendering

### Active Route Polyline
The map uses `polylineToShow` computed property:
```swift
private var polylineToShow: [CLLocationCoordinate2D] {
    guard let currentRoute = viewModel.walkSession.currentRoute,
          currentRoute.routePath.count >= 2 else { return [] }
    
    // routePath automatically decodes Google polylines if encodedPolyline is set
    return currentRoute.routePath  // ✅ Works with Google polylines
}
```

**Rendering**:
```swift
MapPolyline(coordinates: polylineToShow)
    .stroke(currentRoute.color, lineWidth: 4)
```

### Return Route
```swift
private var returnSegment: [CLLocationCoordinate2D] {
    // Uses currentRoute.routePath which handles Google polylines
    let segment = extractReturnSegmentFromRoutePath(
        routePath: currentRoute.routePath,  // ✅ Already decoded
        fromWaypoint: lastWaypoint.coordinate,
        toStart: startLocation
    )
    // ...
}
```

---

## Smart Zoom Support

Smart zoom automatically works with Google polylines:
```swift
private func calculateSmartZoom(for location: CLLocation) -> Double {
    // ...
    if let route = viewModel.walkSession.currentRoute, !route.routePath.isEmpty {
        // routePath automatically decodes Google polylines
        let upcoming = route.routePath.prefix(3)  // ✅ Works with Google polylines
        // Calculate bounding box and zoom...
    }
}
```

---

## Waypoints Support

Waypoints work identically for both MapKit and Google routes:
```swift
// Waypoints from route markers
ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
    Annotation(marker.name, coordinate: marker.coordinate) {
        WaypointMarkerView(...)
    }
}
```

Waypoints come from `currentRoute.qrMarkers`, which are the same regardless of route source.

---

## Cached POIs Support

Cached POIs work identically:
```swift
// Cached POIs (passive)
if let cachedMarkers = cachedPOIs,
   viewModel.walkSession.currentRoute == nil {
    ForEach(cachedMarkers, id: \.id) { marker in
        Annotation(marker.name, coordinate: marker.coordinate) {
            WaypointMarkerView(...)
        }
    }
}
```

---

## Auto-Follow Support

Auto-follow works identically for Google routes:
```swift
private func handleLocation(_ location: CLLocation) {
    // ...
    currentZoom = calculateSmartZoom(for: location)  // ✅ Works with Google routes
    updateCamera(to: location.coordinate)
}
```

The camera follows the user's location along the route, regardless of whether it's a MapKit or Google route.

---

## Gesture Support

Gestures are fully interactive via `.simultaneousGesture()`:
```swift
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
```

✅ **Map remains fully interactive** - pan, zoom, and rotate all work.

---

## Cached Routes Support

Cached routes already store Google polylines:
```swift
struct CachedRoute {
    let polyline: String  // ✅ Google encoded polyline string
    // ...
}
```

When cached routes are loaded, they're converted back to `WalkingRoute` with `encodedPolyline` set, so decoding works automatically.

---

## Complete Flow

### Google Directions Route:
```
1. Google Directions API returns route with encoded polyline
   ↓
2. GeneratedRoute.polyline (String) contains encoded polyline
   ↓
3. WalkingRoute created with encodedPolyline: result.polyline
   ↓
4. viewModel.walkSession.currentRoute = route
   ↓
5. Map accesses currentRoute.routePath
   ↓
6. routePath computed property checks encodedPolyline
   ↓
7. If set, PolylineDecoder.decode() decodes it
   ↓
8. Returns [CLLocationCoordinate2D] array
   ↓
9. MapPolyline renders the decoded coordinates
   ✅ Rendered on map!
```

### MapKit Route:
```
1. MapKit returns MKRoute with polyline
   ↓
2. WalkingRoute created with encodedPolyline: nil (or MapKit polyline encoded)
   ↓
3. routePath falls back to marker coordinates OR uses encoded polyline
   ↓
4. MapPolyline renders coordinates
   ✅ Rendered on map!
```

---

## Key Points

1. **Automatic Decoding**: `WalkingRoute.routePath` automatically decodes Google polylines
2. **Transparent**: Map code doesn't need to know if route is from Google or MapKit
3. **Smart Zoom**: Works with both route types
4. **Waypoints**: Work identically
5. **Cached POIs**: Work identically
6. **Auto-Follow**: Works identically
7. **Gestures**: Fully interactive via `.simultaneousGesture()`
8. **Cached Routes**: Already support Google polylines

---

## Verification

The system is **already fully set up** to support Google Directions polylines:

✅ `PolylineDecoder` exists and works
✅ `WalkingRoute.routePath` automatically decodes Google polylines
✅ Map uses `currentRoute.routePath` which handles both types
✅ Smart zoom uses `route.routePath` which works with both
✅ Waypoints, cached POIs, auto-follow all work identically
✅ Gestures use `.simultaneousGesture()` for full interactivity

**No additional changes needed** - the system is designed to handle both MapKit and Google routes transparently!
