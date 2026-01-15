# Auto-Snap Fixes Applied (v1.9.16)

## Issues Found and Fixed

### 1. ✅ `updateCameraZoom()` Not Checking User Interaction
**Problem:** `updateCameraZoom()` was moving the camera even when user had interacted with the map.

**Location:** `WalkingMapView.swift` line 1356

**Fix:** Added guard to check `userInteractedWithMap` before updating camera:
```swift
guard !userInteractedWithMap else {
    print("🎯 [UPDATE CAMERA ZOOM] ❌ BLOCKED: userInteractedWithMap == true")
    return
}
```

**Impact:** Prevents camera from snapping back when zoom changes occur after user interaction.

---

### 2. ✅ `startActiveZoom()` Not Checking User Interaction
**Problem:** `startActiveZoom()` was moving the camera even when user had interacted with the map.

**Location:** `WalkingMapView.swift` line 1260

**Fix:** Added guard to check `userInteractedWithMap` before starting active zoom:
```swift
guard !userInteractedWithMap else {
    print("🎯 [ACTIVE ZOOM] ❌ BLOCKED: userInteractedWithMap == true")
    return
}
```

**Impact:** Prevents camera from snapping back when passing a turn or starting active zoom after user interaction.

---

### 3. ✅ `showFullRouteThenFollow()` Overriding User Interaction
**Problem:** `showFullRouteThenFollow()` was forcing resume after 2 seconds even if user had interacted.

**Location:** `WalkingMapView.swift` line 1215-1219

**Fix:** Added check to only resume if user hasn't interacted:
```swift
if introPhase == .followingUser && !userInteractedWithMap {
    resumeAutoFollow()
}
```

**Impact:** Prevents forced resume when user taps location button while they've already interacted with map.

---

### 4. ✅ Grace Period Too Short for Programmatic Updates
**Problem:** 0.5 second grace period was too short, causing false positives where programmatic updates were detected as user interactions.

**Location:** `WalkingMapView.swift` line 503

**Fix:** Increased grace period from 0.5s to 1.0s:
```swift
let isRecentProgrammaticUpdate = lastProgrammaticUpdateTime != nil &&
    now.timeIntervalSince(lastProgrammaticUpdateTime!) < 1.0  // Increased from 0.5
```

**Impact:** Reduces false positives where programmatic camera updates are incorrectly detected as user interactions.

---

## Remaining Potential Issues (Not Fixed Yet)

### ⚠️ Issue 5: Timer Race Condition
**Location:** `WalkingMapView.swift` line 1498-1558

**Potential Problem:** The timer checks every 0.5 seconds. If `lastInteractionTime` is updated at the wrong moment, it could trigger early.

**Mitigation:** The timer already checks `timeSinceLastInteraction >= 5.0`, so this should be safe. But if there's a race condition where `lastInteractionTime` gets reset incorrectly, it could cause issues.

**Recommendation:** Add more logging to track when `lastInteractionTime` is updated and why.

---

### ⚠️ Issue 6: Multiple Timers Running
**Potential Problem:** If `handleMapInteraction()` is called multiple times quickly, multiple timers might be created.

**Current Protection:** The code does `autoFollowResumeTimer?.invalidate()` before creating a new timer, so this should be safe.

---

### ⚠️ Issue 7: `.userLocation()` Automatic Snapping
**Location:** `WalkingMapView.swift` lines 609, 1040, 1187, 1266

**Potential Problem:** Using `.userLocation()` can cause automatic snapping behavior in SwiftUI MapKit.

**Current Usage:**
- Line 609: Location button (user-initiated, OK)
- Line 1040: Intro phase setup (should be OK)
- Line 1187: `showFullRouteThenFollow()` fallback (could be issue)
- Line 1266: `startActiveZoom()` fallback (now guarded by `userInteractedWithMap` check)

**Recommendation:** Consider replacing `.userLocation()` with explicit `.camera()` calls for more control.

---

## Testing Checklist

After these fixes, test the following scenarios:

1. ✅ **User zooms out, then waits 5 seconds** → Should auto-resume
2. ✅ **User zooms out, then continues interacting** → Should NOT auto-resume
3. ✅ **User zooms out, then passes a turn** → Should NOT snap back (was Issue 1)
4. ✅ **User zooms out, then taps location button** → Should show full route, then resume only if user hasn't interacted (was Issue 3)
5. ✅ **User zooms out, then location updates** → Should NOT snap back (already guarded)
6. ✅ **User zooms out, then heading updates** → Should NOT snap back (already guarded)
7. ✅ **User zooms out, then zoom level changes** → Should NOT snap back (was Issue 1)

---

## Summary

**Fixed Issues:** 4
- `updateCameraZoom()` now respects user interaction
- `startActiveZoom()` now respects user interaction
- `showFullRouteThenFollow()` now respects user interaction
- Grace period increased to prevent false positives

**Remaining Concerns:** 3
- Timer race conditions (mitigated by 5-second check)
- Multiple timers (protected by invalidation)
- `.userLocation()` automatic behavior (mostly user-initiated or guarded)

These fixes should significantly reduce inappropriate auto-snapping behavior.
