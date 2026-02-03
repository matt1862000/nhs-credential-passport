# "X mins left" with Google refresh – code to re-implement after revert

After you `git checkout .` (or `git restore .`) to return to the last commit, the "mins left" flow is **already there** except for one optional fix. Here’s what makes it work and what to add back.

---

## 1. What makes "mins left" work with Google refresh (already in last commit)

### A. WaitingRoomViewModel – `updateCurrentRoute`

**File:** `WalkingWR/ViewModels/WaitingRoomViewModel.swift`

When Google (or MapKit fallback) returns a refreshed route, we update the view model and notify observers so the pill and map use the new duration:

```swift
/// v2.1.1: Update current route with refreshed data (e.g., after background Google Directions fetch)
/// Updates both selectedRoute and walkSession.currentRoute so map refreshes automatically
func updateCurrentRoute(_ route: WalkingRoute) {
    selectedRoute = route
    if walkSession.isActive {
        walkSession.currentRoute = route

        // v2.1.1: Update direction monitoring with new directions
        if !route.walkingDirections.isEmpty {
            locationService.updateDirections(route.walkingDirections, routePath: route.routePath)
        }

        // Force UI refresh so "xx mins left" and other views pick up Google's duration (they observe viewModel, not WalkSession directly)
        objectWillChange.send()
    }
    print("🔄 [ROUTE UPDATE] Route updated: '\(route.name)' with \(route.walkingDirections.count) directions, \(route.routePath.count) polyline points, \(route.durationMinutes)min")
}
```

This is **already in the last commit** – no change needed after revert.

---

### B. RouteSelectionView – call `updateCurrentRoute` when Google returns

**File:** `WalkingWR/Views/RouteSelectionView.swift` (in `handleStartWalk`, inside the background `Task`)

After fetching Google Directions in the background we update the current route so the map and "mins left" use the new duration:

```swift
if let refreshedRoute = await mapsService.refreshRouteWithGoogleOnly(
    route: route,
    userLocation: userLocation
) {
    await MainActor.run {
        // Update the route with Google directions - map will refresh
        viewModel.updateCurrentRoute(refreshedRoute)
        // ... logging
    }
} else {
    // Optional: MapKit fallback then viewModel.updateCurrentRoute(mapKitRoute)
}
```

At **last commit** this is already present (Google path + optional MapKit fallback both call `viewModel.updateCurrentRoute(...)`). No change needed after revert.

---

### C. WalkingMapView – pill uses `walkSession.currentRoute?.durationMinutes`

**File:** `WalkingWR/Views/WalkingMapView.swift` (in `topOverlay`)

The ring/pill gets duration from the view model’s current route so it updates when Google (or fallback) updates the route:

```swift
CompactStatusRing(
    walkDurationMinutes: viewModel.walkSession.currentRoute?.durationMinutes ?? 15,
    walkStartTime: viewModel.walkSession.startTime,
    // ...
)
```

This is **already in the last commit** – no change needed after revert.

---

## 2. What to re-implement after revert (one addition)

The only thing that was added **after** the last commit for "mins left" is a **stable identity** on the pill so that when `objectWillChange.send()` runs, SwiftUI doesn’t tear down and recreate the pill (which would reset "Track steps?" / "mins left" flip state).

**File:** `WalkingWR/Views/WalkingMapView.swift`  
**Location:** Right after the closing `)` of `CompactStatusRing(...)` in `topOverlay`, before `Spacer()`.

**Add this line:**

```swift
                )
                .id("compactStatusRing") // Stable identity so Google refresh (objectWillChange) doesn't recreate pill and reset Track steps / mins left state

                Spacer()
```

So the full block looks like:

```swift
                CompactStatusRing(
                    walkDurationMinutes: viewModel.walkSession.currentRoute?.durationMinutes ?? 15,
                    walkStartTime: viewModel.walkSession.startTime,
                    healthKitService: viewModel.healthKitService,
                    isStepTrackingEnabled: $isStepTrackingEnabled,
                    showMotionExplainer: $showMotionExplainer,
                    hasClinicianSelected: viewModel.selectedClinician != nil && !viewModel.hasNoClinicsAvailable,
                    onEnableSteps: { ... }
                )
                .id("compactStatusRing") // Stable identity so Google refresh (objectWillChange) doesn't recreate pill and reset Track steps / mins left state

                Spacer()
```

---

## 3. Summary

- **Return to last commit:** e.g. `git checkout .` or `git restore .` (and optionally `git clean -fd` for untracked files).
- **Re-implement:** In `WalkingMapView.swift`, add `.id("compactStatusRing")` (and the comment) after the `CompactStatusRing(...)` in `topOverlay` as above.

The rest of the "mins left" + Google refresh flow (updateCurrentRoute, calling it from handleStartWalk, pill reading `walkSession.currentRoute?.durationMinutes`) is already in the last commit.
