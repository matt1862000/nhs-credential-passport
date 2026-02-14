import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import CoreLocation

class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    
    /// When Documents/diagnostic_trigger.txt exists, run 20 & 25 min route generation and write results to Documents/diagnostic_routes.json (for automated testing).
    private static let diagnosticTriggerFilename = "diagnostic_trigger.txt"
    private static let diagnosticOutputFilename = "diagnostic_routes.json"
    private static let diagnosticProgressFilename = "diagnostic_progress.txt"
    
    // Notification action identifiers (must match NotificationService)
    static let delayNotificationCategory = "DELAY_NOTIFICATION"  // Updated to match NotificationService
    static let stopNotificationsAction = "STOP_NOTIFICATIONS"
    static let viewDetailsAction = "VIEW_DETAILS"
    
    // Store pending notification for cold launch
    static var pendingNotification: [String: String]? = nil
    // Flag to suppress in-app alerts when coming from push
    static var suppressInAppAlertsFlag: Bool = false
    // Flag to suppress walk alerts (halfway/return) when coming from walk push notification
    static var cameFromWalkNotification: Bool = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Configure Firebase FIRST
        FirebaseApp.configure()
        
        // Set messaging delegate
        Messaging.messaging().delegate = self
        
        // Register notification categories with actions
        registerNotificationCategories()
        
        // Set delegate for handling notifications (but don't request permission yet)
        // Permission will be requested after splash/onboarding screen
        UNUserNotificationCenter.current().delegate = self
        
        // Register for remote notifications (this is safe even before permission is granted)
        DispatchQueue.main.async {
            application.registerForRemoteNotifications()
        }
        
        // Diagnostic route run: triggered by Documents/diagnostic_trigger.txt file (Finder file sharing)
        // OR by launch argument -RUN_DIAGNOSTIC (Xcode scheme > Run > Arguments > "-RUN_DIAGNOSTIC")
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let triggerByFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.diagnosticTriggerFilename).path) } ?? false
            let triggerByLaunchArg = ProcessInfo.processInfo.arguments.contains("-RUN_DIAGNOSTIC")
            if triggerByFile || triggerByLaunchArg {
                print("[DIAGNOSTIC] Trigger detected: file=\(triggerByFile), launchArg=\(triggerByLaunchArg)")
            await runDiagnosticRouteGeneration()
            }
        }
        
        return true
    }
    
    private func runDiagnosticRouteGenerationIfTriggered() async {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let triggerURL = docs.appendingPathComponent(Self.diagnosticTriggerFilename)
        guard FileManager.default.fileExists(atPath: triggerURL.path) else { return }
        await runDiagnosticRouteGeneration()
    }
    
    // MARK: - Comprehensive Route Generation Diagnostic (v2.1.11)
    // 12-phase test harness: initial generation, +1, cross-bucket, Google refresh,
    // cancel-save, deduplication, POI quality, dead zone, travel-to-start,
    // distance consistency, API health, and route permutation.
    
    private func runDiagnosticRouteGeneration() async {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[DIAGNOSTIC] No Documents directory"); return
        }
        let triggerURL = docs.appendingPathComponent(Self.diagnosticTriggerFilename)
        let outputURL = docs.appendingPathComponent(Self.diagnosticOutputFilename)
        try? "[DIAGNOSTIC_STARTED]".write(to: outputURL.appendingPathExtension("started"), atomically: true, encoding: .utf8)
        
        // Request live GPS with up to 10s wait, fall back to hardcoded WF2 Kirkhamgate
        let fallback = CLLocationCoordinate2D(latitude: 53.6825, longitude: -1.4915)
        print("[DIAGNOSTIC] Requesting GPS fix (up to 10s)…")
        let gpsCoord = await Self.requestGPSFix(timeout: 10)
        let testLocation: CLLocationCoordinate2D
        if let gps = gpsCoord {
            testLocation = gps
            print("[DIAGNOSTIC] ✅ Using LIVE GPS: \(gps.latitude), \(gps.longitude)")
        } else {
            testLocation = fallback
            print("[DIAGNOSTIC] ⚠️ GPS unavailable after 10s — using fallback: \(fallback.latitude), \(fallback.longitude)")
        }
        let mapsService = GoogleMapsService.shared
        let cacheService = RouteCacheService.shared
        let prepopService = PrePopulatedPOIService.shared
        let buckets = [10]  // TEMP: Single bucket for quick testing (restore: stride(from: 10, through: 60, by: 5).map { $0 })
        let overallStart = Date()
        
        // Shared API health counters
        var apiOsrmCalls = 0, apiOsrmTimeouts = 0
        var apiGoogleCalls = 0, apiGoogleFailures = 0
        var apiPlacesCalls = 0, apiPlacesFailures = 0
        
        // Clear previous progress file
        let progressURL = docs.appendingPathComponent(Self.diagnosticProgressFilename)
        try? FileManager.default.removeItem(at: progressURL)
        // Clear previous partial results
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("diagnostic_partial.json"))
        
        print("[DIAGNOSTIC] ════════════════════════════════════════════════════════")
        print("[DIAGNOSTIC] Route Generation Test Harness — (\(testLocation.latitude), \(testLocation.longitude))")
        print("[DIAGNOSTIC] Buckets: \(buckets.map { "\($0)min" }.joined(separator: ", "))")
        print("[DIAGNOSTIC] ════════════════════════════════════════════════════════")
        
        diagnosticUpdateProgress(docs, phase: "STARTED", detail: "12 phases, \(buckets.count) buckets (\(buckets.first ?? 0)-\(buckets.last ?? 0) min)")
        await diagnosticNotify("Diagnostic Started", body: "12 phases, \(buckets.count) buckets. Progress in diagnostic_progress.txt")
        
        // Ensure prepop DB is loaded
        // On real device, reverse geocode returns "WF2 9EX" → matches "WF2" in supported list → downloads DB.
        // On simulator, reverse geocode often fails, so the center-based fallback runs. The WF2 center
        // (53.7029, -1.5496) is 4.4km from Kirkhamgate — outside the 2500m fallback radius.
        // Fix: first try with the actual test location. If DB still not loaded, retry with the WF2 center
        // point (simulates what would happen on a real device where geocode succeeds).
        diagnosticUpdateProgress(docs, phase: "Phase 0/12: Loading prepopulated database...")
        print("[DIAGNOSTIC] Phase 0: Ensuring prepopulated database is loaded...")
        await prepopService.downloadDatabaseIfNeeded(userLocation: testLocation)
        if !prepopService.hasDownloadedDatabase {
            print("[DIAGNOSTIC] Phase 0: DB not loaded (simulator geocode likely failed) — retrying with WF2 center...")
            let wf2Center = CLLocationCoordinate2D(latitude: 53.7029, longitude: -1.5496) // WF2 0GU center
            await prepopService.downloadDatabaseIfNeeded(userLocation: wf2Center)
            if prepopService.hasDownloadedDatabase {
                print("[DIAGNOSTIC] Phase 0: ✅ DB loaded via WF2 center fallback")
            } else {
                print("[DIAGNOSTIC] Phase 0: ⚠️ DB still not loaded — prepop routes will be empty")
            }
        } else {
            print("[DIAGNOSTIC] Phase 0: ✅ DB already loaded")
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: Initial Route Generation (all buckets)
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 1/12: Initial Route Generation", detail: "\(buckets.count) buckets")
        await diagnosticNotify("Diagnostic Phase 1/12", body: "Initial route generation — \(buckets.count) buckets")
        print("[DIAGNOSTIC] ═══ PHASE 1: Initial Route Generation ═══")
        var phase1Results: [String: Any] = [:]
        // Store all generated routes for later phases
        var allGeneratedRoutes: [(bucket: Int, route: GeneratedRoute, walkingRoute: WalkingRoute, source: String, timeMs: Int)] = []
        
        for bucket in buckets {
            let bucketStart = Date()
            var bucketRoutes: [[String: Any]] = []
            var excludePlaceIds: Set<String> = []
            
            // 1a. Load prepop routes
            let prepopRoutes = prepopService.getPrePopulatedRoutes(near: testLocation, durationMinutes: bucket)
            let prepopCount = prepopRoutes?.count ?? 0
            print("[DIAGNOSTIC] \(bucket)min: \(prepopCount) prepop routes found")
            
            if let prepopRoutes = prepopRoutes {
                for cached in prepopRoutes.prefix(3) {
                    let wr = RouteConversionHelper.walkingRoute(from: cached.route, origin: testLocation, name: cached.name ?? "Prepop", description: cached.description ?? "")
                    let inBand = Self.diagnosticIsRouteInBand(durationMinutes: wr.durationMinutes, distanceMeters: wr.distanceMeters, targetDuration: bucket)
                    let firstWP = cached.route.places.first
                    let travelDist = firstWP.map { Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) } ?? 0
                    let travelMin = travelDist / 80.0
                    let impliedSpeed = wr.durationMinutes > 0 ? Double(wr.distanceMeters) / Double(wr.durationMinutes) : 0
                    
                    let routeInfo: [String: Any] = [
                        "name": wr.name,
                        "source": cached.isDeadZoneFallback ? "prepop_deadzone" : "prepop",
                        "durationMinutes": wr.durationMinutes,
                        "distanceMeters": wr.distanceMeters,
                        "inBand": inBand,
                        "deviationPercent": bucket > 0 ? round(Double(abs(wr.durationMinutes - bucket)) / Double(bucket) * 1000) / 10 : 0,
                        "waypointCount": cached.route.places.count,
                        "polylineLength": wr.trimmed?.count ?? 0,
                        "directionsCount": wr.walkingDirections.count,
                        "qrMarkerCount": wr.qrMarkers.count,
                        "waypoints": cached.route.places.enumerated().map { (i, p) -> [String: Any] in
                            let wpDist = Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude))
                            return [
                                "index": i,
                                "name": p.name,
                                "placeId": p.placeId,
                                "lat": p.coordinate.latitude,
                                "lng": p.coordinate.longitude,
                                "types": p.types ?? [],
                                "distanceFromOriginMeters": round(wpDist)
                            ]
                        },
                        "generationTimeMs": 0,
                        "impliedSpeedMpm": round(impliedSpeed * 10) / 10,
                        "travelToStartMeters": round(travelDist),
                        "travelToStartMinutes": round(travelMin * 10) / 10,
                        "isDeadZoneFallback": cached.isDeadZoneFallback
                    ]
                    bucketRoutes.append(routeInfo)
                    allGeneratedRoutes.append((bucket: bucket, route: cached.route, walkingRoute: wr, source: "prepop", timeMs: 0))
                    excludePlaceIds.formUnion(cached.route.places.map { $0.placeId })
                }
            }
            
            // 1b. Generate up to 3 live routes
            var liveCount = 0
            for attempt in 0..<3 {
                let genStart = Date()
                do {
                    let route = try await mapsService.generateRouteTopologySafe(
                        from: testLocation,
                        targetDurationMinutes: bucket,
                        excludePlaceIds: excludePlaceIds,
                        prefetchedPOIs: nil
                    )
                    let genTimeMs = Int(Date().timeIntervalSince(genStart) * 1000)
                    let wr = RouteConversionHelper.walkingRoute(from: route, origin: testLocation, name: "Live \(attempt + 1)", description: "")
                    let inBand = Self.diagnosticIsRouteInBand(durationMinutes: wr.durationMinutes, distanceMeters: wr.distanceMeters, targetDuration: bucket)
                    let firstWP = route.places.first
                    let travelDist = firstWP.map { Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) } ?? 0
                    let impliedSpeed = wr.durationMinutes > 0 ? Double(wr.distanceMeters) / Double(wr.durationMinutes) : 0
                    
                    let routeInfo: [String: Any] = [
                        "name": wr.name,
                        "source": "live",
                        "durationMinutes": wr.durationMinutes,
                        "distanceMeters": wr.distanceMeters,
                        "inBand": inBand,
                        "deviationPercent": bucket > 0 ? round(Double(abs(wr.durationMinutes - bucket)) / Double(bucket) * 1000) / 10 : 0,
                        "waypointCount": route.places.count,
                        "polylineLength": wr.trimmed?.count ?? 0,
                        "directionsCount": wr.walkingDirections.count,
                        "qrMarkerCount": wr.qrMarkers.count,
                        "waypoints": route.places.enumerated().map { (i, p) -> [String: Any] in
                            let wpDist = Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude))
                            return [
                                "index": i,
                                "name": p.name,
                                "placeId": p.placeId,
                                "lat": p.coordinate.latitude,
                                "lng": p.coordinate.longitude,
                                "types": p.types ?? [],
                                "distanceFromOriginMeters": round(wpDist)
                            ]
                        },
                        "generationTimeMs": genTimeMs,
                        "impliedSpeedMpm": round(impliedSpeed * 10) / 10,
                        "travelToStartMeters": round(travelDist),
                        "travelToStartMinutes": round(travelDist / 80.0 * 10) / 10,
                        "isDeadZoneFallback": false
                    ]
                    bucketRoutes.append(routeInfo)
                    allGeneratedRoutes.append((bucket: bucket, route: route, walkingRoute: wr, source: "live", timeMs: genTimeMs))
                    excludePlaceIds.formUnion(route.places.map { $0.placeId })
                    liveCount += 1
                    apiGoogleCalls += 1
                    let liveWPNames = route.places.map { $0.name }.joined(separator: ", ")
                    print("[DIAGNOSTIC] \(bucket)min live \(attempt + 1): \(wr.durationMinutes)min, \(wr.distanceMeters)m, \(route.places.count) WPs [\(liveWPNames)], \(genTimeMs)ms, inBand=\(inBand)")
                } catch {
                    let genTimeMs = Int(Date().timeIntervalSince(genStart) * 1000)
                    apiGoogleFailures += 1
                    print("[DIAGNOSTIC] \(bucket)min live \(attempt + 1): ERROR in \(genTimeMs)ms — \(error.localizedDescription)")
                }
            }
            
            let bucketTimeMs = Int(Date().timeIntervalSince(bucketStart) * 1000)
            phase1Results["\(bucket)"] = [
                "prepopRoutes": prepopCount,
                "liveRoutes": liveCount,
                "timeMs": bucketTimeMs,
                "routes": bucketRoutes
            ]
            print("[DIAGNOSTIC] \(bucket)min bucket complete: \(prepopCount) prepop + \(liveCount) live = \(bucketRoutes.count) total, \(bucketTimeMs)ms")
            let bucketIdx = buckets.firstIndex(of: bucket).map { $0 + 1 } ?? 0
            diagnosticUpdateProgress(docs, phase: "Phase 1/12: Bucket \(bucketIdx)/\(buckets.count)", detail: "\(bucket)min → \(bucketRoutes.count) routes (\(bucketTimeMs)ms)")
        }
        
        // Save partial results after Phase 1
        diagnosticSavePartial(docs, output: [
            "status": "in_progress",
            "completedPhase": 1,
            "totalRoutesSoFar": allGeneratedRoutes.count,
            "elapsedSeconds": round(Date().timeIntervalSince(overallStart) * 10) / 10,
            "phases": ["initialGeneration": ["buckets": phase1Results]] as [String: Any]
        ])
        diagnosticUpdateProgress(docs, phase: "Phase 1/12 COMPLETE", detail: "\(allGeneratedRoutes.count) total routes")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: +1 Generation Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 2/12: +1 Generation Test", detail: "buckets: 15, 25, 40 min")
        await diagnosticNotify("Diagnostic Phase 2/12", body: "+1 generation test")
        print("[DIAGNOSTIC] ═══ PHASE 2: +1 Generation Test ═══")
        var phase2Results: [[String: Any]] = []
        var plusOneExcludedIds: Set<String> = []  // accumulate across +1 attempts
        for testBucket in [10, 10, 10, 10, 10] {  // TEMP: 5x +1 tests at 10min (restore: [15, 25, 40])
            let phase1Ids = Set(allGeneratedRoutes.filter { $0.bucket == testBucket }.flatMap { $0.route.places.map { $0.placeId } })
            let allUsedIds = phase1Ids.union(plusOneExcludedIds)
            let plusOneStart = Date()
            var success = false, inBand = false, timedOut = false
            var plusOneTimeMs = 0
            var plusOneRoute: GeneratedRoute? = nil
            var plusOneWR: WalkingRoute? = nil
            
            // 10-second timeout like the real +1 button
            let deadline = Date().addingTimeInterval(10)
            do {
                let route = try await mapsService.generateRouteTopologySafe(
                    from: testLocation,
                    targetDurationMinutes: testBucket,
                    excludePlaceIds: allUsedIds,
                    prefetchedPOIs: nil
                )
                plusOneTimeMs = Int(Date().timeIntervalSince(plusOneStart) * 1000)
                timedOut = Date() > deadline
                let wr = RouteConversionHelper.walkingRoute(from: route, origin: testLocation, name: "+1", description: "")
                inBand = Self.diagnosticIsRouteInBand(durationMinutes: wr.durationMinutes, distanceMeters: wr.distanceMeters, targetDuration: testBucket)
                success = true
                plusOneRoute = route
                plusOneWR = wr
                let wpNames = route.places.map { $0.name }.joined(separator: ", ")
                print("[DIAGNOSTIC] +1 for \(testBucket)min: \(wr.durationMinutes)min, \(route.places.count) WPs [\(wpNames)], inBand=\(inBand), \(plusOneTimeMs)ms, timedOut=\(timedOut)")
                // Accumulate this route's POIs so next +1 won't repeat
                plusOneExcludedIds.formUnion(route.places.map { $0.placeId })
            } catch {
                plusOneTimeMs = Int(Date().timeIntervalSince(plusOneStart) * 1000)
                timedOut = Date() > deadline
                print("[DIAGNOSTIC] +1 for \(testBucket)min: FAILED in \(plusOneTimeMs)ms, timedOut=\(timedOut)")
            }
            var plusOneResult: [String: Any] = [
                "bucket": testBucket,
                "success": success,
                "inBand": inBand,
                "timeMs": plusOneTimeMs,
                "timedOut": timedOut
            ]
            // If the +1 route was generated, add detailed info
            if let route = plusOneRoute, let wr = plusOneWR {
                let impliedSpeed = wr.durationMinutes > 0 ? Double(wr.distanceMeters) / Double(wr.durationMinutes) : 0
                let firstWP = route.places.first
                let travelDist = firstWP.map { Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) } ?? 0
                plusOneResult["durationMinutes"] = wr.durationMinutes
                plusOneResult["distanceMeters"] = wr.distanceMeters
                plusOneResult["deviationPercent"] = testBucket > 0 ? round(Double(abs(wr.durationMinutes - testBucket)) / Double(testBucket) * 1000) / 10 : 0
                plusOneResult["waypointCount"] = route.places.count
                plusOneResult["impliedSpeedMpm"] = round(impliedSpeed * 10) / 10
                plusOneResult["travelToStartMeters"] = round(travelDist)
                plusOneResult["waypoints"] = route.places.enumerated().map { (i, p) -> [String: Any] in
                    let wpDist = Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude))
                    return [
                        "index": i,
                        "name": p.name,
                        "placeId": p.placeId,
                        "lat": p.coordinate.latitude,
                        "lng": p.coordinate.longitude,
                        "types": p.types ?? [],
                        "distanceFromOriginMeters": round(wpDist)
                    ]
                }
            }
            phase2Results.append(plusOneResult)
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 2/12 COMPLETE", detail: "\(phase2Results.count) +1 tests")
        diagnosticSavePartial(docs, output: [
            "status": "in_progress", "completedPhase": 2,
            "totalRoutesSoFar": allGeneratedRoutes.count,
            "elapsedSeconds": round(Date().timeIntervalSince(overallStart) * 10) / 10,
            "phases": [
                "initialGeneration": ["buckets": phase1Results],
                "plusOneGeneration": ["results": phase2Results]
            ] as [String: Any]
        ])
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 3: Cross-Bucket Cache Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 3/12: Cross-Bucket Cache Test")
        await diagnosticNotify("Diagnostic Phase 3/12", body: "Cross-bucket cache test")
        print("[DIAGNOSTIC] ═══ PHASE 3: Cross-Bucket Cache Test ═══")
        var phase3Results: [String: Any] = ["stored": false, "retrieved": false]
        cacheService.clearSessionCache()
        // Find any route whose actual duration lands in a different bucket
        if let crossCandidate = allGeneratedRoutes.first(where: {
            RouteCacheService.roundToNearest5Minutes($0.walkingRoute.durationMinutes) != RouteCacheService.roundToNearest5Minutes($0.bucket)
        }) {
            let actualBucket = RouteCacheService.roundToNearest5Minutes(crossCandidate.walkingRoute.durationMinutes)
            let requestedBucket = RouteCacheService.roundToNearest5Minutes(crossCandidate.bucket)
            cacheService.addToSessionCrossBucket(route: crossCandidate.walkingRoute, data: crossCandidate.route, isFromGoogle: false, currentBucket: requestedBucket)
            let summary = cacheService.sessionCrossBucketPoolSummary()
            let stored = !summary.isEmpty
            print("[DIAGNOSTIC] Cross-bucket: stored route (\(crossCandidate.walkingRoute.durationMinutes)min actual) from \(requestedBucket)min bucket → pool: \(summary)")
            
            // Try to consume for the actual bucket
            let consumed = cacheService.consumeSessionCrossBucket(for: actualBucket) { route, targetDuration in
                Self.diagnosticIsRouteInBand(durationMinutes: route.durationMinutes, distanceMeters: route.distanceMeters, targetDuration: targetDuration)
            }
            let retrieved = !consumed.isEmpty
            print("[DIAGNOSTIC] Cross-bucket: consumed \(consumed.count) route(s) for \(actualBucket)min bucket, retrieved=\(retrieved)")
            phase3Results = [
                "stored": stored,
                "storedBucket": actualBucket,
                "requestedBucket": requestedBucket,
                "routeDuration": crossCandidate.walkingRoute.durationMinutes,
                "retrieved": retrieved,
                "retrievedCount": consumed.count
            ]
        } else {
            print("[DIAGNOSTIC] Cross-bucket: No cross-bucket candidate found (all routes land in their requested bucket)")
            phase3Results["note"] = "No cross-bucket candidate — all routes in-band for their bucket"
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 3/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 4: Google Refresh Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 4/12: Google Refresh Test")
        await diagnosticNotify("Diagnostic Phase 4/12", body: "Google refresh test")
        print("[DIAGNOSTIC] ═══ PHASE 4: Google Refresh Test ═══")
        var phase4Results: [String: Any] = ["success": false]
        if let refreshCandidate = allGeneratedRoutes.first(where: { $0.walkingRoute.qrMarkers.count >= 1 }) {
            let wr = refreshCandidate.walkingRoute
            let preDuration = wr.durationMinutes
            let preDistance = wr.distanceMeters
            let prePolylineLen = wr.trimmed?.count ?? 0
            let preDirections = wr.walkingDirections.count
            
            let refreshStart = Date()
            if let refreshed = await mapsService.refreshRouteWithGoogleOnly(route: wr, userLocation: testLocation) {
                let refreshMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
                apiGoogleCalls += 1
                phase4Results = [
                    "success": true,
                    "elapsedMs": refreshMs,
                    "hasAPIKey": mapsService.hasAPIKey,
                    "pre": [
                        "duration": preDuration,
                        "distance": preDistance,
                        "polylineLen": prePolylineLen,
                        "directionsCount": preDirections
                    ],
                    "post": [
                        "duration": refreshed.durationMinutes,
                        "distance": refreshed.distanceMeters,
                        "polylineLen": refreshed.trimmed?.count ?? 0,
                        "directionsCount": refreshed.walkingDirections.count
                    ],
                    "polylineChanged": (refreshed.trimmed?.count ?? 0) != prePolylineLen,
                    "directionsPopulated": refreshed.walkingDirections.count > preDirections,
                    "durationChanged": refreshed.durationMinutes != preDuration
                ]
                print("[DIAGNOSTIC] Google refresh: \(preDuration)min → \(refreshed.durationMinutes)min, polyline \(prePolylineLen) → \(refreshed.trimmed?.count ?? 0), directions \(preDirections) → \(refreshed.walkingDirections.count), \(refreshMs)ms")
            } else {
                let refreshMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
                apiGoogleFailures += 1
                phase4Results = ["success": false, "elapsedMs": refreshMs, "hasAPIKey": mapsService.hasAPIKey, "error": "refreshRouteWithGoogleOnly returned nil"]
                print("[DIAGNOSTIC] Google refresh: FAILED in \(refreshMs)ms")
            }
        } else {
            phase4Results["error"] = "No route with waypoints available for refresh test"
            print("[DIAGNOSTIC] Google refresh: No route with waypoints available")
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 4/12 COMPLETE")
        diagnosticSavePartial(docs, output: [
            "status": "in_progress", "completedPhase": 4,
            "totalRoutesSoFar": allGeneratedRoutes.count,
            "elapsedSeconds": round(Date().timeIntervalSince(overallStart) * 10) / 10,
            "phases": [
                "initialGeneration": ["buckets": phase1Results],
                "plusOneGeneration": ["results": phase2Results],
                "crossBucketCache": phase3Results,
                "googleRefresh": phase4Results
            ] as [String: Any]
        ])
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 5: Cancel-Save Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 5/12: Cancel-Save Test")
        await diagnosticNotify("Diagnostic Phase 5/12", body: "Cancel-save test")
        print("[DIAGNOSTIC] ═══ PHASE 5: Cancel-Save Test ═══")
        var phase5Results: [String: Any] = ["stored": 0, "retrieved": 0, "match": false]
        let cancelTestBucket = 20
        let cancelRoutes = allGeneratedRoutes.filter { $0.bucket == cancelTestBucket }.prefix(3)
        if !cancelRoutes.isEmpty {
            let cachedMetas = cancelRoutes.map { entry in
                RouteCacheService.CachedRouteWithMetadata(
                    route: entry.route,
                    name: entry.walkingRoute.name,
                    description: entry.walkingRoute.description,
                    directions: nil,
                    isDeadZoneFallback: false,
                    isFromPrePopulatedDatabase: false
                )
            }
            cacheService.setSessionRoutes(Array(cachedMetas), at: testLocation, durationMinutes: cancelTestBucket)
            let storedCount = cachedMetas.count
            
            // Simulate cancel — just leave session cache. Now retrieve.
            let retrieved = cacheService.getCachedRoutes(near: testLocation, durationMinutes: cancelTestBucket)
            let retrievedCount = retrieved?.count ?? 0
            let match = retrievedCount >= storedCount
            phase5Results = ["stored": storedCount, "retrieved": retrievedCount, "match": match]
            print("[DIAGNOSTIC] Cancel-save: stored \(storedCount) routes, retrieved \(retrievedCount), match=\(match)")
        } else {
            print("[DIAGNOSTIC] Cancel-save: No routes available for \(cancelTestBucket)min bucket")
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 5/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 6: Route Deduplication Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 6/12: Route Deduplication Test")
        await diagnosticNotify("Diagnostic Phase 6/12", body: "Route deduplication test")
        print("[DIAGNOSTIC] ═══ PHASE 6: Route Deduplication Test ═══")
        var phase6Results: [String: Any] = [:]
        for bucket in buckets {
            let bucketEntries = allGeneratedRoutes.filter { $0.bucket == bucket }
            guard bucketEntries.count >= 2 else { continue }
            var signatures = Set<String>()
            var jaccardPairs: [Double] = []
            var duplicatePairs = 0
            
            for entry in bucketEntries {
                let sig = entry.route.places.map { $0.placeId }.sorted().joined(separator: ",") + "|\(entry.route.distanceMeters / 100)"
                signatures.insert(sig)
            }
            
            for i in 0..<bucketEntries.count {
                for j in (i+1)..<bucketEntries.count {
                    let set1 = Set(bucketEntries[i].route.places.map { $0.placeId })
                    let set2 = Set(bucketEntries[j].route.places.map { $0.placeId })
                    let intersection = set1.intersection(set2).count
                    let union = set1.union(set2).count
                    let jaccard = union > 0 ? Double(intersection) / Double(union) : 0
                    jaccardPairs.append(jaccard)
                    if jaccard > 0.8 { duplicatePairs += 1 }
                }
            }
            
            let avgJaccard = jaccardPairs.isEmpty ? 0 : round(jaccardPairs.reduce(0, +) / Double(jaccardPairs.count) * 100) / 100
            phase6Results["\(bucket)"] = [
                "routeCount": bucketEntries.count,
                "uniqueSignatures": signatures.count,
                "avgJaccard": avgJaccard,
                "duplicatePairs": duplicatePairs
            ]
            print("[DIAGNOSTIC] Dedup \(bucket)min: \(bucketEntries.count) routes, \(signatures.count) unique sigs, avgJaccard=\(avgJaccard), dupes=\(duplicatePairs)")
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 6/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 7: POI Quality and Diversity Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 7/12: POI Quality & Diversity Test")
        await diagnosticNotify("Diagnostic Phase 7/12", body: "POI quality & diversity test")
        print("[DIAGNOSTIC] ═══ PHASE 7: POI Quality & Diversity Test ═══")
        var totalPOIs = 0
        var junkNames: [String] = []
        var typeDistribution: [String: Int] = [:]
        var diversityPerBucket: [String: Int] = [:]
        
        for entry in allGeneratedRoutes {
            var bucketTypes = Set<String>()
            for place in entry.route.places {
                totalPOIs += 1
                if GoogleMapsService.isJunkPOIName(place.name) {
                    junkNames.append(place.name)
                }
                for t in (place.types ?? []) {
                    typeDistribution[t, default: 0] += 1
                    bucketTypes.insert(t)
                }
            }
            let bk = "\(entry.bucket)"
            diversityPerBucket[bk] = max(diversityPerBucket[bk] ?? 0, bucketTypes.count)
        }
        
        let phase7Results: [String: Any] = [
            "totalPOIs": totalPOIs,
            "junkNamesFound": junkNames.count,
            "junkNames": junkNames,
            "typeDistribution": typeDistribution,
            "diversityPerBucket": diversityPerBucket
        ]
        print("[DIAGNOSTIC] POI quality: \(totalPOIs) total, \(junkNames.count) junk names\(junkNames.isEmpty ? "" : " [\(junkNames.joined(separator: ", "))]")")
        print("[DIAGNOSTIC] Type distribution: \(typeDistribution.sorted(by: { $0.value > $1.value }).prefix(10).map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        
        diagnosticUpdateProgress(docs, phase: "Phase 7/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 8: Dead Zone Fallback Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 8/12: Dead Zone Fallback Test")
        await diagnosticNotify("Diagnostic Phase 8/12", body: "Dead zone fallback test")
        print("[DIAGNOSTIC] ═══ PHASE 8: Dead Zone Fallback Test ═══")
        var phase8Results: [String: Any] = ["naturalDeadZone": false]
        // Check if any bucket had zero in-band routes
        for bucket in buckets {
            let bucketEntries = allGeneratedRoutes.filter { $0.bucket == bucket }
            let inBandCount = bucketEntries.filter { Self.diagnosticIsRouteInBand(durationMinutes: $0.walkingRoute.durationMinutes, distanceMeters: $0.walkingRoute.distanceMeters, targetDuration: bucket) }.count
            if inBandCount == 0 && !bucketEntries.isEmpty {
                // Check if any were dead zone fallback
                let dzRoutes = bucketEntries.filter { entry in
                    let ratio = Double(entry.walkingRoute.durationMinutes) / Double(bucket)
                    return ratio >= 0.70 && ratio < 0.80
                }
                phase8Results = [
                    "naturalDeadZone": true,
                    "bucket": bucket,
                    "totalRoutes": bucketEntries.count,
                    "inBandRoutes": 0,
                    "deadZoneFallbackRoutes": dzRoutes.count,
                    "closestDuration": bucketEntries.min(by: { abs($0.walkingRoute.durationMinutes - bucket) < abs($1.walkingRoute.durationMinutes - bucket) })?.walkingRoute.durationMinutes ?? 0,
                    "closestPercent": bucketEntries.min(by: { abs($0.walkingRoute.durationMinutes - bucket) < abs($1.walkingRoute.durationMinutes - bucket) }).map { round(Double($0.walkingRoute.durationMinutes) / Double(bucket) * 100) } ?? 0
                ]
                print("[DIAGNOSTIC] Dead zone: \(bucket)min bucket has 0 in-band routes, \(dzRoutes.count) in 70-80% range")
                break
            }
        }
        if !(phase8Results["naturalDeadZone"] as? Bool ?? false) {
            print("[DIAGNOSTIC] Dead zone: No natural dead zone found — all buckets have in-band routes")
        }
        
        diagnosticUpdateProgress(docs, phase: "Phase 8/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 9: Travel-to-Start Time Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 9/12: Travel-to-Start Time Test")
        await diagnosticNotify("Diagnostic Phase 9/12", body: "Travel-to-start time test")
        print("[DIAGNOSTIC] ═══ PHASE 9: Travel-to-Start Time Test ═══")
        var travelPercents: [Double] = []
        var flaggedTravelRoutes = 0
        for entry in allGeneratedRoutes {
            guard let firstPlace = entry.route.places.first else { continue }
            let dist = Self.distanceBetweenCoords(testLocation, CLLocationCoordinate2D(latitude: firstPlace.coordinate.latitude, longitude: firstPlace.coordinate.longitude))
            let travelMin = dist / 80.0
            let pct = entry.bucket > 0 ? (travelMin / Double(entry.bucket)) * 100 : 0
            travelPercents.append(pct)
            if pct > 25 { flaggedTravelRoutes += 1 }
        }
        let avgTravelPct = travelPercents.isEmpty ? 0 : round(travelPercents.reduce(0, +) / Double(travelPercents.count) * 10) / 10
        let maxTravelPct = round((travelPercents.max() ?? 0) * 10) / 10
        let phase9Results: [String: Any] = [
            "avgPercent": avgTravelPct,
            "maxPercent": maxTravelPct,
            "flaggedRoutes": flaggedTravelRoutes,
            "totalRoutes": travelPercents.count
        ]
        print("[DIAGNOSTIC] Travel-to-start: avg \(avgTravelPct)%, max \(maxTravelPct)%, \(flaggedTravelRoutes) flagged (>25%)")
        
        diagnosticUpdateProgress(docs, phase: "Phase 9/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 10: Distance vs Duration Consistency
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 10/12: Distance vs Duration Consistency")
        await diagnosticNotify("Diagnostic Phase 10/12", body: "Distance vs duration consistency")
        print("[DIAGNOSTIC] ═══ PHASE 10: Distance vs Duration Consistency ═══")
        var speeds: [Double] = []
        var flaggedTooSlow = 0, flaggedTooFast = 0
        for entry in allGeneratedRoutes {
            guard entry.walkingRoute.durationMinutes > 0 else { continue }
            let speedMpm = Double(entry.walkingRoute.distanceMeters) / Double(entry.walkingRoute.durationMinutes)
            speeds.append(speedMpm)
            if speedMpm < 50 { flaggedTooSlow += 1 }
            if speedMpm > 120 { flaggedTooFast += 1 }
        }
        let avgSpeed = speeds.isEmpty ? 0 : round(speeds.reduce(0, +) / Double(speeds.count) * 10) / 10
        let phase10Results: [String: Any] = [
            "avgSpeedMpm": avgSpeed,
            "flaggedTooSlow": flaggedTooSlow,
            "flaggedTooFast": flaggedTooFast,
            "totalRoutes": speeds.count
        ]
        print("[DIAGNOSTIC] Distance consistency: avg \(avgSpeed) m/min, \(flaggedTooSlow) too slow (<50), \(flaggedTooFast) too fast (>120)")
        
        diagnosticUpdateProgress(docs, phase: "Phase 10/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 11: API Health
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 11/12: API Health")
        print("[DIAGNOSTIC] ═══ PHASE 11: API Health ═══")
        let phase11Results: [String: Any] = [
            "hasGoogleAPIKey": mapsService.hasAPIKey,
            "google": [
                "calls": apiGoogleCalls,
                "failures": apiGoogleFailures,
                "successRate": apiGoogleCalls > 0 ? round(Double(apiGoogleCalls - apiGoogleFailures) / Double(apiGoogleCalls) * 100) / 100 : 0
            ] as [String: Any],
            "osrm": [
                "calls": apiOsrmCalls,
                "timeouts": apiOsrmTimeouts
            ] as [String: Any],
            "places": [
                "calls": apiPlacesCalls,
                "failures": apiPlacesFailures
            ] as [String: Any]
        ]
        print("[DIAGNOSTIC] API health: Google \(apiGoogleCalls) calls (\(apiGoogleFailures) failures), hasKey=\(mapsService.hasAPIKey)")
        
        diagnosticUpdateProgress(docs, phase: "Phase 11/12 COMPLETE")
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 12: Route Permutation Test
        // ═══════════════════════════════════════════════════════════════════
        diagnosticUpdateProgress(docs, phase: "Phase 12/12: Route Permutation Test")
        await diagnosticNotify("Diagnostic Phase 12/12", body: "Route permutation test — nearly done!")
        print("[DIAGNOSTIC] ═══ PHASE 12: Route Permutation Test ═══")
        var permTested = 0, permPermutable = 0, permUniqueSignatures = 0
        var existingSignatures = Set<String>()
        
        let permCandidates = allGeneratedRoutes.filter { $0.route.places.count >= 2 }.prefix(3)
        for entry in permCandidates {
            permTested += 1
            let places = entry.route.places
            let origSig = places.map { $0.placeId }.sorted().joined(separator: ",") + "|\(entry.route.distanceMeters / 100)"
            existingSignatures.insert(origSig)
            
            let reversedPlaces = Array(places.reversed())
            let reversedSig = reversedPlaces.map { $0.placeId }.sorted().joined(separator: ",") + "|\(entry.route.distanceMeters / 100)"
            
            // Sorted placeIds will be same, so check if waypoint ORDER differs
            let origOrder = places.map { $0.placeId }.joined(separator: ",")
            let reversedOrder = reversedPlaces.map { $0.placeId }.joined(separator: ",")
            let orderDiffers = origOrder != reversedOrder
            
            if orderDiffers {
                permPermutable += 1
                // Check if this would create a unique route in the set
                let orderSig = reversedOrder + "|\(entry.route.distanceMeters / 100)"
                if !existingSignatures.contains(orderSig) {
                    permUniqueSignatures += 1
                    existingSignatures.insert(orderSig)
                }
            }
            print("[DIAGNOSTIC] Permutation: \(entry.walkingRoute.name) (\(places.count) waypoints) — orderDiffers=\(orderDiffers)")
        }
        let phase12Results: [String: Any] = [
            "tested": permTested,
            "permutable": permPermutable,
            "uniqueSignatures": permUniqueSignatures
        ]
        print("[DIAGNOSTIC] Permutation: \(permTested) tested, \(permPermutable) permutable, \(permUniqueSignatures) unique")
        
        // ═══════════════════════════════════════════════════════════════════
        // OUTPUT
        // ═══════════════════════════════════════════════════════════════════
        let totalTimeSeconds = round(Date().timeIntervalSince(overallStart) * 100) / 100
        let totalRoutes = allGeneratedRoutes.count
        let totalInBand = allGeneratedRoutes.filter { Self.diagnosticIsRouteInBand(durationMinutes: $0.walkingRoute.durationMinutes, distanceMeters: $0.walkingRoute.distanceMeters, targetDuration: $0.bucket) }.count
        
        diagnosticUpdateProgress(docs, phase: "Phase 12/12 COMPLETE")
        diagnosticUpdateProgress(docs, phase: "ALL PHASES COMPLETE", detail: "\(totalRoutes) routes, \(totalInBand) in-band, \(totalTimeSeconds)s total")
        
        print("[DIAGNOSTIC] ════════════════════════════════════════════════════════")
        print("[DIAGNOSTIC] COMPLETE: \(totalRoutes) routes, \(totalInBand) in-band, \(totalTimeSeconds)s total")
        print("[DIAGNOSTIC] ════════════════════════════════════════════════════════")
        
        let output: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "location": ["lat": testLocation.latitude, "lng": testLocation.longitude],
            "totalTimeSeconds": totalTimeSeconds,
            "totalRoutes": totalRoutes,
            "totalInBand": totalInBand,
            "phases": [
                "initialGeneration": ["buckets": phase1Results],
                "plusOneGeneration": ["results": phase2Results],
                "crossBucketCache": phase3Results,
                "googleRefresh": phase4Results,
                "cancelSave": phase5Results,
                "deduplication": ["buckets": phase6Results],
                "poiQuality": phase7Results,
                "deadZoneFallback": phase8Results,
                "travelToStart": phase9Results,
                "distanceConsistency": phase10Results,
                "apiHealth": phase11Results,
                "permutation": phase12Results
            ] as [String: Any]
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL)
            try? FileManager.default.removeItem(at: triggerURL)
            print("[DIAGNOSTIC] Wrote \(outputURL.path)")
            if let jsonLine = String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8) {
                print("[DIAGNOSTIC_JSON_START]\(jsonLine)[DIAGNOSTIC_JSON_END]")
            }
            
            // Copy full JSON to clipboard so user can paste it anywhere
            let prettyJSON = String(data: data, encoding: .utf8) ?? ""
            await MainActor.run {
                UIPasteboard.general.string = prettyJSON
                print("[DIAGNOSTIC] ✅ Results copied to clipboard (\(prettyJSON.count) chars)")
            }
            
            // Fire a local notification so the user knows it's done
            let content = UNMutableNotificationContent()
            content.title = "Diagnostic Complete"
            content.body = "Route test finished — \(totalRoutes) routes generated in \(totalTimeSeconds)s. Results copied to clipboard."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "diagnostic_done", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            print("[DIAGNOSTIC] 📬 Notification sent")
            
        } catch {
            print("[DIAGNOSTIC] Failed to write output: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Diagnostic Helpers
    
    /// Replicate isRouteInBand logic from RouteSelectionView
    private static func diagnosticIsRouteInBand(durationMinutes: Int, distanceMeters: Int, targetDuration: Int) -> Bool {
        let rounded = RouteCacheService.roundToNearest5Minutes(targetDuration)
        let isEdgeCase = rounded <= 5 || rounded >= 55
        let minPct: Double = isEdgeCase ? 0.75 : 0.80
        let maxPct: Double = isEdgeCase ? 1.25 : 1.20
        let minDuration = Int(floor(Double(rounded) * minPct))
        let maxDuration = Int(ceil(Double(rounded) * maxPct))
        let minDistance = max(200, rounded * 50)
        return durationMinutes >= minDuration && durationMinutes <= maxDuration && distanceMeters >= minDistance
    }
    
    /// Write live progress to Documents/diagnostic_progress.txt so the user can see where we are
    /// (and if the app crashes, the last line shows exactly which phase was running).
    private func diagnosticUpdateProgress(_ docs: URL, phase: String, detail: String = "") {
        let progressURL = docs.appendingPathComponent(Self.diagnosticProgressFilename)
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(phase)\(detail.isEmpty ? "" : " — \(detail)")\n"
        // Append to progress file (create if missing)
        if let handle = try? FileHandle(forWritingTo: progressURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? line.write(to: progressURL, atomically: true, encoding: .utf8)
        }
        print("[DIAGNOSTIC] PROGRESS: \(phase)\(detail.isEmpty ? "" : " — \(detail)")")
    }
    
    /// Send a notification so the user can see diagnostic progress on the lock screen
    private func diagnosticNotify(_ title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil  // Silent — just visual badge
        let id = "diagnostic_progress_\(UUID().uuidString.prefix(8))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
    
    /// Save partial results JSON after each phase so a crash doesn't lose everything
    private func diagnosticSavePartial(_ docs: URL, output: [String: Any]) {
        let partialURL = docs.appendingPathComponent("diagnostic_partial.json")
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: partialURL)
        }
    }
    
    /// Request a one-shot GPS fix with a timeout. Returns nil if no fix within `timeout` seconds.
    private static func requestGPSFix(timeout: TimeInterval) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            let helper = DiagnosticLocationHelper(timeout: timeout) { coord in
                continuation.resume(returning: coord)
            }
            helper.start()
            // prevent ARC from releasing helper before callback fires
            _ = helper
        }
    }
    
    /// Simple Haversine distance between two coordinates (meters)
    private static func distanceBetweenCoords(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0 // Earth radius in meters
        let dLat = (c2.latitude - c1.latitude) * .pi / 180
        let dLon = (c2.longitude - c1.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(c1.latitude * .pi / 180) * cos(c2.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
    
    private func registerNotificationCategories() {
        // v1.7.4: Categories are now registered in NotificationService.registerNotificationCategories()
        // which includes "Stop Notifications" action on ALL notification types.
        // This avoids the issue where setNotificationCategories() would overwrite each other.
        // The action handlers are still processed here in userNotificationCenter(didReceive:)
        print("📱 Notification categories will be registered by NotificationService")
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 APNs Token received: \(tokenString.prefix(20))...")
        Messaging.messaging().apnsToken = deviceToken
        print("📱 APNs Token set on Messaging - ready for FCM")
        
        // Post notification so other parts of the app can retry FCM operations
        NotificationCenter.default.post(name: Notification.Name("APNSTokenReady"), object: nil)
        print("📱 Posted APNSTokenReady notification - FCM operations can now proceed")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("🔥 FCM Token: \(fcmToken ?? "none")")
        
        // Verify token is valid
        if let token = fcmToken {
            print("🔥 FCM Token length: \(token.count) characters")
            print("🔥 FCM Token (first 20 chars): \(String(token.prefix(20)))...")
        } else {
            print("❌ WARNING: FCM Token is nil - push notifications will not work!")
        }
    }
    
    // Handle incoming remote notification
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📬 Received remote notification: \(userInfo)")
        completionHandler(.newData)
    }
    
    // When app is in foreground, don't show banner - the in-app alert handles it
    // Banners only show when app is in background/closed
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Don't show banner when app is open - in-app alerts handle this
        completionHandler([])
    }
    
    // Handle notification action responses
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        
        print("📱 Notification action: \(actionIdentifier)")
        print("📱 Notification category: \(categoryIdentifier)")
        print("📱 Notification data: \(userInfo)")
        
        // Only handle delay notifications with OK/Stop dialog
        // Walking notifications (halfway, return, etc.) just open the app
        let isDelayNotification = categoryIdentifier == AppDelegate.delayNotificationCategory ||
                                   categoryIdentifier.isEmpty // FCM push notifications may not have category set
        
        // Check if this is a walk notification (halfway, return, marker arrival, etc.)
        let isWalkNotification = categoryIdentifier == "WALKING_ALERT" || 
                                  categoryIdentifier == "RETURN_ALERT"
        
        switch actionIdentifier {
        case AppDelegate.stopNotificationsAction:
            // User tapped "Stop Notifications"
            handleStopNotifications(userInfo: userInfo)
            
        case AppDelegate.viewDetailsAction, UNNotificationDefaultActionIdentifier:
            // User tapped "View Details" or tapped the notification itself
            
            // If this is a walk notification, set flag to suppress in-app duplicate alerts
            if isWalkNotification {
                AppDelegate.cameFromWalkNotification = true
                print("📱 Walk notification tapped (\(categoryIdentifier)) - suppressing in-app walk alerts")
                
                // Post notification to reset any already-shown alerts
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("ResetWalkAlerts"),
                        object: nil
                    )
                }
                
                // Reset the flag after a short delay (so the app has time to check it)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    AppDelegate.cameFromWalkNotification = false
                }
                
                completionHandler()
                return
            }
            
            // Only show delay dialog for delay-related notifications
            guard isDelayNotification else {
                print("📱 Non-delay notification tapped (\(categoryIdentifier)) - just opening app")
                completionHandler()
                return
            }
            
            // Post notification so app can show dialog with OK/Stop options
            print("📱 User tapped delay notification - showing dialog")
            
            let title = response.notification.request.content.title
            let body = response.notification.request.content.body
            let topic = userInfo["topic"] as? String ?? ""
            
            // Immediately suppress in-app alerts
            AppDelegate.suppressInAppAlertsFlag = true
            
            let notificationData = [
                "title": title,
                "body": body,
                "topic": topic
            ]
            
            // Store for pending check - this is the single source of truth
            AppDelegate.pendingNotification = notificationData
            print("📱 Stored pending notification: \(title), suppressing in-app alerts")
            
        case UNNotificationDismissActionIdentifier:
            // User dismissed the notification
            print("📱 User dismissed notification")
            
        default:
            break
        }
        
        completionHandler()
    }
    
    private func handleStopNotifications(userInfo: [AnyHashable: Any]) {
        // Check if this is a clinician/delay notification (has topic)
        if let topic = userInfo["topic"] as? String {
            // Unsubscribe from this clinician's FCM topic
            print("🔕 Unsubscribing from clinician topic: \(topic)")
            
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if let error = error {
                    print("❌ Failed to unsubscribe: \(error.localizedDescription)")
                } else {
                    print("✅ Successfully unsubscribed from \(topic)")
                    
                    // Post notification so UI can update if app is open
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Notification.Name("NotificationsDisabled"),
                            object: nil,
                            userInfo: ["topic": topic]
                        )
                    }
                }
            }
        } else {
            // This is a walking notification (no topic) - cancel all pending walk notifications
            print("🔕 Walking notification - cancelling all pending walk notifications")
            
            // v1.7.8: Do all operations async to prevent blocking the notification handler
            DispatchQueue.global(qos: .utility).async {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                
                // Also clear the active walk flag so no more are scheduled
                UserDefaults.standard.set(false, forKey: "hasActiveWalk")
                WaitingRoomViewModel.clearPersistedPillState()
                
                // Post notification so ViewModel knows to stop the walk
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("WalkNotificationsStopped"),
                        object: nil
                    )
                }
                print("✅ Walk notifications stopped")
            }
        }
    }
}

// MARK: - Diagnostic GPS Helper

/// One-shot location helper for the diagnostic harness. Requests a GPS fix and calls back
/// with the coordinate (or nil on timeout). Self-retaining until callback fires.
private class DiagnosticLocationHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let timeout: TimeInterval
    private let callback: (CLLocationCoordinate2D?) -> Void
    private var fired = false
    private var retainCycle: DiagnosticLocationHelper?  // prevent ARC release
    
    init(timeout: TimeInterval, callback: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.timeout = timeout
        self.callback = callback
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    
    func start() {
        retainCycle = self  // prevent ARC from releasing us
        
        // If we already have permission and a cached location, use it immediately
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if let loc = manager.location, loc.timestamp.timeIntervalSinceNow > -30 {
                finish(loc.coordinate)
                return
            }
            manager.requestLocation()
        } else {
            manager.requestWhenInUseAuthorization()
        }
        
        // Timeout fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            finish(loc.coordinate)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[DIAGNOSTIC] GPS error: \(error.localizedDescription)")
        // Don't finish — let timeout handle it in case a retry succeeds
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finish(nil)
        }
    }
    
    private func finish(_ coord: CLLocationCoordinate2D?) {
        guard !fired else { return }
        fired = true
        manager.stopUpdatingLocation()
        callback(coord)
        retainCycle = nil  // release self
    }
}
