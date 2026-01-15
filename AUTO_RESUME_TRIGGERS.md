# Auto-Resume Triggers Analysis

## Summary
There are **2 places** that can trigger auto-resume in the map:

---

## 1. Timer-Based Auto-Resume (Primary Trigger)
**Location:** `WalkingMapView.swift` line 1498-1558

**How it works:**
- A repeating timer checks every 0.5 seconds
- After **5 seconds** of no user interaction, it calls `resumeAutoFollow()`
- This is the main auto-resume mechanism

**Conditions that must be met:**
- `userInteractedWithMap == true` (user has interacted)
- `introPhase == .followingUser` (in following mode)
- `lastInteractionTime` exists
- `timeSinceLastInteraction >= 5.0` seconds

**Potential Issues:**
- The timer runs every 0.5 seconds, so there's a small window where it could trigger
- If `lastInteractionTime` is updated incorrectly, it might trigger early

---

## 2. Show Full Route Then Follow (Secondary Trigger)
**Location:** `WalkingMapView.swift` line 1215-1219

**How it works:**
- When user taps the location button, it shows full route
- After **2 seconds**, it calls `resumeAutoFollow()` to return to following mode

**Conditions:**
- `introPhase == .followingUser` (must be in following mode)
- This is only called when user explicitly taps the location button

**Potential Issues:**
- If this is called when `userInteractedWithMap == true`, it will force resume even if user was interacting
- The 2-second delay might conflict with the 5-second timer

---

## What Could Cause Unexpected Auto-Resume?

### Issue 1: `onMapCameraChange` False Positives
**Location:** `WalkingMapView.swift` line 496-546

The `onMapCameraChange` handler might be incorrectly detecting programmatic updates as user interactions, or vice versa.

**Current protection:**
- Checks `isProgrammaticCameraUpdate` flag
- Checks `lastProgrammaticUpdateTime` with 0.5 second grace period
- But if the grace period is too short, programmatic updates might be detected as user interactions

### Issue 2: Timer Race Condition
**Location:** `WalkingMapView.swift` line 1498

The timer runs every 0.5 seconds and checks conditions. If `lastInteractionTime` is updated at the wrong moment, it could trigger early.

### Issue 3: `showFullRouteThenFollow` Override
**Location:** `WalkingMapView.swift` line 1215-1219

If `showFullRouteThenFollow()` is called while `userInteractedWithMap == true`, it will force resume after 2 seconds, overriding the user's interaction.

### Issue 4: Location/Heading Updates Triggering Camera Changes
**Location:** `WalkingMapView.swift` line 829, 879

If location or heading updates cause camera changes that are detected by `onMapCameraChange`, they might be incorrectly classified as user interactions or trigger resume.

---

## Recommendations to Fix

### 1. Increase Grace Period for Programmatic Updates
Change the 0.5 second grace period to 1.0 second to be more conservative:

```swift
let isRecentProgrammaticUpdate = lastProgrammaticUpdateTime != nil &&
    now.timeIntervalSince(lastProgrammaticUpdateTime!) < 1.0  // Increased from 0.5
```

### 2. Add Guard in `showFullRouteThenFollow`
Prevent `showFullRouteThenFollow` from resuming if user has interacted:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
    if introPhase == .followingUser && !userInteractedWithMap {  // Add check
        resumeAutoFollow()
    }
}
```

### 3. Add More Logging
Add logging to track when and why auto-resume is triggered:

```swift
print("🔄 [AUTO-RESUME] Triggered from: [SOURCE]")
print("🔄 [AUTO-RESUME] userInteractedWithMap: \(userInteractedWithMap)")
print("🔄 [AUTO-RESUME] timeSinceLastInteraction: \(timeSinceLastInteraction)")
```

### 4. Check for Multiple Timers
Ensure only one timer is running at a time. The current code invalidates the timer, but there might be edge cases where multiple timers exist.

---

## Current Auto-Resume Flow

```
User interacts with map
    ↓
handleMapInteraction() called
    ↓
userInteractedWithMap = true
lastInteractionTime = Date()
Timer starts (checks every 0.5s)
    ↓
[User continues interacting]
    ↓
onMapCameraChange updates lastInteractionTime
    ↓
[User stops interacting]
    ↓
Timer checks: timeSinceLastInteraction >= 5.0?
    ↓ YES
resumeAutoFollow() called
    ↓
userInteractedWithMap = false
Camera animates back to user location
```

---

## Debugging Steps

1. **Check logs for:** `⏰ AUTO-RESUME TRIGGERED` - this shows when timer triggers
2. **Check logs for:** `🔄 RESUMING AUTO-FOLLOW` - this shows when resume happens
3. **Check logs for:** `✅ DETECTED AS USER INTERACTION` - this shows when interactions are detected
4. **Check logs for:** `❌ NOT USER INTERACTION (programmatic update)` - this shows false positives

If you see auto-resume happening unexpectedly, check:
- Was `lastInteractionTime` updated recently?
- Is `isProgrammaticCameraUpdate` being set correctly?
- Is the 0.5 second grace period long enough?
- Is `showFullRouteThenFollow` being called unexpectedly?
