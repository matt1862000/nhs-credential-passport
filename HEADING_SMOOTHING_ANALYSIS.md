# Heading Smoothing Analysis

## Proposed Implementation
```swift
private func handleHeading(_ heading: CLLocationDirection) {
    guard !userInteracting, let current = currentCamera else { return }
    
    // Low-pass filter / smoothing
    let alpha = 0.15
    let filteredHeading = (current.heading * (1 - alpha)) + (heading * alpha)
    
    let camera = MapCamera(
        centerCoordinate: current.centerCoordinate,
        distance: current.distance,
        heading: filteredHeading,
        pitch: current.pitch
    )
    
    currentCamera = camera
    cameraPosition = .camera(camera)
}
```

## Analysis

### ✅ **Pros:**
1. **Reduces jitter**: Smooths out compass noise/fluctuations
2. **Better UX**: Arrow rotation feels smoother, less "jumpy"
3. **Simple implementation**: Easy to understand and maintain

### ⚠️ **Concerns:**

#### 1. **Alpha Value (0.15) is Very Low**
- **15% new value, 85% old value** = heavy smoothing
- **Lag**: Takes ~6-7 updates to reach 63% of target (time constant)
- **Feels sluggish**: Arrow will lag behind actual heading, especially during turns
- **Recommendation**: Try `alpha = 0.3-0.5` for more responsive smoothing

#### 2. **Missing Safety Checks**
Current code has:
```swift
guard introPhase == .followingUser else { return }
guard !userInteracting, !justResumed, let current = currentCamera else { return }
```

Proposed code is missing:
- `introPhase` check (should only update when following user)
- `!justResumed` check (prevents snap-back after auto-resume)

#### 3. **No Handling for Large Heading Changes**
- **Problem**: If user makes 180° turn, smoothing will slowly rotate (feels wrong)
- **Solution**: Skip smoothing for large changes (>30-45°), use direct update

#### 4. **360° Wrap-Around Issue**
- **Problem**: Heading goes from 359° → 1° = 2° change, but smoothing sees 358° difference
- **Solution**: Normalize heading difference before smoothing

#### 5. **No Animation**
- Current code updates directly (no animation)
- With smoothing, might want subtle animation for smoother feel

---

## Recommended Implementation

```swift
private func handleHeading(_ heading: CLLocationDirection) {
    guard introPhase == .followingUser else { return }
    guard !userInteracting, !justResumed, let current = currentCamera else { return }
    
    // Calculate normalized heading difference (handle 360° wrap-around)
    let headingDiff = abs(heading - current.heading)
    let normalizedDiff = min(headingDiff, 360 - headingDiff)
    
    // Skip smoothing for large changes (user is actually turning)
    // Use direct update for responsiveness
    let filteredHeading: CLLocationDirection
    if normalizedDiff > 30 {
        // Large change - update directly (user is turning)
        filteredHeading = heading
    } else {
        // Small change - apply smoothing (reduce jitter)
        let alpha = 0.35  // More responsive than 0.15
        // Handle 360° wrap-around in smoothing
        let shortestAngle = atan2(
            sin((heading - current.heading) * .pi / 180),
            cos((heading - current.heading) * .pi / 180)
        ) * 180 / .pi
        filteredHeading = current.heading + (shortestAngle * alpha)
    }
    
    let camera = MapCamera(
        centerCoordinate: current.centerCoordinate,
        distance: current.distance,
        heading: filteredHeading,
        pitch: current.pitch
    )
    
    currentCamera = camera
    currentCameraState = camera
    
    // Optional: Add subtle animation for smoother feel
    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
        cameraPosition = .camera(camera)
    }
}
```

---

## Alternative: Adaptive Smoothing

```swift
private func handleHeading(_ heading: CLLocationDirection) {
    guard introPhase == .followingUser else { return }
    guard !userInteracting, !justResumed, let current = currentCamera else { return }
    
    // Calculate normalized heading difference
    let headingDiff = abs(heading - current.heading)
    let normalizedDiff = min(headingDiff, 360 - headingHeading)
    
    // Adaptive alpha based on change magnitude
    // Small changes (<5°) = heavy smoothing (reduce jitter)
    // Medium changes (5-30°) = moderate smoothing
    // Large changes (>30°) = no smoothing (direct update)
    let alpha: Double
    if normalizedDiff < 5 {
        alpha = 0.2  // Heavy smoothing for jitter
    } else if normalizedDiff < 30 {
        alpha = 0.5  // Moderate smoothing
    } else {
        alpha = 1.0  // Direct update for turns
    }
    
    let filteredHeading: CLLocationDirection
    if alpha >= 1.0 {
        filteredHeading = heading
    } else {
        // Handle 360° wrap-around
        let shortestAngle = atan2(
            sin((heading - current.heading) * .pi / 180),
            cos((heading - current.heading) * .pi / 180)
        ) * 180 / .pi
        filteredHeading = current.heading + (shortestAngle * alpha)
    }
    
    let camera = MapCamera(
        centerCoordinate: current.centerCoordinate,
        distance: current.distance,
        heading: filteredHeading,
        pitch: current.pitch
    )
    
    currentCamera = camera
    currentCameraState = camera
    cameraPosition = .camera(camera)
}
```

---

## Comparison

| Aspect | Current (No Smoothing) | Proposed (α=0.15) | Recommended (Adaptive) |
|--------|------------------------|------------------|------------------------|
| **Responsiveness** | ✅ Instant | ❌ Laggy (6-7 updates) | ✅ Adaptive |
| **Jitter Reduction** | ❌ None | ✅ Heavy | ✅ Adaptive |
| **Turn Handling** | ✅ Instant | ❌ Slow rotation | ✅ Direct for large |
| **360° Wrap** | ✅ Works | ❌ Issues | ✅ Handled |
| **Safety Checks** | ✅ All present | ❌ Missing some | ✅ All present |

---

## My Recommendation

**Use adaptive smoothing** with:
1. ✅ All safety checks (`introPhase`, `!justResumed`, `!userInteracting`)
2. ✅ 360° wrap-around handling
3. ✅ Skip smoothing for large changes (>30°)
4. ✅ Moderate smoothing (α=0.3-0.5) for small changes
5. ✅ Direct update for turns

**Why?**
- Reduces jitter without feeling sluggish
- Responsive to actual turns
- Handles edge cases properly
- Better user experience

**Avoid α=0.15** because:
- Too heavy (feels laggy)
- Poor turn responsiveness
- Takes too long to catch up

---

## Testing Considerations

1. **Walking straight**: Should feel smooth, no jitter
2. **Turning corners**: Should respond quickly, not lag
3. **360° rotation**: Should handle wrap-around correctly
4. **After auto-resume**: Should not cause snap-back
5. **During interaction**: Should be blocked (already handled)
