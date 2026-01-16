# Code Changes - v1.9.22 (Build 196)

## Summary
**Commit**: `7ff67e1`  
**Date**: Fri Jan 16 20:49:17 2026  
**Author**: Raihan Talukdar

**Status**: ✅ No uncommitted changes - working directory matches HEAD

## Files Changed
- `WalkingWR.xcodeproj/project.pbxproj` (2 lines changed)
- `WalkingWR/Views/WalkingMapView.swift` (55 lines changed: +52 insertions, -7 deletions)

---

## Detailed Changes

### 1. Build Number Increment
**File**: `WalkingWR.xcodeproj/project.pbxproj`

```diff
- CURRENT_PROJECT_VERSION = 195;
+ CURRENT_PROJECT_VERSION = 196;
```
Changed in both Debug and Release configurations.

---

### 2. Interaction Grace Period
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: After `lastAutoResumeTime` state variable (line ~347)

**Added**:
```swift
// v1.9.22: Post-interaction grace period to prevent immediate snap-back
// Absorbs heading bursts and animation completion callbacks after finger lift
private let interactionGracePeriod: TimeInterval = 0.3

private var isInInteractionGracePeriod: Bool {
    guard let last = lastInteractionTime else { return false }
    return Date().timeIntervalSince(last) < interactionGracePeriod
}
```

**Purpose**: Prevents immediate snap-back after user interaction by blocking updates for 0.3 seconds after finger lift.

---

### 3. Gesture-Based Interaction Detection
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: After polyline caching logic (line ~1186)

**Added**:
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

**Purpose**: Detects user interactions immediately via drag gesture, before `onMapCameraChange` fires.

---

### 4. Grace Period Check in Location Updates
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: In `onChange(of: viewModel.locationService.currentLocation)` handler (line ~1237)

**Added**:
```swift
// v1.9.22: Grace period after interaction to prevent immediate snap-back
// Absorbs heading bursts and animation completion callbacks after finger lift
if isInInteractionGracePeriod {
    print("📍 [LOCATION UPDATE] ⏸ Grace period — skipping camera update (time since interaction: \(String(format: "%.2f", Date().timeIntervalSince(lastInteractionTime ?? Date())))s)")
    return
}
```

**Purpose**: Skips location-based camera updates during the 0.3s grace period after interaction.

---

### 5. Grace Period Check in Heading Updates
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: In `onChange(of: viewModel.locationService.heading)` handler (line ~1338)

**Added**:
```swift
// v1.9.22: Grace period after interaction to prevent immediate snap-back
// Absorbs heading bursts and animation completion callbacks after finger lift
if isInInteractionGracePeriod {
    print("⏸ Grace period — skipping camera update (time since interaction: \(String(format: "%.2f", Date().timeIntervalSince(lastInteractionTime ?? Date())))s)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("")
    return
}
```

**Purpose**: Skips heading-based camera updates during the 0.3s grace period after interaction.

---

### 6. Hard-Block in updateCamera()
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: At the start of `updateCamera()` function (line ~1875)

**Added**:
```swift
// v1.9.22: CRITICAL FIX - Hard-block all camera updates during user interaction
// This prevents snap-back even if interaction detection is late or heading/location updates fire
guard !userInteractedWithMap else {
    print("🚫 updateCamera BLOCKED — user interacting")
    return
}
```

**Purpose**: Hard-blocks all camera updates when user is interacting, preventing snap-back even if detection is delayed.

---

### 7. Remove Programmatic Flags from updateCameraZoom()
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: In `updateCameraZoom()` function (line ~1863)

**Changed**:
```diff
- isProgrammaticCameraUpdate = true
- lastProgrammaticUpdateTime = Date()
+ // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
+ // They are only set for intentional recentering actions
```

**Added comment**:
```swift
// v1.9.22: Do NOT mark passive zoom updates as "programmatic"
```

**Purpose**: Passive zoom updates are no longer marked as programmatic, preventing them from masking real user gestures.

---

### 8. Remove Programmatic Flags from updateCamera()
**File**: `WalkingWR/Views/WalkingMapView.swift`  
**Location**: In `updateCamera()` function (line ~1933)

**Changed**:
```diff
- isProgrammaticCameraUpdate = true
- lastProgrammaticUpdateTime = updateTime
+ // NOTE: isProgrammaticCameraUpdate and lastProgrammaticUpdateTime are NOT set here
+ // They are only set for intentional recentering actions
```

**Changed log message**:
```diff
- print("🔧 PROGRAMMATIC CAMERA UPDATE (updateCamera)")
+ print("🔧 PASSIVE CAMERA UPDATE (updateCamera - following user)")
```

**Added comment**:
```swift
// v1.9.22: Do NOT mark passive follow updates as "programmatic"
// Only intentional recentering (resumeAutoFollow, intro animation, zoom-to-waypoint) should set these flags
// This prevents passive updates from masking real user gestures in onMapCameraChange
```

**Purpose**: Passive follow updates are no longer marked as programmatic. Only intentional recentering actions (resumeAutoFollow, intro animation, zoom-to-waypoint) set these flags.

---

## Impact Summary

### What These Changes Fix
1. **Snap-back Prevention**: Hard-block in `updateCamera()` prevents camera from jumping back to user location during interaction
2. **Immediate Detection**: Gesture-based detection catches interactions before `onMapCameraChange` fires
3. **Grace Period**: 0.3s grace period absorbs animation callbacks and heading bursts after finger lift
4. **Better Gesture Detection**: Passive updates no longer mask real user gestures in `onMapCameraChange`

### What Still Sets Programmatic Flags
Only these intentional recentering actions set `isProgrammaticCameraUpdate` and `lastProgrammaticUpdateTime`:
- `resumeAutoFollow()` - When auto-follow resumes after 5s
- Intro animation phases - When showing first waypoint, full route, then following user
- `zoomToTurn()` - When zooming to an approaching turn

### What No Longer Sets Programmatic Flags
- `updateCamera()` - Passive following updates
- `updateCameraZoom()` - Passive zoom adjustments

---

## Testing Notes
- Test manual map panning - should not snap back immediately
- Test auto-follow resume - should work after 5s of no interaction
- Test turn zoom - should still zoom to turns when approaching
- Test heading rotation - arrow should continue rotating even during interaction
