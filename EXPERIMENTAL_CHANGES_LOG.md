# Experimental Changes Log - Since 1.9.15 Build 186

This document captures all experimental changes made since the last stable version (1.9.15 Build 186, commit `14dc85b`). These changes can be re-implemented incrementally.

---

## Feature 1: Fix Map Lag and Waypoint Stall Issues (Build 187)

### Problem
- Map had significant lag when following user
- Map would stall/hang when approaching waypoints
- Camera updates were being blocked incorrectly

### Solution
**File: `WalkingWR/Views/WalkingMapView.swift`**

1. **Unified Camera Update Function**
   - Created `updateCamera(location:heading:)` function that combines location and heading updates
   - Removed separate `updateCameraCenter()` and `updateCameraHeading()` functions
   - Function initializes `currentCameraState` if nil to prevent blocking

2. **Removed Camera Update Blocking**
   - Removed `guard !isApproachingTurn` from location and heading `onChange` handlers
   - Camera now follows user smoothly even when approaching waypoints
   - Modified turn detection to only affect zoom, not camera updates

3. **Optimized Animation Timing**
   - Instant updates for small changes (<15° heading difference OR <20m location change)
   - Short animation (0.08s) for larger changes
   - Removed time-based throttling that caused stuttering

4. **Camera State Management**
   - Added `currentCameraState: MapCamera?` to track camera state separately
   - Prevents nil state from blocking updates

### Code Location
- Lines ~1365-1444: `updateCamera()` function
- Lines ~678-833: Modified `onChange` handlers for location and heading
- Lines ~761-779: Modified turn detection logic

---

## Feature 2: User Interaction Detection and Auto-Resume (Build 187)

### Problem
- When user zooms/swipes map, it would immediately snap back to their location
- No way to manually explore the map without interruption

### Solution
**File: `WalkingWR/Views/WalkingMapView.swift`**

1. **Timestamp-Based Interaction Detection**
   - Added `lastProgrammaticUpdateTime: Date?` to track when we update camera programmatically
   - Added `isProgrammaticCameraUpdate: Bool` flag
   - Modified `onMapCameraChange` to use 0.5s grace period to filter out programmatic updates
   - Only sets `userInteractedWithMap = true` if camera change is NOT from our code

2. **Block Location Updates During Interaction**
   - Added `guard !userInteractedWithMap` at start of `updateCamera()` function
   - Prevents location-based camera updates when user has interacted
   - Heading updates still allowed (for arrow rotation)

3. **Auto-Resume Timer**
   - Added `autoFollowResumeTimer: Timer?` state
   - In `handleMapInteraction()`, starts 30-second timer
   - Timer checks user speed - if speed < 0.5 m/s, auto-resumes following
   - Cleans up timer when user manually resumes or starts moving

4. **State Variables Added**
   ```swift
   @State private var isProgrammaticCameraUpdate: Bool = false
   @State private var lastProgrammaticUpdateTime: Date?
   @State private var lastInteractionTime: Date?
   @State private var lastLocationWhenInteracted: CLLocation?
   @State private var autoFollowResumeTimer: Timer?
   ```

### Code Location
- Lines ~497-515: `onMapCameraChange` handler
- Lines ~1365-1376: Guard in `updateCamera()` function
- Lines ~1235-1270: `handleMapInteraction()` function with auto-resume logic

---

## Feature 3: "Follow Me" Button (Build 188)

### Problem
- After user interacts with map, they need a way to manually resume auto-follow
- Auto-resume timer might not always trigger

### Solution
**File: `WalkingWR/Views/WalkingMapView.swift`**

1. **Button UI**
   - Added "Follow Me" button that appears when `userInteractedWithMap == true` and `introPhase == .followingUser`
   - Positioned in bottom-right, above `WaypointCarousel` with `padding(.bottom, 120)`
   - Uses `zIndex(100)` to ensure visibility
   - Styled with teal accent color, capsule shape, shadow

2. **Button Action**
   - Calls `showFullRouteThenFollow()` function
   - Resets `userInteractedWithMap = false`
   - Cancels auto-resume timer

### Code Location
- Lines ~604-633: "Follow Me" button SwiftUI code block

---

## Feature 4: Arrow Shows Direction of Travel (Build 188)

### Problem
- Arrow showed compass heading (device orientation)
- User wanted arrow to show direction they're actually moving

### Solution
**File: `WalkingWR/Views/WalkingMapView.swift`**

1. **Rotation Logic Change**
   - Changed from using `headingDegrees` (compass heading) to `location.course` (GPS direction of travel)
   - Falls back to `headingDegrees` if `course < 0` (invalid)
   - Inlined calculation in `rotationEffect` modifier to avoid compilation issues

2. **Code Location**
   - Lines ~341-358: Arrow rotation effect (in `Annotation("You", coordinate: location.coordinate)` block)
   - Uses: `let direction = location.course >= 0 ? location.course : viewModel.locationService.headingDegrees`

**File: `WalkingWR/Services/LocationService.swift`**

1. **Enhanced Heading Monitoring** (for debugging)
   - Added `lastHeadingUpdateTime: Date?`
   - Added `headingUpdateTimer: Timer?`
   - Added `startHeadingUpdateMonitoring()` and `stopHeadingUpdateMonitoring()` functions
   - Logs when heading updates stop (for debugging rotation issues)

### Code Location
- Lines ~472-484: Heading update monitoring functions (can be removed if not needed)

---

## Feature 5: Fix Route Display When Swiping Between Waypoints (Current/Uncommitted)

### Problem
- When swiping to a waypoint in carousel, route would disappear
- Route showed from start to waypoint instead of previous waypoint to current waypoint
- Return route (last waypoint → start) not showing when viewing "Return to Start"

### Solution
**File: `WalkingWR/Views/WalkingMapView.swift`**

1. **State Tracking**
   - Added `viewingWaypointId: UUID?` to track which waypoint user is viewing
   - Added `returnToStartWaypointId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!` constant

2. **Route Segment Calculation**
   - Added `calculateRouteSegmentToWaypoint()` function
   - Calculates route from previous waypoint to target waypoint
   - Handles edge cases (first waypoint uses start location, return route uses last waypoint)

3. **Modified Route Display Logic**
   - When `viewingWaypointId` is set, shows route segment to that waypoint
   - Otherwise, uses existing logic (current leg to next waypoint)
   - Return route display also checks `viewingWaypointId == returnToStartWaypointId`

4. **Carousel Integration**
   - Added `onSwipeToWaypoint: ((UUID?) -> Void)?` callback to `WaypointCarousel`
   - In `onChange(of: selectedIndex)`, calls callback with waypoint ID or return-to-start UUID
   - Updates `viewingWaypointId` and `isShowingReturnRoute` appropriately

### Code Location
- Lines ~307-308: State variables
- Lines ~403-429: Modified route display logic
- Lines ~482-507: Modified return route display
- Lines ~677-686: Carousel callback setup
- Lines ~1842-1906: `calculateRouteSegmentToWaypoint()` function
- Lines ~2025: `WaypointCarousel` callback parameter
- Lines ~2095-2099: Carousel `onChange` handler

---

## Implementation Order Recommendation

1. **Feature 1** (Map Lag Fix) - Core functionality, should be first
2. **Feature 2** (Interaction Detection) - Depends on Feature 1, prevents snap-back issues
3. **Feature 3** (Follow Me Button) - Depends on Feature 2, provides manual control
4. **Feature 4** (Arrow Direction) - Independent, can be added anytime
5. **Feature 5** (Route Display Fix) - Independent, can be added anytime

---

## Testing Checklist for Each Feature

### Feature 1: Map Lag Fix
- [ ] Map follows user smoothly without lag
- [ ] Map doesn't stall when approaching waypoints
- [ ] Camera updates are smooth and responsive

### Feature 2: Interaction Detection
- [ ] User can zoom/swipe map without immediate snap-back
- [ ] Auto-resume works after 30 seconds of no movement
- [ ] Manual interaction is correctly detected

### Feature 3: Follow Me Button
- [ ] Button appears when user interacts with map
- [ ] Button is visible (not covered by other UI)
- [ ] Button correctly resumes auto-follow

### Feature 4: Arrow Direction
- [ ] Arrow points in direction of travel (GPS course)
- [ ] Arrow falls back to compass when course unavailable
- [ ] Arrow rotates smoothly

### Feature 5: Route Display Fix
- [ ] Route shows correctly when swiping to waypoint 1
- [ ] Route shows waypoint 1 → waypoint 2 when viewing waypoint 2
- [ ] Return route shows when viewing "Return to Start"
- [ ] Routes don't disappear when swiping

---

## Notes

- All changes are in `WalkingWR/Views/WalkingMapView.swift` except Feature 4 which also touches `LocationService.swift`
- Build number should be incremented after each feature is tested and confirmed working
- Keep this document updated as features are re-implemented
