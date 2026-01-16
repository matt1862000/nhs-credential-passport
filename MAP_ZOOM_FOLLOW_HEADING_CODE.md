# Map Zoom, Follow, and Heading Code Reference

This document contains all code related to map zoom, auto-follow, and heading functionality in `WalkingMapView.swift`.

## Table of Contents
1. [State Variables](#state-variables)
2. [Camera Position & Map View](#camera-position--map-view)
3. [Zoom Functions](#zoom-functions)
4. [Auto-Follow Functions](#auto-follow-functions)
5. [Camera Update Functions](#camera-update-functions)
6. [Location & Heading Update Handlers](#location--heading-update-handlers)
7. [Intro Animation Phases](#intro-animation-phases)

---

## State Variables

```swift
// Camera position state
@State private var cameraPosition: MapCameraPosition = .automatic

// Zoom management
@State private var lastZoomUpdate: Date = Date()
@State private var currentZoomLevel: Double = 150.0 // meters
@State private var currentCameraState: MapCamera? // Track camera state separately

// Auto-follow state
@State private var introPhase: IntroPhase = .showingFirstWaypoint
@State private var userInteractedWithMap: Bool = false  // Cancels intro animation
@State private var autoFollowResumeTimer: Timer?
@State private var isProgrammaticCameraUpdate: Bool = false
@State private var lastProgrammaticUpdateTime: Date?
@State private var lastInteractionTime: Date?
@State private var lastLocationWhenInteracted: CLLocation?
@State private var sustainedSpeedStartTime: Date?

// Turn navigation
@State private var isApproachingTurn: Bool = false
@State private var distanceToNextTurn: Double? = nil

// Intro phases enum
enum IntroPhase: String {
    case showingFirstWaypoint = "First waypoint"
    case showingFullRoute = "Your route"
    case followingUser = "Your location"
}
```

---

## Camera Position & Map View

```swift
Map(position: $cameraPosition) {
    // User location
    UserAnnotation()
    
    // Clinic marker
    Annotation("Clinic", coordinate: clinicCoordinate) {
        // ... marker view
    }
    
    // Route polylines
    // ... route rendering
}
.onMapCameraChange { context in
    // Handles camera change detection and user interaction detection
    // ... (see full implementation in file)
}
```

---

## Zoom Functions

### startActiveZoom()
Initializes active zoom mode with camera following user location.

```swift
private func startActiveZoom() {
    print("🎯 [ACTIVE ZOOM] startActiveZoom called")
    
    // CRITICAL: Don't move camera if user has interacted with map
    guard !userInteractedWithMap else {
        print("🎯 [ACTIVE ZOOM] ❌ BLOCKED: userInteractedWithMap == true")
        return
    }
    
    guard let currentLocation = viewModel.locationService.currentLocation else {
        print("🎯 [ACTIVE ZOOM] ❌ No location, using fallback userLocation")
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
        return
    }
    
    currentZoomLevel = 150.0 // Default zoom level in meters
    // Get heading from location service or location course
    let heading: CLLocationDirection = {
        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            print("🎯 [ACTIVE ZOOM] Using trueHeading: \(trueHeading)°")
            return trueHeading
        } else if currentLocation.course >= 0 {
            print("🎯 [ACTIVE ZOOM] Using location.course: \(currentLocation.course)°")
            return currentLocation.course
        } else {
            print("🎯 [ACTIVE ZOOM] ⚠️ No heading available, using 0°")
            return 0
        }
    }()
    
    print("🎯 [ACTIVE ZOOM] Setting up camera: location=(\(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)), heading=\(heading)°, zoom=\(currentZoomLevel)m")
    
    // Use camera with heading for smooth rotation + custom zoom
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
    
    print("🎯 [ACTIVE ZOOM] ✅ Camera initialized with heading \(heading)°")
}
```

### updateActiveZoom(for location: CLLocation)
Adjusts zoom level based on distance to next waypoint.

```swift
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
```

### updateCameraZoom()
Updates camera zoom level smoothly while maintaining heading.

```swift
private func updateCameraZoom() {
    // CRITICAL: Don't move camera if user has interacted with map
    guard !userInteractedWithMap else {
        print("🎯 [UPDATE CAMERA ZOOM] ❌ BLOCKED: userInteractedWithMap == true")
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

### zoomToWaypoint(_ coordinate: CLLocationCoordinate2D)
Zooms to a specific waypoint.

```swift
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
```

### zoomToTurn(_ coordinate: CLLocationCoordinate2D)
Zooms to a turn when approaching it.

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
    
    let smoothAnimation = Animation.easeInOut(duration: 1.0)
    let newCamera = MapCamera(
        centerCoordinate: coordinate,
        distance: 100.0,  // Closer zoom for turns
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
```

---

## Auto-Follow Functions

### handleMapInteraction()
Handles user map interaction - disables auto-follow temporarily and sets up auto-resume timer.

```swift
private func handleMapInteraction() {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timeString = formatter.string(from: now)
    
    let currentLocation = viewModel.locationService.currentLocation
    let currentCamera = currentCameraState
    
    print("")
    print("═══════════════════════════════════════════════════════════")
    print("👆👆👆 MAP INTERACTION DETECTED 👆👆👆")
    print("═══════════════════════════════════════════════════════════")
    print("⏰ Time: \(timeString)")
    print("")
    print("📍 CURRENT STATE:")
    print("  userInteractedWithMap: \(userInteractedWithMap) → true (changing)")
    print("  introPhase: \(introPhase.rawValue)")
    print("  lastInteractionTime: \(lastInteractionTime != nil ? formatter.string(from: lastInteractionTime!) : "nil")")
    if let loc = currentLocation {
        print("  Current location: (\(String(format: "%.6f", loc.coordinate.latitude)), \(String(format: "%.6f", loc.coordinate.longitude)))")
    } else {
        print("  Current location: nil")
    }
    if let cam = currentCamera {
        print("  Current camera center: (\(String(format: "%.6f", cam.centerCoordinate.latitude)), \(String(format: "%.6f", cam.centerCoordinate.longitude)))")
        print("  Current camera heading: \(String(format: "%.1f", cam.heading))°")
        print("  Current camera distance: \(String(format: "%.1f", cam.distance))m")
    } else {
        print("  Current camera: nil")
    }
    print("")
    print("⚠️ ACTION: Setting userInteractedWithMap = true")
    print("⚠️ Location updates will be blocked, but heading updates will continue")
    print("⚠️ Will auto-resume after 5 seconds of no interaction")
    print("═══════════════════════════════════════════════════════════")
    print("")
    
    // Set interaction flag to disable auto-follow/auto-zoom
    let wasInteracting = userInteractedWithMap
    userInteractedWithMap = true
    
    // v1.9.16: DIAGNOSTIC - Log when userInteractedWithMap changes from false to true
    if !wasInteracting {
        print("")
        print("🚨🚨🚨 userInteractedWithMap CHANGED: false → true 🚨🚨🚨")
        print("  Time: \(timeString)")
        print("  This means auto-follow is now DISABLED")
        print("  Auto-resume timer will start (5 seconds)")
        if let autoResumeTime = lastAutoResumeTime {
            let timeSinceAutoResume = now.timeIntervalSince(autoResumeTime)
            print("  Time since last auto-resume: \(String(format: "%.2f", timeSinceAutoResume))s")
            if timeSinceAutoResume < 3.0 {
                print("  ⚠️⚠️⚠️ IN VULNERABILITY WINDOW - This might be a FALSE POSITIVE! ⚠️⚠️⚠️")
            }
        }
        print("🚨🚨🚨 END STATE CHANGE 🚨🚨🚨")
        print("")
    }
    
    // Record current location when user starts interacting
    lastLocationWhenInteracted = currentLocation
    
    // Cancel any existing resume timer
    if autoFollowResumeTimer != nil {
        print("  ⏰ Cancelling existing auto-resume timer")
        autoFollowResumeTimer?.invalidate()
    }
    
    // Use a repeating timer that checks if user has stopped interacting for 5 seconds
    // CRITICAL: We check timeSinceLastInteraction FIRST - if user is still interacting, 
    // lastInteractionTime keeps getting updated, so timeSinceLastInteraction never reaches 5.0
    print("  ⏰ Creating new auto-resume timer (will check every 0.5s, auto-resume after 5s)")
    // v1.9.16: Use common run loop modes so timer fires even when app is busy
    let timer = Timer(timeInterval: 0.5, repeats: true) { [self] timer in
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: now)
        
        // v1.9.16: DIAGNOSTIC - Log every timer fire to confirm it's running
        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⏰ AUTO-RESUME TIMER CHECK (timer fired)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Time: \(timeString)")
        print("userInteractedWithMap: \(userInteractedWithMap)")
        print("introPhase: \(introPhase.rawValue)")
        print("lastInteractionTime: \(lastInteractionTime != nil ? formatter.string(from: lastInteractionTime!) : "nil")")
        print("Timer is valid: \(timer.isValid)")
        
        // CRITICAL: Don't auto-resume if user is still actively interacting
        // If userInteractedWithMap is false, user already resumed - stop timer
        guard userInteractedWithMap && introPhase == .followingUser else {
            print("❌ BLOCKED: userInteractedWithMap=\(userInteractedWithMap), introPhase=\(introPhase.rawValue)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            timer.invalidate()
            return
        }
        
        // Check if 5 seconds have passed since last interaction
        // If user is still interacting, lastInteractionTime keeps updating, so this never triggers
        guard let lastInteraction = lastInteractionTime else {
            print("❌ BLOCKED: lastInteractionTime is nil")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            timer.invalidate()
            return
        }
        
        let timeSinceLastInteraction = now.timeIntervalSince(lastInteraction)
        print("timeSinceLastInteraction: \(String(format: "%.2f", timeSinceLastInteraction))s")
        
        // CRITICAL: Only proceed if user has STOPPED interacting for 5 seconds
        // If they're still interacting, lastInteractionTime keeps updating, so this stays < 5.0
        guard timeSinceLastInteraction >= 5.0 else {
            // User is still interacting (lastInteractionTime was updated recently)
            print("⏸️ User still interacting (only \(String(format: "%.2f", timeSinceLastInteraction))s since last interaction)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            return
        }
        
        // User has stopped interacting for 5 seconds - auto-resume regardless of movement
        print("")
        print("═══════════════════════════════════════════════════════════════════════════")
        print("⏰⏰⏰ AUTO-RESUME TRIGGERED ⏰⏰⏰")
        print("═══════════════════════════════════════════════════════════════════════════")
        print("⏰ Time: \(timeString)")
        print("⏰ Time since last interaction: \(String(format: "%.2f", timeSinceLastInteraction))s")
        print("⏰ Auto-resuming after 5 seconds of no interaction")
        print("")
        print("📊 STATE AT AUTO-RESUME:")
        print("  userInteractedWithMap: \(userInteractedWithMap) → false (will change)")
        print("  introPhase: \(introPhase.rawValue)")
        print("  lastInteractionTime: \(formatter.string(from: lastInteraction))")
        if let loc = viewModel.locationService.currentLocation {
            print("  Current location: (\(String(format: "%.6f", loc.coordinate.latitude)), \(String(format: "%.6f", loc.coordinate.longitude)))")
        } else {
            print("  Current location: nil")
        }
        if let cam = currentCameraState {
            print("  Current camera center: (\(String(format: "%.6f", cam.centerCoordinate.latitude)), \(String(format: "%.6f", cam.centerCoordinate.longitude)))")
            print("  Current camera heading: \(String(format: "%.1f", cam.heading))°")
        } else {
            print("  Current camera: nil")
        }
        print("═══════════════════════════════════════════════════════════════════════════")
        print("")
        timer.invalidate()
        sustainedSpeedStartTime = nil
        
        // v1.9.16: Note: lastAutoResumeTime will be set inside resumeAutoFollow()
        // This ensures it's tracked regardless of where resumeAutoFollow() is called from
        
        resumeAutoFollow()
    }
    // Schedule timer on common run loop modes so it fires even when app is busy
    RunLoop.main.add(timer, forMode: .common)
    autoFollowResumeTimer = timer
    print("  ⏰ Timer scheduled on .common run loop mode (will fire even when app is busy)")
    print("  ⏰ Timer stored: \(autoFollowResumeTimer != nil), isValid: \(timer.isValid)")
    print("  ⏰ Timer will fire every 0.5s, auto-resume after 5.0s of no interaction")
}
```

### resumeAutoFollow()
Resumes auto-follow and auto-zoom after user interaction with smooth animation.

```swift
private func resumeAutoFollow() {
    print("🔄 [RESUME AUTO-FOLLOW] resumeAutoFollow called")
    print("🔄 [RESUME AUTO-FOLLOW] introPhase: \(introPhase.rawValue), followingUser: \(introPhase == .followingUser)")
    print("🔄 [RESUME AUTO-FOLLOW] currentLocation: \(viewModel.locationService.currentLocation != nil ? "available" : "nil")")
    
    guard introPhase == .followingUser,
          let currentLocation = viewModel.locationService.currentLocation else {
        print("🔄 [RESUME AUTO-FOLLOW] ❌ BLOCKED: introPhase != .followingUser or no location")
        return
    }
    
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timeString = formatter.string(from: Date())
    
    print("")
    print("═══════════════════════════════════════════════════════════")
    print("🔄 RESUMING AUTO-FOLLOW")
    print("═══════════════════════════════════════════════════════════")
    print("Time: \(timeString)")
    print("Setting userInteractedWithMap = false")
    print("✅ Location and heading updates will resume")
    print("═══════════════════════════════════════════════════════════")
    print("")
    
    // Clear interaction flag and location tracking
    userInteractedWithMap = false
    lastLocationWhenInteracted = nil
    sustainedSpeedStartTime = nil // Reset sustained speed tracking
    
    // v1.9.16: Track auto-resume time for vulnerability window detection
    // Set this here so it works regardless of where resumeAutoFollow() is called from
    let now = Date()
    lastAutoResumeTime = now
    print("")
    print("📌📌📌 AUTO-RESUME TRACKING: lastAutoResumeTime set to \(formatter.string(from: now)) 📌📌📌")
    print("  ⚠️ VULNERABILITY WINDOW ACTIVE: Next 3 seconds are high-risk for false positives")
    print("  ⚠️ Any user interaction detected in this window will be flagged as suspicious")
    print("📌📌📌 END AUTO-RESUME TRACKING 📌📌📌")
    print("")
    
    // Clear old diagnostic history (keep last 5 for context)
    if recentCameraChanges.count > 5 {
        recentCameraChanges.removeFirst(recentCameraChanges.count - 5)
    }
    
    // Get current heading
    let heading: CLLocationDirection = {
        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            print("🔄 [RESUME AUTO-FOLLOW] Using trueHeading: \(trueHeading)°")
            return trueHeading
        } else if currentLocation.course >= 0 {
            print("🔄 [RESUME AUTO-FOLLOW] Using location.course: \(currentLocation.course)°")
            return currentLocation.course
        } else if let camera = currentCameraState {
            print("🔄 [RESUME AUTO-FOLLOW] Using existing camera heading: \(camera.heading)°")
            return camera.heading
        } else {
            print("🔄 [RESUME AUTO-FOLLOW] ⚠️ No heading available, using 0°")
            return 0
        }
    }()
    
    print("🔄 [RESUME AUTO-FOLLOW] Setting camera: location=(\(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)), heading=\(heading)°, zoom=\(currentZoomLevel)m")
    
    // Smoothly animate back to user location with camera follow, zoom, and heading
    let newCamera = MapCamera(
        centerCoordinate: currentLocation.coordinate,
        distance: currentZoomLevel,
        heading: heading,
        pitch: 0
    )
    let updateTime = Date()
    let updateTimeString = formatter.string(from: updateTime)
    
    currentCameraState = newCamera
    isProgrammaticCameraUpdate = true
    lastProgrammaticUpdateTime = updateTime

    print("")
    print("🔧 PROGRAMMATIC CAMERA UPDATE (resumeAutoFollow)")
    print("  Time: \(updateTimeString)")
    print("  Location: (\(String(format: "%.6f", currentLocation.coordinate.latitude)), \(String(format: "%.6f", currentLocation.coordinate.longitude)))")
    print("  Heading: \(String(format: "%.1f", heading))°")
    print("  Distance: \(String(format: "%.1f", currentZoomLevel))m")
    print("  Animation: YES (1.5s easeInOut)")
    print("  userInteractedWithMap: \(userInteractedWithMap)")
    print("")

    // Smooth animation back to user location
    withAnimation(.easeInOut(duration: 1.5)) {
        cameraPosition = .camera(newCamera)
    }
    
    print("🔄 [RESUME AUTO-FOLLOW] ✅ Camera resumed with heading \(heading)°")
    
    // Clear timer
    autoFollowResumeTimer?.invalidate()
    autoFollowResumeTimer = nil
}
```

---

## Camera Update Functions

### updateCamera(location:heading:)
Unified camera update function that handles both location and heading updates.

```swift
private func updateCamera(location: CLLocationCoordinate2D, heading: CLLocationDirection? = nil) {
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
    let distance = isApproachingTurn ? min(baseDistance, 100.0) : baseDistance
    
    // Calculate changes for smooth animation decision
    let existingHeading = existingCamera?.heading ?? 0
    let headingDiff = abs(targetHeading - existingHeading)
    
    // Normalize heading difference (handle 360° wrap-around)
    let normalizedHeadingDiff = min(headingDiff, 360 - headingDiff)
    
    // Calculate location change distance
    let locationChange: Double = {
        guard let existing = existingCamera else { return 100 } // Large value to force update
        let latDiff = existing.centerCoordinate.latitude - location.latitude
        let lonDiff = existing.centerCoordinate.longitude - location.longitude
        // Rough conversion: 1 degree ≈ 111km, so 0.0001° ≈ 11m
        return sqrt(latDiff * latDiff + lonDiff * lonDiff) * 111000 // Convert to meters
    }()
    
    // Create new camera instance - always follow user location
    let camera = MapCamera(
        centerCoordinate: location,
        distance: distance,
        heading: targetHeading,
        pitch: existingCamera?.pitch ?? 0
    )
    
    // Update camera state
    let updateTime = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timeString = formatter.string(from: updateTime)
    
    currentCameraState = camera
    isProgrammaticCameraUpdate = true
    lastProgrammaticUpdateTime = updateTime
    
    print("")
    print("🔧 PROGRAMMATIC CAMERA UPDATE (updateCamera)")
    print("  Time: \(timeString)")
    print("  Location: (\(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)))")
    print("  Heading: \(String(format: "%.1f", targetHeading))°")
    print("  Distance: \(String(format: "%.1f", distance))m")
    print("  Location change: \(String(format: "%.1f", locationChange))m")
    print("  Heading change: \(String(format: "%.1f", normalizedHeadingDiff))°")
    print("  Animation: \(normalizedHeadingDiff > 15 || locationChange > 20 ? "YES (large change)" : "NO (small change)")")
    print("  userInteractedWithMap: \(userInteractedWithMap)")
    print("")
    
    // Update strategy:
    // - No animation for small, frequent changes (smooth and responsive)
    // - Short animation only for larger changes (prevents jumps)
    // - Always update to follow user, even when approaching turn
    if normalizedHeadingDiff > 15 || locationChange > 20 {
        // Large change: use very short animation to smooth the jump
        withAnimation(.linear(duration: 0.08)) {
            cameraPosition = .camera(camera)
        }
    } else {
        // Small change: update instantly for smooth following
        cameraPosition = .camera(camera)
    }
}
```

### updateCameraCenter(to:)
Helper to update camera center smoothly.

```swift
private func updateCameraCenter(to coordinate: CLLocationCoordinate2D) {
    updateCamera(location: coordinate)
}
```

### updateCameraHeading(to:at:)
Helper to update camera heading smoothly.

```swift
private func updateCameraHeading(to heading: CLLocationDirection, at coordinate: CLLocationCoordinate2D) {
    updateCamera(location: coordinate, heading: heading)
}
```

---

## Location & Heading Update Handlers

### Location Update Handler
Handles location updates and updates camera to follow user.

```swift
.onChange(of: viewModel.locationService.currentLocation) { _, newLocation in
    let now = Date()
    guard let location = newLocation else {
        print("📍 [LOCATION UPDATE] No location available")
        return
    }
    
    print("📍 [LOCATION UPDATE] New location: (\(location.coordinate.latitude), \(location.coordinate.longitude)), course=\(location.course >= 0 ? "\(location.course)°" : "invalid")")
    print("📍 [LOCATION UPDATE] introPhase: \(introPhase.rawValue), followingUser: \(introPhase == .followingUser)")
    print("📍 [LOCATION UPDATE] userInteractedWithMap: \(userInteractedWithMap)")
    print("📍 [LOCATION UPDATE] isApproachingTurn: \(isApproachingTurn)")
    
    guard introPhase == .followingUser else {
        print("📍 [LOCATION UPDATE] ❌ BLOCKED: introPhase != .followingUser")
        return
    }
    
    // Location updates are blocked when user has interacted (to prevent camera jumping)
    // But heading updates are allowed separately to keep arrow rotating
    // v1.9.16: Safety mechanism - if blocked for too long (>10s), auto-reset to prevent stuck state
    if userInteractedWithMap {
        if let lastInteraction = lastInteractionTime {
            let timeSinceInteraction = now.timeIntervalSince(lastInteraction)
            if timeSinceInteraction > 10.0 {
                // Safety reset: userInteractedWithMap has been true for >10 seconds
                // This shouldn't happen (auto-resume should fire at 5s), but if timer fails, this prevents stuck state
                print("📍 [LOCATION UPDATE] ⚠️ SAFETY RESET: userInteractedWithMap blocked for \(String(format: "%.1f", timeSinceInteraction))s (>10s), auto-resetting")
                userInteractedWithMap = false
                lastInteractionTime = nil
                autoFollowResumeTimer?.invalidate()
                autoFollowResumeTimer = nil
                // Continue to update camera below
            } else {
                print("📍 [LOCATION UPDATE] ❌ BLOCKED: userInteractedWithMap == true (location updates blocked, but heading updates allowed)")
                print("📍 [LOCATION UPDATE]   Time since interaction: \(String(format: "%.1f", timeSinceInteraction))s (auto-resume at 5s)")
                return
            }
        } else {
            // No lastInteractionTime but userInteractedWithMap is true - inconsistent state, reset
            print("📍 [LOCATION UPDATE] ⚠️ SAFETY RESET: userInteractedWithMap=true but lastInteractionTime=nil, resetting")
            userInteractedWithMap = false
            autoFollowResumeTimer?.invalidate()
            autoFollowResumeTimer = nil
            // Continue to update camera below
        }
    }
    
    // Allow camera updates even when approaching turn - just follow user smoothly
    // The turn zoom is handled separately, but we still need to follow user movement
    print("📍 [LOCATION UPDATE] ✅ PROCEEDING: Updating camera (isApproachingTurn: \(isApproachingTurn))")
    
    // Update zoom every 5 seconds or when distance to next waypoint changes significantly
    let timeSinceLastUpdate = Date().timeIntervalSince(lastZoomUpdate)
    if timeSinceLastUpdate >= 5.0 {
        updateActiveZoom(for: location)
        lastZoomUpdate = Date()
    }
    
    // Update camera with both location and current heading together
    // This ensures smooth updates and prevents camera state from being nil
    let currentHeading: CLLocationDirection? = {
        if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
            return trueHeading
        } else if location.course >= 0 {
            return location.course
        } else {
            return nil // Will use existing heading or default
        }
    }()
    
    updateCamera(location: location.coordinate, heading: currentHeading)
}
```

### Heading Update Handler
Handles heading updates and rotates camera to match device rotation.

```swift
.onChange(of: viewModel.locationService.headingDegrees) { oldHeading, newHeading in
    let timestamp = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timeString = formatter.string(from: timestamp)
    
    print("")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🔄 MAP VIEW: HEADING CHANGE DETECTED")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("Time: \(timeString)")
    print("Old heading: \(oldHeading)°")
    print("New heading: \(newHeading)°")
    print("Difference: \(String(format: "%.2f", abs(newHeading - oldHeading)))°")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("STATE CHECK:")
    print("  introPhase: \(introPhase.rawValue)")
    print("  introPhase == .followingUser: \(introPhase == .followingUser)")
    print("  userInteractedWithMap: \(userInteractedWithMap)")
    print("  isApproachingTurn: \(isApproachingTurn)")
    print("  currentLocation: \(viewModel.locationService.currentLocation != nil ? "AVAILABLE" : "NIL")")
    print("  heading object: \(viewModel.locationService.heading != nil ? "AVAILABLE" : "NIL")")
    if let heading = viewModel.locationService.heading {
        print("  heading.trueHeading: \(heading.trueHeading >= 0 ? "\(heading.trueHeading)°" : "INVALID")")
        print("  heading.magneticHeading: \(heading.magneticHeading)°")
        print("  heading.headingAccuracy: \(heading.headingAccuracy >= 0 ? "\(heading.headingAccuracy)°" : "INVALID")")
    }
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    guard introPhase == .followingUser else {
        print("❌ BLOCKED: introPhase != .followingUser")
        print("Current introPhase: \(introPhase.rawValue)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        return
    }
    
    // Allow heading updates even when user has interacted - arrow should always rotate
    // Only block location updates when user has interacted, but allow heading rotation
    // This ensures the arrow continues to rotate smoothly even if user panned the map
    if userInteractedWithMap {
        print("⚠️ userInteractedWithMap == true - heading update will only rotate arrow, NOT move camera")
        // When user has interacted, we should NOT update the camera (which would move it back to user location)
        // The arrow rotation is handled by the rotationEffect modifier in the view, not by camera updates
        // So we just return here - the arrow will still rotate via the rotationEffect
        print("✅ Arrow will continue rotating via rotationEffect, but camera won't move")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        return
    }
    
    // Allow heading updates even when approaching turn - keep arrow rotating smoothly
    guard let currentLocation = viewModel.locationService.currentLocation else {
        print("❌ BLOCKED: currentLocation is nil")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        return
    }
    
    guard newHeading >= 0 else {
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("❌ BLOCKED: INVALID HEADING DETECTED")
        print("═══════════════════════════════════════════════════════════")
        print("Time: \(timeString)")
        print("newHeading: \(newHeading) (NEGATIVE - INVALID)")
        print("⚠️ This may indicate heading updates have stopped!")
        print("═══════════════════════════════════════════════════════════")
        print("")
        return
    }
    
    print("✅ PROCEEDING: All checks passed, updating camera")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("")
    
    // Update camera with both location and heading together for consistency
    updateCamera(location: currentLocation.coordinate, heading: newHeading)
    
    print("✅ Camera update completed at \(timeString)")
    print("")
}
```

---

## Intro Animation Phases

### playIntroAnimation()
Plays the intro camera animation sequence with smooth transitions.

```swift
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
        print("🎬 [INTRO ANIMATION] Phase 3: Switching to followingUser")
        print("🎬 [INTRO ANIMATION] userInteractedWithMap: \(userInteractedWithMap)")
        guard !userInteractedWithMap else {
            print("🎬 [INTRO ANIMATION] ❌ BLOCKED: User interacted, skipping phase 3")
            return // Skip if user interacted
        }
        
        // v1.9.13: Animate transition to user location smoothly
        withAnimation(verySlowAnimation) {
            print("🎬 [INTRO ANIMATION] ✅ Setting introPhase to .followingUser")
            introPhase = .followingUser
            
            // Set initial active zoom state
            currentZoomLevel = 150.0
            if let currentLocation = viewModel.locationService.currentLocation {
                let heading: CLLocationDirection = {
                    if let trueHeading = viewModel.locationService.heading?.trueHeading, trueHeading >= 0 {
                        print("🎬 [INTRO ANIMATION] Using trueHeading: \(trueHeading)°")
                        return trueHeading
                    } else if currentLocation.course >= 0 {
                        print("🎬 [INTRO ANIMATION] Using location.course: \(currentLocation.course)°")
                        return currentLocation.course
                    } else {
                        print("🎬 [INTRO ANIMATION] ⚠️ No heading available, using 0°")
                        return 0
                    }
                }()
                
                print("🎬 [INTRO ANIMATION] Setting initial camera: location=(\(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)), heading=\(heading)°, zoom=150m")
                
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
                
                print("🎬 [INTRO ANIMATION] ✅ Camera initialized, introPhase is now .followingUser")
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
```

---

## Key Concepts

### Zoom Levels
- **Default**: 150m
- **Close to waypoint (<50m)**: 100m
- **Near waypoint (50-200m)**: 120m
- **Medium distance (200-500m)**: 150m
- **Far from waypoint (>500m)**: 200m
- **Approaching turn**: 100m (closer zoom for visibility)

### Auto-Follow States
- **`.showingFirstWaypoint`**: Shows first waypoint (intro phase 1)
- **`.showingFullRoute`**: Shows full route overview (intro phase 2)
- **`.followingUser`**: Auto-follow enabled, camera follows user location and heading

### Interaction Handling
- When user interacts: `userInteractedWithMap = true`
- Location updates are blocked (camera doesn't jump)
- Heading updates continue (arrow still rotates)
- Auto-resume timer starts (5 seconds)
- After 5 seconds of no interaction: `resumeAutoFollow()` is called

### Camera Update Strategy
- **Small changes** (<15° heading, <20m location): Instant update (no animation)
- **Large changes** (>15° heading, >20m location): Short animation (0.08s linear)
- **Resume from interaction**: Smooth animation (1.5s easeInOut)

### Heading Priority
1. Provided heading parameter (if available)
2. Location service true heading
3. Location course
4. Existing camera heading
5. Default: 0°
