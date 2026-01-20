# "Let's Go" Route Refresh Flow

## Overview

When a user taps **"Let's Go"**, the app **refreshes the route** from the user's **current GPS location** to ensure accurate navigation. This is critical because:
- The route was generated from a potentially stale location
- User may have moved since route generation
- Fresh directions ensure the route starts from where they actually are

---

## Step-by-Step Flow

### 1. User Taps "Let's Go" Button

**Location**: `RouteSelectionView.swift` → `handleStartWalk(route:)`

**What happens**:
```swift
1. Cancel background route generation (free up MapKit quota)
2. Check if route was already refreshed (front-loaded optimization)
3. If not refreshed, start refresh process
```

**Log**: `⏱️ [LET'S GO] 🚶 handleStartWalk() STARTED`

---

### 2. Check for Cached Refresh

**Optimization**: If the route was already refreshed (front-loaded), use it immediately.

**Condition**: `isRouteRefreshed && generatedRoute?.name == route.name`

**If cached**:
- ✅ Skip refresh (instant start)
- Use cached refreshed route
- Proceed to `viewModel.selectRoute()` and `viewModel.startWalk()`

**Log**: `⏱️ [LET'S GO] ⚡ Route already refreshed (front-loaded) - using cached refresh`

---

### 3. Start Refresh Process

**If not cached**, the refresh begins:

#### 3a. Immediate UI Feedback
```swift
isStartingWalk = true
routeRefreshStatus = "Preparing to start..."
```

**User sees**: Button changes to "Preparing..." (prevents double-tap)

#### 3b. Get User's Current Location
```swift
if let userLocation = locationService.currentLocation?.coordinate {
    // Proceed with refresh
} else {
    // Fallback: use original route without refresh
}
```

**Log**: `⏱️ [LET'S GO] ✅ User location available: (lat, lng)`

---

### 4. Call Refresh Function

**Function**: `refreshRouteWithGoogleThenMapKit(route:userLocation:)`

**Location**: `GoogleMapsService.swift`

**Purpose**: Get fresh directions from user's current location

**Log**: `⏱️ [LET'S GO] 🔄 Calling refreshRouteWithGoogleThenMapKit...`

---

## 5. Refresh Function: `refreshRouteWithGoogleThenMapKit()`

### Step 1: Check Google Quota

**Condition**: `canUseGoogleDirectionsRefresh`

**Checks**:
- Daily quota not exceeded (default: 100 calls/day)
- API key present
- Network available

**If quota available** → Proceed to Google API
**If quota reached** → Skip to MapKit fallback

**Log**: `⏱️ [ROUTE REFRESH] ✅ Can use Google Directions`

---

### Step 2: Extract Waypoints

**Source**: Route's QR markers (waypoint coordinates)

```swift
let rawWaypoints = route.qrMarkers.map { $0.coordinate }
```

**Example**: If route has 2 waypoints:
- Waypoint 1: (53.70207, -1.55201)
- Waypoint 2: (53.69927, -1.55157)

---

### Step 3: Local Waypoint Optimization

**Function**: `performLocalOptimization(origin:waypoints:)`

**Algorithm**: Nearest Neighbor (greedy)

**Why?**
- Google's `optimize:true` requires **Premium SKU** ($40/month)
- We use **Essentials SKU** ($0.20 per 1000 requests)
- Local optimization gives 80-90% of Google's quality
- **Saves $39.80/month**

**Process**:
1. Start from user's current location
2. Find nearest unvisited waypoint
3. Move to that waypoint
4. Repeat until all visited
5. Return to origin

**Log**: `🌐 ✅ Local optimization: 2 waypoints reordered using Nearest Neighbor`

**Example Output**:
```
🌐   🎯 Waypoints: 2 (optimized locally)
🌐      [1] (53.70207, -1.55201)
🌐      [2] (53.69927, -1.55157)
```

---

### Step 4: Build Google Directions API URL

**Format**:
```
https://maps.googleapis.com/maps/api/directions/json?
  origin={lat},{lng}
  destination={lat},{lng}  (same as origin - loop route)
  waypoints={lat1},{lng1}|{lat2},{lng2}|...
  mode=walking
  key={API_KEY}
```

**Coordinate Precision**: `%.6f,%.6f` (6 decimal places = ~10cm accuracy)

**Example**:
```
origin=53.702894,-1.549582
destination=53.702894,-1.549582
waypoints=53.702067,-1.552009|53.699274,-1.551568
mode=walking
```

**Log**: `🌐   🔗 URL: https://maps.googleapis.com/maps/api/directions/json?...`

---

### Step 5: Make HTTP Request

**Timeout**: 30 seconds

**Headers**:
- `X-Ios-Bundle-Identifier`: `com.nhs.WalkingWR` (for API key restrictions)

**Request**:
```swift
var request = URLRequest(url: url)
request.timeoutInterval = 30.0
request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
let (data, response) = try await session.data(for: request)
```

**Log**: 
```
🌐   ⏱️  Making HTTP request...
🌐   📱 Bundle ID: com.nhs.WalkingWR
🌐   📡 HTTP Status: 200
🌐   📦 Response size: 322 bytes
🌐   ⏱️  Response time: 0.33s
```

---

### Step 6: Parse Google Response

**Success Response** (`status: "OK"`):
```json
{
  "routes": [{
    "legs": [
      {
        "distance": {"text": "230 m", "value": 230},
        "duration": {"text": "3 min", "value": 180},
        "steps": [...]
      }
    ],
    "overview_polyline": {
      "points": "encoded_polyline_string"
    }
  }]
}
```

**What we extract**:
1. **Overview polyline** (route path)
2. **Step polylines** (more detailed, preferred)
3. **Turn-by-turn directions** (from steps)
4. **Distance and duration** per leg

**Polyline Selection**:
- **Preferred**: Step polylines (more points = follows roads better)
- **Fallback**: Overview polyline (fewer points, less precise)

**Log**:
```
🌐   ✅ SUCCESS: Parsed Google route
🌐      ⏱️  Duration: 17min
🌐      📏 Distance: 1188m
🌐      🧭 Directions: 16 steps
🌐      📍 Legs: 3
🌐      📐 Overview polyline: 112 chars → 34 points
🌐      📐 Step polylines: 45 points total
🌐      📐 Using: DETAILED step polylines
🌐      📐 Point density: 28.6 points/km
```

---

### Step 7: Handle Google API Errors

**Common Errors**:

1. **`REQUEST_DENIED`**:
   ```
   "You're calling a legacy API, which is not enabled for your project"
   ```
   - **Fix**: Enable "Directions API (Legacy)" in Google Cloud Console
   - **Fallback**: MapKit

2. **`OVER_QUERY_LIMIT`**:
   ```
   "You have exceeded your daily quota"
   ```
   - **Fallback**: MapKit

3. **`ZERO_RESULTS`**:
   ```
   "No route found"
   ```
   - **Fallback**: MapKit

4. **Network Error**:
   - Timeout (30s exceeded)
   - Connection failed
   - **Fallback**: MapKit

**Log**: `🌐 REFRESH: Google API returned status 'REQUEST_DENIED' - falling back to MapKit`

---

## 6. MapKit Fallback: `refreshRouteWithMapKit()`

**Triggers**:
- Google quota reached
- Google API error
- Google returns no routes

**Function**: `refreshRouteWithMapKit(route:userLocation:)`

### Step 1: Get Directions for Each Leg

**Process**:
```swift
For each leg (origin → waypoint1 → waypoint2 → ... → origin):
  1. Create MKDirections.Request()
  2. Set source and destination
  3. Set transportType = .walking
  4. Call directions.calculate()
  5. Extract polyline points
  6. Check for suspicious routes (shortcuts through fields)
```

**Log**: `🍎 Getting MapKit directions for 3 legs...`

---

### Step 2: Suspicious Route Detection

**Problem**: MapKit sometimes routes through fields/private property

**Detection**:
```swift
ratio = route_distance / straight_line_distance

if ratio < 1.10 && straight_line_distance > 50 {
    // Suspicious! Route is too direct (likely shortcut)
}
```

**Fix Process**:
1. **Try OSRM first** (free, uses OSM barrier data)
2. **If OSRM also suspicious**, try Google (costs money)
3. **If all fail**, keep MapKit (best available)

**Log**:
```
🚨 SUSPICIOUS Leg 0: ratio=1.05 (route: 230m, straight: 220m)
✅ OSRM segment BETTER: ratio=1.18 (route: 260m) [FREE]
```

---

### Step 3: Build Combined Polyline

**Process**:
1. Combine polylines from all legs
2. Encode into single polyline string
3. Calculate total distance and duration

**Log**:
```
🍎 ═══════════════════════════════════════════════════════
🍎 REFRESH COMPLETE (MapKit Fallback)
🍎   ⏱️  Duration: 17min
🍎   📏 Distance: 1188m
🍎   🧭 Directions: 16 steps
🍎   📐 Polyline: 112 chars → 34 points
🍎   📐 Point density: 28.6 points/km
🍎 ═══════════════════════════════════════════════════════
```

---

## 7. Return to "Let's Go" Handler

**After refresh completes**:

### Step 1: Update Route
```swift
viewModel.selectRoute(refreshedRoute)
```

**What this does**:
- Updates `viewModel.selectedRoute`
- Stores refreshed route data
- Updates UI

**Log**: `⏱️ [LET'S GO]   selectRoute() took 0.000s`

---

### Step 2: Start Walk Session
```swift
viewModel.startWalk()
```

**What this does**:
- Sets `walkSession.isActive = true`
- Records start time and location
- Initializes walk tracking
- Sets up notifications

**Log**: `⏱️ [LET'S GO]   startWalk() took 0.007s`

---

### Step 3: Show Map or Pre-Walk Check

**Condition**: `viewModel.showPreWalkWellbeing`

**If true** (pre-walk anxiety check enabled):
```swift
viewModel.pendingActiveWalk = true
isPresented = false  // Dismiss route picker sheet
// Pre-walk sheet will show, then map after
```

**If false** (no pre-walk check):
```swift
isPresented = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    showActiveWalk = true  // Show map immediately
}
```

**Log**: 
- `⏱️ [LET'S GO] ⏳ Pre-walk anxiety check showing - map will appear after`
- OR `⏱️ [LET'S GO] 🗺️ Walk started - showing fullscreen ActiveWalkView`

---

## 8. Timeout & Retry Logic

**Timeout**: 30 seconds per refresh attempt

**Retry**: Up to 1 retry (2 total attempts)

**Process**:
```swift
while retryCount <= maxRetries && refreshedRoute == nil {
    do {
        refreshedRoute = try await withTimeout(seconds: 30) {
            await mapsService.refreshRouteWithGoogleThenMapKit(...)
        }
        break  // Success
    } catch TimeoutError.timeout {
        retryCount += 1
        if retryCount <= maxRetries {
            routeRefreshStatus = "Retrying..."
            await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second pause
            continue
        } else {
            routeRefreshStatus = "Timed out. Tap to retry."
            isStartingWalk = false  // Re-enable button
            return
        }
    }
}
```

**Log**: `⏱️ [LET'S GO] ⏱️ Route refresh timeout (30s) - retrying (1/1)...`

---

## 9. Error Handling

### No User Location

**Fallback**: Use original route without refresh

```swift
if let userLocation = locationService.currentLocation?.coordinate {
    // Refresh route
} else {
    // Use original route
    viewModel.selectRoute(route)  // Original, not refreshed
    viewModel.startWalk()
}
```

**Log**: `⏱️ [LET'S GO] ⚠️ No user location - using original route`

---

### Refresh Fails

**Options**:
1. **Timeout after retries**: Show "Timed out. Tap to retry."
2. **Other error**: Show "Failed. Tap to retry."
3. **Button re-enabled**: User can tap again

**User Experience**:
- Button text changes to error message
- User can tap to retry
- Original route still available as fallback

---

## 10. Performance Metrics

**Typical Refresh Times**:

- **Google Success**: 0.3-1.0 seconds
- **MapKit Fallback**: 15-30 seconds (multiple legs)
- **OSRM Fallback**: 2-5 seconds

**Total "Let's Go" Flow**:
- **With Google**: ~1-2 seconds total
- **With MapKit**: ~20-35 seconds total
- **With timeout/retry**: Up to 60+ seconds

**Log**: `⏱️ [LET'S GO] ✅ Total time: 49.27s`

---

## 11. Route Quality Summary

**After refresh**, the app logs a comprehensive summary:

```
╔═══════════════════════════════════════════════════════════╗
║       🚶 ROUTE QUALITY SUMMARY (Copy & Paste)             ║
╠═══════════════════════════════════════════════════════════╣
║ Route: Via Kirkhamgate Fisher
║ Duration: 17min | Distance: 1188m
║ Waypoints: 2
║ Directions: 16 steps
║ Polyline: 34 points (28.6 pts/km)
║ ⚡ MEDIUM DENSITY - should follow main roads
╠═══════════════════════════════════════════════════════════╣
║ First 3 directions:
║   1. Start on Kirkhamgate Villas
║   2. Turn right onto Kirkhamgate Villas
║   3. Turn left onto Hawthorne Close
╠═══════════════════════════════════════════════════════════╣
║ API CALLS:
║   ✅ Directions API: 1 success
╚═══════════════════════════════════════════════════════════╝
```

**Quality Indicators**:
- **Point density**:
  - <20 pts/km: ⚠️ LOW (may not follow roads)
  - 20-50 pts/km: ⚡ MEDIUM (follows main roads)
  - >50 pts/km: ✅ HIGH (follows roads accurately)

---

## 12. Key Code Locations

### Entry Point
- **File**: `WalkingWR/Views/RouteSelectionView.swift`
- **Function**: `handleStartWalk(route:)` (line ~2546)

### Refresh Logic
- **File**: `WalkingWR/Services/GoogleMapsService.swift`
- **Function**: `refreshRouteWithGoogleThenMapKit()` (line ~3637)
- **Fallback**: `refreshRouteWithMapKit()` (line ~3446)

### Optimization
- **File**: `WalkingWR/Services/GoogleMapsService.swift`
- **Function**: `performLocalOptimization()` (line ~7048)

### Walk Start
- **File**: `WalkingWR/ViewModels/WaitingRoomViewModel.swift`
- **Function**: `startWalk()` (line ~604)

---

## 13. Summary Flow Diagram

```
User Taps "Let's Go"
    ↓
Check if route already refreshed?
    ├─ YES → Use cached refresh (instant)
    └─ NO  → Start refresh process
            ↓
        Get user's current location
            ↓
        Check Google quota available?
            ├─ YES → Google Directions API
            │         ├─ Local optimization (Nearest Neighbor)
            │         ├─ Build API URL
            │         ├─ Make HTTP request (30s timeout)
            │         ├─ Parse response
            │         └─ Extract polyline + directions
            │
            └─ NO  → MapKit Fallback
                      ├─ Get directions for each leg
                      ├─ Check for suspicious routes
                      ├─ Fix suspicious routes (OSRM/Google)
                      └─ Build combined polyline
            ↓
        Update route with fresh data
            ↓
        viewModel.selectRoute(refreshedRoute)
            ↓
        viewModel.startWalk()
            ↓
        Show pre-walk check OR map directly
```

---

## 14. Current Issues (from your logs)

1. **Google Directions API**: `REQUEST_DENIED`
   - Legacy API not enabled in Google Cloud Console
   - **Impact**: Always falls back to MapKit (slower, 20-30s)

2. **Google Places API**: `HTTP 403`
   - API not enabled
   - **Impact**: No Google POIs during route generation

3. **Gemini API**: `HTTP 403` (IP restriction)
   - API key has IP restriction
   - **Impact**: Route names fall back to templates

---

## 15. Cost Breakdown

**Per "Let's Go" Tap**:
- **Google Success**: ~$0.0002 (1 call × $0.20/1000)
- **MapKit Fallback**: FREE
- **OSRM Fallback**: FREE

**Daily Estimate** (100 users, 1 walk each):
- **Google**: 100 calls × $0.0002 = **$0.02/day**
- **Monthly**: ~$0.60/month

**Optimization Savings**:
- **Without local optimization**: Would need Premium SKU = $40/month
- **With local optimization**: Essentials SKU = $0.60/month
- **Savings**: **$39.40/month** 🎉
