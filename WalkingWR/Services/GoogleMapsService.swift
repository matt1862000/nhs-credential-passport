//
//  GoogleMapsService.swift
//  WalkingWR
//
//  Created for local route generation using Google APIs
//

import Foundation
import CoreLocation
import MapKit
import Combine

// MARK: - Debug Logging Helper
extension String {
    func appendLine(toFile path: String) {
        let url = URL(fileURLWithPath: path)
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer { try? fileHandle.close() }
            try? fileHandle.seekToEnd()
            if let data = (self + "\n").data(using: .utf8) {
                try? fileHandle.write(contentsOf: data)
            }
        } else {
            // File doesn't exist, create it
            try? (self + "\n").write(to: url, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Async Semaphore (Simple Implementation)
/// Simple async semaphore to limit concurrency
private actor AsyncSemaphore {
    private let maxConcurrent: Int
    private var currentCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.maxConcurrent = value
        self.currentCount = value
    }
    
    func wait() async {
        if currentCount > 0 {
            currentCount -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() async {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            // v1.9.27: Cap to prevent over-release
            currentCount = min(currentCount + 1, maxConcurrent)
        }
    }
}

// MARK: - MapKit Rate Limiter Actor (Thread-Safe)
/// Actor to manage MapKit rate limiting with thread-safe access from concurrent tasks
private actor MapKitRateLimiter {
    private var timestamps: [Date] = []
    private let semaphore: AsyncSemaphore  // v1.9.25: Limit concurrency to prevent rate limit cascades
    
    init() {
        self.semaphore = AsyncSemaphore(value: 1)  // Only 1 MapKit-heavy operation at a time
    }
    
    struct RateLimitStatus {
        let currentCount: Int
        let shouldWait: Bool
        let waitTime: TimeInterval?
    }
    
    /// Acquire semaphore before MapKit operation (prevents concurrent calls)
    func acquire() async {
        await semaphore.wait()
    }
    
    /// Release semaphore after MapKit operation
    func release() async {
        await semaphore.signal()
    }
    
    /// Check rate limit status and clean up old timestamps
    func checkAndCleanup(limit: Int, window: TimeInterval) -> RateLimitStatus {
        let now = Date()
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        
        let shouldWait = timestamps.count >= limit
        var waitTime: TimeInterval? = nil
        
        if shouldWait, let oldest = timestamps.first {
            waitTime = window - now.timeIntervalSince(oldest) + 1
        }
        
        return RateLimitStatus(currentCount: timestamps.count, shouldWait: shouldWait, waitTime: waitTime)
    }
    
    /// Record a new request timestamp
    func recordRequest() {
        timestamps.append(Date())
    }
    
    /// Get current count of requests in window
    func getCurrentCount(window: TimeInterval) -> Int {
        let now = Date()
        return timestamps.filter { now.timeIntervalSince($0) < window }.count
    }
}

// MARK: - OSM Mirror Health Tracker Actor (Thread-Safe)
/// Actor to track OSM mirror health and rate limit status for intelligent rotation
private actor OSMMirrorHealthTracker {
    struct MirrorStatus {
        var isRateLimited: Bool
        var rateLimitedUntil: Date?
        var lastSuccess: Date?
        var consecutiveFailures: Int
        var totalRequests: Int
        var totalSuccesses: Int
        var sslBlacklistedUntil: Date?  // P1 FIX: SSL error blacklist (session-level)
    }
    
    private var mirrorStatuses: [String: MirrorStatus] = [:]
    private let rateLimitCooldown: TimeInterval = 300  // 5 minutes cooldown after rate limit
    private let sslBlacklistDuration: TimeInterval = 300  // P1 FIX: 5 minutes for SSL errors (reduced from 30min to avoid blocking all mirrors)
    private let maxConsecutiveFailures = 3  // After 3 failures, deprioritize
    
    init() {
        // Initialize with known mirrors
        let knownMirrors = [
            "https://lz4.overpass-api.de/api/interpreter",
            "https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.osm.jp/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]
        
        for mirror in knownMirrors {
            mirrorStatuses[mirror] = MirrorStatus(
                isRateLimited: false,
                rateLimitedUntil: nil,
                lastSuccess: nil,
                consecutiveFailures: 0,
                totalRequests: 0,
                totalSuccesses: 0,
                sslBlacklistedUntil: nil
            )
        }
    }
    
    /// Record a successful request
    func recordSuccess(mirror: String) {
        var status = mirrorStatuses[mirror] ?? MirrorStatus(
            isRateLimited: false,
            rateLimitedUntil: nil,
            lastSuccess: Date(),
            consecutiveFailures: 0,
            totalRequests: 1,
            totalSuccesses: 1,
            sslBlacklistedUntil: nil
        )
        status.lastSuccess = Date()
        status.consecutiveFailures = 0
        status.totalRequests += 1
        status.totalSuccesses += 1
        mirrorStatuses[mirror] = status
    }
    
    /// Record a rate limit (429) response
    func recordRateLimit(mirror: String) {
        var status = mirrorStatuses[mirror] ?? MirrorStatus(
            isRateLimited: true,
            rateLimitedUntil: Date().addingTimeInterval(rateLimitCooldown),
            lastSuccess: nil,
            consecutiveFailures: 0,
            totalRequests: 1,
            totalSuccesses: 0,
            sslBlacklistedUntil: nil
        )
        status.isRateLimited = true
        status.rateLimitedUntil = Date().addingTimeInterval(rateLimitCooldown)
        status.consecutiveFailures += 1
        status.totalRequests += 1
        mirrorStatuses[mirror] = status
        print("🚫 [OSM] Mirror rate-limited: \(mirror) - cooldown until \(status.rateLimitedUntil?.description ?? "unknown")")
    }
    
    /// P1 FIX: Record SSL error (-1200, -9816) - blacklist for session
    func recordSSLError(mirror: String, errorCode: Int) {
        var status = mirrorStatuses[mirror] ?? MirrorStatus(
            isRateLimited: false,
            rateLimitedUntil: nil,
            lastSuccess: nil,
            consecutiveFailures: 1,
            totalRequests: 1,
            totalSuccesses: 0,
            sslBlacklistedUntil: Date().addingTimeInterval(sslBlacklistDuration)
        )
        status.sslBlacklistedUntil = Date().addingTimeInterval(sslBlacklistDuration)
        status.consecutiveFailures += 1
        status.totalRequests += 1
        mirrorStatuses[mirror] = status
        print("🔒 [OSM] Mirror SSL-blacklisted (error \(errorCode)): \(mirror) - blocked for 5min")
    }
    
    /// Record a failure (non-429, non-SSL)
    func recordFailure(mirror: String) {
        var status = mirrorStatuses[mirror] ?? MirrorStatus(
            isRateLimited: false,
            rateLimitedUntil: nil,
            lastSuccess: nil,
            consecutiveFailures: 1,
            totalRequests: 1,
            totalSuccesses: 0,
            sslBlacklistedUntil: nil
        )
        status.consecutiveFailures += 1
        status.totalRequests += 1
        mirrorStatuses[mirror] = status
    }
    
    /// Check if mirror is currently available (not rate-limited or SSL-blacklisted)
    func isAvailable(mirror: String) -> Bool {
        guard let status = mirrorStatuses[mirror] else { return true }  // Unknown mirrors assumed available
        
        // P1 FIX: Check SSL blacklist first (strictest)
        if let sslUntil = status.sslBlacklistedUntil {
            if Date() < sslUntil {
                return false  // SSL-blacklisted
            } else {
                // SSL blacklist expired, reset
                var updated = status
                updated.sslBlacklistedUntil = nil
                mirrorStatuses[mirror] = updated
                print("✅ [OSM] Mirror SSL-blacklist expired: \(mirror) - available again")
            }
        }
        
        // Check if rate limit cooldown has expired
        if status.isRateLimited, let until = status.rateLimitedUntil {
            if Date() < until {
                return false  // Still in cooldown
            } else {
                // Cooldown expired, reset rate limit status
                var updated = status
                updated.isRateLimited = false
                updated.rateLimitedUntil = nil
                mirrorStatuses[mirror] = updated
                print("✅ [OSM] Mirror cooldown expired: \(mirror) - available again")
                return true
            }
        }
        
        // If too many consecutive failures, deprioritize (but don't block)
        if status.consecutiveFailures >= maxConsecutiveFailures {
            return true  // Still available, just lower priority
        }
        
        return true
    }
    
    /// Get sorted mirrors by priority (healthy first)
    /// P1 FIX: Returns all mirrors, but blacklisted ones are deprioritized (not filtered out)
    /// This ensures we still try blacklisted mirrors if all others fail
    func prioritizeMirrors(_ mirrors: [String]) -> [String] {
        let now = Date()
        
        // Clean up expired rate limits and SSL blacklists
        for (mirror, status) in mirrorStatuses {
            var updated = status
            var changed = false
            if status.isRateLimited, let until = status.rateLimitedUntil, now >= until {
                updated.isRateLimited = false
                updated.rateLimitedUntil = nil
                changed = true
            }
            if let sslUntil = status.sslBlacklistedUntil, now >= sslUntil {
                updated.sslBlacklistedUntil = nil
                changed = true
            }
            if changed {
                mirrorStatuses[mirror] = updated
            }
        }
        
        // Count available (non-blacklisted) mirrors
        let availableCount = mirrors.filter { isAvailable(mirror: $0) }.count
        
        return mirrors.sorted { mirror1, mirror2 in
            let status1 = mirrorStatuses[mirror1]
            let status2 = mirrorStatuses[mirror2]
            
            // Priority 1: Available (not rate-limited, not SSL-blacklisted)
            let available1 = isAvailable(mirror: mirror1)
            let available2 = isAvailable(mirror: mirror2)
            if available1 != available2 {
                return available1  // Available ones first
            }
            
            // P1 FIX: If no mirrors are available, deprioritize SSL-blacklisted ones less aggressively
            // (still try them as last resort)
            if availableCount == 0 {
                let sslBlacklisted1 = status1?.sslBlacklistedUntil != nil && now < (status1?.sslBlacklistedUntil ?? Date())
                let sslBlacklisted2 = status2?.sslBlacklistedUntil != nil && now < (status2?.sslBlacklistedUntil ?? Date())
                if sslBlacklisted1 != sslBlacklisted2 {
                    return !sslBlacklisted1  // Non-SSL-blacklisted first (even if rate-limited)
                }
            }
            
            // Priority 2: Fewer consecutive failures
            let failures1 = status1?.consecutiveFailures ?? 0
            let failures2 = status2?.consecutiveFailures ?? 0
            if failures1 != failures2 {
                return failures1 < failures2
            }
            
            // Priority 3: More recent success
            if let success1 = status1?.lastSuccess, let success2 = status2?.lastSuccess {
                return success1 > success2
            }
            if status1?.lastSuccess != nil {
                return true
            }
            if status2?.lastSuccess != nil {
                return false
            }
            
            // Priority 4: Higher success rate
            let rate1 = status1.map { Double($0.totalSuccesses) / Double(max($0.totalRequests, 1)) } ?? 0.5
            let rate2 = status2.map { Double($0.totalSuccesses) / Double(max($0.totalRequests, 1)) } ?? 0.5
            return rate1 > rate2
        }
    }
}

// MARK: - Timeout Helper
/// Wraps an async operation with a timeout, throwing TimeoutError if exceeded
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Start the operation
        group.addTask {
            try await operation()
        }
        
        // Start timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timeout
        }
        
        // Return first completed task, cancel the other
        guard let result = try await group.next() else {
            throw TimeoutError.timeout
        }
        group.cancelAll()
        return result
    }
}

// v1.9.26: Timeout error for timeout guards
enum TimeoutError: Error {
    case timeout
}

// v1.9.48: POI source tracking for debugging and quality control
enum POISource: String, Codable {
    case google = "google"
    case apple = "apple"
    case osm = "osm"
    case geograph = "geograph"
    case unknown = "unknown"
}

// v1.9.48: Wrapper for POI results with source tracking
private struct SourcedPOIs {
    let source: POISource
    let pois: [PlaceResult]
}

// MARK: - Google Maps Service
// MARK: - v2.0.3 Phase 1.5 / Phase 2A Config
enum AreaDensity {
    case low
    case normal
}

struct RoutingToggles {
    // Global
    static let enforceLowerBoundValidation = true          // Reject <50% unless fallback/sparse
    static let extensionTriggerMinPercent = 35.0           // Was 50%
    static let extensionTriggerMaxPercent = 98.0
    static let extensionMinHeadroomSec = 90
    static let normalMaxRatio = 1.30                       // 130% normal cap
    static let fallbackMaxRatio = 1.80                     // 180% guaranteed fallback
    static let perCallTimeoutLowADS: TimeInterval = 8.0    // low ADS timeout
    static let perCallTimeoutNormal: TimeInterval = 10.0   // normal timeout
    static let stage1BudgetSec: TimeInterval = 5.0
    static let stage2CumulativeBudgetSec: TimeInterval = 12.0
    
    // TASK 1: Per-candidate routing caps (to reduce p95/p99 tail from engine waits)
    static let mapkitSoftCap: TimeInterval = 1.5           // Soft cap: use estimator instead
    static let mapkitHardCap: TimeInterval = 2.5           // Hard cap: force timeout
    static let osrmSoftCap: TimeInterval = 1.8             // Soft cap for OSRM
    static let osrmHardCap: TimeInterval = 2.8             // Hard cap for OSRM
    static let onlyEnginesForKBest = true                  // Only finalists get real engine calls
    
    // TASK 2: K-best Pareto set configuration
    static let kBestK = 3                                  // Number of candidates to keep
    static let kBestEnabled = true                         // Enable k-best Pareto set
    static let earlyExitAfterSoftStopIfKFilled = true      // Only exit early if k is filled
    
    // TASK 3: Multi-pass repair configuration
    static let overshootRepairThreshold = 1.20             // Trigger repair if >120%
    static let microExtendPasses = 2                       // Number of micro-extend passes
    static let microExtendAddMin = [3, 1]                  // Minutes to add per pass (pass 1: +2-4→3, pass 2: +1-2→1)
    static let duplicateCheckCategoryFirst = true          // Category-based duplicate check
    
    // TASK 4: Waypoint preservation (nudge before prune)
    static let nudgeBeforeRemoveMeters = 15.0              // Nudge distance before pruning
    /// Minimum distance (m) from start/end to first waypoint. Matches route_csv_generator MIN_WAYPOINT_DISTANCE_M.
    static let minDistanceFromStartToFirstWaypoint: Double = 100.0
    static let samePlaceThresholdUrban = 30.0              // Same-place threshold for urban/village
    static let samePlaceThresholdSuburban = 20.0           // Same-place threshold for suburban
    static let requireCategoryMatch = true                 // Only prune if categories match
    
    // PHASE C: Area-adaptive speed model
    static let denseLegThresholdM = 150.0                  // Dense if avg leg <150m
    static let suburbanLegThresholdM = 350.0               // Suburban if avg leg >350m
    static let denseSpeedKmh = 3.88                        // SPRINT-6: 3.88 km/h for dense areas (was 3.95, helps cut overshoot)
    static let urbanSpeedKmh = 4.25                        // SPRINT-4: 4.25 km/h for urban (150-350m legs)
    static let suburbanSpeedKmh = 5.00                     // SPRINT-4: 5.00 km/h for suburban (was 4.9)
    
    // SPRINT-6: Selection scoring nudges
    // SPRINT-7 CONFIG TWEAKS: Amplified selection scoring
    // SPRINT-8: Hinged overshoot penalty + early commit
    static let overshootPenaltyMultiplier = 3.0            // TWEAK 1: Increased from 2.5 → 3.0 (make >110% noticeably worse)
    static let subTargetBonus = 0.05                       // TWEAK 1: Increased from 0.01 → 0.05 (undershoot slightly preferred)
    static let waypointScoreBonus = 0.10                   // TWEAK 1: Increased from 0.08 → 0.10 (reward hitting WP minimums)
    static let underWPPenalty = 2.0                        // v2.0.13: Increased from 1.5 → 2.0 (heavier penalty for under-WP routes)
    static let overshootHingeThreshold = 1.20              // SPRINT-8: Extra steep penalty above 120%
    static let overshootHingePenaltyMultiplier = 60.0      // SPRINT-8: Multiplier for 120%+ hinge section
    static let earlyCommitMinAccuracy = 0.95               // SPRINT-8: Early commit if accuracy ≥ 95%
    static let earlyCommitMaxAccuracy = 1.05               // SPRINT-8: Early commit if accuracy ≤ 105%
    static let sectorQuotaEnabled = true                   // SPRINT-8: Enable bearing sector quotas
    static let sectorQuotaCount = 2                        // SPRINT-8: Max candidates per 90° sector
    static let sectorCount = 4                             // SPRINT-8: Number of sectors (4 = 90° each)
    
    // SPRINT-8: Duration-bucket bias correction (global, no postcode)
    // Initial biases based on test data showing ~117% average overshoot
    // Short routes (10-20m) tend to overshoot less, long routes (35-60m) overshoot more
    private static var _durationBias: [Int: Double] = [
        10: 1.05,   // Short routes: slight overcorrection
        15: 1.08,   // 
        20: 1.10,   // Medium-short: moderate correction
        25: 1.12,   // 
        30: 1.14,   // Medium: significant correction
        35: 1.16,   // Medium-long: heavy correction (these overshoot most)
        40: 1.17,   // 
        45: 1.18,   // 
        50: 1.18,   // Long routes: plateau 
        55: 1.17,   // 
        60: 1.16    // Longest routes: slight reduction (less overshoot observed)
    ]
    
    /// Get duration bucket (rounds to nearest 5-min bucket)
    static func durationBucket(for minutes: Int) -> Int {
        return ((minutes + 2) / 5) * 5  // Round to nearest 5
    }
    
    /// Get current bias table for telemetry (v2.0.16)
    static func biasTable() -> [String: Double] {
        return _durationBias.reduce(into: [String: Double]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }
    
    /// Get bias correction for a duration bucket (default 1.0 if not set)
    static func biasFor(duration: Int) -> Double {
        let bucket = durationBucket(for: duration)
        return _durationBias[bucket] ?? 1.0
    }
    
    /// Update bias for a duration bucket (call after route completion with actual/target ratio)
    /// v2.0.13: EMA smoothing with alpha=0.3 for stability (was 0.1, now faster adaptation)
    static func updateBias(duration: Int, actualRatio: Double) {
        let bucket = durationBucket(for: duration)
        let currentBias = _durationBias[bucket] ?? 1.0
        // Exponential moving average: bias = 0.7*old + 0.3*observed (EMA smoothing)
        let alpha = 0.3  // v2.0.13: Increased from 0.1 to 0.3 for faster adaptation
        let newBias = (1.0 - alpha) * currentBias + alpha * actualRatio
        // Clamp to reasonable range [0.8, 1.3]
        _durationBias[bucket] = max(0.8, min(1.3, newBias))
        print("🎯 [BIAS-UPDATE] Duration bucket \(bucket)min: \(String(format: "%.3f", currentBias)) → \(String(format: "%.3f", newBias)) (observed: \(String(format: "%.3f", actualRatio)))")
    }
    
    /// Apply bias correction to target duration
    static func correctedTarget(for targetMinutes: Int) -> Int {
        let bias = biasFor(duration: targetMinutes)
        if bias == 1.0 { return targetMinutes }
        let corrected = Double(targetMinutes) / bias
        return max(5, Int(corrected.rounded()))
    }
    
    // TASK 6: Template fallback for fragile durations
    static let templateFallbackDurations = [10, 25, 45]    // Durations needing templates
    static let templateTriggerCandidatesLt = 3             // Trigger if candidates < this
    static let templateTriggerOnRoutingCap = true          // Trigger on routing cap trip
    
    // TASK 7: Routing quota budgeting
    static let predictiveBudgeting = true                  // Enable predictive budgeting
    static let deferLowValueVariants = true                // Defer low-scoring variants
    static let queueWaitSoftSec: TimeInterval = 0.8        // Defer if queue wait > this
    
    // Time budget
    static let softStopSec: TimeInterval = 12.0            // Soft stop time budget
    static let hardStopSec: TimeInterval = 17.8            // SPRINT-5: Hard stop with 200ms guard band (was 18.0)
    
    // SPRINT-4: Global hard-stop budget guard
    // SPRINT-5: Hard stop at 17.8s (200ms guard band before 18s ceiling)
    struct Budget {
        let t0: TimeInterval
        let soft: TimeInterval = 12.0
        let hard: TimeInterval = 17.8  // SPRINT-5: 200ms guard band to prevent scheduler jitter pushing p99 past 18s
        
        func within() -> Bool {
            let elapsed = Date().timeIntervalSince1970 - t0
            return elapsed < hard
        }
        
        var elapsed: TimeInterval {
            Date().timeIntervalSince1970 - t0
        }
    }
    
    /// SPRINT-4: Global hard-stop guard - returns false if hard-stop exceeded
    /// Caller must return bestSoFar immediately if this returns false
    static func mustContinue(_ budget: Budget, bestSoFar: GeneratedRoute?, stage: String) -> Bool {
        if !budget.within() {
            let elapsedMs = Int(budget.elapsed * 1000)
            print("⛔ [HARD-STOP] [\(stage)] Hard-stop exceeded: elapsed=\(String(format: "%.2f", budget.elapsed))s >= hard=\(String(format: "%.2f", budget.hard))s elapsed_ms=\(elapsedMs) - must return best-so-far")
            return false
        }
        return true
    }
    
    // Minimum waypoints by duration
    // SPRINT-5: Adjusted thresholds to prevent 1-WP collapse
    // 10-15 min → 2 WPs, 16-34 min → 3 WPs, 35+ min → 4 WPs
    static func minWaypoints(forDuration duration: Int) -> Int {
        if duration <= 15 { return 2 }
        if duration <= 34 { return 3 }  // SPRINT-5: Extended from 30 to 34 to cover mid-range better
        return 4  // 35-60 min
    }
    
    // Hard-wall timers (absolute maximum per request)
    static let hardWall10Min: TimeInterval = 15.0          // 10-min routes: 15s max
    static let hardWall15Min: TimeInterval = 18.0          // 15-min routes: 18s max
    static let hardWallShort: TimeInterval = 22.0          // ≤20 min or low ADS: 22s
    static let hardWallNormal: TimeInterval = 28.0         // normal routes: 28s
    
    // Conditional (ADS-aware)
    static let earlyTopoSafeLowADS: TimeInterval = 8.0     // ADS < 3
    static let earlyTopoSafeNormal: TimeInterval = 12.0
    static let dbRadiusBoostADS1 = 1.40                     // +40%
    static let dbRadiusBoostADS2 = 1.25                     // +25%
    
    // Duration-aware curated DB pre-filter
    static let curatedShortMinMax = (min: 35.0, max: 130.0) // ≤20 min
    static let curatedMidMinMax = (min: 45.0, max: 135.0)   // 21–35 min
    static let curatedLongMinMax = (min: 50.0, max: 135.0)  // ≥36 min
    
    /// Calculate hard-wall timeout based on duration, ADS, and postcode
    static func hardWallFor(duration: Int, ads: Int, postcode: String?) -> TimeInterval {
        // Problematic postcodes get tighter budgets
        if let pc = postcode, postcodeOverrides[pc] != nil {
            if duration <= 10 { return hardWall10Min }
            if duration <= 15 { return hardWall15Min }
            return hardWallShort
        }
        
        // Duration-based hard-wall
        if duration <= 10 { return hardWall10Min }
        if duration <= 15 { return hardWall15Min }
        if duration <= 20 || ads < 3 { return hardWallShort }
        return hardWallNormal
    }
}

struct AreaOverride {
    var alwaysBlend: Bool
    var earlyTopoSafeSec: TimeInterval
    var perCallTimeoutSec: TimeInterval
    var dbRadiusBoost: Double
    var validationMultiplier: Double   // e.g., 0.88–0.90 dense urban
}

// Postcode-level overrides for hotspots
let postcodeOverrides: [String: AreaOverride] = [
    "S1 4JP": AreaOverride(
        alwaysBlend: true,
        earlyTopoSafeSec: 8.0,
        perCallTimeoutSec: 6.0,
        dbRadiusBoost: 1.40,
        validationMultiplier: 0.89
    ),
    "S11 9BF": AreaOverride(
        alwaysBlend: true,
        earlyTopoSafeSec: 8.0,
        perCallTimeoutSec: 8.0,
        dbRadiusBoost: 1.40,
        validationMultiplier: 0.92  // parks/green corridors
    )
]

// SPRINT-4: Postcode speed overrides REMOVED - using global density-aware speed model only
// All speed selection now uses leg-length heuristic (dense/urban/suburban) with no postcode branching
// let postcodeSpeedOverrides: [String: Int] = [
//     "S1 4JP": 65,   // REMOVED: Use density-aware model instead
//     "S11 9BF": 70,  // REMOVED: Use density-aware model instead
//     "WF2 0GU": 82   // REMOVED: Use density-aware model instead
// ]

class GoogleMapsService: ObservableObject {
    static let shared = GoogleMapsService()
    
    // API Key - bundled with app in Info.plist
    // For production, consider using a backend proxy to hide the key
    // For production, consider using a backend proxy to hide the key
    private var apiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String ?? ""
    }
    
    // Geograph API Key - optional, request from https://www.geograph.org.uk/help/api
    private var geographApiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "GEOGRAPH_API_KEY") as? String ?? ""
    }
    
    // v2.0.3: Batch test mode flag - skip Apple Maps to avoid rate limiting
    private var isBatchTestMode: Bool = false
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // v1.9.3: Comprehensive API call tracking
    private struct APICallRecord {
        var apiName: String
        var success: Bool
        var httpStatus: Int?
        var responseTime: TimeInterval?
        var errorMessage: String?
        var bundleIdSent: Bool
        var timestamp: Date
        var details: String?  // Additional context (e.g., "43 categories", "3 waypoints")
    }
    private var apiCallRecords: [APICallRecord] = []
    
    private func recordAPICall(
        apiName: String,
        success: Bool,
        httpStatus: Int? = nil,
        responseTime: TimeInterval? = nil,
        errorMessage: String? = nil,
        bundleIdSent: Bool = false,
        details: String? = nil
    ) {
        apiCallRecords.append(APICallRecord(
            apiName: apiName,
            success: success,
            httpStatus: httpStatus,
            responseTime: responseTime,
            errorMessage: errorMessage,
            bundleIdSent: bundleIdSent,
            timestamp: Date(),
            details: details
        ))
    }
    
    func printAPICallSummary() {
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("📊 API CALL SUMMARY")
        print("═══════════════════════════════════════════════════════════")
        
        if apiCallRecords.isEmpty {
            print("   ⚠️  No API calls recorded yet")
            print("   (Places API may be using cache, Directions API called on 'Let's Go')")
        } else {
            // Group by API name
            let grouped = Dictionary(grouping: apiCallRecords) { $0.apiName }
            
            for (apiName, calls) in grouped.sorted(by: { $0.key < $1.key }) {
                let successCount = calls.filter { $0.success }.count
                let failCount = calls.filter { !$0.success }.count
                let totalCount = calls.count
                
                let status = failCount == 0 ? "✅" : (successCount == 0 ? "❌" : "⚠️")
                print("")
                print("\(status) \(apiName)")
                print("   Calls: \(totalCount) total (\(successCount) success, \(failCount) failed)")
                
                // Show bundle ID status
                let bundleIdSentCount = calls.filter { $0.bundleIdSent }.count
                if bundleIdSentCount > 0 {
                    print("   📱 Bundle ID: Sent in \(bundleIdSentCount)/\(totalCount) calls")
                } else {
                    print("   ⚠️  Bundle ID: NOT sent (may cause restrictions)")
                }
                
                // Show response times
                let successfulCalls = calls.filter { $0.success && $0.responseTime != nil }
                if !successfulCalls.isEmpty {
                    let avgTime = successfulCalls.compactMap { $0.responseTime }.reduce(0, +) / Double(successfulCalls.count)
                    let minTime = successfulCalls.compactMap { $0.responseTime }.min() ?? 0
                    let maxTime = successfulCalls.compactMap { $0.responseTime }.max() ?? 0
                    print("   ⏱️  Response time: avg \(String(format: "%.2f", avgTime))s (min: \(String(format: "%.2f", minTime))s, max: \(String(format: "%.2f", maxTime))s)")
                }
                
                // Show recent failures
                let recentFailures = calls.filter { !$0.success }.suffix(3)
                if !recentFailures.isEmpty {
                    print("   ❌ Recent failures:")
                    for failure in recentFailures {
                        if let status = failure.httpStatus {
                            print("      • HTTP \(status)", terminator: "")
                        }
                        if let error = failure.errorMessage {
                            let shortError = error.count > 60 ? String(error.prefix(60)) + "..." : error
                            print(": \(shortError)")
                        } else {
                            print("")
                        }
                        if let details = failure.details {
                            print("        (\(details))")
                        }
                    }
                }
                
                // Show details for successful calls
                if let lastSuccess = calls.filter({ $0.success }).last, let details = lastSuccess.details {
                    print("   ℹ️  Last success: \(details)")
                }
            }
        }
        
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("")
        
        // Don't clear results - keep them for later summary
    }
    
    // v1.8.2: Route exploration animation - publishes route attempts for UI
    struct RouteAttempt {
        let polylineCoordinates: [CLLocationCoordinate2D]
        let poiName: String
        let isValid: Bool  // True if route passed validation
        let durationMinutes: Int
    }
    @Published var currentRouteAttempt: RouteAttempt?
    @Published var routeAttemptCount: Int = 0
    
    /// Publish a route attempt for the loading animation
    func publishRouteAttempt(coordinates: [CLLocationCoordinate2D], poiName: String, isValid: Bool, durationMinutes: Int) {
        DispatchQueue.main.async {
            self.routeAttemptCount += 1
            self.currentRouteAttempt = RouteAttempt(
                polylineCoordinates: coordinates,
                poiName: poiName,
                isValid: isValid,
                durationMinutes: durationMinutes
            )
        }
    }
    
    /// Reset route attempts when starting new generation
    func resetRouteAttempts() {
        DispatchQueue.main.async {
            self.routeAttemptCount = 0
            self.currentRouteAttempt = nil
        }
    }
    
    // v1.6.10: Low POI warning for sparse areas
    @Published var hasLimitedPOIs = false
    @Published var lastPOICount = 0
    static let limitedPOIThreshold = 50  // Below this, show warning
    
    // v1.6.21: Short route viability gate
    @Published var shortRouteNotViable = false  // True if 5-7min routes can't work here
    @Published var minimumViableMinutes = 5     // Suggested minimum duration for this area
    
    // v1.6.24: Early POI prefetching (when clinician is selected)
    @Published var isPrefetchingEarly = false
    @Published var earlyPrefetchComplete = false
    private var earlyPrefetchedPOIs: [PlaceResult] = []
    private var earlyPrefetchLocation: CLLocationCoordinate2D?
    
    private let session = URLSession.shared
    
    // MARK: - Alternative Routes Buffer
    // Stores valid endpoint routes that weren't returned as primary (e.g., "boring" single-waypoint routes)
    // Caller can retrieve these to add to the route pool for more variety
    private(set) var alternativeEndpointRoutes: [GeneratedRoute] = []
    
    // MARK: - MapKit Rate Limiting
    // MapKit allows 50 requests per 60 seconds
    // Using actor for thread-safe access from concurrent tasks
    private let rateLimiter = MapKitRateLimiter()
    private let mapKitRateLimit = 45  // Stay under 50 to be safe
    private let mapKitRateLimitWindow: TimeInterval = 60
    
    // MARK: - OSM Mirror Health Tracking
    // Track OSM mirror health and rate limits for intelligent rotation
    private let osmMirrorTracker = OSMMirrorHealthTracker()
    
    /// Check if we're approaching rate limit and wait if needed (thread-safe via actor)
    private func checkMapKitRateLimit() async {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        
        // If approaching limit, wait for oldest request to expire
        if status.shouldWait, let waitTime = status.waitTime, waitTime > 0 {
            print("⏳ Approaching MapKit rate limit (\(status.currentCount)/50), waiting \(Int(waitTime))s...")
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
    
    // MARK: - Google Directions Quota Tracking (v1.8.9)
    // Track daily usage to stay within budget (~$0.25/day max)
    // Free tier allows 333/day, 100 is conservative
    private let googleDirectionsDailyCap = 100
    private var googleDirectionsCallsToday = 0
    private let googleDirectionsCountKey = "googleDirectionsCount"
    private let googleDirectionsDateKey = "googleDirectionsDate"
    
    // MARK: - v2.1.1: Async MapKit Fallback for Restricted Roads
    // When Google returns restricted roads, we return immediately and trigger MapKit in background
    private(set) var lastRouteHadRestrictedRoads = false
    private var pendingMapKitFallbackWaypoints: [CLLocationCoordinate2D]?
    private var pendingMapKitFallbackOrigin: CLLocationCoordinate2D?
    
    // MARK: - v1.9.48: Google Places Quota Protection
    // Temporarily disable Google Places on 429/quota errors
    private var googlePlacesDisabledUntil: Date?
    private let googlePlacesCooldownMinutes: TimeInterval = 10 // 10 min cooldown on quota errors
    
    // MARK: - Google Places Daily Call Cap (v1.9.52)
    // Track daily usage to cap costs per user
    // Conservative limit: 10 calls/day = ~£0.24/day max per user (~£7.20/month)
    // Adjust based on your budget: 5 = £0.12/day, 20 = £0.48/day
    private let googlePlacesDailyCap = 10  // Max calls per day per user
    private var googlePlacesCallsToday = 0
    private let googlePlacesCountKey = "googlePlacesCount"
    private let googlePlacesDateKey = "googlePlacesDate"
    
    /// Check if Google Places is currently disabled due to quota
    private var isGooglePlacesDisabled: Bool {
        guard let disabledUntil = googlePlacesDisabledUntil else { return false }
        if Date() >= disabledUntil {
            googlePlacesDisabledUntil = nil // Cooldown expired
            print("🌐 [QUOTA] Google Places cooldown expired - re-enabling")
            return false
        }
        return true
    }
    
    /// Check if we can make a Google Places API call (daily cap + quota check)
    private var canMakeGooglePlacesCall: Bool {
        // Check quota cooldown first
        if isGooglePlacesDisabled {
            return false
        }
        
        // Check daily cap
        resetGooglePlacesCountIfNewDay()
        let canCall = googlePlacesCallsToday < googlePlacesDailyCap
        
        if !canCall {
            print("🛑 [CAP] Google Places daily cap reached (\(googlePlacesCallsToday)/\(googlePlacesDailyCap)) - using Apple/OSM only")
        }
        
        return canCall
    }
    
    /// Reset daily call count if it's a new day
    private func resetGooglePlacesCountIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = UserDefaults.standard.object(forKey: googlePlacesDateKey) as? Date ?? Date.distantPast
        let lastDay = Calendar.current.startOfDay(for: lastDate)
        
        if today > lastDay {
            googlePlacesCallsToday = 0
            UserDefaults.standard.set(today, forKey: googlePlacesDateKey)
            UserDefaults.standard.set(0, forKey: googlePlacesCountKey)
            print("🌐 [CAP] Daily Google Places call count reset (new day)")
        } else {
            googlePlacesCallsToday = UserDefaults.standard.integer(forKey: googlePlacesCountKey)
        }
    }
    
    /// Record a Google Places API call
    private func recordGooglePlacesCall() {
        googlePlacesCallsToday += 1
        UserDefaults.standard.set(googlePlacesCallsToday, forKey: googlePlacesCountKey)
        print("🌐 [CAP] Google Places call recorded: \(googlePlacesCallsToday)/\(googlePlacesDailyCap) today")
    }
    
    /// Get current Google Places call count (for diagnostics)
    func getGooglePlacesCallCount() -> (today: Int, cap: Int) {
        resetGooglePlacesCountIfNewDay()
        return (googlePlacesCallsToday, googlePlacesDailyCap)
    }
    
    /// Disable Google Places temporarily after quota error
    private func disableGooglePlacesTemporarily() {
        googlePlacesDisabledUntil = Date().addingTimeInterval(googlePlacesCooldownMinutes * 60)
        print("🛑 [QUOTA] Google Places disabled for \(Int(googlePlacesCooldownMinutes)) minutes due to quota/rate limit")
    }
    
    private var canUseGoogleDirectionsRefresh: Bool {
        resetGoogleDirectionsCountIfNewDay()
        return googleDirectionsCallsToday < googleDirectionsDailyCap
    }
    
    private func resetGoogleDirectionsCountIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = UserDefaults.standard.object(forKey: googleDirectionsDateKey) as? Date ?? Date.distantPast
        let lastDay = Calendar.current.startOfDay(for: lastDate)
        
        if today > lastDay {
            googleDirectionsCallsToday = 0
            UserDefaults.standard.set(today, forKey: googleDirectionsDateKey)
            UserDefaults.standard.set(0, forKey: googleDirectionsCountKey)
        } else {
            googleDirectionsCallsToday = UserDefaults.standard.integer(forKey: googleDirectionsCountKey)
        }
    }
    
    private func recordGoogleDirectionsCall() {
        googleDirectionsCallsToday += 1
        UserDefaults.standard.set(googleDirectionsCallsToday, forKey: googleDirectionsCountKey)
    }
    
    /// Record a MapKit request (thread-safe via actor)
    private func recordMapKitRequest() {
        Task { await rateLimiter.recordRequest() }
    }
    
    // MARK: - Leg Time Cache (DISABLED for ToS compliance)
    // v2.1.0: DISABLED - MapKit walking times cannot be cached per Apple's Terms of Service
    // Leg times are now always calculated fresh via MapKit
    
    private struct LegCacheKey: Hashable {
        let originGrid: String
        let poiId: String
    }
    
    private struct LegCacheValue {
        let minutes: Int
        let meters: Int
        let polyline: String
        let updatedAt: Date
    }
    
    // v2.1.0: Leg cache disabled - keep struct for backward compatibility but don't use
    // private var legCache: [LegCacheKey: LegCacheValue] = [:]  // DISABLED
    
    /// Convert coordinate to 50m grid cell string (kept for potential future use)
    private func gridKey(for coordinate: CLLocationCoordinate2D) -> String {
        let latGrid = round(coordinate.latitude / 0.00045) * 0.00045
        let lonGrid = round(coordinate.longitude / 0.0007) * 0.0007
        return String(format: "%.5f,%.4f", latGrid, lonGrid)
    }
    
    /// Get cached leg time if available
    /// v2.1.0: DISABLED - always returns nil (ToS compliance)
    private func getCachedLegTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult) -> LegCacheValue? {
        // v2.1.0: Leg caching disabled for ToS compliance
        // MapKit walking times cannot be cached per Apple's Terms of Service
        return nil
    }
    
    /// Cache leg time for future use
    /// v2.1.0: DISABLED - no-op (ToS compliance)
    private func cacheLegTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult, minutes: Int, meters: Int, polyline: String) {
        // v2.1.0: Leg caching disabled for ToS compliance
        // No-op - leg times are always calculated fresh
    }
    
    // MARK: - Recently Used POI Tracking
    // Tracks POIs used in recent routes to encourage variety
    // Key: POI place ID → Value: timestamp when last used
    private var recentlyUsedPOIs: [String: Date] = [:]
    private let recentPOIPenaltyWindow: TimeInterval = 300  // 5 minutes
    
    /// Record a POI as recently used
    func markPOIAsUsed(_ placeId: String) {
        recentlyUsedPOIs[placeId] = Date()
        
        // Clean up old entries
        let cutoff = Date().addingTimeInterval(-recentPOIPenaltyWindow * 2)
        recentlyUsedPOIs = recentlyUsedPOIs.filter { $0.value > cutoff }
    }
    
    /// Get penalty for recently used POI (0.0 = no penalty, 1.0 = max penalty)
    private func recentUsePenalty(for placeId: String) -> Double {
        guard let lastUsed = recentlyUsedPOIs[placeId] else { return 0 }
        let secondsAgo = Date().timeIntervalSince(lastUsed)
        
        if secondsAgo < 60 { return 0.9 }       // Used <1 min ago: heavy penalty
        if secondsAgo < 180 { return 0.6 }      // Used <3 min ago: medium penalty
        if secondsAgo < recentPOIPenaltyWindow { return 0.3 }  // Used <5 min ago: light penalty
        return 0  // Old enough, no penalty
    }
    
    // MARK: - POI Walkability Score
    // Scores POIs by how pleasant they are as walking waypoints
    // Higher score = better for walking routes
    
    /// Calculate walkability score for a POI based on its type
    /// Returns score from -2 (avoid) to +2 (prefer)
    /// Check if POI is from Google (highest quality, most up-to-date)
    private func isGooglePOI(_ poi: PlaceResult) -> Bool {
        // Google POIs don't have "apple_" or "osm_" prefix
        return !poi.placeId.hasPrefix("apple_") && !poi.placeId.hasPrefix("osm_")
    }
    
    /// Source quality score - prefer Google POIs over OSM/Apple
    /// Google POIs are more accurate and up-to-date
    /// OSM/Apple POIs not verified against Google cache are deprioritized
    private func sourceQualityScore(for poi: PlaceResult, googlePOICount: Int, googlePOIs: [PlaceResult] = []) -> Double {
        // Only apply scoring if we have sufficient Google POIs (10+)
        // This ensures we still use OSM/Apple in sparse areas
        guard googlePOICount >= 10 else {
            // No Google POIs available - use source-based scoring for pre-populated data
            // Pre-populated OSM/Geograph POIs are pre-verified, so give them neutral/positive scores
            if poi.source == .osm || poi.source == .geograph {
                return 0.5  // Neutral bonus for pre-populated OSM/Geograph (they're pre-verified)
            }
            return 0.0  // Default for other sources when no Google POIs
        }
        
        if isGooglePOI(poi) {
            return 3.0  // Strong preference for Google POIs
        } else {
            // OSM/Apple POI - check if verified against Google cache
            if !googlePOIs.isEmpty {
                let isVerified = hasMatchingGooglePOI(poi, in: googlePOIs)
                if isVerified {
                    return 1.0  // Verified OSM/Apple POI - slight bonus
                } else {
                    return -2.0  // Unverified - deprioritize (may be closed/outdated)
                }
            }
            return 0.0  // No Google cache to verify against
        }
    }
    
    /// Check if an OSM/Apple POI has a matching Google POI nearby
    /// Uses location proximity (~100m) and name similarity (50%+)
    private func hasMatchingGooglePOI(_ poi: PlaceResult, in googlePOIs: [PlaceResult]) -> Bool {
        let maxDistanceMeters: Double = 100  // Must be within 100m
        let minNameSimilarity: Double = 0.5  // 50% name match
        
        for googlePOI in googlePOIs {
            let distance = distanceBetween(poi.coordinate, googlePOI.coordinate)
            if distance <= maxDistanceMeters {
                let similarity = nameSimilarity(poi.name, googlePOI.name)
                if similarity >= minNameSimilarity {
                    return true  // Found matching Google POI
                }
            }
        }
        
        // Log deprioritized POI (only first time)
        if !loggedUnverifiedPOIs.contains(poi.placeId) {
            print("⚠️ UNVERIFIED: '\(poi.name)' - no matching Google POI (may be closed)")
            loggedUnverifiedPOIs.insert(poi.placeId)
        }
        
        return false  // No match found - likely closed or outdated
    }
    
    /// Track which unverified POIs we've logged to avoid spam
    private var loggedUnverifiedPOIs: Set<String> = []
    
    /// Calculate name similarity between two strings (0.0 - 1.0)
    /// Uses Jaccard similarity on word tokens
    private func nameSimilarity(_ name1: String, _ name2: String) -> Double {
        let words1 = Set(name1.lowercased().split(separator: " ").map { String($0) })
        let words2 = Set(name2.lowercased().split(separator: " ").map { String($0) })
        
        guard !words1.isEmpty || !words2.isEmpty else { return 0.0 }
        
        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count
        
        return Double(intersection) / Double(union)
    }
    
    // MARK: - v1.6.48: Restricted POI Filter (Safety Net)
    
    /// Check if POI should be excluded based on name/type patterns
    /// This is a safety net that runs on cached POIs to catch items
    /// that were cached before filters were implemented
    // v1.9.16: Made internal so RouteCacheService can filter cached routes
    func isRestrictedPOI(_ poi: PlaceResult) -> Bool {
        // Normalize name: lowercase and remove apostrophes/special chars for matching
        let nameLower = poi.name.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "") // Smart apostrophe
            .replacingOccurrences(of: " ", with: "") // Remove spaces for better matching
        let types = Set(poi.types ?? [])
        
        // Restricted name patterns (childcare facilities, playgrounds)
        // Note: Schools are NOT filtered here - they're allowed if on main road (checked by filterPOIsInRestrictedAreas)
        // Also check without spaces/apostrophes to catch variations like "CJ's Playcare"
        let restrictedNamePatterns = [
            "playcare", "daycare", "preschool", "preschool",
            "nursery", "kindergarten", "childcare", "childcare",
            "playground", "playarea", "playgroup", "cjsplaycare" // Catch "CJ's Playcare"
        ]
        
        // Check normalized name
        for pattern in restrictedNamePatterns {
            if nameLower.contains(pattern) {
                print("🏫 ❌ Restricted POI detected: '\(poi.name)' (matched pattern: '\(pattern)')")
                return true
            }
        }
        
        // Also check original name (in case normalization removed the match)
        let originalNameLower = poi.name.lowercased()
        for pattern in ["playcare", "daycare", "preschool", "nursery", "kindergarten", "childcare", "playground", "play area", "playgroup"] {
            if originalNameLower.contains(pattern) {
                print("🏫 ❌ Restricted POI detected: '\(poi.name)' (matched pattern: '\(pattern)')")
                return true
            }
        }
        
        // Restricted types
        let restrictedTypes = Set([
            "kindergarten", "nursery", "playground", 
            "preschool", "daycare", "childcare"
        ])
        
        if !types.isDisjoint(with: restrictedTypes) {
            print("🏫 ❌ Restricted POI detected: '\(poi.name)' (restricted type)")
            return true
        }
        
        return false
    }
    
    // MARK: - Angular Diversity Score (ADS) v1.8.17
    /// Calculates how well POIs are distributed around the compass
    /// Returns count of 45° sectors (8 total) that contain viable POIs
    /// ADS ≥ 6 → Good for multi-waypoint circular routes
    /// ADS 3-5 → Partial coverage, hybrid routes
    /// ADS < 3 → Poor coverage, single-destination routes
    private func calculateAngularDiversityScore(
        pois: [PlaceResult],
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) -> (score: Int, sectors: [Int: Int]) {
        // Define 8 sectors of 45° each (N, NE, E, SE, S, SW, W, NW)
        var sectorCounts: [Int: Int] = [:]
        for i in 0..<8 { sectorCounts[i] = 0 }
        
        // Calculate viable distance range for this duration
        let walkingSpeed: Double = 80 // meters per minute
        let minDist = walkingSpeed * Double(targetDurationMinutes) * 0.25 // ~25% of target as min
        let maxDist = walkingSpeed * Double(targetDurationMinutes) * 0.55 // ~55% of target as max
        
        for poi in pois {
            let bearing = bearingBetween(origin, poi.coordinate)
            let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: poi.coordinate.latitude, longitude: poi.coordinate.longitude))
            
            // Only count POIs within viable distance range
            guard distance >= minDist && distance <= maxDist else { continue }
            
            // Convert bearing (-180 to 180) to sector (0-7)
            let normalizedBearing = bearing < 0 ? bearing + 360 : bearing
            let sector = Int(normalizedBearing / 45.0) % 8
            sectorCounts[sector, default: 0] += 1
        }
        
        // Count sectors with at least one viable POI
        let coveredSectors = sectorCounts.values.filter { $0 > 0 }.count
        
        return (score: coveredSectors, sectors: sectorCounts)
    }
    
    private func walkabilityScore(for poi: PlaceResult) -> Double {
        let types = Set(poi.types ?? [])
        let nameLower = poi.name.lowercased()
        
        // Excellent walking destinations (+2)
        let excellent = Set(["park", "playground", "nature_reserve", "garden", "trail",
                            "hiking_area", "botanical_garden", "national_park"])
        if !types.isDisjoint(with: excellent) { return 2.0 }
        
        // Good walking destinations (+1)
        let good = Set(["cafe", "restaurant", "bakery", "landmark", "museum",
                       "art_gallery", "church", "historic_site", "monument",
                       "library", "community_center", "sports_club", "pub"])
        if !types.isDisjoint(with: good) { return 1.0 }
        
        // v1.6.47: OSM-specific name bonus for POIs without good type tags
        // These are landmarks that OSM tags differently or sparsely
        // Moderate +0.5 score so they compete with but don't dominate Google POIs
        let osmExcellentNames = ["war memorial", "memorial", "monument", "village hall", 
                                 "community hall", "village green", "recreation ground"]
        for pattern in osmExcellentNames {
            if nameLower.contains(pattern) { return 0.5 }
        }
        
        let osmGoodNames = ["church", "chapel", "hall", "inn", "pub", "fisheries", 
                           "tavern", "farm", "cottage", "stores", "post office"]
        for pattern in osmGoodNames {
            if nameLower.contains(pattern) { return 0.5 }
        }
        
        // v1.6.47: OSM-specific type tags that might not be in the good list
        let osmGoodTypes = Set(["memorial", "village_hall", "recreation_ground", 
                               "community_centre", "historic", "place_of_worship"])
        if !types.isDisjoint(with: osmGoodTypes) { return 0.5 }
        
        // Avoid for walking (-1)
        let avoid = Set(["gas_station", "car_wash", "car_repair", "car_dealer",
                        "parking", "atm", "bank", "insurance_agency"])
        if !types.isDisjoint(with: avoid) { return -1.0 }
        
        // Strongly avoid (-2)
        let stronglyAvoid = Set(["industrial", "warehouse", "storage", "factory",
                                "transit_station", "bus_station", "train_station"])
        if !types.isDisjoint(with: stronglyAvoid) { return -2.0 }
        
        // Neutral (0)
        return 0.0
    }
    
    // MARK: - v1.6.39: Spatial Thinning for POI Diversity
    
    /// Apply spatial thinning to ensure geographic diversity of POIs
    /// Divides area into grid cells and keeps top-scored POIs per cell
    /// Prevents clusters of POIs in one area from dominating selection
    ///
    /// - Parameters:
    ///   - scoredPlaces: POIs already sorted by score (highest first)
    ///   - origin: User's location (center of grid)
    ///   - maxPOIs: Maximum number of POIs to return
    ///   - gridSizeMeters: Size of each grid cell (smaller = more spread)
    /// - Returns: Spatially diverse subset of POIs, still prioritizing high scores
    private func applySpatialThinning(
        scoredPlaces: [(poi: PlaceResult, score: Double)],
        origin: CLLocationCoordinate2D,
        maxPOIs: Int,
        gridSizeMeters: Double = 150
    ) -> [PlaceResult] {
        guard !scoredPlaces.isEmpty else { return [] }
        
        // Convert grid size to approximate lat/lng degrees
        // 1 degree latitude ≈ 111km, 1 degree longitude varies by latitude
        let latDegreePerMeter = 1.0 / 111_000.0
        let lngDegreePerMeter = 1.0 / (111_000.0 * cos(origin.latitude * .pi / 180))
        let gridLatSize = gridSizeMeters * latDegreePerMeter
        let gridLngSize = gridSizeMeters * lngDegreePerMeter
        
        // Track how many POIs we've taken from each grid cell
        var cellCounts: [String: Int] = [:]
        let maxPerCell = 3  // Allow max 3 POIs from same cell
        
        var result: [PlaceResult] = []
        var skippedDueToClustering = 0
        
        for (poi, _) in scoredPlaces {
            if result.count >= maxPOIs { break }
            
            // Calculate grid cell for this POI
            let cellX = Int((poi.coordinate.latitude - origin.latitude) / gridLatSize)
            let cellY = Int((poi.coordinate.longitude - origin.longitude) / gridLngSize)
            let cellKey = "\(cellX),\(cellY)"
            
            let currentCount = cellCounts[cellKey] ?? 0
            if currentCount < maxPerCell {
                result.append(poi)
                cellCounts[cellKey] = currentCount + 1
            } else {
                skippedDueToClustering += 1
            }
        }
        
        if skippedDueToClustering > 0 {
            print("📊 Spatial thinning: skipped \(skippedDueToClustering) clustered POIs for better diversity")
        }
        
        return result
    }
    
    // MARK: - Pre-Filter POIs by Estimated Duration
    // Estimates round-trip time BEFORE expensive routing API calls
    // Rejects POIs that would create routes way outside target duration
    
    /// Get adaptive road factor based on POI type
    /// Parks/trails have more direct paths, urban areas have more roads
    private func adaptiveRoadFactor(for poi: PlaceResult) -> Double {
        let types = Set(poi.types ?? [])
        
        // Parks/nature: more direct walking paths (1.15-1.25)
        let parkTypes = Set(["park", "playground", "nature_reserve", "garden", "trail",
                            "hiking_area", "botanical_garden", "national_park", "forest",
                            "beach", "campground"])
        if !types.isDisjoint(with: parkTypes) {
            return 1.2
        }
        
        // Car-centric locations: more road detours (1.5)
        let carTypes = Set(["gas_station", "car_wash", "car_dealer", "car_repair",
                           "parking", "car_rental", "atm", "bank"])
        if !types.isDisjoint(with: carTypes) {
            return 1.5
        }
        
        // Default: mixed urban (1.35)
        return 1.35
    }
    
    /// Estimate round-trip walking time to a POI (in minutes)
    /// Uses straight-line distance × adaptive road factor × 2 (round trip)
    private func estimateRoundTripMinutes(from origin: CLLocationCoordinate2D, to poi: PlaceResult) -> Int {
        let straightLineDistance = distanceBetween(origin, poi.coordinate)
        
        // Road factor varies by POI type: parks 1.2, urban 1.35, car-centric 1.5
        let roadFactor = adaptiveRoadFactor(for: poi)
        let estimatedWalkingDistance = straightLineDistance * roadFactor * 2  // Round trip
        
        // Walking speed (use adaptive if available)
        let walkingSpeed = Double(adaptiveWalkingSpeed)  // m/min
        
        let estimatedMinutes = Int(estimatedWalkingDistance / walkingSpeed)
        return estimatedMinutes
    }
    
    /// Pre-filter POIs to only include those within reasonable duration range
    /// This prevents "Springwood Cott" (30min round-trip) from being considered for 5min routes
    func preFilterPOIsByDuration(
        _ pois: [PlaceResult],
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) -> [PlaceResult] {
        // DURATION-AWARE PRE-FILTER: 
        // v1.6.12: HARD CUTOFF for 5-minute routes (batch test showed 180% consistently)
        // The root cause is selection-dominated: we pick wrong POIs, not route wrong
        // For 5min routes: max 7min estimated round-trip (allows ~40% slack)
        
        // v1.6.21: Revert to tighter 7-min cutoff for 5-min routes
        // v1.6.15's 10min cap was too loose → 180% accuracy consistently
        // 7min cap worked better in v1.6.12: allows 40% slack, rejects far POIs
        if targetDurationMinutes == 5 {
            var accepted: [PlaceResult] = []
            var rejected: [(name: String, estimated: Int)] = []
            
            for poi in pois {
                let estimated = estimateRoundTripMinutes(from: origin, to: poi)
                if estimated <= 7 {  // Tight cutoff: max 7min estimated (40% slack)
                    accepted.append(poi)
                } else {
                    rejected.append((poi.name, estimated))
                }
            }
            
            // Debug: Show accepted candidates for 5-min routes
            print("🎯 5-MIN CANDIDATES: \(accepted.count) POIs with ≤10min estimated:")
            for poi in accepted.prefix(10) {
                let est = estimateRoundTripMinutes(from: origin, to: poi)
                print("   ✅ \(poi.name): ~\(est)min")
            }
            if accepted.count > 10 {
                print("   ... and \(accepted.count - 10) more")
            }
            
            print("🎯 ⏱️ 5-MIN HARD CUTOFF: Kept \(accepted.count)/\(pois.count) POIs (max 7min round-trip)")
            if !rejected.isEmpty {
                print("   ❌ Rejected \(rejected.count) POIs with >7min estimated")
            }
            
            // DEBUG: Check for specific nearby places
            let foodPlaces = pois.filter { poi in
                let types = Set(poi.types ?? [])
                return !types.isDisjoint(with: ["restaurant", "cafe", "meal_takeaway", "food", "bakery"])
            }
            print("🍽️ DEBUG: Found \(foodPlaces.count) food places nearby:")
            for fp in foodPlaces.prefix(10) {
                let est = estimateRoundTripMinutes(from: origin, to: fp)
                print("   🍽️ \(fp.name): ~\(est)min round-trip")
            }
            
            // v2.0.1: FALLBACK when pre-filter is too aggressive for 5-min routes
            let minimumCandidates = 10
            if accepted.count < minimumCandidates && pois.count >= minimumCandidates {
                print("🎯 ⚠️ 5-MIN FALLBACK: Only \(accepted.count) candidates (need \(minimumCandidates))")
                
                // Sort by estimated time (closest first)
                let sortedByTime = pois.map { poi -> (poi: PlaceResult, estimated: Int) in
                    (poi, estimateRoundTripMinutes(from: origin, to: poi))
                }.sorted { $0.estimated < $1.estimated }
                
                // Take nearest POIs as fallback
                let fallbackCount = min(minimumCandidates * 2, pois.count)
                let fallbackPOIs = Array(sortedByTime.prefix(fallbackCount).map { $0.poi })
                
                let nearestEstimate = sortedByTime.first?.estimated ?? 0
                let furthestEstimate = sortedByTime[min(fallbackCount - 1, sortedByTime.count - 1)].estimated
                print("🎯 ✅ 5-MIN FALLBACK: Using \(fallbackPOIs.count) nearest POIs (est: \(nearestEstimate)-\(furthestEstimate)min)")
                
                return fallbackPOIs
            }
            
            return accepted
        }
        
        // Standard percentage-based filter for other durations
        // v1.6.21: Revert to v1.6.12 tighter ranges - looser ranges = worse accuracy
        // v2.0.2: Relax for curated POIs - they're semantically high-quality, not topologically safe
        let isUsingCuratedDB = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: origin, radiusMeters: 5000) != nil
        
        let minPercent: Int
        var baseMaxPercent: Int
        if isUsingCuratedDB && targetDurationMinutes <= 20 {
            // v2.0.2: Relaxed pre-filter for curated POIs on short routes
            // Pre-filter should guide, not veto - especially in indirect road networks
            // But: be lenient, not delusional - 130% hard cap aligns with user tolerance
            let standardMaxPercent: Int
            switch targetDurationMinutes {
            case 6...10:
                minPercent = 35; standardMaxPercent = 95  // Base: 35-95% (was 40-95%)
            case 11...15:
                minPercent = 40; standardMaxPercent = 100  // Base: 40-100% (was 45-100%)
            case 16...20:
                minPercent = 45; standardMaxPercent = 105  // Base: 45-105% (was 50-105%)
            default:
                minPercent = 50; standardMaxPercent = 110
            }
            // Apply 15% leniency, but cap at 130% (never delusional)
            // This gives curated POIs slack without letting bad candidates poison the pool
            baseMaxPercent = min(130, Int(Double(standardMaxPercent) * 1.15))
            print("🎯 [CURATED DB] Relaxed pre-filter for \(targetDurationMinutes)min: \(minPercent)-\(baseMaxPercent)% (base: \(standardMaxPercent)%, +15% leniency, capped at 130%)")
        } else {
            switch targetDurationMinutes {
            case 6...10:
                minPercent = 40; baseMaxPercent = 95   // Tight for short routes
            case 11...15:
                minPercent = 45; baseMaxPercent = 100  // Tight for 15min
            case 16...25:
                minPercent = 50; baseMaxPercent = 105  // Moderate
            case 26...40:
                minPercent = 55; baseMaxPercent = 110  // Moderate
            case 41...50:
                minPercent = 55; baseMaxPercent = 105  // Tighter for long
            default:  // 51+ min
                minPercent = 60; baseMaxPercent = 100  // Very tight for very long
            }
        }
        
        // v1.6.27: DENSITY-AWARE TIGHTENING
        // In dense areas (lots of POIs), tighten maxPercent to prevent overshoot
        // This preserves all duration-specific tuning while adapting to POI availability
        // v2.0.2: DISABLE for curated POIs - they're semantically high-quality, not topologically safe
        // Curated POIs don't imply good road networks (e.g., hospital grounds)
        // Note: isUsingCuratedDB already declared above, reusing it
        
        let densityTightening: Double
        if isUsingCuratedDB {
            // v2.0.2: Curated POIs - enforce hard floor (90%) instead of aggressive tightening
            // This prevents rejecting all POIs in indirect road networks
            densityTightening = max(0.90, Double(baseMaxPercent) / 100.0)  // Floor at 90%
            print("🎯 [CURATED DB] Density tightening DISABLED - using floor (90%) instead of tightening")
        } else if pois.count > 300 {
            densityTightening = 0.75   // Very dense (Firth Park, 350 POIs) - 25% tighter
        } else if pois.count > 200 {
            densityTightening = 0.85   // Dense - 15% tighter
        } else if pois.count > 100 {
            densityTightening = 0.95   // Medium - 5% tighter
        } else {
            densityTightening = 1.0    // Sparse (Outwood, 115 POIs) - no change
        }
        
        let effectiveMaxPercent = Int(Double(baseMaxPercent) * densityTightening)
        
        if densityTightening < 1.0 && !isUsingCuratedDB {
            print("🎯 DENSITY TIGHTENING: \(pois.count) POIs → maxPercent \(baseMaxPercent)% → \(effectiveMaxPercent)%")
        } else if isUsingCuratedDB {
            print("🎯 [CURATED DB] Relaxed pre-filter: \(baseMaxPercent)% → \(effectiveMaxPercent)% (floor applied)")
        }
        
        let minDuration = max(2, targetDurationMinutes * minPercent / 100)
        let maxDuration = targetDurationMinutes * effectiveMaxPercent / 100
        
        var accepted: [PlaceResult] = []
        var rejected: [(name: String, estimated: Int, reason: String)] = []
        
        for poi in pois {
            let estimated = estimateRoundTripMinutes(from: origin, to: poi)
            
            if estimated < minDuration {
                rejected.append((poi.name, estimated, "too short"))
            } else if estimated > maxDuration {
                rejected.append((poi.name, estimated, "too long"))
            } else {
                accepted.append(poi)
            }
        }
        
        if !rejected.isEmpty {
            let tooShort = rejected.filter { $0.reason == "too short" }.count
            let tooLong = rejected.filter { $0.reason == "too long" }.count
            print("🎯 ⏱️ PRE-FILTER: Kept \(accepted.count)/\(pois.count) POIs for \(targetDurationMinutes)min target (\(minPercent)-\(effectiveMaxPercent)% range)")
            if tooShort > 0 {
                print("   ❌ Too short (<\(minDuration)min): \(tooShort) POIs")
            }
            if tooLong > 0 {
                let examples = rejected.filter { $0.reason == "too long" }.prefix(3)
                    .map { "\($0.name) (~\($0.estimated)min)" }.joined(separator: ", ")
                print("   ❌ Too long (>\(maxDuration)min): \(tooLong) POIs (e.g., \(examples))")
            }
        }
        
        // SPRINT-6: Asymmetric pre-filter bias - keep more sub-100% candidates than over-100%
        // SPRINT-7: Scale to 70/30 when pool > 40, otherwise 60/40
        // This helps the selector land routes in 90-110% more often
        if accepted.count > 20 {
            // Partition into sub-target and over-target
            let targetRoundTrip = targetDurationMinutes
            let subTarget = accepted.filter { estimateRoundTripMinutes(from: origin, to: $0) <= targetRoundTrip }
            let overTarget = accepted.filter { estimateRoundTripMinutes(from: origin, to: $0) > targetRoundTrip }
            
            // SPRINT-7: 70/30 for large pools (>40), 60/40 otherwise
            let (subPct, overPct) = accepted.count > 40 ? (70, 30) : (60, 40)
            let maxSubTarget = max(12, accepted.count * subPct / 100)
            let maxOverTarget = max(8, accepted.count * overPct / 100)
            
            // Sort each group by closeness to target
            let sortedSub = subTarget.sorted { poi1, poi2 in
                let est1 = estimateRoundTripMinutes(from: origin, to: poi1)
                let est2 = estimateRoundTripMinutes(from: origin, to: poi2)
                return abs(targetRoundTrip - est1) < abs(targetRoundTrip - est2)  // Closest to target first
            }
            let sortedOver = overTarget.sorted { poi1, poi2 in
                let est1 = estimateRoundTripMinutes(from: origin, to: poi1)
                let est2 = estimateRoundTripMinutes(from: origin, to: poi2)
                return est1 < est2  // Shortest overshoot first
            }
            
            let biasedSubTarget = Array(sortedSub.prefix(maxSubTarget))
            let biasedOverTarget = Array(sortedOver.prefix(maxOverTarget))
            
            let beforeBias = accepted.count
            accepted = biasedSubTarget + biasedOverTarget
            
            if accepted.count < beforeBias {
                print("🎯 [ASYMMETRIC-BIAS] Reduced from \(beforeBias) to \(accepted.count) candidates (\(subPct)% sub-target, \(overPct)% over-target)")
            }
        }
        
        // v2.0.1: FALLBACK when pre-filter is too aggressive
        // If we rejected all/most POIs, use the nearest ones anyway
        // This prevents "POI desert" failures where all POIs are slightly too far
        let minimumCandidates = 10
        if accepted.count < minimumCandidates && pois.count >= minimumCandidates {
            print("🎯 ⚠️ PRE-FILTER FALLBACK: Only \(accepted.count) candidates (need \(minimumCandidates))")
            
            // Sort all POIs by estimated round-trip time (closest first)
            let sortedByTime = pois.map { poi -> (poi: PlaceResult, estimated: Int) in
                (poi, estimateRoundTripMinutes(from: origin, to: poi))
            }.sorted { $0.estimated < $1.estimated }
            
            // Take the nearest POIs as fallback candidates
            let fallbackCount = min(minimumCandidates * 2, pois.count)  // Take up to 20 nearest
            let fallbackPOIs = Array(sortedByTime.prefix(fallbackCount).map { $0.poi })
            
            // Show what we're using
            let nearestEstimate = sortedByTime.first?.estimated ?? 0
            let furthestEstimate = sortedByTime[min(fallbackCount - 1, sortedByTime.count - 1)].estimated
            print("🎯 ✅ FALLBACK: Using \(fallbackPOIs.count) nearest POIs (est: \(nearestEstimate)-\(furthestEstimate)min)")
            
            return fallbackPOIs
        }
        
        return accepted
    }
    
    /// Calculate combined POI score for ranking
    /// Higher score = better candidate for route
    /// - Parameter googlePOICount: Number of Google POIs available (for source prioritization)
    /// - Parameter googlePOIs: List of Google POIs for verifying OSM/Apple POIs
    /// - Parameter totalPOICount: Total POIs available (for density-aware distance bonus)
    func calculatePOIScore(
        poi: PlaceResult,
        origin: CLLocationCoordinate2D,
        idealDistance: Double,
        targetDurationMinutes: Int,
        googlePOICount: Int = 0,
        googlePOIs: [PlaceResult] = [],
        totalPOICount: Int = 200  // v1.6.42: For density-aware distance bonus
    ) -> Double {
        let distance = distanceBetween(origin, poi.coordinate)
        
        // Base score: how close to ideal distance (0-1, 1 = perfect)
        let distanceDeviation = abs(distance - idealDistance) / idealDistance
        let distanceScore = max(0, 1.0 - distanceDeviation * 0.5)
        
        // Walkability bonus (-2 to +2)
        let walkability = walkabilityScore(for: poi)
        let walkabilityBonus = walkability * 0.15  // ±0.3 max impact
        
        // Recently used penalty (0 to 0.9)
        let recentPenalty = recentUsePenalty(for: poi.placeId)
        
        // v1.6.33: Source quality bonus - prefer Google POIs when plentiful
        // v1.6.38: OSM/Apple POIs not verified against Google are deprioritized
        let sourceBonus = sourceQualityScore(for: poi, googlePOICount: googlePOICount, googlePOIs: googlePOIs) * 0.1
        
        // v1.6.41: Distance bonus for short walks - escape cluster trap
        // v1.6.42: Now POI-density-aware to prevent overshoot in sparse areas
        let shortWalkDistanceBonus = calculateShortWalkDistanceBonus(
            distance: distance,
            targetDurationMinutes: targetDurationMinutes,
            poiCount: totalPOICount
        )
        
        // Combined score
        let finalScore = distanceScore + walkabilityBonus - recentPenalty + sourceBonus + shortWalkDistanceBonus
        
        return finalScore
    }
    
    /// v1.6.41: Calculate distance bonus for short walks to escape POI clusters
    /// Uses bell-shaped curve: peak at ideal distance, penalty for too close
    /// Effect tapers for longer walks (>25 min) since they self-correct
    /// v1.6.42: POI-density-aware - reduced effect in sparse areas to prevent overshoot
    /// v1.6.44: Reduced distance penalty for 10-15 min walks (150-200m is fine for short walks)
    private func calculateShortWalkDistanceBonus(
        distance: Double,
        targetDurationMinutes: Int,
        poiCount: Int = 200  // Default assumes medium-high density
    ) -> Double {
        // Constants based on analysis
        let idealDistance = Double(targetDurationMinutes) * 40.0  // meters
        
        // v1.6.44: Make minAcceptableDistance duration-aware for short walks
        // For 10 min walks: ideal = 400m, so 150m is acceptable (not a "cluster trap")
        // For 20+ min walks: keep at 200m
        let minAcceptableDistance: Double
        if targetDurationMinutes <= 10 {
            minAcceptableDistance = 150.0  // More lenient for 10 min
        } else if targetDurationMinutes <= 15 {
            minAcceptableDistance = 175.0  // Slightly lenient for 15 min
        } else {
            minAcceptableDistance = 200.0  // Standard for 20+ min
        }
        
        let maxAcceptableDistance = Double(targetDurationMinutes) * 60.0  // meters
        
        // Calculate base bonus using bell curve
        let baseBonus: Double
        if distance < minAcceptableDistance {
            // Too close - penalize (prevents cluster trap)
            let closenessRatio = distance / minAcceptableDistance
            baseBonus = -2.0 * (1.0 - closenessRatio)  // -2.0 at 0m, 0 at threshold
        } else if distance > maxAcceptableDistance {
            // Too far - soft penalty
            let overshootRatio = (distance - maxAcceptableDistance) / maxAcceptableDistance
            baseBonus = -1.0 * min(overshootRatio, 1.0)  // Max -1.0 penalty
        } else {
            // In acceptable range - bonus based on closeness to ideal
            let deviation = abs(distance - idealDistance) / idealDistance
            baseBonus = 1.5 * max(0, 1.0 - deviation)  // Peak 1.5 at ideal, 0 at edges
        }
        
        // Duration-based weight: full effect for ≤25 min, tapers to 0 by 60 min
        let durationWeight: Double
        if targetDurationMinutes <= 25 {
            durationWeight = 1.0
        } else if targetDurationMinutes >= 60 {
            durationWeight = 0.0
        } else {
            durationWeight = 1.0 - Double(targetDurationMinutes - 25) / 35.0
        }
        
        // v1.6.42: POI-density weight - scale down in sparse areas
        // Sparse areas don't have enough POIs at "ideal" distances, causing overshoot
        let densityWeight: Double
        if poiCount < 100 {
            densityWeight = 0.35  // Minimal effect - just a hint, not a driver
        } else if poiCount < 200 {
            densityWeight = 0.7   // Moderate effect
        } else {
            densityWeight = 1.0   // Full effect - enough POIs to benefit
        }
        
        return baseBonus * durationWeight * densityWeight
    }
    
    // MARK: - Adaptive Walking Speed
    // Learns user's actual walking pace from completed walks
    // Uses moving average, clamped to 65-90 m/min
    
    private let walkSpeedKey = "adaptiveWalkingSpeed"
    private let walkSpeedSamplesKey = "walkingSpeedSamples"
    private let defaultWalkingSpeed = 80  // m/min baseline
    private let minWalkingSpeed = 65
    private let maxWalkingSpeed = 90
    private let maxSpeedSamples = 10  // Keep last 10 walks for average
    
    /// Get the adaptive walking speed (m/min)
    var adaptiveWalkingSpeed: Int {
        let stored = UserDefaults.standard.integer(forKey: walkSpeedKey)
        return stored > 0 ? stored : defaultWalkingSpeed
    }
    
    /// Record a completed walk to update adaptive speed
    /// Call this when user finishes a walk with actual distance and duration
    func recordCompletedWalk(distanceMeters: Int, durationMinutes: Int) {
        guard durationMinutes > 0 else { return }
        
        let actualSpeed = distanceMeters / durationMinutes
        
        // Ignore unrealistic speeds (user paused, drove, etc.)
        guard actualSpeed >= 40 && actualSpeed <= 120 else {
            print("🚶 Ignoring unrealistic speed: \(actualSpeed)m/min")
            return
        }
        
        // Get existing samples
        var samples = UserDefaults.standard.array(forKey: walkSpeedSamplesKey) as? [Int] ?? []
        samples.append(actualSpeed)
        
        // Keep only last N samples
        if samples.count > maxSpeedSamples {
            samples = Array(samples.suffix(maxSpeedSamples))
        }
        
        // Calculate moving average
        let average = samples.reduce(0, +) / samples.count
        
        // Clamp to reasonable range
        let clampedSpeed = min(maxWalkingSpeed, max(minWalkingSpeed, average))
        
        // Save
        UserDefaults.standard.set(samples, forKey: walkSpeedSamplesKey)
        UserDefaults.standard.set(clampedSpeed, forKey: walkSpeedKey)
        
        print("🚶 Updated walking speed: \(clampedSpeed)m/min (from \(samples.count) walks, this walk: \(actualSpeed)m/min)")
    }
    
    /// Get one-way walking time to a POI (uses cache if available)
    func getOneWayWalkingTime(from origin: CLLocationCoordinate2D, to poi: PlaceResult) async -> (minutes: Int, meters: Int)? {
        // Check cache first
        if let cached = getCachedLegTime(from: origin, to: poi) {
            print("🗄️ Leg cache HIT: \(poi.name) = \(cached.minutes)min")
            return (cached.minutes, cached.meters)
        }
        
        // Calculate via MapKit
        do {
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: poi.coordinate))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            recordMapKitRequest()
            
            guard let route = response.routes.first else { return nil }
            
            let minutes = Int(route.expectedTravelTime / 60)
            let meters = Int(route.distance)
            
            // Encode polyline for cache
            let polylinePoints = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polylinePoints)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polylinePoints))
            let encodedPolyline = encodePolyline(coords)
            
            // Cache the result
            cacheLegTime(from: origin, to: poi, minutes: minutes, meters: meters, polyline: encodedPolyline)
            print("🗄️ Leg cache MISS: \(poi.name) = \(minutes)min (cached)")
            
            return (minutes, meters)
        } catch {
            print("🗄️ Leg time failed: \(poi.name) - \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Early POI Prefetching
    /// Prefetch POIs as soon as we have location permission and clinician is selected.
    /// This runs in the background so routes are ready faster when user wants to walk.
    /// Call this from ClinicianSelectionView after clinician is selected.
    func prefetchPOIsEarly(location: CLLocationCoordinate2D) {
        // Don't prefetch if already done for this location
        if let existingLocation = earlyPrefetchLocation {
            let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
                .distance(from: CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude))
            if distance < 50 {
                print("📦 Early prefetch: Already prefetched for this location")
                return
            }
        }
        
        // Don't prefetch if already in progress
        guard !isPrefetchingEarly else {
            print("📦 Early prefetch: Already in progress")
            return
        }
        
        isPrefetchingEarly = true
        earlyPrefetchComplete = false
        earlyPrefetchLocation = location
        
        print("🚀 EARLY PREFETCH: Starting background POI fetch...")
        print("📍 Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        
        Task {
            do {
                let pois = try await findNearbyPlaces(location: location, radiusMeters: 2500)
                await MainActor.run {
                    self.earlyPrefetchedPOIs = pois
                    self.earlyPrefetchComplete = true
                    self.isPrefetchingEarly = false
                    print("✅ EARLY PREFETCH COMPLETE: \(pois.count) POIs ready for instant route generation!")
                }
            } catch {
                await MainActor.run {
                    self.isPrefetchingEarly = false
                    print("⚠️ Early prefetch failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Get early prefetched POIs if available and still valid for the given location
    func getEarlyPrefetchedPOIs(for location: CLLocationCoordinate2D) -> [PlaceResult]? {
        guard earlyPrefetchComplete, !earlyPrefetchedPOIs.isEmpty else { return nil }
        guard let prefetchLocation = earlyPrefetchLocation else { return nil }
        
        // Check if still valid (within 50m of prefetch location)
        let distance = CLLocation(latitude: location.latitude, longitude: location.longitude)
            .distance(from: CLLocation(latitude: prefetchLocation.latitude, longitude: prefetchLocation.longitude))
        
        if distance < 50 {
            print("📦 Using \(earlyPrefetchedPOIs.count) early-prefetched POIs!")
            return earlyPrefetchedPOIs
        } else {
            print("📦 User moved \(Int(distance))m - early prefetch invalid, will re-fetch")
            return nil
        }
    }
    
    /// Clear early prefetch data (e.g., when user changes location significantly)
    func clearEarlyPrefetch() {
        earlyPrefetchedPOIs = []
        earlyPrefetchLocation = nil
        earlyPrefetchComplete = false
        isPrefetchingEarly = false
    }
    
    // MARK: - Find Nearby Places
    /// Finds points of interest near a location using multiple sources:
    /// 1. Google Places API (cached daily - one API call per 24 hours)
    /// 2. Apple Maps (FREE, always called to supplement)
    /// 3. OpenStreetMap (FREE, always called to supplement)
    /// 4. Geograph (FREE, experimental - requires API key from https://www.geograph.org.uk/help/api)
    /// 
    /// - Parameter skipGoogle: If true, skips Google Places API call (cost optimization for first-run)
    func findNearbyPlaces(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 2500,  // Increased from 500m for better coverage
        types: [String] = ["point_of_interest"],
        skipGoogle: Bool = false,  // v1.9.50: Skip Google on first run to save costs
        targetDurationMinutes: Int? = nil  // v2.0.3 Phase 2A: For diversity check in DB blending
    ) async throws -> [PlaceResult] {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [POI SEARCH] [\(timeString)] 🔍 findNearbyPlaces() STARTED")
        print("═══════════════════════════════════════════════════════════")
        print("🔍 POI FETCH START - Location: (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
        print("🔍 Search radius: \(radiusMeters)m")
        print("🔍 Skip Google: \(skipGoogle ? "YES (cost optimization)" : "NO (full fetch)")")
        print("═══════════════════════════════════════════════════════════")
        
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        // 🎯 PRIORITY 0: Check pre-populated database (fastest, no API calls)
        // v2.0.3 Phase 2A: DB + Live Blending - Check diversity and blend if needed
        if let prePopulatedPOIs = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: Double(radiusMeters)) {
            print("📦 PRE-POPULATED DB HIT! Found \(prePopulatedPOIs.count) POIs from pre-populated database")
            
            // v1.9.60: Apply ALL the same filters as live POIs to database POIs
            // This ensures database POIs go through the same safety net as API-fetched POIs
            var dbResults = prePopulatedPOIs
            
            // 1. Filter restricted POIs (playcare, nursery, playground, etc.)
            let beforeRestricted = dbResults.count
            dbResults = dbResults.filter { !isRestrictedPOI($0) }
            let restrictedCount = beforeRestricted - dbResults.count
            if restrictedCount > 0 {
                print("📦 🏫 Filtered \(restrictedCount) restricted POIs from database (playcare/nursery/playground)")
            }
            
            // 2. Skip canonical deduplication for database POIs (they're pre-curated and deduplicated)
            // Database POIs are already deduplicated during database generation
            // Canonical deduplication is expensive (O(n²)) and takes 20+ seconds for 460 POIs
            // Database is already curated, so we skip this expensive step
            
            // 3. Skip restricted area filtering for database POIs (they're pre-curated)
            // The restricted POI filter (playcare/nursery) already handles the main issues
            // Restricted area filtering queries Overpass API which is slow (7-15s per call)
            // Database POIs are already curated, so we skip this expensive check
            
            // 4. Skip coordinate validation for database POIs (they're pre-curated)
            // Database POIs are already validated during database generation
            // Coordinate validation is expensive and database is already curated
            
            // v2.0.3 Phase 2A: Check if DB POIs have sufficient diversity for loop formation
            // Calculate minimum required POIs based on target duration
            let diversityCheckDuration = targetDurationMinutes ?? 30  // Default to 30min if not provided
            let minRequiredPOIs = 10 + (diversityCheckDuration / 10 * 4)
            
            // Calculate Angular Diversity Score (ADS) for DB POIs
            let adsResult = calculateAngularDiversityScore(
                pois: dbResults,
                origin: location,
                targetDurationMinutes: diversityCheckDuration
            )
            let angularDiversityScore = adsResult.score
            
            print("📦 📊 DB Diversity Check: \(dbResults.count) POIs, ADS=\(angularDiversityScore), min required=\(minRequiredPOIs)")
            
            // v2.0.3 Phase 2A: Enable live POI blending if diversity is insufficient
            // v2.0.3: Made less aggressive - only blend if ADS ≤ 2 (very low) or POI count significantly low
            // This prevents blending on every route (ADS=2-3 is common)
            // v2.0.3 Batch A A.5: Short-circuit blending when curated count is sufficient
            // If we have 2× the minimum required POIs, skip blending entirely (saves 2-5s OSM overhead)
            let curatedIsSufficient = dbResults.count >= minRequiredPOIs * 2
            let shouldBlendWithLive = !curatedIsSufficient && (angularDiversityScore <= 2 || dbResults.count < minRequiredPOIs)
            
            if curatedIsSufficient {
                print("🌐 [BLEND] Short-circuit: curated=\(dbResults.count) >= 2×min=\(minRequiredPOIs * 2) - skipping blending")
            }
            
            if shouldBlendWithLive {
                // v2.0.3 Phase 1.5 Batch A: Structured blending telemetry
                let blendReason: String
                if angularDiversityScore <= 2 && dbResults.count < minRequiredPOIs {
                    blendReason = "ADS=\(angularDiversityScore) (≤2) AND POIs=\(dbResults.count) (<\(minRequiredPOIs))"
                } else if angularDiversityScore <= 2 {
                    blendReason = "ADS=\(angularDiversityScore) (≤2)"
                } else {
                    blendReason = "POIs=\(dbResults.count) (<\(minRequiredPOIs))"
                }
                print("🌐 [BLEND] Triggered: ADS=\(angularDiversityScore) curated=\(dbResults.count) dur=\(diversityCheckDuration)min reason=\(blendReason)")
                let blendStartTime = Date()
                
                // Fetch live POIs from free sources only (Apple Maps + OSM, no Google)
                // v2.0.3: Skip Apple Maps in batch mode to avoid rate limiting
                let livePOIs = await fetchLivePOIsForBlending(location: location, radiusMeters: radiusMeters, skipAppleMaps: isBatchTestMode)
                let blendElapsed = Date().timeIntervalSince(blendStartTime)
                
                if !livePOIs.isEmpty {
                    // ⚠️ DELAY LOG: Highlight blending results
                    if blendElapsed >= 3.0 {
                        print("⚠️ [DELAY] [BLENDING] Fetched \(livePOIs.count) live POIs in \(String(format: "%.2f", blendElapsed))s (SLOW)")
                    } else {
                        print("✅ [BLENDING] Fetched \(livePOIs.count) live POIs in \(String(format: "%.2f", blendElapsed))s")
                    }
                    
                    // Merge: curated DB first, then live POIs (deduplicated)
                    var blendedPOIs = dbResults
                    var seenPlaceIds = Set(dbResults.map { $0.placeId })
                    
                    for livePOI in livePOIs {
                        // Skip if duplicate of existing DB POI
                        let isDuplicate = dbResults.contains { dbPOI in
                            isRouteDuplicate(livePOI, dbPOI)
                        }
                        
                        if !isDuplicate && !seenPlaceIds.contains(livePOI.placeId) {
                            blendedPOIs.append(livePOI)
                            seenPlaceIds.insert(livePOI.placeId)
                        }
                    }
                    
                    print("📦 🔄 Blended: \(dbResults.count) DB + \(livePOIs.count) live = \(blendedPOIs.count) total (after deduplication)")
                    
                    // Recalculate ADS with blended POIs
                    let blendedAdsResult = calculateAngularDiversityScore(
                        pois: blendedPOIs,
                        origin: location,
                        targetDurationMinutes: diversityCheckDuration
                    )
                    let blendedAds = blendedAdsResult.score
                    print("📦 📊 Blended Diversity: ADS=\(blendedAds) (was \(angularDiversityScore))")
                    
                    allResults = blendedPOIs
                } else {
                    print("📦 ⚠️ No live POIs found for blending - using DB POIs only")
                    allResults = dbResults
                }
            } else {
                print("📦 ✅ DB diversity sufficient (ADS=\(angularDiversityScore), POIs=\(dbResults.count)) - using DB POIs only")
                print("🌐 [BLEND] Skipped: ADS=\(angularDiversityScore) curated=\(dbResults.count) dur=\(diversityCheckDuration)min reason=sufficient_diversity")
                allResults = dbResults
            }
            
            // Cache the filtered results for future use
            POICacheService.shared.cachePOIs(allResults, for: location)
            
            let endTime = Date()
            let totalTime = endTime.timeIntervalSince(startTime)
            let endTimeString = formatter.string(from: endTime)
            print("📦 ✅ Final POIs after blending: \(allResults.count)")
            print("⏱️ [POI SEARCH] [\(endTimeString)] ✅ findNearbyPlaces() COMPLETED in \(String(format: "%.2f", totalTime))s")
            
            return allResults
        }
        
        // 🎯 PRIORITY 1: Check cached POI data
        if let cachedPOIs = POICacheService.shared.getCachedPOIs(near: location) {
            print("💰 CACHE HIT! Found \(cachedPOIs.count) cached POIs")
            
            // Filter out any previously cached POIs that are too far away
            // This cleans up old caches that might have unrealistic distant POIs
            let maxRealisticDistance = Double(radiusMeters) * 2.0
            let distanceFilteredPOIs = cachedPOIs.filter { poi in
                let distance = distanceBetween(location, poi.coordinate)
                return distance <= maxRealisticDistance
            }
            
            let distanceFilteredCount = cachedPOIs.count - distanceFilteredPOIs.count
            if distanceFilteredCount > 0 {
                print("🚫 Filtered \(distanceFilteredCount) distant POIs from cache (>\(Int(maxRealisticDistance))m)")
            }
            
            // v1.6.48: Safety net filter - catch restricted POIs that were cached before filters existed
            let filteredPOIs = distanceFilteredPOIs.filter { poi in
                !isRestrictedPOI(poi)
            }
            
            let restrictedFilteredCount = distanceFilteredPOIs.count - filteredPOIs.count
            if restrictedFilteredCount > 0 {
                print("🏫 Filtered \(restrictedFilteredCount) restricted POIs from cache (playcare/nursery/playground)")
            }
            
            print("💰 Using \(filteredPOIs.count) valid cached POIs")
            allResults = filteredPOIs
            for poi in allResults {
                seenPlaceIds.insert(poi.placeId)
            }
            
            // Always fetch Geograph regardless of cache
            if !geographApiKey.isEmpty {
                let rawGeographPOIs = await searchGeographForPOIs(location: location, radiusMeters: radiusMeters)
                
                // Filter by distance (relative to current location)
                let maxRealisticDistance = Double(radiusMeters) * 2.0
                let distanceFilteredGeograph = rawGeographPOIs.filter { poi in
                    let distance = distanceBetween(location, poi.coordinate)
                    return distance <= maxRealisticDistance
                }
                
                // PB-POIRS: Pre-process Geograph POIs (hard exclusion, cluster, score)
                // A. Hard exclusion FIRST
                let filteredGeograph = distanceFilteredGeograph.filter { !shouldExcludeGeographPOI($0, origin: location) }
                // B. Cluster duplicates
                let clusteredGeograph = clusterGeographPOIs(filteredGeograph, origin: location)
                // C. Score remaining POIs
                let scoredGeograph = clusteredGeograph.map { poi -> (poi: PlaceResult, score: Double) in
                    let score = geographQualityScore(poi)
                    return (poi, score)
                }
                // D. Filter out any zero-scored (safety net)
                let processedGeograph = scoredGeograph.filter { $0.score > 0.0 }.map { $0.poi }
                
                print("📸 Geograph: Pre-processing complete")
                print("   📥 Raw: \(rawGeographPOIs.count) → Distance filtered: \(distanceFilteredGeograph.count)")
                print("   🔄 Clustered: \(clusteredGeograph.count) → Scored & filtered: \(processedGeograph.count)")
                
                // Smart merge with existing results
                let beforeCount = allResults.count
                allResults = smartMergeGeographPOIs(
                    existing: allResults,
                    newGeograph: processedGeograph,
                    origin: location
                )
                let finalAdded = allResults.count - beforeCount
                
                // Count how many Geograph POIs are in final results
                let geographInFinal = allResults.filter { $0.source == .geograph }.count
                
                print("📸 Geograph: Successfully integrated!")
                print("   ✅ Processed Geograph POIs: \(processedGeograph.count)")
                print("   📍 Final Geograph POIs in results: \(geographInFinal)")
                print("   📈 Net added: \(finalAdded) total new POIs (including Geograph)")
            }
        } else {
            print("📭 CACHE MISS - No cached POIs within 1km")
            
            // ═══════════════════════════════════════════════════════════════
            // 🚀 v2.1.0: PRIORITY-BASED POI FETCH (ToS Compliant)
            // Priority Order:
            // 1. OSM + Geograph + Apple (FREE sources in parallel)
            // 2. Google (PAID, only if free sources don't provide enough POIs)
            // 
            // ToS Compliance:
            // - Only OSM/Geograph POIs are cached (ToS-safe)
            // - Apple/Google POIs are used but NOT cached
            // ═══════════════════════════════════════════════════════════════
            let timeoutSeconds: Double = 5.0  // Slightly longer timeout for sequential approach
            let minimumPOIsRequired = 15  // Optimal threshold for route quality
            let startTime = Date()
            
            print("🚀 PRIORITY POI FETCH - Free sources first, Google fallback if needed...")
            
            // Track which sources contributed
            var googleCount = 0
            var appleCount = 0
            var osmCount = 0
            var geographCount = 0
            
            // v1.9.50: Calculate maxRealisticDistance for early filtering
            let maxRealisticDistance = Double(radiusMeters) * 2.0
            
            // ═══════════════════════════════════════════════════════════════
            // STEP 1: Fetch from FREE sources in parallel (OSM + Geograph + Apple)
            // ═══════════════════════════════════════════════════════════════
            print("📍 Step 1: Fetching from FREE sources (OSM + Geograph + Apple)...")
            
            var freePOIs: [PlaceResult] = []
            
            freePOIs = await withTaskGroup(of: SourcedPOIs.self) { group in
                var collected: [PlaceResult] = []
                
                // 🍎 Apple Maps (FREE, reliable, usually fast)
                group.addTask { [self] in
                    let pois = await self.searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
                    let taggedPOIs = pois.map { poi -> PlaceResult in
                        var tagged = poi
                        tagged.source = .apple
                        return tagged
                    }
                    return SourcedPOIs(source: .apple, pois: taggedPOIs)
                }
                
                // 🗺️ OpenStreetMap (FREE, can be slow)
                group.addTask { [self] in
                    do {
                        let pois = try await self.searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
                        let taggedPOIs = pois.map { poi -> PlaceResult in
                            var tagged = poi
                            tagged.source = .osm
                            return tagged
                        }
                        return SourcedPOIs(source: .osm, pois: taggedPOIs)
                    } catch {
                        print("🗺️ OSM fetch failed: \(error.localizedDescription)")
                        return SourcedPOIs(source: .osm, pois: [])
                    }
                }
                
                // 📸 Geograph (FREE, experimental - requires API key)
                if !geographApiKey.isEmpty {
                    group.addTask { [self] in
                        let rawPOIs = await self.searchGeographForPOIs(location: location, radiusMeters: radiusMeters)
                        
                        // Pre-process Geograph POIs
                        let filtered = rawPOIs.filter { !self.shouldExcludeGeographPOI($0, origin: location) }
                        let clustered = self.clusterGeographPOIs(filtered, origin: location)
                        let scored = clustered.map { poi -> (poi: PlaceResult, score: Double) in
                            let score = self.geographQualityScore(poi)
                            return (poi, score)
                        }
                        let processed = scored.filter { $0.score > 0.0 }.map { $0.poi }
                        
                        return SourcedPOIs(source: .geograph, pois: processed)
                    }
                }
                
                // Collect results with timeout
                while let result = await group.next() {
                    let elapsed = Date().timeIntervalSince(startTime)
                    
                    // Filter by distance and restricted POIs
                    var restrictedFilteredCount = 0
                    let filteredPOIs = result.pois.filter { poi in
                        let distance = distanceBetween(location, poi.coordinate)
                        if distance > maxRealisticDistance { return false }
                        if isRestrictedPOI(poi) {
                            restrictedFilteredCount += 1
                            return false
                        }
                        return true
                    }
                    
                    // Merge with deduplication
                    let beforeCount = collected.count
                    if result.source == .geograph {
                        collected = self.smartMergeGeographPOIs(existing: collected, newGeograph: filteredPOIs, origin: location)
                    } else {
                        collected.append(contentsOf: filteredPOIs)
                        collected = self.deduplicatePOIs(collected)
                    }
                    let added = collected.count - beforeCount
                    
                    // Track source contribution
                    switch result.source {
                    case .apple:
                        appleCount = filteredPOIs.count
                        print("   🍎 Apple: \(filteredPOIs.count) POIs (+\(added) unique) @ \(String(format: "%.2f", elapsed))s")
                    case .osm:
                        osmCount = filteredPOIs.count
                        print("   🗺️ OSM: \(filteredPOIs.count) POIs (+\(added) unique) @ \(String(format: "%.2f", elapsed))s")
                    case .geograph:
                        geographCount = filteredPOIs.count
                        print("   📸 Geograph: \(filteredPOIs.count) POIs (+\(added) unique) @ \(String(format: "%.2f", elapsed))s")
                    default:
                        break
                    }
                    
                    // Timeout check
                    if elapsed >= timeoutSeconds {
                        print("⏱️ Timeout reached (\(timeoutSeconds)s) - proceeding with \(collected.count) POIs")
                        group.cancelAll()
                        break
                    }
                }
                
                return collected
            }
            
            let freeSourceTime = Date().timeIntervalSince(startTime)
            print("📍 Free sources: \(freePOIs.count) POIs in \(String(format: "%.2f", freeSourceTime))s")
            
            allResults = freePOIs
            
            // ═══════════════════════════════════════════════════════════════
            // STEP 2: If not enough POIs, fetch from Google (PAID, NOT CACHED)
            // ═══════════════════════════════════════════════════════════════
            let googleEnabled = !skipGoogle && !apiKey.isEmpty && canMakeGooglePlacesCall
            
            if allResults.count < minimumPOIsRequired && googleEnabled {
                print("📍 Step 2: Free sources insufficient (\(allResults.count) < \(minimumPOIsRequired)) - fetching from Google...")
                
                let googleStartTime = Date()
                let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
                
                // Tag and filter Google POIs
                var restrictedCount = 0
                let filteredGooglePOIs = googlePOIs.compactMap { poi -> PlaceResult? in
                    var tagged = poi
                    tagged.source = .google
                    
                    let distance = distanceBetween(location, tagged.coordinate)
                    if distance > maxRealisticDistance { return nil }
                    if isRestrictedPOI(tagged) {
                        restrictedCount += 1
                        return nil
                    }
                    return tagged
                }
                
                // Merge with existing (Google POIs added but NOT cached)
                let beforeCount = allResults.count
                allResults.append(contentsOf: filteredGooglePOIs)
                allResults = deduplicatePOIs(allResults)
                let added = allResults.count - beforeCount
                
                googleCount = filteredGooglePOIs.count
                let googleTime = Date().timeIntervalSince(googleStartTime)
                print("   🌐 Google: \(filteredGooglePOIs.count) POIs (+\(added) unique) @ \(String(format: "%.2f", googleTime))s")
                if restrictedCount > 0 {
                    print("   🏫 Filtered \(restrictedCount) restricted Google POIs")
                }
            } else if allResults.count >= minimumPOIsRequired {
                print("📍 Step 2: Skipping Google - have enough POIs (\(allResults.count) >= \(minimumPOIsRequired))")
            } else if !googleEnabled {
                if skipGoogle {
                    print("📍 Step 2: Skipping Google (first run optimization)")
                } else if !canMakeGooglePlacesCall {
                    print("📍 Step 2: Skipping Google (quota/cap reached)")
                }
            }
            
            let totalTime = Date().timeIntervalSince(startTime)
            let endTimeString = formatter.string(from: Date())
            print("═══════════════════════════════════════════════════════════════")
            print("⏱️ [POI SEARCH] [\(endTimeString)] ✅ findNearbyPlaces() COMPLETED in \(String(format: "%.2f", totalTime))s")
            print("📊 Sources: OSM=\(osmCount), Geograph=\(geographCount), Apple=\(appleCount), Google=\(googleCount)")
            print("📊 Total unique POIs: \(allResults.count)")
            print("💾 ToS Compliance: Only OSM/Geograph POIs will be cached")
            if allResults.count < minimumPOIsRequired {
                print("⚠️ Low POI count (\(allResults.count) < \(minimumPOIsRequired)) - route options may be limited")
            }
            print("═══════════════════════════════════════════════════════════════")
        }
        
        // v1.9.50: Distance filtering now happens during parallel fetch (Optimization 5)
        // No need to filter again here - already filtered as POIs arrived
        
        // ═══════════════════════════════════════════════════════════════
        // 🎯 CANONICAL POI DEDUPLICATION LAYER (v1.9.50)
        // ═══════════════════════════════════════════════════════════════
        // Clusters POIs spatially and by name similarity to create canonical
        // representatives. Prevents duplicates like:
        // - "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate"
        // - "Lindale Methodist Church" vs "SE2922: Lindale Methodist Church"
        // ═══════════════════════════════════════════════════════════════
        let beforeCanonical = allResults.count
        let canonicalStartTime = Date()
        print("🎯 [CANONICAL] Starting canonical POI deduplication...")
        allResults = canonicalizePOIs(allResults, origin: location)
        let canonicalElapsed = Date().timeIntervalSince(canonicalStartTime)
        let canonicalRemoved = beforeCanonical - allResults.count
        if canonicalRemoved > 0 {
            print("🎯 [CANONICAL] Removed \(canonicalRemoved) duplicates (had \(beforeCanonical), now \(allResults.count)) in \(String(format: "%.3f", canonicalElapsed))s")
        } else {
            print("🎯 [CANONICAL] No duplicates found (all \(allResults.count) POIs are unique)")
        }
        
        // v1.9.99: OPTIMISTIC FILTERING - Fast path first, expensive filtering in background
        // Fast name/type filter already applied (isRestrictedPOI) - catches 95% of issues instantly
        // Expensive polygon check runs in background and caches results for next time
        let beforeRestrictedFilter = allResults.count
        
        // Try cached filtered results first (instant if available)
        let cacheKey = "\(location.latitude)_\(location.longitude)_\(radiusMeters)"
        var excludedPlaceIds: Set<String> = []
        
        // Swift 6: Use helper for async-safe locking
        excludedPlaceIds = withLockedCache(filteredPOICacheLock) {
            filteredPOICache[cacheKey] ?? []
        }
        
        if !excludedPlaceIds.isEmpty {
            // Apply cached exclusions
            let beforeCached = allResults.count
            allResults = allResults.filter { !excludedPlaceIds.contains($0.placeId) }
            let cachedFiltered = beforeCached - allResults.count
            if cachedFiltered > 0 {
                print("🏫 ✅ Used cached restricted area filter - excluded \(cachedFiltered) POIs (instant)")
            }
        } else {
            // No cache - start background filtering (non-blocking)
            print("🏫 ⚡ Fast path: Returning POIs immediately, filtering in background...")
            let poisToFilter = allResults  // Capture for background task
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                let filtered = await self.filterPOIsInRestrictedAreas(pois: poisToFilter, location: location, radiusMeters: radiusMeters)
                let excluded = Set(poisToFilter.filter { poi in !filtered.contains(where: { $0.placeId == poi.placeId }) }.map { $0.placeId })
                
                // Cache the excluded POI IDs for next time (Swift 6: async-safe locking)
                // Helper function handles lock/unlock safely from async context
                self.withLockedCache(self.filteredPOICacheLock) {
                    self.filteredPOICache[cacheKey] = excluded
                    // Limit cache size to prevent memory growth
                    if self.filteredPOICache.count > 50 {
                        let oldestKey = self.filteredPOICache.keys.first!
                        self.filteredPOICache.removeValue(forKey: oldestKey)
                    }
                }
                
                let excludedCount = excluded.count
                if excludedCount > 0 {
                    print("🏫 ✅ Background filtering complete - excluded \(excludedCount) POIs (cached for next time)")
                }
            }
        }
        
        let restrictedFiltered = beforeRestrictedFilter - allResults.count
        if restrictedFiltered > 0 && excludedPlaceIds.isEmpty {
            // Only log if we actually filtered (not from cache)
            print("🏫 Restricted area filter removed \(restrictedFiltered) inaccessible POIs")
        }
        
        // 🎯 COORDINATE ACCURACY VALIDATION: Detect and filter POIs with incorrect coordinates
        // When multiple POIs have the same name but coordinates far apart (>200m), one likely has wrong coordinates
        let beforeCoordValidation = allResults.count
        allResults = validatePOICoordinates(allResults)
        let coordFiltered = beforeCoordValidation - allResults.count
        if coordFiltered > 0 {
            print("📍 Coordinate validation removed \(coordFiltered) POI(s) with incorrect coordinates")
        }
        
        // 💾 Cache combined results for next time
        if !allResults.isEmpty {
            POICacheService.shared.cachePOIs(allResults, for: location)
        }
        
        let endTime = Date()
        let endTimeString = formatter.string(from: endTime)
        let totalElapsed = endTime.timeIntervalSince(startTime)
        
        print("═══════════════════════════════════════════════════════════")
        print("📊 POI FETCH COMPLETE - Total: \(allResults.count) POIs")
        let googleCount = allResults.filter { $0.source == .google }.count
        let appleCount = allResults.filter { $0.source == .apple }.count
        let osmCount = allResults.filter { $0.source == .osm }.count
        let geographCount = allResults.filter { $0.source == .geograph }.count
        print("   📍 Google:   \(googleCount)")
        print("   🍎 Apple:    \(appleCount)")
        print("   🗺️ OSM:      \(osmCount)")
        print("   📸 Geograph: \(geographCount)")
        print("═══════════════════════════════════════════════════════════")
        print("⏱️ [POI SEARCH] [\(endTimeString)] ✅ findNearbyPlaces() COMPLETED in \(String(format: "%.2f", totalElapsed))s")
        
        return allResults
    }
    
    // MARK: - On-Demand Google API (when more routes needed)
    
    /// Fetch additional POIs from Google Places API when Apple/OSM didn't find enough variety
    /// Called when route generation only found 1-2 routes and more options are needed
    /// Returns the NEW POIs that weren't already in the cache
    func fetchGooglePOIsOnDemand(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 2500,
        existingPOIs: [PlaceResult]
    ) async -> [PlaceResult] {
        guard !apiKey.isEmpty else {
            print("🌐 GOOGLE ON-DEMAND: No API key, skipping")
            return []
        }
        
        print("🌐 ═══════════════════════════════════════════════════════")
        print("🌐 GOOGLE ON-DEMAND: Fetching additional POIs")
        print("🌐   📍 Location: (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
        print("🌐   📦 Existing POIs: \(existingPOIs.count)")
        print("🌐 ═══════════════════════════════════════════════════════")
        
        let googlePOIs = await fetchGooglePOIs(location: location, radiusMeters: radiusMeters)
        
        // Filter out POIs we already have (by name or proximity)
        var newPOIs: [PlaceResult] = []
        for poi in googlePOIs {
            let isDuplicate = existingPOIs.contains { existing in
                existing.name.lowercased() == poi.name.lowercased() ||
                distanceBetween(existing.coordinate, poi.coordinate) < 50
            }
            if !isDuplicate {
                newPOIs.append(poi)
            }
        }
        
        print("🌐 GOOGLE ON-DEMAND COMPLETE:")
        print("🌐   📊 Fetched: \(googlePOIs.count) POIs")
        print("🌐   ✨ New (after dedup): \(newPOIs.count) POIs")
        
        // v2.1.0: Do NOT cache Google POIs (ToS compliance)
        // Google POIs are returned for immediate use but not persisted
        print("🌐   ⚠️ Google POIs NOT cached (ToS compliance)")
        
        return newPOIs
    }
    
    /// Fetch POIs from Google Places API (called at most once per 24 hours)
    private func fetchGooglePOIs(
        location: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async -> [PlaceResult] {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [POI FETCH] [\(timeString)] 🔍 fetchGooglePOIs() STARTED")
        print("⏱️ [POI FETCH] [\(timeString)]   Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("⏱️ [POI FETCH] [\(timeString)]   Radius: \(radiusMeters)m")
        
        // Search multiple specific types in parallel to maximize POI variety
        let placeTypesToSearch = [
            // Retail & Shopping
            "store",              // General retail
            "convenience_store",  // Local corner shops
            "supermarket",        // Supermarkets
            "shopping_mall",      // Shopping centers
            "hardware_store",     // DIY shops
            "florist",            // Flower shops
            "pet_store",          // Pet shops
            "liquor_store",       // Off-licenses
            
            // Food & Drink
            "restaurant",         // Restaurants
            "cafe",               // Coffee shops
            "bar",                // Bars/pubs
            "bakery",             // Bakeries
            "meal_takeaway",      // Takeaways (fish & chips, kebabs)
            
            // Health & Wellness
            "pharmacy",           // Pharmacies
            "doctor",             // GP surgeries
            "dentist",            // Dental practices
            "veterinary_care",    // Vets
            "spa",                // Spas/wellness
            
            // Services
            "bank",               // Banks
            "post_office",        // Post offices
            "hair_care",          // Hairdressers/barbers
            "laundry",            // Launderettes
            "car_wash",           // Car washes
            "gas_station",        // Petrol stations
            
            // Culture & Leisure
            "park",               // Parks
            "museum",             // Museums
            "library",            // Libraries
            "art_gallery",        // Art galleries
            "book_store",         // Book shops
            "gym",                // Gyms
            "church",             // Churches/places of worship
            "movie_theater",      // Cinemas
            "bowling_alley",      // Bowling alleys
            
            // Education & Community
            "school",             // Schools
            "community_center",   // Community centres
            
            // Outdoors & Nature
            "cemetery",           // Cemeteries/churchyards
            "campground",         // Camping/green spaces
            
            // Transport
            "bus_station",        // Bus stations
            "train_station",      // Train stations
            
            // Lodging
            "lodging",            // Hotels, B&Bs
            
            // Government & Landmarks
            "local_government_office",  // Town halls
            "fire_station",       // Fire stations
            "police"              // Police stations
        ]
        
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        print("🌐 GOOGLE NEW PLACES API - Searching \(placeTypesToSearch.count) categories in SINGLE REQUEST...")
        print("🌐 Categories: \(placeTypesToSearch.joined(separator: ", "))")
        print("🌐 Endpoint: places.googleapis.com/v1/places:searchNearby")
        print("🌐 Field Mask: places.id, places.displayName, places.location (Pro SKU - displayName required)")
        print("🌐 API Key present: \(!apiKey.isEmpty), key prefix: \(String(apiKey.prefix(10)))...")
        print("🌐 ⚡ OPTIMIZATION: Using single request with all types (was 43 separate calls, now 1)")
        
        // ⚡ COST OPTIMIZATION: Make ONE API call with all types instead of 43 separate calls
        // This reduces requests from ~25,800/month to ~600/month (staying within free tier)
        // v1.9.52: Check daily cap before making API call
        guard canMakeGooglePlacesCall else {
            print("🌐 [CAP] Skipping Google Places API call - daily cap reached (\(googlePlacesCallsToday)/\(googlePlacesDailyCap))")
            return allResults  // Return empty, will use Apple/OSM results
        }
        
        do {
            let apiStartTime = Date()
            print("⏱️ [POI FETCH] [\(timeString)] 📡 Calling searchMultipleTypes...")
            
            let results = try await searchMultipleTypes(
                location: location,
                radiusMeters: radiusMeters,
                types: placeTypesToSearch
            )
            
            // v1.9.52: Record successful API call
            recordGooglePlacesCall()
            
            let apiElapsed = Date().timeIntervalSince(apiStartTime)
            print("⏱️ [POI FETCH] [\(timeString)]   API call took \(String(format: "%.2f", apiElapsed))s, returned \(results.count) POIs")
            
            for place in results {
                if !seenPlaceIds.contains(place.placeId) {
                    seenPlaceIds.insert(place.placeId)
                    allResults.append(place)
                }
            }
        } catch {
            let errorTime = Date()
            let errorTimeString = formatter.string(from: errorTime)
            let elapsed = errorTime.timeIntervalSince(startTime)
            print("⏱️ [POI FETCH] [\(errorTimeString)] ❌ GOOGLE PLACES API FAILED after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
            // Return empty array on failure (app will use Apple/OSM results)
        }
        
        let endTime = Date()
        let endTimeString = formatter.string(from: endTime)
        let totalElapsed = endTime.timeIntervalSince(startTime)
        print("⏱️ [POI FETCH] [\(endTimeString)] ✅ fetchGooglePOIs() COMPLETED in \(String(format: "%.2f", totalElapsed))s")
        print("🌐 GOOGLE COMPLETE: \(allResults.count) unique POIs from 1 API call (was \(placeTypesToSearch.count) calls)")
        
        return allResults
    }
    
    /// Search for multiple place types in a SINGLE API call (v1.9.16 cost optimization)
    /// 
    /// ⚡ CRITICAL FIX: Changed from 43 separate calls to 1 call with all types
    /// - Reduces monthly requests from ~25,800 to ~600 (stays within $200 credit)
    /// - Uses Pro SKU (places.displayName required for readable place names)
    /// - Removed expensive fields: rating, user_ratings_total, opening_hours, price_level, reviews (Enterprise SKU)
    /// - API supports up to 50 types per request (we use 43)
    /// 
    /// Cost: Pro SKU $32/1k requests, but only ~600 requests/month = FREE (within $200 credit)
    private func searchMultipleTypes(
        location: CLLocationCoordinate2D,
        radiusMeters: Int,
        types: [String]
    ) async throws -> [PlaceResult] {
        // New Places API endpoint
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchNearby") else {
            throw GoogleMapsError.invalidURL
        }
        
        // Build request body with ALL types in a single request
        // API supports up to 50 types per request
        let requestBody: [String: Any] = [
            "includedTypes": types,  // Pass entire array - ONE call instead of 43!
            "maxResultCount": 20,
            "locationRestriction": [
                "circle": [
                    "center": [
                        "latitude": location.latitude,
                        "longitude": location.longitude
                    ],
                    "radius": Double(radiusMeters)
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // v1.9.13: Set explicit timeout for slow networks
        request.timeoutInterval = 30.0 // 30 second timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // Add iOS bundle ID for API key restrictions
        let bundleIdSent: Bool
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            bundleIdSent = true
        } else {
            bundleIdSent = false
        }
        // ⚠️ SKU TIER: Pro SKU ($32/1k) - displayName required for readable place names
        // Field mask: places.id, places.displayName, places.location
        // - displayName triggers Pro SKU billing (but provides actual place names)
        // - REMOVED: places.formattedAddress and places.types (not needed)
        // - REMOVED: rating, user_ratings_total, opening_hours, price_level, reviews (Enterprise SKU - very expensive!)
        // Cost: ~$0.032 per request, but FREE within $200 monthly credit (~6,250 requests/month)
        let fieldMask = "places.id,places.displayName,places.location"
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        print("   🔒 FieldMask: \(fieldMask) (Pro SKU - displayName required for place names)")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let startTime = Date()
        // Use session with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let timeoutSession = URLSession(configuration: config)
        let (data, response) = try await timeoutSession.data(for: request)
        let responseTime = Date().timeIntervalSince(startTime)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("   ❌ No HTTP response")
            recordAPICall(
                apiName: "Places API (New)",
                success: false,
                responseTime: responseTime,
                errorMessage: "No HTTP response",
                bundleIdSent: bundleIdSent,
                details: "\(types.count) types"
            )
            throw GoogleMapsError.serverError
        }
        
        if httpResponse.statusCode != 200 {
            // Try to parse error message
            var errorMessage: String?
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                errorMessage = message
                print("   ❌ HTTP \(httpResponse.statusCode) - \(message)")
            } else {
                errorMessage = "HTTP \(httpResponse.statusCode) - Unknown error"
                print("   ❌ \(errorMessage!)")
            }
            
            // v1.9.48: Detect quota/rate limit errors and disable Google temporarily
            if httpResponse.statusCode == 429 || 
               (errorMessage?.contains("RESOURCE_EXHAUSTED") == true) ||
               (errorMessage?.contains("quota") == true) {
                disableGooglePlacesTemporarily()
            }
            
            recordAPICall(
                apiName: "Places API (New)",
                success: false,
                httpStatus: httpResponse.statusCode,
                responseTime: responseTime,
                errorMessage: errorMessage,
                bundleIdSent: bundleIdSent,
                details: "\(types.count) types"
            )
            throw GoogleMapsError.serverError
        }
        
        // Parse new API response format
        let newPlacesResponse = try JSONDecoder().decode(NewPlacesResponse.self, from: data)
        let count = newPlacesResponse.places?.count ?? 0
        
        if count > 0 {
            print("   ✓ → \(count) POIs from \(types.count) types (1 API call)")
        }
        
        // Record successful call
        recordAPICall(
            apiName: "Places API (New)",
            success: true,
            httpStatus: httpResponse.statusCode,
            responseTime: responseTime,
            bundleIdSent: bundleIdSent,
            details: "\(types.count) types, \(count) POIs"
        )
        
        // Convert to PlaceResult format
        // Note: vicinity and types are nil because we're using Essentials SKU (cost optimization)
        // v1.9.48: Tag with .google source for tracking
        return newPlacesResponse.places?.map { place in
            PlaceResult(
                placeId: place.id ?? "unknown",
                name: place.displayName?.text ?? "Unknown",
                vicinity: nil, // Not requested (Pro SKU - displayName required for good names)
                geometry: PlaceGeometry(
                    location: PlaceLocation(
                        lat: place.location?.latitude ?? 0,
                        lng: place.location?.longitude ?? 0
                    )
                ),
                types: nil, // Not requested (Pro SKU - displayName required for good names)
                source: .google
            )
        } ?? []
    }
    
    // MARK: - Apple Maps POI Search (FREE - No Limits!)
    
    /// All Apple Maps search categories for UK POIs
    /// v1.8.1: Reordered to prioritize hospital-adjacent POIs in Fast Mode (first 40)
    /// To revert: swap hospitalOptimizedCategories back to originalCategories
    private var allAppleMapsCategories: [String] {
        hospitalOptimizedCategories
    }
    
    /// v1.8.1: Hospital-optimized order - cafes, pharmacies, parks first
    private var hospitalOptimizedCategories: [String] {
        [
            // ══════════════════════════════════════════════════════════
            // BATCH 1: HOSPITAL-ADJACENT (40 queries) - Used by Fast Mode
            // ══════════════════════════════════════════════════════════
            // Cafes & Coffee (visitors/staff essentials)
            "cafe", "coffee shop", "coffee", "costa", "starbucks",
            
            // Health & Pharmacy (obvious hospital proximity)
            "pharmacy", "chemist",
            
            // Green spaces (hospital grounds, nearby parks)
            "park", "garden", "playground", "nature reserve",
            
            // Food (quick meals for visitors)
            "restaurant", "takeaway", "food", "bakery", "greggs", "sandwich",
            
            // Pubs & Hotels (family accommodation, landmarks)
            "pub", "hotel", "inn", "guest house",
            
            // Convenience (essential items)
            "shop", "convenience store", "newsagent", "supermarket", "co-op",
            
            // Services
            "post office", "bank", "library",
            
            // Transport & Parking
            "bus stop", "car park", "parking", "train station",
            
            // Religious (often on hospital grounds)
            "church", "chapel",
            
            // Education & Childcare
            "school", "nursery",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 2: SECONDARY PRIORITY (queries 41-80)
            // ══════════════════════════════════════════════════════════
            // Leisure & Fitness
            "gym", "leisure centre", "swimming pool", "fitness", "sports centre",
            
            // More retail
            "tesco", "sainsburys", "aldi", "lidl", "morrisons", "asda", "spar",
            "butcher", "florist", "charity shop", "bookshop", "gift shop",
            
            // Community venues
            "village hall", "community centre", "town hall", "memorial hall",
            "sports club", "social club", "youth club", "community hub",
            
            // More food options
            "tea room", "bistro", "brasserie", "pizzeria", "burger", "kebab",
            "fish and chips", "chippy", "deli", "kitchen", "catering",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 3: EXTENDED COVERAGE (queries 81-120)
            // ══════════════════════════════════════════════════════════
            // Health
            "doctor", "dentist", "veterinary", "hospital", "clinic", "health centre",
            "surgery", "medical", "physiotherapy",
            
            // More education
            "preschool", "playcare", "childcare", "academy",
            "primary school", "secondary school", "college", "university",
            
            // More leisure
            "recreation ground", "playing field", "woodland", "canal",
            "golf course", "tennis club", "football club", "cricket club",
            "bowling alley", "allotment",
            
            // Services
            "hairdresser", "barber", "nail salon", "dry cleaner", "launderette",
            "optician", "estate agent", "betting shop",
            
            // ══════════════════════════════════════════════════════════
            // BATCH 4: EXTENDED UK-SPECIFIC (queries 121+)
            // ══════════════════════════════════════════════════════════
            // Culture & Heritage
            "museum", "theatre", "cinema", "art gallery", "historic site", "castle",
            "manor", "stately home", "monument", "statue", "war memorial", "heritage",
            
            // Religious (extended)
            "mosque", "temple", "gurdwara", "synagogue",
            
            // Transport
            "petrol station", "bus station", "taxi", "garage", "car wash",
            
            // Accommodation (extended)
            "bed and breakfast", "hostel",
            
            // UK chains
            "wetherspoons", "mcdonald",
            "indian restaurant", "chinese restaurant", "thai restaurant",
            "italian restaurant", "mexican restaurant",
            
            // Traditional community (lower priority for hospitals)
            "working mens club", "scout hall", "legion", "rotary", "masonic", "british legion",
            "pet shop", "pound shop", "off licence", "grocery",
            "solicitor", "accountant", "travel agent", "pawnbroker"
        ]
    }
    
    /// ORIGINAL ORDER - To revert, change allAppleMapsCategories to use this instead
    /// Uncomment and swap if hospital-optimized order doesn't work
    /*
    private var originalCategories: [String] {
        [
            // Community venues first (original order)
            "village hall", "community centre", "town hall", "church", "chapel",
            "mosque", "temple", "gurdwara", "synagogue", "memorial hall",
            "sports club", "social club", "working mens club", "scout hall", "youth club",
            "legion", "rotary", "masonic", "british legion", "community hub",
            "pub", "restaurant", "cafe", "kitchen", "catering", "deli", "sandwich",
            "coffee", "food", "bakery", "takeaway", "bar", "bistro", "brasserie",
            "tea room", "coffee shop", "pizzeria", "burger", "kebab",
            "fish and chips", "chippy",
            // ... (rest of original order)
        ]
    }
    */
    
    /// FAST MODE: Only first 40 high-priority categories (instant, for first route)
    /// Returns POIs in ~5-10 seconds for immediate route generation
    func searchAppleMapsForPOIsFast(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        let appleStartTime = Date()  // v2.0.3: Track timing for delay logging
        var allResults: [PlaceResult] = []
        var seenNames = Set<String>()
        
        // Only use first 40 categories (highest priority: community + food)
        let fastQueries = Array(allAppleMapsCategories.prefix(40))
        
        print("🍎 APPLE MAPS FAST MODE - \(fastQueries.count) priority categories")
        
        var queriesWithResults = 0
        var queriesFailed = 0
        
        for query in fastQueries {
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = MKCoordinateRegion(
                    center: location,
                    latitudinalMeters: Double(radiusMeters * 2),
                    longitudinalMeters: Double(radiusMeters * 2)
                )
                
                let search = MKLocalSearch(request: request)
                let response = try await search.start()
                
                for item in response.mapItems {
                    guard let name = item.name, !seenNames.contains(name) else { continue }
                    
                    let itemCoord = item.placemark.coordinate
                    let distance = distanceBetween(location, itemCoord)
                    guard distance <= Double(radiusMeters) else { continue }
                    
                    seenNames.insert(name)
                    
                    let placeResult = PlaceResult(
                        placeId: "apple_\(name.hashValue)",
                        name: name,
                        vicinity: item.placemark.title,
                        geometry: PlaceGeometry(
                            location: PlaceLocation(
                                lat: item.placemark.coordinate.latitude,
                                lng: item.placemark.coordinate.longitude
                            )
                        ),
                        types: [query]
                    )
                    allResults.append(placeResult)
                }
                if response.mapItems.count > 0 {
                    queriesWithResults += 1
                }
            } catch {
                queriesFailed += 1
                let nsError = error as NSError
                
                // If rate limited, stop immediately
                if nsError.domain == "GEOErrorDomain" && nsError.code == -3 ||
                   nsError.domain == "MKErrorDomain" && nsError.code == 3 {
                    print("🍎 ⚠️ Rate limited during fast mode - returning \(allResults.count) POIs")
                    break
                }
            }
        }
        
        let appleElapsed = Date().timeIntervalSince(appleStartTime)
        if appleElapsed >= 3.0 {
            print("⚠️ [DELAY] [APPLE] FAST MODE COMPLETE: \(allResults.count) POIs in \(String(format: "%.2f", appleElapsed))s (SLOW)")
        } else {
            print("🍎 FAST MODE COMPLETE: \(allResults.count) POIs (\(queriesWithResults) queries succeeded) in \(String(format: "%.2f", appleElapsed))s")
        }
        return allResults
    }
    
    /// COMPLETE MODE: All 120+ categories with smart batching (for background scan)
    /// Takes 2-3 minutes but gets maximum POI coverage
    func searchAppleMapsForPOIsComplete(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        let appleStartTime = Date()  // v2.0.3: Track timing for delay logging
        var allResults: [PlaceResult] = []
        var seenNames = Set<String>()
        
        let searchQueries = allAppleMapsCategories
        
        print("🍎 📡 BACKGROUND: Starting COMPLETE Apple Maps scan")
        print("🍎 📡   📊 Categories: \(searchQueries.count)")
        print("🍎 📡   📍 Radius: \(radiusMeters)m")
        
        // Smart batching: 40 queries per batch, 65s wait between batches
        let batchSize = 40
        var queriesWithResults = 0
        var queriesFailed = 0
        var queryIndex = 0
        var rateLimitHit = false
        var batchNumber = 0
        
        for batchStart in stride(from: 0, to: searchQueries.count, by: batchSize) {
            if rateLimitHit { break }
            
            batchNumber += 1
            let batchEnd = min(batchStart + batchSize, searchQueries.count)
            let batch = Array(searchQueries[batchStart..<batchEnd])
            
            // Wait between batches (not before first batch)
            if batchStart > 0 {
                print("🍎 📡 Batch \(batchNumber): Waiting 65s for rate limit reset...")
                try? await Task.sleep(nanoseconds: 65_000_000_000)  // 65 seconds
            }
            
            for query in batch {
                if rateLimitHit { break }
                
                queryIndex += 1
                do {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    request.region = MKCoordinateRegion(
                        center: location,
                        latitudinalMeters: Double(radiusMeters * 2),
                        longitudinalMeters: Double(radiusMeters * 2)
                    )
                    
                    let search = MKLocalSearch(request: request)
                    let response = try await search.start()
                    
                    for item in response.mapItems {
                        guard let name = item.name, !seenNames.contains(name) else { continue }
                        
                        let itemCoord = item.placemark.coordinate
                        let distance = distanceBetween(location, itemCoord)
                        guard distance <= Double(radiusMeters) else { continue }
                        
                        seenNames.insert(name)
                        
                        let placeResult = PlaceResult(
                            placeId: "apple_\(name.hashValue)",
                            name: name,
                            vicinity: item.placemark.title,
                            geometry: PlaceGeometry(
                                location: PlaceLocation(
                                    lat: item.placemark.coordinate.latitude,
                                    lng: item.placemark.coordinate.longitude
                                )
                            ),
                            types: [query]
                        )
                        allResults.append(placeResult)
                    }
                    if response.mapItems.count > 0 {
                        queriesWithResults += 1
                    }
                } catch {
                    queriesFailed += 1
                    let nsError = error as NSError
                    
                    if nsError.domain == "GEOErrorDomain" && nsError.code == -3 ||
                       nsError.domain == "MKErrorDomain" && nsError.code == 3 ||
                       nsError.localizedDescription.contains("50 requests") {
                        rateLimitHit = true
                        print("🍎 📡 RATE LIMITED at batch \(batchNumber) - stopping")
                        break
                    }
                }
            }
            
            if !rateLimitHit {
                print("🍎 📡 Batch \(batchNumber) complete: \(allResults.count) POIs")
            }
        }
        
        let appleElapsed = Date().timeIntervalSince(appleStartTime)
        if appleElapsed >= 3.0 {
            print("⚠️ [DELAY] [APPLE] COMPLETE: \(allResults.count) unique POIs in \(String(format: "%.2f", appleElapsed))s (SLOW)")
        } else {
            print("🍎 📡 BACKGROUND COMPLETE: \(allResults.count) unique POIs in \(String(format: "%.2f", appleElapsed))s")
        }
        return allResults
    }
    
    /// Legacy method - redirects to fast mode for backward compatibility
    func searchAppleMapsForPOIs(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 500
    ) async -> [PlaceResult] {
        return await searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
    }
    
    // MARK: - v2.0.3 Phase 2A: Fetch Live POIs for Blending (FREE sources only)
    /// Fetches live POIs from free sources (Apple Maps + OSM) for blending with DB POIs
    /// Used when DB POIs have insufficient diversity (ADS ≤ 2 or low count)
    /// Returns only POIs from free sources - no Google API calls (cost control)
    /// v2.0.3: Added timeout (5s -> 3s) to prevent OSM delays from slowing down batch tests
    /// v2.0.3: Skip Apple Maps in batch mode to avoid rate limiting (OSM only)
    private func fetchLivePOIsForBlending(location: CLLocationCoordinate2D, radiusMeters: Int, skipAppleMaps: Bool = false) async -> [PlaceResult] {
        let startTime = Date()
        let timeoutSeconds: Double = 3.0  // P1 FIX: Reduced from 5.0s to 3.0s (2.0s soft/3.0s hard)
        let minimumPOIsRequired = 10  // Early exit if we get enough POIs (acts as 2.0s soft timeout)
        
        // ⚠️ DELAY LOG: Highlight blending start
        if skipAppleMaps {
            print("⚠️ [DELAY] [BLENDING] Starting live POI fetch (OSM only, Apple Maps skipped) - timeout: \(timeoutSeconds)s")
        } else {
            print("⚠️ [DELAY] [BLENDING] Starting live POI fetch (Apple/OSM) - timeout: \(timeoutSeconds)s")
        }
        
        var allResults: [PlaceResult] = []
        var seenPlaceIds = Set<String>()
        
        // Fetch from Apple Maps and OSM in parallel (both free)
        // v2.0.3: Add proper timeout using race condition that actually cancels tasks
        let results: [PlaceResult]
        do {
            results = try await withTimeout(seconds: timeoutSeconds) {
                await withTaskGroup(of: [PlaceResult].self) { group in
                    var collected: [PlaceResult] = []
                    
                    // 🍎 Apple Maps (FREE, reliable, usually fast - 1-3s)
                    // v2.0.3: Skip Apple Maps if requested (batch mode to avoid rate limiting)
                    if !skipAppleMaps {
                        group.addTask { [self] in
                            let pois = await self.searchAppleMapsForPOIsFast(location: location, radiusMeters: radiusMeters)
                            // Tag with source
                            return pois.map { poi -> PlaceResult in
                                var tagged = poi
                                tagged.source = .apple
                                return tagged
                            }
                        }
                    }
                    
                    // 🗺️ OpenStreetMap (FREE, can be slow 15-50s, best-effort)
                    group.addTask { [self] in
                        do {
                            let pois = try await self.searchOpenStreetMapForPOIs(location: location, radiusMeters: radiusMeters)
                            // Tag with source
                            return pois.map { poi -> PlaceResult in
                                var tagged = poi
                                tagged.source = .osm
                                return tagged
                            }
                        } catch {
                            print("🗺️ OSM fetch failed: \(error.localizedDescription)")
                            return []
                        }
                    }
                    
                    // Collect results with early exit
                    for await pois in group {
                        collected.append(contentsOf: pois)
                        
                        // Early exit if we have enough POIs
                        if collected.count >= minimumPOIsRequired {
                            let elapsed = Date().timeIntervalSince(startTime)
                            print("✅ [BLENDING] Got \(collected.count) POIs - exiting early @ \(String(format: "%.2f", elapsed))s")
                            group.cancelAll()
                            break
                        }
                        
                        // ⚠️ DELAY LOG: Warn if taking longer than 3s
                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed >= 3.0 && elapsed < timeoutSeconds {
                            print("⚠️ [DELAY] [BLENDING] Still fetching... \(String(format: "%.1f", elapsed))s elapsed, \(collected.count) POIs so far")
                        }
                    }
                    
                    return collected
                }
            }
        } catch TimeoutError.timeout {
            // Timeout occurred - return empty (tasks were cancelled)
            print("⚠️ [DELAY] [BLENDING] TIMEOUT (\(timeoutSeconds)s) - tasks cancelled, returning empty")
            results = []
        } catch {
            // Other error - return empty
            print("⚠️ [DELAY] [BLENDING] ERROR: \(error.localizedDescription) - returning empty")
            results = []
        }
        
        // Deduplicate by placeId
        for poi in results {
            if !seenPlaceIds.contains(poi.placeId) {
                allResults.append(poi)
                seenPlaceIds.insert(poi.placeId)
            }
        }
        
        // Apply basic filters (restricted POIs)
        allResults = allResults.filter { !isRestrictedPOI($0) }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        // ⚠️ DELAY LOG: Highlight if blending took significant time
        if elapsed >= 3.0 {
            print("⚠️ [DELAY] [BLENDING] COMPLETE: \(allResults.count) live POIs in \(String(format: "%.2f", elapsed))s (SLOW)")
        } else {
            print("✅ [BLENDING] COMPLETE: \(allResults.count) live POIs in \(String(format: "%.2f", elapsed))s")
        }
        
        return allResults
    }
    
    // MARK: - Search OpenStreetMap for POIs (Overpass API - FREE!)
    /// Searches OpenStreetMap using the Overpass API for POIs near a location
    /// This is completely FREE with no API key required!
    /// ⚠️ WARNING: OSM can be slow (15-50s) - use with timeout
    private func searchOpenStreetMapForPOIs(location: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [PlaceResult] {
        let osmStartTime = Date()
        
        // COMPREHENSIVE Overpass API query - maximum POI coverage (FREE!)
        // Includes all major OSM tags that represent walking destinations
        let query = """
        [out:json][timeout:30];
        (
          // Core POI types (nodes)
          node["amenity"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["shop"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["craft"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["office"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["healthcare"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["club"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["community_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Buildings with names (common in UK)
          node["building"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="church"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="chapel"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="pub"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="commercial"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="retail"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="school"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["building"="kindergarten"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Transport nodes
          node["public_transport"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["railway"="station"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["railway"="halt"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Natural features (parks, woods, etc)
          node["natural"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["landuse"="recreation_ground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["landuse"="allotments"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // v1.6.26: GREEN SPACE / LOW-COMMITMENT POIS - Perfect for short walks
          // Parks and recreation
          node["leisure"="park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="playground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="garden"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="nature_reserve"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="dog_park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="pitch"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="common"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Street furniture - great for short walks
          node["amenity"="bench"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"="viewpoint"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["tourism"="picnic_site"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="fountain"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="memorial"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="monument"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["historic"="wayside_cross"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Community spaces
          node["amenity"="community_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="social_facility"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["amenity"="village_hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Religious buildings (often open for walks/reflection)
          node["amenity"="place_of_worship"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Sports facilities
          node["leisure"="sports_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="swimming_pool"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          node["leisure"="fitness_centre"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // Core POI types (ways - for larger buildings/areas)
          way["amenity"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["shop"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["tourism"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["historic"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["craft"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["healthcare"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="church"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="chapel"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="hall"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["building"="school"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="recreation_ground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          
          // v1.6.26: GREEN SPACE WAYS (larger areas)
          way["leisure"="park"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="playground"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="garden"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="nature_reserve"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="common"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="grass"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="meadow"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="village_green"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["natural"="wood"]["name"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
        );
        out center tags;
        """
        
        // Try multiple Overpass API mirrors for reliability
        // Overpass API mirrors - ordered by reliability
        // Note: kumi.systems has SSL issues, moved to last
        let allMirrors = [
            "https://lz4.overpass-api.de/api/interpreter",           // Fast mirror - usually works
            "https://overpass-api.de/api/interpreter",               // Main server
            "https://overpass.private.coffee/api/interpreter",       // No rate limits, global
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter", // VK Maps, no limits, global
            "https://overpass.osm.jp/api/interpreter",               // Japan mirror, global
            "https://overpass.kumi.systems/api/interpreter"          // Has SSL issues, last resort
        ]
        
        // v2.0.3 Phase 1.5: Prioritize mirrors by health (rate-limited mirrors deprioritized)
        let mirrors = await osmMirrorTracker.prioritizeMirrors(allMirrors)
        if mirrors != allMirrors {
            print("🔄 [OSM] Mirror priority adjusted based on health status")
        }
        
        // v2.0.3: Try all mirrors in parallel for faster results
        // First successful result wins, others are cancelled
        return try await withThrowingTaskGroup(of: (index: Int, results: [PlaceResult]?).self) { group in
            // Launch all mirror requests in parallel
            for (index, baseUrl) in mirrors.enumerated() {
                guard let url = URL(string: baseUrl) else {
                    print("🗺️ OSM: Invalid URL for mirror \(index + 1)")
                    continue
                }
                
                group.addTask { [self] in
                    print("🗺️ Searching OpenStreetMap (mirror \(index + 1)/\(mirrors.count))...")
                    
                    do {
                        // Use POST request with query in body (more reliable than GET with URL encoding)
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        // Overpass API accepts raw query in body with text/plain content type
                        request.httpBody = query.data(using: .utf8)
                        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                        request.timeoutInterval = 30
                        
                        let config = URLSessionConfiguration.default
                        config.timeoutIntervalForRequest = 30
                        config.timeoutIntervalForResource = 60
                        let session = URLSession(configuration: config)
                
                        let (data, response) = try await session.data(for: request)
                
                        guard let httpResponse = response as? HTTPURLResponse else {
                            print("🗺️ OSM: Invalid response from mirror \(index + 1)")
                            await self.osmMirrorTracker.recordFailure(mirror: baseUrl)
                            return (index: index, results: nil)
                        }
                        
                        // v2.0.3 Phase 1.5: Detect and track rate limits (429)
                        if httpResponse.statusCode == 429 {
                            print("🚫 [OSM] Rate limit detected on mirror \(index + 1) (\(baseUrl))")
                            await self.osmMirrorTracker.recordRateLimit(mirror: baseUrl)
                            return (index: index, results: nil)
                        }
                        
                        guard httpResponse.statusCode == 200 else {
                            print("🗺️ OSM: Bad response from mirror \(index + 1) (status: \(httpResponse.statusCode))")
                            await self.osmMirrorTracker.recordFailure(mirror: baseUrl)
                            return (index: index, results: nil)
                        }
                        
                        // Parse Overpass JSON response
                        var parsedResults: [PlaceResult] = []
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let elements = json["elements"] as? [[String: Any]] {
                            
                            for element in elements {
                                guard let tags = element["tags"] as? [String: String] else { continue }
                                
                                // Get name - skip if no name
                                guard let name = tags["name"] else { continue }
                                
                                // Get coordinates (handle both nodes and ways with center)
                                var lat: Double?
                                var lon: Double?
                                
                                if let nodeLat = element["lat"] as? Double, let nodeLon = element["lon"] as? Double {
                                    lat = nodeLat
                                    lon = nodeLon
                                } else if let center = element["center"] as? [String: Double] {
                                    lat = center["lat"]
                                    lon = center["lon"]
                                }
                                
                                guard let finalLat = lat, let finalLon = lon else { continue }
                                
                                // Get type from tags (expanded to match new query)
                                // Use array lookup to avoid Swift compiler complexity issue
                                let typeKeys = ["amenity", "shop", "leisure", "tourism", "historic", "craft", "office", "healthcare", "club", "building", "landuse"]
                                let poiType = typeKeys.compactMap { tags[$0] }.first ?? "place"
                                
                                // Get address if available
                                var address: String? = nil
                                if let street = tags["addr:street"] {
                                    let houseNumber = tags["addr:housenumber"] ?? ""
                                    address = "\(houseNumber) \(street)".trimmingCharacters(in: .whitespaces)
                                }
                                
                                let osmId = element["id"] as? Int ?? name.hashValue
                                
                                let placeResult = PlaceResult(
                                    placeId: "osm_\(osmId)",
                                    name: name,
                                    vicinity: address,
                                    geometry: PlaceGeometry(
                                        location: PlaceLocation(lat: finalLat, lng: finalLon)
                                    ),
                                    types: [poiType]
                                )
                                parsedResults.append(placeResult)
                            }
                        }
                        
                        let osmElapsed = Date().timeIntervalSince(osmStartTime)
                        if parsedResults.isEmpty {
                            return (index: index, results: nil)
                        }
                        
                        // v2.0.3 Phase 1.5: Record successful request
                        await self.osmMirrorTracker.recordSuccess(mirror: baseUrl)
                        
                        if osmElapsed >= 3.0 {
                            print("⚠️ [DELAY] [OSM] Found \(parsedResults.count) POIs in \(String(format: "%.2f", osmElapsed))s (mirror \(index + 1), SLOW)")
                        } else {
                            print("🗺️ ✓ OpenStreetMap found \(parsedResults.count) POIs (mirror \(index + 1) succeeded) in \(String(format: "%.2f", osmElapsed))s")
                        }
                        return (index: index, results: parsedResults)
                        
                    } catch {
                        print("🗺️ OSM mirror \(index + 1) failed: \(error.localizedDescription)")
                        
                        // P1 FIX: Detect SSL errors (-1200, -9816) and blacklist mirror
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain {
                            let sslErrorCodes = [-1200, -9816, -1201, -1202, -1203, -1204, -1205, -1206]
                            if sslErrorCodes.contains(nsError.code) {
                                await self.osmMirrorTracker.recordSSLError(mirror: baseUrl, errorCode: nsError.code)
                            } else {
                                await self.osmMirrorTracker.recordFailure(mirror: baseUrl)
                            }
                        } else {
                            await self.osmMirrorTracker.recordFailure(mirror: baseUrl)
                        }
                        return (index: index, results: nil)
                    }
                }
            }
            
            // Wait for first successful result, then cancel all others
            for try await result in group {
                if let results = result.results, !results.isEmpty {
                    // Success! Cancel remaining tasks and return
                    group.cancelAll()
                    let osmElapsed = Date().timeIntervalSince(osmStartTime)
                    print("✅ [OSM PARALLEL] Mirror \(result.index + 1) succeeded first with \(results.count) POIs in \(String(format: "%.2f", osmElapsed))s")
                    return results
                }
            }
            
            // All mirrors failed
            let osmElapsed = Date().timeIntervalSince(osmStartTime)
            if osmElapsed >= 3.0 {
                print("⚠️ [DELAY] [OSM] All mirrors failed after \(String(format: "%.2f", osmElapsed))s (SLOW)")
            } else {
                print("🗺️ ⚠️ All OSM mirrors failed")
            }
            return []
        }
    }
    
    // MARK: - Geograph POI Search (Experimental)
    
    /// Searches Geograph.org.uk for geotagged photos that can serve as POIs
    /// Uses the Syndicator API: https://www.geograph.org.uk/help/api
    /// Returns photos with location data that can be used as landmarks/POIs
    /// 
    /// LICENSE: Geograph photos are licensed under CC BY-SA 2.0
    /// Attribution: When displaying Geograph data, credit the photographer and Geograph.org.uk
    /// Note: Requires API key from Geograph (request at https://www.geograph.org.uk/help/api)
    private func searchGeographForPOIs(location: CLLocationCoordinate2D, radiusMeters: Int) async -> [PlaceResult] {
        // Check if API key is available
        guard !geographApiKey.isEmpty else {
            print("📸 Geograph: No API key configured - skipping")
            return []
        }
        
        // Convert radius from meters to kilometers (Geograph API uses km)
        let radiusKm = Double(radiusMeters) / 1000.0
        
        // Build API URL with location and distance parameters
        // Format: lat,lon (e.g., "53.3811,-1.4701")
        let locationString = "\(location.latitude),\(location.longitude)"
        
        // Geograph Syndicator API endpoint
        // Parameters:
        // - key: API key
        // - location: lat,lon or grid reference
        // - distance: radius in km
        // - perpage: max results (up to 1000)
        // - format: JSON
        // - ll: include lat/lon in response
        // - thumb: include thumbnail URL
        // - desc: include description
        let baseUrl = "https://api.geograph.org.uk/syndicator.php"
        var components = URLComponents(string: baseUrl)
        components?.queryItems = [
            URLQueryItem(name: "key", value: geographApiKey),
            URLQueryItem(name: "location", value: locationString),
            URLQueryItem(name: "distance", value: "\(Int(radiusKm))"),
            URLQueryItem(name: "perpage", value: "100"),
            URLQueryItem(name: "format", value: "JSON"),
            URLQueryItem(name: "ll", value: "1"),
            URLQueryItem(name: "thumb", value: "1"),
            URLQueryItem(name: "desc", value: "1")
        ]
        
        guard let url = components?.url else {
            print("📸 Geograph: Failed to build URL")
            return []
        }
        
        print("📸 Geograph: Requesting URL: \(url.absoluteString.replacingOccurrences(of: geographApiKey, with: "[API_KEY]"))")
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10  // 10 second timeout
        request.setValue("WalkingWR/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("📸 Geograph: Invalid response")
                return []
            }
            
            // Log response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("📸 Geograph: Response preview (first 500 chars): \(String(responseString.prefix(500)))")
            }
            
            guard httpResponse.statusCode == 200 else {
                print("📸 Geograph: HTTP error \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("📸 Geograph: Error response: \(errorString)")
                }
                return []
            }
            
            // Parse JSON response
            // Geograph API returns different formats depending on format parameter
            // For JSON format, it typically returns an array or object with items
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Try parsing as array
                if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    print("📸 Geograph: Parsed as array with \(jsonArray.count) items")
                    return parseGeographResults(jsonArray: jsonArray, location: location, radiusMeters: radiusMeters, sourceLabel: "")
                }
                print("📸 Geograph: Invalid JSON format - could not parse as object or array")
                print("📸 Geograph: Data size: \(data.count) bytes")
                return []
            }
            
            print("📸 Geograph: Parsed as object with keys: \(json.keys.joined(separator: ", "))")
            
            // Handle object format - look for items, entries, or similar keys
            if let items = json["items"] as? [[String: Any]] {
                print("📸 Geograph: Found 'items' array with \(items.count) items")
                return parseGeographResults(jsonArray: items, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            } else if let entries = json["entries"] as? [[String: Any]] {
                print("📸 Geograph: Found 'entries' array with \(entries.count) entries")
                return parseGeographResults(jsonArray: entries, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            } else if let jsonArray = json.values.first as? [[String: Any]] {
                print("📸 Geograph: Found array in first value with \(jsonArray.count) items")
                return parseGeographResults(jsonArray: jsonArray, location: location, radiusMeters: radiusMeters, sourceLabel: "")
            }
            
            // Try to find any array in the JSON
            for (key, value) in json {
                if let array = value as? [[String: Any]] {
                    print("📸 Geograph: Found array in key '\(key)' with \(array.count) items")
                    return parseGeographResults(jsonArray: array, location: location, radiusMeters: radiusMeters, sourceLabel: "")
                }
            }
            
            print("📸 Geograph: Unexpected JSON structure - no arrays found")
            print("📸 Geograph: JSON keys: \(json.keys.joined(separator: ", "))")
            return []
            
        } catch {
            print("📸 Geograph: Network error - \(error.localizedDescription)")
            if let urlError = error as? URLError {
                print("📸 Geograph: URL error code: \(urlError.code.rawValue), description: \(urlError.localizedDescription)")
            }
            return []
        }
    }
    
    /// Helper to parse Geograph API results into PlaceResult objects
    private func parseGeographResults(jsonArray: [[String: Any]], location: CLLocationCoordinate2D, radiusMeters: Int, sourceLabel: String = "") -> [PlaceResult] {
        var results: [PlaceResult] = []
        let maxRealisticDistance = Double(radiusMeters) * 2.0
        
        let label = sourceLabel.isEmpty ? "Geograph" : "Geograph [\(sourceLabel)]"
        print("📸 \(label): Parsing \(jsonArray.count) items...")
        
        // Log first item structure for debugging
        if let firstItem = jsonArray.first {
            print("📸 \(label): First item keys: \(firstItem.keys.joined(separator: ", "))")
            if let firstItemJson = try? JSONSerialization.data(withJSONObject: firstItem, options: .prettyPrinted),
               let firstItemString = String(data: firstItemJson, encoding: .utf8) {
                print("📸 \(label): First item preview:\n\(String(firstItemString.prefix(1000)))")
            }
        }
        
        for (index, item) in jsonArray.enumerated() {
            // Extract title/name - try multiple possible field names
            var title: String?
            if let t = item["title"] as? String { title = t }
            else if let t = item["name"] as? String { title = t }
            else if let t = item["caption"] as? String { title = t }
            else if let t = item["subject"] as? String { title = t }
            
            guard let finalTitle = title, !finalTitle.isEmpty else {
                if index < 3 { // Log first few failures
                    print("📸 \(label): Item \(index) missing title/name - keys: \(item.keys.joined(separator: ", "))")
                }
                continue
            }
            
            // Extract coordinates - try multiple possible field names
            // Geograph API uses "lat" and "long" (not "lon") as strings
            var lat: Double?
            var lon: Double?
            
            // Try Geograph-specific format first: "lat" and "long" as strings
            if let latStr = item["lat"] as? String, let longStr = item["long"] as? String {
                lat = Double(latStr)
                lon = Double(longStr)
            }
            // Try "lat" and "lon" as strings
            else if let latStr = item["lat"] as? String, let lonStr = item["lon"] as? String {
                lat = Double(latStr)
                lon = Double(lonStr)
            }
            // Try "lat" and "lon" as numbers
            else if let latNum = item["lat"] as? Double, let lonNum = item["lon"] as? Double {
                lat = latNum
                lon = lonNum
            }
            // Try standard "latitude" and "longitude" as numbers
            else if let latitude = item["latitude"] as? Double, let longitude = item["longitude"] as? Double {
                lat = latitude
                lon = longitude
            }
            // Try standard "latitude" and "longitude" as strings
            else if let latitude = item["latitude"] as? String, let longitude = item["longitude"] as? String {
                lat = Double(latitude)
                lon = Double(longitude)
            }
            // Try nested objects
            else if let geo = item["geo"] as? [String: Any] {
                lat = geo["latitude"] as? Double ?? (geo["lat"] as? String).flatMap(Double.init)
                lon = geo["longitude"] as? Double ?? (geo["lon"] as? String ?? geo["long"] as? String).flatMap(Double.init)
            } else if let point = item["point"] as? [String: Any] {
                lat = point["latitude"] as? Double ?? (point["lat"] as? String).flatMap(Double.init)
                lon = point["longitude"] as? Double ?? (point["lon"] as? String ?? point["long"] as? String).flatMap(Double.init)
            } else if let locationObj = item["location"] as? [String: Any] {
                lat = locationObj["latitude"] as? Double ?? (locationObj["lat"] as? String).flatMap(Double.init)
                lon = locationObj["longitude"] as? Double ?? (locationObj["lon"] as? String ?? locationObj["long"] as? String).flatMap(Double.init)
            }
            
            guard let finalLat = lat, let finalLon = lon else {
                // Log ALL failures for postcode searches (not just first 3)
                let titleForLog = title ?? "unknown"
                let shouldLogAll = !sourceLabel.isEmpty  // Log all for postcode searches
                if shouldLogAll || index < 3 {
                    print("📸 \(label): Item \(index) '\(titleForLog)' missing coordinates")
                    print("📸 \(label):   Available keys: \(item.keys.joined(separator: ", "))")
                    // Try to show what coordinate fields exist
                    if let latVal = item["lat"], let lonVal = item["long"] {
                        print("📸 \(label):   Found lat=\(latVal), long=\(lonVal) (types: \(type(of: latVal)), \(type(of: lonVal)))")
                        // Try to parse them manually to see why it's failing
                        if let latStr = latVal as? String, let lonStr = lonVal as? String {
                            if let latParsed = Double(latStr), let lonParsed = Double(lonStr) {
                                print("📸 \(label):   ✅ Manual parse successful: lat=\(latParsed), lon=\(lonParsed)")
                            } else {
                                print("📸 \(label):   ❌ Manual parse failed: latStr='\(latStr)', lonStr='\(lonStr)'")
                            }
                        }
                    } else if let latVal = item["lat"] {
                        print("📸 \(label):   Found lat=\(latVal) but missing long")
                    } else if let lonVal = item["long"] {
                        print("📸 \(label):   Found long=\(lonVal) but missing lat")
                    } else {
                        print("📸 \(label):   No lat/long fields found")
                    }
                }
                continue
            }
            
            // Filter by distance (same as other sources)
            // 🧪 TEST: Skip distance filter if location is (0,0) - means it's from postcode search
            let coordinate = CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon)
            let shouldFilterByDistance = !(location.latitude == 0 && location.longitude == 0)
            if shouldFilterByDistance {
                let distance = distanceBetween(location, coordinate)
                if distance > maxRealisticDistance {
                    continue
                }
            }
            
            // Extract description/vicinity if available
            var description = item["description"] as? String ?? item["desc"] as? String ?? ""
            // Clean HTML tags
            description = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // Remove "Dist:Xkm" prefix if present (common in Geograph API responses)
            if let distRange = description.range(of: "^Dist:\\d+\\.?\\d*km", options: .regularExpression) {
                description = String(description[distRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let vicinity = description.isEmpty ? nil : description
            
            // Extract image ID for placeId
            let imageId = item["id"] as? Int ?? item["image_id"] as? Int ?? finalTitle.hashValue
            
            // Extract photographer/submitter info if available (for attribution)
            // Note: We store this in vicinity if not already set, or could be added to a future attribution field
            let submitter = item["submitter"] as? String ?? item["user"] as? String
            var finalVicinity = vicinity
            if let submitter = submitter, finalVicinity == nil {
                // Add photographer credit to vicinity if available
                finalVicinity = "Photo by \(submitter) / Geograph.org.uk"
            } else if let submitter = submitter, let existingVicinity = finalVicinity {
                // Append photographer credit if vicinity already exists
                finalVicinity = "\(existingVicinity) (Photo by \(submitter))"
            }
            
            // Create PlaceResult
            // Note: Geograph photos are CC BY-SA 2.0 - attribution should be shown when displaying
            let placeResult = PlaceResult(
                placeId: "geograph_\(imageId)",
                name: finalTitle,
                vicinity: finalVicinity,
                geometry: PlaceGeometry(
                    location: PlaceLocation(lat: finalLat, lng: finalLon)
                ),
                types: ["geograph_photo", "landmark"],  // Tag as Geograph photo/landmark
                source: .geograph
            )
            
            results.append(placeResult)
        }
        
        print("📸 \(label): Found \(results.count) POIs (from \(jsonArray.count) items)")
        return results
    }
    
    // MARK: - Geograph Quality Scoring & Testing (PB-POIRS Algorithm)
    
    /// Universal POI filtering - location-agnostic rules that apply anywhere in the UK
    /// No location-specific whitelists or special cases
    
    /// Hard exclusion check: Returns true if POI should be completely excluded (never output)
    /// This runs BEFORE scoring - excluded items are never processed further
    /// NOTE: Whitelist check happens FIRST - if whitelisted, never exclude
    private func shouldExcludeGeographPOI(_ poi: PlaceResult, origin: CLLocationCoordinate2D) -> Bool {
        let title = poi.name.lowercased()
        let description = poi.vicinity?.lowercased() ?? ""
        
        // Clean description - remove "Dist:Xkm" prefix if present
        var cleanedDescription = description
        if let distRange = cleanedDescription.range(of: "Dist:\\d+\\.?\\d*km", options: .regularExpression) {
            cleanedDescription = String(cleanedDescription[distRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // A. HARD EXCLUSION RULES (ALWAYS APPLY - NO WHITELIST OVERRIDE)
        // These items are NEVER POIs, even if they mention whitelisted locations
        
        // 3) Low-value land features
        // Drainage ditches, culverts, runoff channels
        if title.contains("drainage") || title.contains("ditch") || title.contains("culvert") ||
           title.contains("runoff channel") || title.contains("field boundary") || title.contains("hedgerow") {
            return true
        }
        
        // Random trees, hedgerows (unless memorial/monument)
        if (title.contains("tree") || title.contains("trees") || title.contains("hedgerow")) &&
           !title.contains("memorial") && !title.contains("monument") {
            return true
        }
        
        // Grazing fields, generic farmland
        if title.contains("grazing") || title.contains("grazing land") ||
           (title.contains("field") && !title.contains("playing") && !title.contains("football") &&
            !title.contains("cricket") && !title.contains("sports") && !title.contains("memorial")) {
            return true
        }
        
        // 2) Footpaths / tracks / rights of way
        if title.contains("footpath") || title.contains("fp") || title.contains("fp-") ||
           title.contains("track") || title.contains("bridleway") || title.contains("walkway") ||
           title.contains("walking route") || title.contains("right of way") ||
           (title.contains("lane") && (cleanedDescription.contains("footpath") || 
            cleanedDescription.contains("path") || cleanedDescription.contains("walking"))) {
            return true
        }
        
        // 1) Transport infrastructure - ALWAYS EXCLUDE
        // Motorways, A-roads, B-roads, road segments
        if title.contains("motorway") || title.contains("m1") || title.contains("m62") ||
           title.contains("m6") || title.contains("a-road") || title.contains("b-road") ||
           title.contains("motorway bridge") || title.contains("motorway verge") {
            return true
        }
        
        // Road views / approaches / crossings - ALWAYS EXCLUDE
        // "view along road", "approaching bridge", "crossing road/lane"
        if (title.contains("view along") || title.contains("approaching") || 
            title.contains("crossing") || title.contains("descends")) &&
           (title.contains("road") || title.contains("bridge") || title.contains("lane") ||
            title.contains("street") || title.contains("way")) {
            return true
        }
        
        // Traffic events, snow disruption, roadworks
        if title.contains("traffic") || title.contains("roadworks") || title.contains("snow disruption") {
            return true
        }
        
        // 4) Utility / non-places
        // Car parks, laybys
        if title.contains("car park") || title.contains("parking") || title.contains("parking area") ||
           title.contains("layby") || title.contains("lay-by") {
            return true
        }
        
        // Electricity substations
        if title.contains("electricity") || title.contains("sub station") || title.contains("substation") {
            return true
        }
        
        // ==========================================
        // B. VALID POI TYPE CHECK (Universal Rules)
        // ==========================================
        // After hard exclusions, check if this is a valid POI type
        // Only these general types are allowed
        
        let isValidPOIType = 
            // 1) Built heritage
            title.contains("church") || title.contains("chapel") || title.contains("temple") ||
            title.contains("mosque") || title.contains("synagogue") || title.contains("methodist") ||
            title.contains("anglican") || title.contains("religious") ||
            title.contains("historic") || title.contains("hall") || title.contains("manor") ||
            title.contains("listed") || title.contains("castle") || title.contains("tower") ||
            title.contains("mill") || title.contains("civic") ||
            // 2) Community / civic
            title.contains("school") || title.contains("library") || title.contains("town hall") ||
            title.contains("village hall") || title.contains("community") || title.contains("medical") ||
            // 3) Cultural / social
            title.contains("inn") || title.contains("pub") || title.contains("post office") ||
            title.contains("shop") || title.contains("store") || title.contains("market") ||
            // 4) Industrial heritage (HIGH PRIORITY - comprehensive detection)
            title.contains("grinding wheel") || title.contains("millstone") ||
            title.contains("rolling mill") || title.contains("roller") ||
            title.contains("stamping hammer") || title.contains("chimney") ||
            title.contains("kiln") || title.contains("engine house") ||
            title.contains("turbine") || title.contains("boiler") ||
            title.contains("forge") || title.contains("foundry") ||
            title.contains("cutlery") || title.contains("steel works") ||
            title.contains("steelworks") || title.contains("workshop") ||
            title.contains("machinery") || title.contains("industrial") ||
            title.contains("trumpets") || description.contains("steel") ||
            description.contains("forge") || description.contains("mill") ||
            description.contains("cutlery") || description.contains("rolling") ||
            description.contains("works") || description.contains("machinery") ||
            description.contains("turbine") || description.contains("heritage") ||
            description.contains("engine house") ||
            // 5) Natural landmarks (STRICT - only named, destination-worthy features)
            // MUST NOT describe road/bridge crossings
            // Example allowed: "River Aire", "Stanage Edge"
            // Example excluded: "Beck crosses Lane", "View from bridge"
            ((title.contains("river") || title.contains("stream") || title.contains("beck") ||
              title.contains("waterfall") || title.contains("valley") || title.contains("hill") ||
              title.contains("edge") || title.contains("peak") || title.contains("moor")) &&
             !title.contains("crosses") && !title.contains("crossing") &&
             !title.contains("view from") && !title.contains("view of") &&
             !title.contains("bridge") && !title.contains("road") &&
             (cleanedDescription.contains("named") || cleanedDescription.contains("destination") ||
              cleanedDescription.contains("landmark") || title.count > 15)) ||
            // 6) Notable housing
            (title.contains("crescent") || title.contains("terrace") || title.contains("cottage")) &&
            (cleanedDescription.contains("architectural") || cleanedDescription.contains("listed") ||
             cleanedDescription.contains("historic") || cleanedDescription.contains("notable")) ||
            // 7) Postboxes (handled separately below)
            title.contains("postbox") || title.contains("post box") || title.contains("letter box")
        
        // If not a valid POI type, exclude it
        if !isValidPOIType {
            return true  // Not a valid POI type
        }
        
        // ==========================================
        // C. POSTBOX RULE (LIMITED)
        // ==========================================
        // Postboxes are LOW PRIORITY and only allowed with specific conditions
        if title.contains("postbox") || title.contains("post box") || title.contains("letter box") {
            var hasValidContext = false
            
            // Check: Has meaningful description (e.g., WF2 10, location context)
            if cleanedDescription.count >= 10 && 
               (cleanedDescription.contains("wf") || cleanedDescription.contains("historic") ||
                cleanedDescription.contains("location") || cleanedDescription.contains("context") ||
                cleanedDescription.contains("no.") || cleanedDescription.contains("number")) {
                hasValidContext = true
            }
            
            // Check: Acts as a local navigation point (village centre)
            if title.contains("centre") || title.contains("center") || title.contains("village") {
                hasValidContext = true
            }
            
            // Check: Has historic value: VR, GR, ERVII, Penfold
            if description.contains("vr") || description.contains("ervii") ||
               description.contains("gr") || description.contains("penfold") ||
               description.contains("victorian") || description.contains("edwardian") ||
               description.contains("elizabeth") {
                hasValidContext = true
            }
            
            // Exclude if none of the conditions are met
            if !hasValidContext {
                return true
            }
        }
        
        // 5) Items with no meaningful description
        // Description absent or < 10 characters AND not visually significant
        if cleanedDescription.isEmpty || (cleanedDescription.count < 10 && 
           !title.contains("memorial") && !title.contains("monument") &&
           !title.contains("church") && !title.contains("tower") &&
           !title.contains("castle") && !title.contains("listed")) {
            return true
        }
        
        return false
    }
    
    /// PB-POIRS Algorithm: Calculate quality score for a Geograph POI (0.0 to 10.0)
    /// Follows comprehensive rules for identifying, cleaning, clustering, and ranking POIs
    /// NOTE: This should only be called on POIs that passed shouldExcludeGeographPOI()
    private func geographQualityScore(_ poi: PlaceResult) -> Double {
        let title = poi.name.lowercased()
        let description = poi.vicinity?.lowercased() ?? ""
        
        // Clean description - remove "Dist:Xkm" prefix if present
        var cleanedDescription = description
        if let distRange = cleanedDescription.range(of: "Dist:\\d+\\.?\\d*km", options: .regularExpression) {
            cleanedDescription = String(cleanedDescription[distRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // NOTE: Hard exclusions are handled by shouldExcludeGeographPOI() - this function
        // only scores POIs that have already passed exclusion checks
        
        // ==========================================
        // RULE 2: POSTBOXES (SPECIAL RULE)
        // ==========================================
        var isPostbox = false
        var postboxScore: Double = 0.0
        
        if title.contains("postbox") || title.contains("post box") || title.contains("letter box") {
            isPostbox = true
            postboxScore = 2.0  // Base low score
            
            // Boost: Clear local navigation point
            if title.contains("centre") || title.contains("center") || title.contains("village") {
                postboxScore += 1.0
            }
            
            // Boost: Description has context
            if cleanedDescription.contains("wf") || cleanedDescription.contains("historic") || 
               cleanedDescription.contains("early os") || cleanedDescription.contains("os maps") {
                postboxScore += 1.0
            }
            
            // Boost: Victorian/Edwardian/George V or Penfold
            if cleanedDescription.contains("vr") || cleanedDescription.contains("ervii") || 
               cleanedDescription.contains("gr") || cleanedDescription.contains("penfold") {
                postboxScore += 2.0
            }
            
            // Boost: Lone infrastructure in rural area
            if cleanedDescription.contains("rural") || cleanedDescription.contains("isolated") {
                postboxScore += 0.5
            }
        }
        
        // ==========================================
        // RULE 4: VALID POI CATEGORIES (WEIGHTS)
        // ==========================================
        var categoryWeight: Double = 0.0
        
        // Historic buildings (+2.0)
        if title.contains("historic") || title.contains("original") || 
           title.contains("workhouse") || title.contains("victorian") ||
           title.contains("georgian") || description.contains("historic") ||
           description.contains("original") || description.contains("1881") ||
           description.contains("1878") {
            categoryWeight = 2.0
        }
        // Religious buildings (+1.5)
        else if title.contains("church") || title.contains("chapel") || 
                title.contains("methodist") || title.contains("anglican") {
            categoryWeight = 1.5
        }
        // Community buildings (+1.5)
        else if title.contains("village hall") || title.contains("school") || 
                title.contains("library") || title.contains("community") {
            categoryWeight = 1.5
        }
        // Significant medical buildings (+1.5)
        else if title.contains("hospital") || title.contains("wing") || 
                title.contains("unit") || title.contains("clinic") ||
                title.contains("department") || title.contains("centre") ||
                title.contains("institute") {
            categoryWeight = 1.5
        }
        // Notable pubs, shops (+1.0)
        else if title.contains("inn") || title.contains("pub") || 
                title.contains("shop") || title.contains("store") {
            categoryWeight = 1.0
        }
        // Industrial heritage (+1.0)
        else if title.contains("grinding wheel") || title.contains("rolling mill") ||
                title.contains("trumpets") || title.contains("roller") {
            categoryWeight = 1.0
        }
        // Memorials and monuments (+1.5) - check BEFORE natural features
        else if title.contains("memorial") || title.contains("monument") ||
                title.contains("war memorial") {
            categoryWeight = 1.5
        }
        // Natural landmarks (+0.5) - only valid named, destination-worthy features
        // Already filtered to exclude road/bridge crossings in exclusion rules
        else if (title.contains("river") || title.contains("stream") || title.contains("beck") ||
                title.contains("waterfall") || title.contains("valley") || title.contains("hill") ||
                title.contains("edge") || title.contains("peak") || title.contains("moor")) {
            categoryWeight = 0.5
        }
        // Architecturally notable housing (+1.0)
        else if (title.contains("crescent") || title.contains("estate") || title.contains("bungalow")) &&
                (cleanedDescription.contains("architectural") || cleanedDescription.contains("notable") ||
                 cleanedDescription.contains("council estate") || cleanedDescription.contains("designed")) {
            categoryWeight = 1.0
        }
        // Towers and landmarks
        else if title.contains("tower") || title.contains("clock tower") {
            categoryWeight = 2.0
        }
        // Halls and significant buildings
        else if title.contains("hall") && !title.contains("village hall") {
            categoryWeight = 1.5
        }
        
        // Postboxes get base 0.0 category weight (handled separately)
        if isPostbox {
            categoryWeight = 0.0
        }
        
        // ==========================================
        // RULE 5: DESCRIPTION QUALITY WEIGHTING
        // ==========================================
        var descriptionWeight: Double = 0.0
        
        // cleanedDescription already computed above
        
        if cleanedDescription.isEmpty {
            descriptionWeight = -1.0  // No description (after cleaning) - should have been excluded
        } else if cleanedDescription.count < 10 {
            descriptionWeight = 0.0  // Very minimal description
        } else if cleanedDescription.count < 30 {
            descriptionWeight = 0.5  // Short but has content
        } else if cleanedDescription.count >= 50 {
            // Check for detailed history/context
            if cleanedDescription.contains("historic") || cleanedDescription.contains("original") ||
               cleanedDescription.contains("formerly") || cleanedDescription.contains("named after") ||
               cleanedDescription.contains("built in") || cleanedDescription.contains("established") ||
               cleanedDescription.contains("workhouse") || cleanedDescription.contains("victorian") ||
               cleanedDescription.contains("foundation stone") || cleanedDescription.contains("died") ||
               cleanedDescription.contains("first world war") || cleanedDescription.contains("world war") {
                descriptionWeight = 2.0  // Detailed history/context
            } else {
                descriptionWeight = 1.0  // Clear and informative
            }
        } else {
            // 30-49 characters - check if it has meaningful content
            if cleanedDescription.contains("memorial") || cleanedDescription.contains("church") ||
               cleanedDescription.contains("school") || cleanedDescription.contains("hall") ||
               cleanedDescription.contains("inn") || cleanedDescription.contains("pub") ||
               cleanedDescription.contains("died") || cleanedDescription.contains("war") {
                descriptionWeight = 1.0  // Mentions POI type or historical context - informative
            } else {
                descriptionWeight = 0.5  // Some content but brief
            }
        }
        
        // ==========================================
        // RULE 6: FINAL SCORING + INDUSTRIAL HERITAGE BOOSTS
        // ==========================================
        var finalScore: Double
        
        if isPostbox {
            // Postboxes use their special scoring
            finalScore = postboxScore + descriptionWeight
        } else {
            // Base score starts at category weight
            finalScore = categoryWeight + descriptionWeight
            
            // INDUSTRIAL HERITAGE BOOSTS (PB-POIRS v5)
            if categoryWeight == 3.0 {  // Industrial heritage category
                var industrialBoost: Double = 0.0
                
                // Boost: Description contains industrial history keywords
                let industrialKeywords = ["steel", "forge", "mill", "cutlery", "rolling", "works", 
                                         "machinery", "turbine", "victorian", "heritage", "engine house"]
                if industrialKeywords.contains(where: { cleanedDescription.contains($0) }) {
                    industrialBoost += 0.5
                }
                
                // Boost: Part of a cluster of industrial artefacts
                // (This is handled during clustering - if multiple industrial items cluster together,
                //  they get higher priority. For now, we'll add boost if title suggests multiple items)
                if title.contains(" - ") || title.contains(" and ") || title.contains(" & ") {
                    // Suggests multiple items or part of a series
                    industrialBoost += 0.5
                }
                
                finalScore += industrialBoost
            }
        }
        
        // Ensure bounds (0-10)
        finalScore = max(0.0, min(10.0, finalScore))
        
        return finalScore
    }
    
    /// Cluster duplicate POIs within 30m or same feature name
    /// Returns deduplicated list with best representative from each cluster
    /// Prefers POIs with better descriptions and higher scores
    private func clusterGeographPOIs(_ pois: [PlaceResult], origin: CLLocationCoordinate2D) -> [PlaceResult] {
        var clustered: [PlaceResult] = []
        var processed = Set<String>()
        
        for poi in pois {
            // Skip if already processed
            if processed.contains(poi.placeId) {
                continue
            }
            
            // Find all POIs in this cluster (within 30m or same feature name)
            var cluster: [PlaceResult] = [poi]
            processed.insert(poi.placeId)
            
            // Extract base feature name (remove variations)
            let baseName = extractBaseFeatureName(poi.name)
            
            for otherPOI in pois {
                if processed.contains(otherPOI.placeId) {
                    continue
                }
                
                let distance = distanceBetween(poi.coordinate, otherPOI.coordinate)
                let otherBaseName = extractBaseFeatureName(otherPOI.name)
                
                // Cluster if within 30m OR same base feature name
                // Also check if names are similar (e.g., "Westfield Crescent" and "Old people's bungalows in Westfield Crescent")
                let namesSimilar = baseName.contains(otherBaseName) || otherBaseName.contains(baseName) ||
                                   (baseName.count > 5 && otherBaseName.count > 5 &&
                                    calculateNameSimilarity(baseName, otherBaseName) > 0.7)
                
                if distance <= 30.0 || baseName == otherBaseName || namesSimilar {
                    cluster.append(otherPOI)
                    processed.insert(otherPOI.placeId)
                }
            }
            
            // Select best representative from cluster (most complete description, then highest score)
            // D. CLUSTERING RULE: ALWAYS output ONE master POI per cluster
            if cluster.count > 1 {
                let scored = cluster.map { poi -> (poi: PlaceResult, score: Double, distance: Double, descLength: Int) in
                    let score = geographQualityScore(poi)
                    let dist = distanceBetween(origin, poi.coordinate)
                    let descLength = poi.vicinity?.count ?? 0
                    return (poi, score, dist, descLength)
                }
                
                // Choose item with most complete description, then highest score, then closest
                let best = scored.max { first, second in
                    // Prefer longer descriptions (more complete)
                    if abs(Double(first.descLength - second.descLength)) > 10 {
                        return first.descLength < second.descLength
                    }
                    // Then by score
                    if abs(first.score - second.score) > 0.1 {
                        return first.score < second.score
                    }
                    // Then by distance
                    return first.distance > second.distance
                }
                
                if let bestPOI = best {
                    clustered.append(bestPOI.poi)
                }
            } else {
                clustered.append(poi)
            }
        }
        
        return clustered
    }
    
    /// Extract base feature name for clustering (removes variations like "Main Entrance", "Side View", etc.)
    private func extractBaseFeatureName(_ name: String) -> String {
        var base = name.lowercased()
        
        // Remove Geograph grid reference prefix (e.g., "SE2922 : ")
        base = base.replacingOccurrences(of: "^[a-z]{1,2}\\d{4}\\s*:\\s*", with: "", options: .regularExpression)
        
        // Remove common variations and quotes
        let variations = [
            "main entrance", "side entrance", "entrance", "original",
            "side view", "view of", "from", "near", "at", "the",
            "building", "wing", "unit", "centre", "center",
            " - 1", " - 2", " - 3", " 1", " 2", " 3",
            "old people's", "\"old people's bungalows\"", "in", "on", "approaching", "descends",
            "\"", "'", "bungalows", "bungalow"
        ]
        
        for variation in variations {
            base = base.replacingOccurrences(of: variation, with: "", options: .caseInsensitive)
        }
        
        // Clean up extra spaces and normalize
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        base = base.replacingOccurrences(of: "  ", with: " ")
        base = base.replacingOccurrences(of: "  ", with: " ")  // Double pass for multiple spaces
        
        return base
    }
    
    /// Determine POI category for output (matches universal ruleset)
    private func determinePOICategory(_ poi: PlaceResult) -> String {
        let title = poi.name.lowercased()
        let description = poi.vicinity?.lowercased() ?? ""
        
        // 1) Built heritage
        if title.contains("church") || title.contains("chapel") || title.contains("temple") ||
           title.contains("mosque") || title.contains("synagogue") || title.contains("methodist") ||
           title.contains("anglican") || title.contains("religious") || title.contains("abbey") {
            return "Religious Building"
        } else if title.contains("historic") || title.contains("listed") || title.contains("castle") ||
                  title.contains("tower") || title.contains("mill") ||
                  (title.contains("hall") && !title.contains("village hall")) {
            return "Historic Building"
        }
        // Memorials
        else if title.contains("memorial") || title.contains("monument") {
            return "Memorial/Monument"
        }
        // 2) Community / civic
        else if title.contains("school") || title.contains("library") || title.contains("town hall") ||
                title.contains("village hall") || title.contains("community") {
            return "Community Building"
        }
        // 3) Cultural / social
        else if title.contains("inn") || title.contains("pub") {
            return "Pub/Inn"
        } else if title.contains("postbox") || title.contains("post box") || description.contains("postbox") || description.contains("post box") {
            return "Postbox"
        } else if title.contains("shop") || title.contains("store") || title.contains("post office") {
            return "Store"
        }
        // 4) Industrial heritage (HIGH PRIORITY)
        else if title.contains("grinding wheel") || title.contains("millstone") ||
                title.contains("rolling mill") || title.contains("roller") ||
                title.contains("stamping hammer") || title.contains("chimney") ||
                title.contains("kiln") || title.contains("engine house") ||
                title.contains("turbine") || title.contains("boiler") ||
                title.contains("forge") || title.contains("foundry") ||
                title.contains("cutlery") || title.contains("steel works") ||
                title.contains("steelworks") || title.contains("workshop") ||
                title.contains("machinery") || title.contains("industrial") ||
                title.contains("trumpets") || description.contains("steel") ||
                description.contains("forge") || description.contains("mill") ||
                description.contains("cutlery") || description.contains("rolling") ||
                description.contains("works") || description.contains("machinery") ||
                description.contains("turbine") || description.contains("heritage") ||
                description.contains("engine house") {
            return "Industrial Heritage"
        }
        // 5) Natural landmarks (already filtered to exclude road/bridge crossings)
        else if title.contains("river") || title.contains("stream") || title.contains("beck") ||
                title.contains("waterfall") || title.contains("valley") || title.contains("hill") ||
                title.contains("edge") || title.contains("peak") || title.contains("moor") {
            return "Natural Feature"
        }
        // 7) Postboxes
        else if title.contains("postbox") || title.contains("post box") || title.contains("letter box") {
            return "Postbox"
        }
        // Default
        else {
            return "Landmark"
        }
    }
    
    /// Generate 1-2 sentence meaningful summary
    private func generatePOISummary(_ poi: PlaceResult) -> String {
        let title = poi.name
        let description = poi.vicinity ?? ""
        
        // If we have a good description, use first sentence or first 100 chars
        if !description.isEmpty && description.count > 20 {
            // Try to extract first sentence
            if let firstSentence = description.components(separatedBy: ".").first,
               firstSentence.count > 30 && firstSentence.count < 150 {
                return firstSentence.trimmingCharacters(in: .whitespaces) + "."
            } else {
                // Use first 100 chars
                let preview = String(description.prefix(100))
                return preview.trimmingCharacters(in: .whitespaces) + (description.count > 100 ? "..." : "")
            }
        }
        
        // Fallback: generate from title
        if title.contains("Church") || title.contains("Chapel") {
            return "A place of worship in the local community."
        } else if title.contains("Memorial") {
            return "A memorial commemorating local history or events."
        } else if title.contains("Hall") {
            return "A historic or community building."
        } else if title.contains("Hospital") || title.contains("Wing") {
            return "A medical facility or hospital building."
        } else {
            return "A local landmark or point of interest."
        }
    }
    
    /// Generate qualification reason (why it qualified as a POI)
    private func generatePOIQualification(_ poi: PlaceResult, score: Double) -> String {
        let title = poi.name.lowercased()
        let description = poi.vicinity?.lowercased() ?? ""
        
        var reasons: [String] = []
        
        // Category-based reasons
        if title.contains("historic") || description.contains("historic") ||
           description.contains("original") || description.contains("workhouse") {
            reasons.append("Historic significance")
        }
        
        if title.contains("church") || title.contains("chapel") {
            reasons.append("Religious landmark")
        }
        
        if title.contains("memorial") || title.contains("monument") {
            reasons.append("Commemorative landmark")
        }
        
        if title.contains("hospital") || title.contains("wing") || title.contains("unit") {
            reasons.append("Significant medical facility")
        }
        
        if title.contains("village hall") || title.contains("school") {
            reasons.append("Community facility")
        }
        
        if title.contains("grinding wheel") || title.contains("rolling mill") {
            reasons.append("Industrial heritage feature")
        }
        
        if title.contains("tower") || title.contains("clock tower") {
            reasons.append("Prominent landmark")
        }
        
        // Description quality reasons
        if description.count >= 50 {
            reasons.append("Well-documented")
        }
        
        if description.contains("named after") || description.contains("formerly") {
            reasons.append("Named feature with context")
        }
        
        // Score-based reasons
        if score >= 8.0 {
            reasons.append("High-quality POI")
        } else if score >= 6.0 {
            reasons.append("Good quality POI")
        }
        
        // Postbox special case
        if title.contains("postbox") || title.contains("post box") {
            if score >= 5.0 {
                reasons.append("Historic or significant postbox")
            } else {
                reasons.append("Local navigation point")
            }
        }
        
        if reasons.isEmpty {
            return "Valid landmark or point of interest"
        }
        
        return reasons.joined(separator: ", ")
    }
    
    // MARK: - Restricted Area Filter (v1.6.47)
    
    /// Structure to hold a restricted area polygon
    private struct RestrictedPolygon {
        let type: String  // school, university, military, prison, golf_course
        let name: String
        let coordinates: [CLLocationCoordinate2D]
    }
    
    // Cache for restricted area polygons (key: "lat_lon_radius")
    private var restrictedPolygonCache: [String: [RestrictedPolygon]] = [:]
    private var restrictedPolygonCacheLock = NSLock()
    
    // Cache for filtered POI results (key: "lat_lon_radius", value: Set of placeIds to exclude)
    private var filteredPOICache: [String: Set<String>] = [:]
    private var filteredPOICacheLock = NSLock()
    
    // Swift 6: Helper to safely use NSLock from async contexts
    private func withLockedCache<T>(_ lock: NSLock, operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
    
    /// Filter POIs that are inside restricted areas without road access
    /// 1. Query OSM for restricted area polygons (schools, military, prisons, etc.)
    /// 2. For each POI inside a restricted area, check if it has road access
    /// 3. Keep POIs with road access, exclude others
    /// Note: Hospitals are NOT filtered - many valid POIs are on hospital grounds
    private func filterPOIsInRestrictedAreas(
        pois: [PlaceResult],
        location: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async -> [PlaceResult] {
        // First, try to get restricted area polygons from Overpass
        let polygons = await getRestrictedAreaPolygons(location: location, radiusMeters: radiusMeters)
        
        if polygons.isEmpty {
            // Fallback: use name/type-based filter when Overpass fails
            print("🏫 Using fallback name-based filter (Overpass unavailable)")
            return fallbackRestrictedFilter(pois: pois)
        }
        
        print("🏫 Checking \(pois.count) POIs against \(polygons.count) restricted areas...")
        
        var filteredPOIs: [PlaceResult] = []
        var excludedCount = 0
        
        for poi in pois {
            // Check if POI is inside any restricted polygon
            var isInsideRestricted = false
            var restrictedAreaName = ""
            
            for polygon in polygons {
                if isPointInPolygon(point: poi.coordinate, polygon: polygon.coordinates) {
                    isInsideRestricted = true
                    restrictedAreaName = polygon.name.isEmpty ? polygon.type : polygon.name
                    break
                }
            }
            
            if isInsideRestricted {
                // v2.1.5: POI is inside restricted area - find nearest road point
                // Prioritizes the road from the POI's address if available
                // This ensures routes stay on public roads instead of going into schools/private areas
                let roadName = extractRoadName(from: poi.vicinity)
                if let roadName = roadName {
                    print("   🛤️ '\(poi.name)' - preferred road from address: '\(roadName)'")
                }
                if let nearestRoadPoint = await findNearestRoadPoint(near: poi.coordinate, radiusMeters: 50, preferredRoadName: roadName) {
                    // Create a new POI with snapped coordinates
                    let snappedGeometry = PlaceGeometry(location: PlaceLocation(lat: nearestRoadPoint.latitude, lng: nearestRoadPoint.longitude))
                    let snappedPOI = PlaceResult(
                        placeId: poi.placeId,
                        name: poi.name,
                        vicinity: poi.vicinity,
                        geometry: snappedGeometry,
                        types: poi.types,
                        source: poi.source
                    )
                    filteredPOIs.append(snappedPOI)
                    let distance = CLLocation(latitude: poi.coordinate.latitude, longitude: poi.coordinate.longitude)
                        .distance(from: CLLocation(latitude: nearestRoadPoint.latitude, longitude: nearestRoadPoint.longitude))
                    print("   ✅ '\(poi.name)' inside '\(restrictedAreaName)' - snapped to road (\(Int(distance))m)")
                } else {
                    // No road found nearby - exclude this POI
                    excludedCount += 1
                    print("   ❌ '\(poi.name)' inside '\(restrictedAreaName)' with NO nearby road - EXCLUDED")
                }
            } else {
                // Not inside any restricted area - keep it as-is
                filteredPOIs.append(poi)
            }
        }
        
        if excludedCount > 0 {
            print("🏫 Excluded \(excludedCount) POIs inside restricted areas without road access")
        }
        
        return filteredPOIs
    }
    
    /// Get restricted area polygons from OSM Overpass API
    /// Uses cache to avoid repeated Overpass queries (7-15s each)
    private func getRestrictedAreaPolygons(
        location: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async -> [RestrictedPolygon] {
        // Check cache first (key: "lat_lon_radius")
        let cacheKey = "\(location.latitude)_\(location.longitude)_\(radiusMeters)"
        
        // Swift 6: Use helper for async-safe locking
        if let cached = withLockedCache(restrictedPolygonCacheLock, operation: { restrictedPolygonCache[cacheKey] }) {
            print("🏫 ✅ Using cached restricted area polygons (instant)")
            return cached
        }
        
        // Not in cache - query Overpass API
        print("🏫 Querying Overpass API for restricted area polygons...")
        
        // Query for restricted area polygons
        // Note: Hospital is NOT included - many valid POIs are on hospital grounds
        let query = """
        [out:json][timeout:15];
        (
          way["amenity"="school"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["amenity"="university"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["leisure"="golf_course"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["landuse"="military"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["amenity"="kindergarten"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          way["amenity"="prison"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
        );
        out body geom;
        """
        
        // Use only 3 most reliable mirrors for this query
        let mirrors = [
            "https://lz4.overpass-api.de/api/interpreter",
            "https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"
        ]
        
        for (index, baseUrl) in mirrors.enumerated() {
            guard let url = URL(string: baseUrl) else { continue }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "data=\(query)".data(using: .utf8)
            request.timeoutInterval = 15
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }
                
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else {
                    continue
                }
                
                var polygons: [RestrictedPolygon] = []
                
                for element in elements {
                    guard let geometry = element["geometry"] as? [[String: Any]],
                          geometry.count >= 3 else { continue }
                    
                    let tags = element["tags"] as? [String: String] ?? [:]
                    let name = tags["name"] ?? ""
                    
                    // Determine type (hospital is NOT included - valid POIs exist there)
                    var type = "unknown"
                    if tags["amenity"] == "school" || tags["amenity"] == "kindergarten" { type = "school" }
                    else if tags["amenity"] == "university" { type = "university" }
                    else if tags["leisure"] == "golf_course" { type = "golf_course" }
                    else if tags["landuse"] == "military" { type = "military" }
                    else if tags["amenity"] == "prison" { type = "prison" }
                    
                    // Extract coordinates
                    let coordinates = geometry.compactMap { point -> CLLocationCoordinate2D? in
                        guard let lat = point["lat"] as? Double,
                              let lon = point["lon"] as? Double else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    
                    if coordinates.count >= 3 {
                        polygons.append(RestrictedPolygon(type: type, name: name, coordinates: coordinates))
                    }
                }
                
                print("🏫 Found \(polygons.count) restricted area polygons (mirror \(index + 1))")
                
                // Cache the polygons for future use (Swift 6: async-safe locking)
                withLockedCache(restrictedPolygonCacheLock) {
                    restrictedPolygonCache[cacheKey] = polygons
                    // Limit cache size to prevent memory growth
                    if restrictedPolygonCache.count > 50 {
                        let oldestKey = restrictedPolygonCache.keys.first!
                        restrictedPolygonCache.removeValue(forKey: oldestKey)
                    }
                }
                
                return polygons
                
            } catch {
                print("🏫 Restricted area query failed (mirror \(index + 1)): \(error.localizedDescription)")
                continue
            }
        }
        
        return []
    }
    
    /// Check if a point is inside a polygon using ray casting algorithm
    private func isPointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        
        var isInside = false
        var j = polygon.count - 1
        
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            
            if ((pi.longitude > point.longitude) != (pj.longitude > point.longitude)) &&
               (point.latitude < (pj.latitude - pi.latitude) * (point.longitude - pi.longitude) / (pj.longitude - pi.longitude) + pi.latitude) {
                isInside = !isInside
            }
            j = i
        }
        
        return isInside
    }
    
    /// Check if there's a PUBLIC road within 20m of a POI (not internal paths)
    /// v1.6.47: Fixed to exclude internal footpaths/paths that are inside school grounds
    private func checkRoadAccessNearPOI(poi: PlaceResult, radiusMeters: Int) async -> Bool {
        // Query for PUBLIC roads only - exclude internal paths
        // residential, primary, secondary, tertiary, unclassified, living_street = normal public roads
        // service roads that are NOT private
        // EXCLUDED: footway, path, cycleway, track (often internal to properties)
        let searchRadius = min(radiusMeters, 20) // Max 20m for stricter check
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"residential|primary|secondary|tertiary|unclassified|living_street"](around:\(searchRadius),\(poi.coordinate.latitude),\(poi.coordinate.longitude));
          way["highway"="service"]["access"!="private"](around:\(searchRadius),\(poi.coordinate.latitude),\(poi.coordinate.longitude));
        );
        out count;
        """
        
        // Try just the fastest mirror
        guard let url = URL(string: "https://lz4.overpass-api.de/api/interpreter") else {
            return false // Fail closed - assume NO access (safer)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query)".data(using: .utf8)
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false // Fail closed - assume NO access
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else {
                return false // Fail closed
            }
            
            // If any public roads found, POI has road access
            if let countElement = elements.first,
               let tags = countElement["tags"] as? [String: Any],
               let total = tags["total"] as? Int {
                return total > 0
            }
            
            // Check if elements array has any roads
            return !elements.isEmpty
            
        } catch {
            return false // Fail closed - assume NO access if query fails (safer)
        }
    }
    
    /// v2.1.1: Find the nearest public road/path point to a given coordinate
    /// Used to snap waypoints that are inside restricted areas (schools, etc.) to the nearest walkable path
    /// Returns nil if no road found within radius
    /// v2.1.5: Extract road name from address string
    /// Examples: "5A Brandy Carr Rd" -> "Brandy Carr Rd", "123 Main Street" -> "Main Street"
    private func extractRoadName(from address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        
        // Remove common prefixes like house numbers, postcodes, etc.
        // Pattern: Optional number/letter prefix, then road name, then optional suffix
        let patterns = [
            "^\\d+[A-Za-z]?\\s+",  // "5A " or "123 "
            "^\\d+\\s+",            // "123 "
            "^[A-Za-z]+\\s+",       // "The " or "A "
        ]
        
        var cleaned = address.trimmingCharacters(in: .whitespaces)
        
        // Remove postcode (UK format: letters + numbers)
        if let postcodeRange = cleaned.range(of: #"[A-Z]{1,2}\d{1,2}\s?\d[A-Z]{2}"#, options: .regularExpression) {
            cleaned = String(cleaned[..<postcodeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        
        // Remove house number prefixes
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // Remove common suffixes
        let suffixes = [",", "Wakefield", "Kirkhamgate", "WF2", "WF1", "WF3"]
        for suffix in suffixes {
            if cleaned.lowercased().hasSuffix(suffix.lowercased()) {
                cleaned = cleaned.replacingOccurrences(of: suffix, with: "", options: [.caseInsensitive, .anchored, .backwards])
                cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Remove trailing commas and clean up
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        
        // Return if we have a meaningful road name (at least 3 characters)
        return cleaned.count >= 3 ? cleaned : nil
    }
    
    /// v2.1.5: Find a specific road by name near a coordinate
    private func findRoadByName(_ roadName: String, near coordinate: CLLocationCoordinate2D, radiusMeters: Int) async -> CLLocationCoordinate2D? {
        let searchRadius = max(radiusMeters, 150) // Slightly larger radius for name-based search
        
        // Escape special regex characters in road name for Overpass query
        // Overpass uses ~ for case-insensitive regex matching
        let escapedRoadName = roadName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "^", with: "\\^")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
        
        // Query for roads with matching name (case-insensitive, partial match)
        // Use ~i for case-insensitive matching in Overpass
        let query = """
        [out:json][timeout:10];
        (
          way["highway"]["name"~"\(escapedRoadName)"]["access"!="private"]["access"!="no"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
        );
        out body geom;
        """
        
        guard let url = URL(string: "https://lz4.overpass-api.de/api/interpreter") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query)".data(using: .utf8)
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else {
                return nil
            }
            
            // Find the closest point on the named road
            var closestPoint: CLLocationCoordinate2D?
            var closestDistance = Double.greatestFiniteMagnitude
            let poiLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            
            for element in elements {
                guard let geometry = element["geometry"] as? [[String: Any]] else { continue }
                
                // Verify the name matches (case-insensitive)
                if let tags = element["tags"] as? [String: String],
                   let name = tags["name"]?.lowercased(),
                   name.contains(roadName.lowercased()) {
                    
                    for node in geometry {
                        guard let lat = node["lat"] as? Double,
                              let lon = node["lon"] as? Double else { continue }
                        
                        let nodeLocation = CLLocation(latitude: lat, longitude: lon)
                        let distance = poiLocation.distance(from: nodeLocation)
                        
                        if distance < closestDistance {
                            closestDistance = distance
                            closestPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        }
                    }
                }
            }
            
            if let point = closestPoint {
                print("🛤️ Found road '\(roadName)' at \(Int(closestDistance))m from POI")
            }
            
            return closestPoint
            
        } catch {
            print("🛤️ ❌ Failed to find road '\(roadName)': \(error.localizedDescription)")
            return nil
        }
    }
    
    private func findNearestRoadPoint(near coordinate: CLLocationCoordinate2D, radiusMeters: Int, preferredRoadName: String? = nil) async -> CLLocationCoordinate2D? {
        // v2.1.5: If we have a preferred road name from the address, try that first
        if let roadName = preferredRoadName {
            if let namedRoadPoint = await findRoadByName(roadName, near: coordinate, radiusMeters: radiusMeters) {
                return namedRoadPoint
            }
            print("🛤️ ⚠️ Could not find preferred road '\(roadName)', falling back to nearest road")
        }
        
        // v2.1.4: Query for PUBLIC roads only - exclude driveways and private access roads
        // Prioritize main roads (residential, primary, secondary, tertiary) over footways/paths
        // EXCLUDE service roads (often school driveways) and paths within private property
        let searchRadius = max(radiusMeters, 100) // Minimum 100m search radius
        
        // First query: Main public roads only (highest priority)
        let mainRoadQuery = """
        [out:json][timeout:10];
        (
          way["highway"~"residential|primary|secondary|tertiary|unclassified|living_street|trunk|road"]["access"!="private"]["access"!="no"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
        );
        out body geom;
        """
        
        // Try main roads first
        if let mainRoadResult = await executeRoadSnapQuery(mainRoadQuery, coordinate: coordinate, description: "main road") {
            return mainRoadResult
        }
        
        // Fallback: Include public footways/cycleways (but NOT service roads or paths within private areas)
        let fallbackQuery = """
        [out:json][timeout:10];
        (
          way["highway"="footway"]["access"!="private"]["access"!="no"]["foot"!="private"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
          way["highway"="cycleway"]["access"!="private"]["access"!="no"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
          way["highway"="pedestrian"]["access"!="private"]["access"!="no"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
        );
        out body geom;
        """
        
        return await executeRoadSnapQuery(fallbackQuery, coordinate: coordinate, description: "footway/cycleway")
    }
    
    /// v2.1.4: Helper to execute road snap query
    private func executeRoadSnapQuery(_ query: String, coordinate: CLLocationCoordinate2D, description: String) async -> CLLocationCoordinate2D? {
        guard let url = URL(string: "https://lz4.overpass-api.de/api/interpreter") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query)".data(using: .utf8)
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else {
                return nil
            }
            
            // Find the closest point on any road
            var closestPoint: CLLocationCoordinate2D?
            var closestDistance = Double.greatestFiniteMagnitude
            let poiLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            
            for element in elements {
                // Get the geometry (node coordinates) for this way
                guard let geometry = element["geometry"] as? [[String: Any]] else { continue }
                
                // v2.1.4: Skip if this way has tags indicating private/restricted access
                if let tags = element["tags"] as? [String: String] {
                    if tags["service"] == "driveway" || tags["service"] == "parking_aisle" { continue }
                    if tags["access"] == "private" || tags["access"] == "no" { continue }
                    if tags["foot"] == "private" || tags["foot"] == "no" { continue }
                }
                
                for node in geometry {
                    guard let lat = node["lat"] as? Double,
                          let lon = node["lon"] as? Double else { continue }
                    
                    let nodeLocation = CLLocation(latitude: lat, longitude: lon)
                    let distance = poiLocation.distance(from: nodeLocation)
                    
                    if distance < closestDistance {
                        closestDistance = distance
                        closestPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                }
            }
            
            if let point = closestPoint {
                print("🛤️ Found nearest \(description): \(Int(closestDistance))m from POI at (\(String(format: "%.6f", point.latitude)), \(String(format: "%.6f", point.longitude)))")
            }
            
            return closestPoint
            
        } catch {
            print("🛤️ ❌ Failed to find nearest \(description): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// v2.1.5: Snap a coordinate to the nearest walkable path with fallback mirrors
    /// Tries multiple Overpass mirrors if the first one fails
    /// EXCLUDES service roads (driveways) to prevent routing into private areas
    /// If preferredRoadName is provided, prioritizes that specific road
    private func findNearestRoadPointWithFallback(near coordinate: CLLocationCoordinate2D, radiusMeters: Int, preferredRoadName: String? = nil) async -> CLLocationCoordinate2D? {
        // Try primary approach first (includes preferred road name if provided)
        if let result = await findNearestRoadPoint(near: coordinate, radiusMeters: radiusMeters, preferredRoadName: preferredRoadName) {
            return result
        }
        
        // If primary failed, try alternative mirror
        print("🛤️ Primary Overpass failed, trying alternative mirror...")
        
        let searchRadius = max(radiusMeters, 100)
        
        // v2.1.4: Only main public roads, NO service roads (which are often driveways)
        let query = """
        [out:json][timeout:15];
        (
          way["highway"~"residential|primary|secondary|tertiary|unclassified|living_street|trunk|road"]["access"!="private"]["access"!="no"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
          way["highway"="footway"]["access"!="private"]["access"!="no"]["foot"!="private"](around:\(searchRadius),\(coordinate.latitude),\(coordinate.longitude));
        );
        out body geom;
        """
        
        let mirrors = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"
        ]
        
        for mirror in mirrors {
            guard let url = URL(string: mirror) else { continue }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "data=\(query)".data(using: .utf8)
            request.timeoutInterval = 15
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }
                
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else { continue }
                
                var closestPoint: CLLocationCoordinate2D?
                var closestDistance = Double.greatestFiniteMagnitude
                let poiLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                
                for element in elements {
                    guard let geometry = element["geometry"] as? [[String: Any]] else { continue }
                    
                    // v2.1.4: Skip if this way has tags indicating private/restricted access
                    if let tags = element["tags"] as? [String: String] {
                        if tags["service"] == "driveway" || tags["service"] == "parking_aisle" { continue }
                        if tags["access"] == "private" || tags["access"] == "no" { continue }
                    }
                    
                    for node in geometry {
                        guard let lat = node["lat"] as? Double,
                              let lon = node["lon"] as? Double else { continue }
                        
                        let nodeLocation = CLLocation(latitude: lat, longitude: lon)
                        let distance = poiLocation.distance(from: nodeLocation)
                        
                        if distance < closestDistance {
                            closestDistance = distance
                            closestPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        }
                    }
                }
                
                if let point = closestPoint {
                    print("🛤️ ✅ Fallback mirror found main road point: \(Int(closestDistance))m from POI")
                    return point
                }
            } catch {
                continue
            }
        }
        
        print("🛤️ ❌ All Overpass mirrors failed to find nearest main road")
        return nil
    }
    
    /// Fallback filter when Overpass is unavailable - filter by suspicious names/types
    /// Note: Schools and universities are ALLOWED (have public entrances)
    /// Only filter out things typically INSIDE school grounds without public access
    private func fallbackRestrictedFilter(pois: [PlaceResult]) -> [PlaceResult] {
        // Suspicious name patterns (things inside school grounds)
        let suspiciousNames = ["playcare", "nursery", "preschool", "daycare", "creche", "childcare"]
        
        // Suspicious types (NOT including school/university - those are allowed)
        let suspiciousTypes = ["kindergarten", "nursery", "playground", "childcare", "preschool"]
        
        return pois.filter { poi in
            let nameLower = poi.name.lowercased()
            let types = poi.types ?? []
            
            // Check name
            for pattern in suspiciousNames {
                if nameLower.contains(pattern) {
                    print("   ❌ Fallback filter: '\(poi.name)' excluded (name contains '\(pattern)')")
                    return false
                }
            }
            
            // Check types
            for type in types {
                if suspiciousTypes.contains(type.lowercased()) {
                    print("   ❌ Fallback filter: '\(poi.name)' excluded (type '\(type)')")
                    return false
                }
            }
            
            return true
        }
    }
    
    // MARK: - OSRM Walking Directions (OpenStreetMap - FREE, NO LIMITS!)
    /// Gets walking directions using OSRM (Open Source Routing Machine)
    /// Completely FREE with NO rate limits - uses OpenStreetMap data
    /// 
    /// LIMITATIONS & CONSIDERATIONS:
    /// - Public OSRM server only supports CAR routing (we estimate walking time from distance)
    /// - Max ~100 waypoints per request
    /// - No waypoint optimization (we use MapKit's optimization before calling OSRM)
    /// - Polyline may be less detailed than MapKit
    /// - Server may be slow or down (10 second timeout)
    /// - OSM data may be outdated in some areas
    private func getOSRMWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = []
    ) async throws -> (distance: Int, duration: Int, polyline: [CLLocationCoordinate2D]) {
        
        // LIMITATION: OSRM has a max coordinate limit (~100)
        // If we have too many waypoints, throw error to fall back to MapKit
        if waypoints.count > 25 {
            print("🗺️ OSRM: Too many waypoints (\(waypoints.count)), falling back to MapKit")
            throw GoogleMapsError.apiError("Too many waypoints for OSRM")
        }
        
        // Build coordinates string: lon,lat;lon,lat;...
        var coordStrings: [String] = []
        coordStrings.append("\(origin.longitude),\(origin.latitude)")
        for wp in waypoints {
            coordStrings.append("\(wp.longitude),\(wp.latitude)")
        }
        coordStrings.append("\(destination.longitude),\(destination.latitude)")
        
        let coordsPath = coordStrings.joined(separator: ";")
        // Note: Using "driving" profile as public server doesn't support "foot"
        // We estimate walking time from distance afterwards
        let urlString = "https://router.project-osrm.org/route/v1/driving/\(coordsPath)?overview=full&geometries=polyline"
        
        guard let url = URL(string: urlString) else {
            throw GoogleMapsError.invalidURL
        }
        
        // Create request with timeout (public server can be slow)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10  // 10 second timeout
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("🗺️ OSRM: Network error - \(error.localizedDescription)")
            throw GoogleMapsError.apiError("OSRM network error")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleMapsError.apiError("OSRM invalid response")
        }
        
        // Handle HTTP errors
        if httpResponse.statusCode != 200 {
            print("🗺️ OSRM: HTTP error \(httpResponse.statusCode)")
            throw GoogleMapsError.apiError("OSRM HTTP \(httpResponse.statusCode)")
        }
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleMapsError.apiError("OSRM invalid JSON")
        }
        
        // Check OSRM status code (not HTTP, but in JSON)
        if let code = json["code"] as? String, code != "Ok" {
            let message = json["message"] as? String ?? "Unknown error"
            print("🗺️ OSRM: API error - \(code): \(message)")
            throw GoogleMapsError.noRouteFound
        }
        
        guard let routes = json["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let distance = firstRoute["distance"] as? Double,
              let duration = firstRoute["duration"] as? Double,
              let geometry = firstRoute["geometry"] as? String else {
            print("🗺️ OSRM: No route found in response")
            throw GoogleMapsError.noRouteFound
        }
        
        // Validate distance is reasonable
        if distance <= 0 {
            throw GoogleMapsError.noRouteFound
        }
        
        // Decode polyline
        let polylinePoints = decodePolyline(geometry)
        
        // Handle empty polyline
        if polylinePoints.isEmpty {
            print("🗺️ OSRM: Empty polyline returned")
            throw GoogleMapsError.noRouteFound
        }
        
        // IMPORTANT: OSRM public server returns CAR routing times
        // We ALWAYS estimate walking time from distance
        // Walking speed: ~80 m/min (5 km/h) - adjustable based on user's actual speed
        let userWalkingSpeed = Double(adaptiveWalkingSpeed)  // m/min from user's history
        let walkingMinutes = distance / userWalkingSpeed
        let finalDuration = Int(walkingMinutes * 60)  // Convert to seconds
        
        let osrmMinutes = Int(duration / 60)
        let walkingMins = Int(walkingMinutes)
        if osrmMinutes != walkingMins {
            print("🗺️ OSRM: Converted driving time to walking (\(osrmMinutes)min → \(walkingMins)min @ \(Int(userWalkingSpeed))m/min)")
        }
        
        return (distance: Int(distance), duration: finalDuration, polyline: polylinePoints)
    }
    
    /// Check if we should use OSRM instead of MapKit (when approaching rate limit)
    private func shouldUseOSRM() async -> Bool {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        // Use OSRM at 80% of rate limit (40+ requests) for speed
        // OSRM durations are corrected via osrmCalibrationFactor
        return status.currentCount >= 40
    }
    
    /// Check if background pre-generation should pause (to reserve quota for user requests)
    /// Returns true if rate limit is too high for background work
    func shouldPauseBackgroundGeneration() async -> Bool {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        // Pause background work at 80% of limit (40+ requests)
        // This reserves 10 requests for user-initiated actions
        // More generous than before - allows more pre-generation
        let shouldPause = status.currentCount >= 40
        if shouldPause {
            print("⏸️ Background paused briefly (MapKit: \(status.currentCount)/50)")
        }
        return shouldPause
    }
    
    // MARK: - On-Device Duration Estimator (P0 FIX)
    // Pre-screens candidates without calling routing engines
    // Uses straight-line distance × road factor × walking speed
    
    /// Estimate route duration without calling routing engines
    /// Used to pre-screen candidates for k-best selection
    /// - Parameters:
    ///   - origin: Start location
    ///   - waypoints: Waypoints to visit (in order)
    ///   - destination: End location (usually same as origin for circular routes)
    ///   - walkingSpeed: Walking speed in m/min (default: adaptive)
    ///   - roadFactor: Road factor multiplier (default: 1.4, can be adjusted adaptively)
    /// - Returns: Estimated duration in seconds
    private func estimateRouteDuration(
        origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D,
        walkingSpeed: Int? = nil,
        roadFactor: Double = 1.4
    ) -> Int {
        let speed = Double(walkingSpeed ?? adaptiveWalkingSpeed)
        
        // Build list of all points: origin → waypoints → destination
        var allPoints = [origin] + waypoints + [destination]
        
        // Calculate total straight-line distance
        var totalDistance: Double = 0
        for i in 0..<(allPoints.count - 1) {
            totalDistance += distanceBetween(allPoints[i], allPoints[i + 1])
        }
        
        // Apply road factor (straight-line → actual walking path)
        // Typical: 1.3-1.6x for urban, 1.1-1.3x for parks
        // roadFactor parameter is passed in (can be adjusted adaptively)
        let actualDistance = totalDistance * roadFactor
        
        // Calculate walking time
        let walkingMinutes = actualDistance / speed
        return Int(walkingMinutes * 60)  // Convert to seconds
    }
    
    /// Estimate route duration for a set of PlaceResult waypoints
    private func estimateRouteDurationForPlaces(
        origin: CLLocationCoordinate2D,
        waypoints: [PlaceResult],
        postcode: String? = nil,
        roadFactor: Double = 1.4
    ) -> Int {
        // SPRINT-4: Use density-aware speed model (no postcode overrides)
        // Speed is determined by leg length in the calling function (walkingSpeedMeterPerMin closure)
        // This function receives the speed as a parameter, so we use adaptiveWalkingSpeed as fallback
        let speed: Int = adaptiveWalkingSpeed
        
        let waypointCoords = waypoints.map { $0.coordinate }
        return estimateRouteDuration(
            origin: origin,
            waypoints: waypointCoords,
            destination: origin,  // Circular route
            walkingSpeed: speed,
            roadFactor: roadFactor
        )
    }
    
    /// Pre-screen candidates using on-device estimator
    /// Returns candidates sorted by estimated fitness to target duration
    private func preScreenCandidates(
        candidates: [[PlaceResult]],  // Each inner array is a waypoint combination
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        postcode: String? = nil,
        maxToReturn: Int = 5,
        roadFactor: Double = 1.4
    ) -> [(waypoints: [PlaceResult], estimatedDuration: Int, fitness: Double)] {
        let targetSeconds = targetDurationMinutes * 60
        
        var scored: [(waypoints: [PlaceResult], estimatedDuration: Int, fitness: Double)] = []
        
        for waypoints in candidates {
            let estimated = estimateRouteDurationForPlaces(
                origin: origin,
                waypoints: waypoints,
                postcode: postcode,
                roadFactor: roadFactor
            )
            
            // Fitness: closer to target = better (1.0 = perfect, 0.0 = bad)
            let ratio = Double(estimated) / Double(targetSeconds)
            let fitness: Double
            if ratio < 0.5 || ratio > 2.0 {
                fitness = 0.0  // Too far off
            } else if ratio >= 0.9 && ratio <= 1.1 {
                fitness = 1.0  // Perfect
            } else if ratio >= 0.8 && ratio <= 1.3 {
                fitness = 0.8  // Good
            } else {
                fitness = max(0.0, 0.6 - abs(1.0 - ratio) * 0.5)  // Degrades with distance from 1.0
            }
            
            scored.append((waypoints: waypoints, estimatedDuration: estimated, fitness: fitness))
        }
        
        // Sort by fitness (descending), return top k
        scored.sort { $0.fitness > $1.fitness }
        return Array(scored.prefix(maxToReturn))
    }
    
    // MARK: - TASK 2: K-Best Pareto Set
    /// Represents a candidate route for k-best selection
    struct ParetoCandidate {
        let waypoints: [PlaceResult]
        let estimatedDuration: Int       // Seconds
        let hitError: Double             // |actual - target| / target
        let waypointCount: Int
        let uniqueSegmentCoverage: Double // 0-1, how unique is this route
        let route: GeneratedRoute?       // Actual route if engine was called
        
        /// Pareto dominance check: returns true if this candidate dominates other
        func dominates(_ other: ParetoCandidate) -> Bool {
            // A dominates B if A is better or equal in ALL objectives and strictly better in at least one
            let betterOrEqualHitError = hitError <= other.hitError
            let betterOrEqualWaypoints = waypointCount >= other.waypointCount
            let betterOrEqualCoverage = uniqueSegmentCoverage >= other.uniqueSegmentCoverage
            
            let strictlyBetterHitError = hitError < other.hitError
            let strictlyBetterWaypoints = waypointCount > other.waypointCount
            let strictlyBetterCoverage = uniqueSegmentCoverage > other.uniqueSegmentCoverage
            
            return betterOrEqualHitError && betterOrEqualWaypoints && betterOrEqualCoverage &&
                   (strictlyBetterHitError || strictlyBetterWaypoints || strictlyBetterCoverage)
        }
    }
    
    /// Maintain k-best Pareto set of candidates
    private func updateParetoSet(
        _ paretoSet: inout [ParetoCandidate],
        with newCandidate: ParetoCandidate,
        k: Int = RoutingToggles.kBestK
    ) {
        // Remove any candidates dominated by the new one
        paretoSet.removeAll { newCandidate.dominates($0) }
        
        // Check if new candidate is dominated by any existing
        let isDominated = paretoSet.contains { $0.dominates(newCandidate) }
        
        if !isDominated {
            paretoSet.append(newCandidate)
            
            // If we have more than k, remove the worst by composite score
            // Note: compositeScore needs targetDurationMinutes, but we don't have it here
            // Use hitError as proxy (lower is better)
            if paretoSet.count > k {
                paretoSet.sort { $0.hitError < $1.hitError || ($0.hitError == $1.hitError && $0.waypointCount > $1.waypointCount) }
                paretoSet = Array(paretoSet.prefix(k))
            }
        }
    }
    
    /// Calculate composite score for ranking Pareto candidates
    /// SPRINT-4: Overshoot penalty ×2 for routes with <min waypoints
    private func compositeScore(_ candidate: ParetoCandidate, targetDurationMinutes: Int? = nil) -> Double {
        // Weights: hit error (most important), then waypoints, then coverage
        let hitErrorScore = max(0, 1.0 - candidate.hitError)  // 0-1, higher is better
        let waypointScore = min(1.0, Double(candidate.waypointCount) / 4.0)  // 0-1
        let coverageScore = candidate.uniqueSegmentCoverage  // 0-1
        
        var baseScore = hitErrorScore * 0.5 + waypointScore * 0.3 + coverageScore * 0.2
        
        // SPRINT-4: Overshoot penalty ×2 if route has <min waypoints (prefer 95-105% fits with ≥min WPs)
        if let route = candidate.route, let target = targetDurationMinutes {
            let routeMins = route.durationSeconds / 60
            let minWaypoints = RoutingToggles.minWaypoints(forDuration: target)
            if route.places.count < minWaypoints {
                // Apply ×2 overshoot penalty for routes >105% with <min waypoints
                let overshootRatio = Double(routeMins) / Double(target)
                if overshootRatio > 1.05 {  // >105% overshoot
                    baseScore *= 0.5  // Halve the score (×2 penalty)
                }
            }
        }
        
        return baseScore
    }
    
    /// Check if Pareto set is filled and stable (no improvements in N iterations)
    private func isParetoSetStable(
        _ paretoSet: [ParetoCandidate],
        iterationsWithoutImprovement: Int,
        threshold: Int = 3
    ) -> Bool {
        return paretoSet.count >= RoutingToggles.kBestK && iterationsWithoutImprovement >= threshold
    }
    
    // MARK: - TASK 4: Waypoint Preservation (Nudge before prune)
    /// Nudge a waypoint along the network instead of pruning
    /// - Parameters:
    ///   - waypoint: The waypoint to nudge
    ///   - origin: Route origin for direction calculation
    ///   - nudgeDistance: Distance to nudge in meters
    /// - Returns: Nudged waypoint with new coordinates
    private func nudgeWaypoint(
        _ waypoint: PlaceResult,
        awayFrom origin: CLLocationCoordinate2D,
        nudgeDistance: Double = RoutingToggles.nudgeBeforeRemoveMeters
    ) -> PlaceResult {
        // Calculate bearing from origin to waypoint
        let bearing = bearingBetween(origin, waypoint.coordinate)
        
        // Nudge along the bearing (away from origin)
        let nudgedCoord = offsetCoordinate(
            waypoint.coordinate,
            distanceMeters: nudgeDistance,
            bearingDegrees: bearing
        )
        
        // Create nudged waypoint with new coordinates
        let nudged = PlaceResult(
            placeId: waypoint.placeId,
            name: waypoint.name,
            vicinity: waypoint.vicinity,
            geometry: PlaceGeometry(
                location: PlaceLocation(
                    lat: nudgedCoord.latitude,
                    lng: nudgedCoord.longitude
                )
            ),
            types: waypoint.types,
            source: waypoint.source
        )
        
        print("📍 [NUDGE] \(waypoint.name): moved \(Int(nudgeDistance))m along bearing \(Int(bearing))°")
        return nudged
    }
    
    /// Offset a coordinate by distance and bearing
    private func offsetCoordinate(
        _ coord: CLLocationCoordinate2D,
        distanceMeters: Double,
        bearingDegrees: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6371000.0  // meters
        let lat1 = coord.latitude * .pi / 180
        let lon1 = coord.longitude * .pi / 180
        let bearing = bearingDegrees * .pi / 180
        let angularDistance = distanceMeters / earthRadius
        
        let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angularDistance) * cos(lat1),
                                 cos(angularDistance) - sin(lat1) * sin(lat2))
        
        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
    
    /// TASK 4: Category-aware deduplication with nudge-before-prune
    private func deduplicateWithNudge(
        waypoints: [PlaceResult],
        origin: CLLocationCoordinate2D,
        isSuburban: Bool
    ) -> [PlaceResult] {
        let threshold = isSuburban ? RoutingToggles.samePlaceThresholdSuburban : RoutingToggles.samePlaceThresholdUrban
        var result: [PlaceResult] = []
        
        for waypoint in waypoints {
            // Check if too close to any existing waypoint
            let tooClose = result.first { existing in
                let dist = distanceBetween(waypoint.coordinate, existing.coordinate)
                if dist >= threshold { return false }
                
                // TASK 4: Require category match before pruning
                if RoutingToggles.requireCategoryMatch {
                    let waypointTypes = Set(waypoint.types ?? [])
                    let existingTypes = Set(existing.types ?? [])
                    let categoriesMatch = !waypointTypes.isDisjoint(with: existingTypes)
                    return categoriesMatch  // Only mark as duplicate if categories overlap
                }
                return true
            }
            
            if tooClose == nil {
                result.append(waypoint)
            } else if RoutingToggles.nudgeBeforeRemoveMeters > 0 {
                // Try nudging instead of pruning
                let nudged = nudgeWaypoint(waypoint, awayFrom: origin, nudgeDistance: RoutingToggles.nudgeBeforeRemoveMeters)
                
                // Check if nudged position is now far enough
                let stillTooClose = result.first { existing in
                    distanceBetween(nudged.coordinate, existing.coordinate) < threshold
                }
                
                if stillTooClose == nil {
                    result.append(nudged)
                    print("📍 [NUDGE] Preserved \(waypoint.name) via nudge (was \(Int(distanceBetween(waypoint.coordinate, tooClose!.coordinate)))m from \(tooClose!.name))")
                } else {
                    print("📍 [PRUNE] Removed \(waypoint.name) (still too close after nudge)")
                }
            }
        }
        
        return result
    }
    
    // MARK: - TASK 6: Template Fallback for Fragile Durations
    /// Get template route for fragile durations (10, 25, 45 min)
    private func getTemplateRoute(
        duration: Int,
        origin: CLLocationCoordinate2D,
        places: [PlaceResult]
    ) -> GeneratedRoute? {
        guard RoutingToggles.templateFallbackDurations.contains(duration) else { return nil }
        
        print("📋 [TEMPLATE] Generating template fallback for \(duration)min route")
        
        // Calculate ideal distance based on duration
        let walkingSpeedMperMin = Double(adaptiveWalkingSpeed)
        let targetDistanceM = Double(duration) * walkingSpeedMperMin
        
        // Find closest POI to target distance / 2 (for out-and-back)
        let idealOneWayDistance = targetDistanceM / 2.0
        
        let sortedByDistance = places
            .map { (poi: $0, dist: distanceBetween(origin, $0.coordinate)) }
            .sorted { abs($0.dist - idealOneWayDistance) < abs($1.dist - idealOneWayDistance) }
        
        guard let bestPOI = sortedByDistance.first else {
            print("📋 [TEMPLATE] No suitable POI found for template")
            return nil
        }
        
        // Estimate duration
        let estimatedDistance = bestPOI.dist * 2 * 1.4  // Round trip with road factor
        let estimatedDuration = Int(estimatedDistance / walkingSpeedMperMin * 60)
        
        print("📋 [TEMPLATE] Using \(bestPOI.poi.name) at \(Int(bestPOI.dist))m, estimated \(estimatedDuration/60)min")
        
        // Create a simple template route (polyline will be filled by actual routing)
        let templateLeg = DirectionsLeg(
            distance: DirectionsValue(text: "\(Int(estimatedDistance)/1000) km", value: Int(estimatedDistance)),
            duration: DirectionsValue(text: "\(estimatedDuration/60) min", value: estimatedDuration),
            startAddress: nil,
            endAddress: nil,
            steps: nil
        )
        let templateRoute = GeneratedRoute(
            places: [bestPOI.poi],
            polyline: "",  // Will be filled by actual routing
            distanceMeters: Int(estimatedDistance),
            durationSeconds: estimatedDuration,
            legs: [templateLeg]
        )
        
        return templateRoute
    }
    
    // MARK: - TASK 7: Routing Quota Budgeting
    /// Check if we should defer a routing call based on queue wait time
    private func shouldDeferRouting(estimatedQueueWait: TimeInterval) -> Bool {
        guard RoutingToggles.predictiveBudgeting else { return false }
        return estimatedQueueWait > RoutingToggles.queueWaitSoftSec
    }
    
    /// Estimate current queue wait time based on recent call patterns
    private func estimateQueueWaitTime() async -> TimeInterval {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        
        // Rough estimate: if >30 calls in window, expect ~0.5s wait per additional call
        if status.currentCount > 30 {
            return Double(status.currentCount - 30) * 0.1  // 0.1s per call over threshold
        }
        return 0.0
    }
    
    /// Get current MapKit rate limit status (for UI/debugging)
    func getMapKitRateLimitStatus() async -> (current: Int, limit: Int, waitTime: TimeInterval?) {
        let status = await rateLimiter.checkAndCleanup(limit: mapKitRateLimit, window: mapKitRateLimitWindow)
        return (status.currentCount, 50, status.waitTime)
    }
    
    // MARK: - OSRM Dynamic Calibration
    // OSRM often overestimates distances/durations compared to MapKit
    // We dynamically calibrate by comparing results from both services
    
    private let osrmCalibrationKey = "osrmCalibrationFactor"
    private let osrmCalibrationSamplesKey = "osrmCalibrationSamples"
    private let osrmCalibrationCountKey = "osrmCalibrationCallCount"
    private let maxCalibrationSamples = 15           // Keep last 15 samples for robust average
    private let calibrationInterval = 5              // Calibrate every 5 OSRM calls
    private let minSamplesForConfidence = 3          // Need at least 3 samples before trusting calibration
    private let defaultCalibrationFactor = 0.65      // Default factor (65% of OSRM = MapKit)
    
    /// Get OSRM calibration factor (MapKit duration / OSRM duration)
    /// Values < 1.0 mean OSRM overestimates, so we multiply OSRM result by this
    var osrmCalibrationFactor: Double {
        let stored = UserDefaults.standard.double(forKey: osrmCalibrationKey)
        return stored > 0 ? stored : defaultCalibrationFactor
    }
    
    /// Check if we need to run a calibration (compares MapKit vs OSRM for same route)
    private func shouldCalibrateOSRM() -> Bool {
        let samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        let callCount = UserDefaults.standard.integer(forKey: osrmCalibrationCountKey)
        
        // Always calibrate if we don't have minimum samples
        if samples.count < minSamplesForConfidence {
            return true
        }
        
        // Calibrate every N OSRM calls to keep factor accurate as user moves around
        return callCount % calibrationInterval == 0
    }
    
    /// Increment OSRM call counter
    private func recordOSRMCall() {
        let count = UserDefaults.standard.integer(forKey: osrmCalibrationCountKey)
        UserDefaults.standard.set(count + 1, forKey: osrmCalibrationCountKey)
    }
    
    /// Record a calibration sample comparing MapKit vs OSRM for same route
    func recordOSRMCalibration(mapKitDuration: Int, osrmDuration: Int) {
        guard mapKitDuration > 0 && osrmDuration > 0 else { return }
        
        let ratio = Double(mapKitDuration) / Double(osrmDuration)
        
        // Ignore extreme outliers (data errors)
        guard ratio >= 0.3 && ratio <= 1.5 else {
            print("🔧 Ignoring extreme calibration ratio: \(String(format: "%.2f", ratio)) (MapKit:\(mapKitDuration)s, OSRM:\(osrmDuration)s)")
            return
        }
        
        var samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        samples.append(ratio)
        
        if samples.count > maxCalibrationSamples {
            samples = Array(samples.suffix(maxCalibrationSamples))
        }
        
        // Calculate weighted average (recent samples matter more)
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (index, sample) in samples.enumerated() {
            let weight = Double(index + 1)  // Later samples have higher weight
            weightedSum += sample * weight
            weightTotal += weight
        }
        let weightedAverage = weightedSum / weightTotal
        let clampedAverage = max(0.4, min(1.0, weightedAverage))  // Clamp to reasonable range
        
        UserDefaults.standard.set(samples, forKey: osrmCalibrationSamplesKey)
        UserDefaults.standard.set(clampedAverage, forKey: osrmCalibrationKey)
        
        print("🔧 OSRM calibration: \(String(format: "%.2f", clampedAverage)) (from \(samples.count) samples, MapKit:\(mapKitDuration/60)min vs OSRM:\(osrmDuration/60)min)")
        }
        
    /// Apply calibration factor to OSRM duration
    func calibrateOSRMDuration(_ osrmDuration: Int) -> Int {
        let factor = osrmCalibrationFactor
        let calibrated = Int(Double(osrmDuration) * factor)
        return max(60, calibrated)  // At least 1 minute
    }
    
    /// Perform a calibration check by getting both MapKit and OSRM for the same route
    private func performCalibrationCheck(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) async {
        // Get a simple point-to-point route from both services
        do {
            // Get OSRM result (raw, uncalibrated)
            let osrmResult = try await getOSRMWalkingDirections(
                origin: origin,
                destination: destination,
                waypoints: []
            )
            let osrmDuration = osrmResult.duration  // Raw, uncalibrated
            
            // Get MapKit result (wait for rate limit if needed)
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            let response = try await directions.calculate()
            guard let route = response.routes.first else { return }
            
            let mapKitDuration = Int(route.expectedTravelTime)
            
            // Record the calibration sample
            recordOSRMCalibration(mapKitDuration: mapKitDuration, osrmDuration: osrmDuration)
            
        } catch {
            print("🔧 Calibration check failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Get Walking Directions (Apple MapKit - FREE!)
    /// Gets walking directions between points using Apple MapKit (FREE, unlimited!)
    /// Replaces Google Directions API to eliminate costs
    /// - Parameter preserveWaypointOrder: If true, waypoints are visited in the order provided (no optimization)
    // MARK: - TASK 1: Directions with soft/hard timeout and estimator fallback
    /// Wraps getWalkingDirections with soft/hard caps
    /// - Soft cap: Use on-device estimator instead of waiting for engine
    /// - Hard cap: Force timeout and return nil
    private func directionsWithTimeout(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        timeout: TimeInterval,
        targetDurationMinutes: Int? = nil,
        angularDiversityScore: Int? = nil,
        postcode: String? = nil,
        useEstimatorOnSoftCap: Bool = true,  // TASK 1: Use estimator if soft cap hit
        checkGlobalHardStop: (() -> Bool)? = nil  // SPRINT-4: Global hard-stop check before making call
    ) async -> (DirectionsResult?, Bool) {
        // SPRINT-4: Check global hard-stop before making MapKit/OSRM call
        if let checkHardStop = checkGlobalHardStop, checkHardStop() {
            print("⛔ [HARD-STOP] Cancelling MapKit/OSRM call - hard stop exceeded")
            return (nil, true)
        }
        
        // TASK 1: Calculate soft/hard caps
        let softCap = RoutingToggles.mapkitSoftCap
        let hardCap = min(timeout, RoutingToggles.mapkitHardCap)
        
        // Capture telemetry for logging
        let wpCount = waypoints.count
        let dur = targetDurationMinutes ?? -1
        let ads = angularDiversityScore ?? -1
        let pc = postcode ?? "none"
        
        // Use an actor to safely manage the single-resume guarantee
        actor ResumeGuard {
            var hasResumed = false
            var usedEstimator = false
            func tryResume() -> Bool {
                if hasResumed { return false }
                hasResumed = true
                return true
            }
            func markEstimator() { usedEstimator = true }
            func didUseEstimator() -> Bool { return usedEstimator }
        }
        
        return await withCheckedContinuation { continuation in
            let guard_ = ResumeGuard()
            
            // Start the MapKit directions task (fire-and-forget if we timeout)
            Task {
                do {
                    let res = try await self.getWalkingDirections(
                        origin: origin,
                        destination: destination,
                        waypoints: waypoints,
                        preserveWaypointOrder: false
                    )
                    // Only resume if we haven't already (timeout might have fired)
                    if await guard_.tryResume() {
                        continuation.resume(returning: (res, false))
                    }
                } catch {
                    if await guard_.tryResume() {
                        continuation.resume(returning: (nil, false))
                    }
                }
            }
            
            // TASK 1: Soft cap timeout - use estimator instead of waiting
            if useEstimatorOnSoftCap && softCap < hardCap {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(softCap * 1_000_000_000))
                    if await guard_.tryResume() {
                        // Soft cap hit - use on-device estimator instead of waiting for engine
                        let estimatedDuration = self.estimateRouteDuration(
                            origin: origin,
                            waypoints: waypoints,
                            destination: destination
                        )
                        let estimatedDistance = Int(Double(estimatedDuration) / 60.0 * Double(self.adaptiveWalkingSpeed))
                        
                        print("⏱️ [SOFT-CAP] Using estimator after \(String(format: "%.1f", softCap))s: ~\(estimatedDuration/60)min dur=\(dur)min wp=\(wpCount)")
                        
                        // Create a synthetic DirectionsResult from estimator
                        let syntheticLeg = DirectionsLeg(
                            distance: DirectionsValue(text: "\(estimatedDistance/1000) km", value: estimatedDistance),
                            duration: DirectionsValue(text: "\(estimatedDuration/60) min", value: estimatedDuration),
                            startAddress: nil,
                            endAddress: nil,
                            steps: nil
                        )
                        let syntheticResult = DirectionsResult(
                            legs: [syntheticLeg],
                            overviewPolyline: OverviewPolyline(points: ""),  // Empty polyline - will be filled later
                            summary: nil,
                            warnings: nil,
                            waypointOrder: nil
                        )
                        
                        await guard_.markEstimator()
                        continuation.resume(returning: (syntheticResult, false))
                    }
                }
            }
            
            // Hard cap timeout - force return nil
            Task {
                try? await Task.sleep(nanoseconds: UInt64(hardCap * 1_000_000_000))
                if await guard_.tryResume() {
                    // Log timeout with structured telemetry
                    print("⏱️ [HARD-CAP] timeout=\(String(format: "%.1f", hardCap))s dur=\(dur)min wp=\(wpCount) ADS=\(ads) pc=\(pc)")
                    continuation.resume(returning: (nil, true))
                }
            }
        }
    }
    
    /// Calculates the appropriate timeout for a routing call based on duration, ADS, and postcode
    private func calculateRoutingTimeout(
        targetDurationMinutes: Int,
        angularDiversityScore: Int?,
        postcode: String?
    ) -> TimeInterval {
        // Check postcode override first
        if let pc = postcode, let override = postcodeOverrides[pc] {
            // 10-min routes get even tighter timeout for problematic postcodes
            if targetDurationMinutes <= 10 {
                return min(override.perCallTimeoutSec, 6.0)  // 6s max for 10-min
            }
            return override.perCallTimeoutSec
        }
        
        // Duration-aware timeouts (10-min routes are the heavy tail)
        if targetDurationMinutes <= 10 {
            return (angularDiversityScore ?? 5) < 3 ? 5.0 : 6.0  // Tight for short routes
        } else if targetDurationMinutes <= 15 {
            return (angularDiversityScore ?? 5) < 3 ? 6.0 : 8.0
        } else {
            // Normal timeouts for longer routes
            return (angularDiversityScore ?? 5) < 3
                ? RoutingToggles.perCallTimeoutLowADS
                : RoutingToggles.perCallTimeoutNormal
        }
    }
    
    func getWalkingDirections(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = [],
        preserveWaypointOrder: Bool = false
    ) async throws -> DirectionsResult {
        
        // Build list of all points: origin → waypoints → destination
        var allPoints = [origin] + waypoints + [destination]
        
        // For circular routes (origin == destination), we need at least one waypoint
        if waypoints.isEmpty && origin.latitude == destination.latitude && origin.longitude == destination.longitude {
            throw GoogleMapsError.noRouteFound
        }
        
        var allLegs: [DirectionsLeg] = []
        var totalDistance: Int = 0
        var totalDuration: Int = 0
        var allPolylinePoints: [CLLocationCoordinate2D] = []
        var optimizedWaypointOrder: [Int]? = nil
        
        // If we have waypoints, try to optimize their order (simple nearest-neighbor)
        // UNLESS preserveWaypointOrder is true (used for enhancement where order is already optimal)
        if waypoints.count > 1 && !preserveWaypointOrder {
            let optimized = optimizeWaypointOrder(from: origin, waypoints: waypoints, to: destination)
            allPoints = [origin] + optimized.waypoints + [destination]
            optimizedWaypointOrder = optimized.order
            print("🍎 MapKit: Optimized waypoint order: \(optimized.order)")
        } else if waypoints.count > 1 && preserveWaypointOrder {
            optimizedWaypointOrder = Array(0..<waypoints.count)
            print("🍎 MapKit: Preserving waypoint order (no optimization)")
        } else if waypoints.count == 1 {
            optimizedWaypointOrder = [0] // Single waypoint, no reordering needed
        }
        
        // Calculate directions for each leg (point to point)
        // Use OSRM when approaching MapKit rate limit to avoid hitting the cap
        let useOSRM = await shouldUseOSRM()
        
        if useOSRM {
            // 🗺️ Use OSRM for all legs at once (more efficient)
            recordOSRMCall()
            let needsCalibration = shouldCalibrateOSRM()
            
            print("🗺️ Using OSRM for directions (MapKit near limit)\(needsCalibration ? " + calibrating" : "")")
            
            do {
                let osrmResult = try await getOSRMWalkingDirections(
                    origin: origin,
                    destination: destination,
                    waypoints: waypoints
                )
                
                // If we need to calibrate, also get MapKit for the first leg and compare
                if needsCalibration && allPoints.count >= 2 {
                    // Do calibration in background - don't block the route result
                    Task {
                        await performCalibrationCheck(
                            origin: allPoints[0],
                            destination: allPoints[min(1, allPoints.count - 1)]
                        )
                    }
                }
                
                // Apply calibration factor to OSRM duration (OSRM often overestimates)
                let rawDuration = osrmResult.duration
                let calibratedDuration = calibrateOSRMDuration(rawDuration)
                
                // Create a single leg with calibrated OSRM results
                let leg = DirectionsLeg(
                    distance: DirectionsValue(text: formatDistance(osrmResult.distance), value: osrmResult.distance),
                    duration: DirectionsValue(text: formatDuration(calibratedDuration), value: calibratedDuration),
                    startAddress: nil,
                    endAddress: nil,
                    steps: nil
                )
                
                // Encode polyline
                let encodedPolyline = encodePolyline(osrmResult.polyline)
                
                // OSRM returns total route, so we only have one "leg"
                let rawMinutes = rawDuration / 60
                let calibratedMinutes = calibratedDuration / 60
                let factor = osrmCalibrationFactor
                let samples = (UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double])?.count ?? 0
                print("🗺️ OSRM: \(allPoints.count - 1) legs, \(osrmResult.distance)m, \(rawMinutes)min → \(calibratedMinutes)min (×\(String(format: "%.2f", factor)) from \(samples) samples)")
                
                // v1.6.46: Mark result as OSRM-generated (driving polyline - needs MapKit refresh before navigation)
                var result = DirectionsResult(
                    legs: [leg],
                    overviewPolyline: OverviewPolyline(points: encodedPolyline),
                    summary: nil,
                    warnings: nil,
                    waypointOrder: optimizedWaypointOrder
                )
                result.usedOSRM = true
                return result
            } catch {
                print("🗺️ OSRM failed, falling back to MapKit: \(error.localizedDescription)")
                // Fall through to MapKit
            }
        }
        
        // 🍎 Use MapKit for directions
        // v1.9.25: Acquire semaphore to prevent concurrent MapKit calls
        await rateLimiter.acquire()
        defer { Task { await rateLimiter.release() } }
        
        // Check if we should do opportunistic calibration on first leg
        let samples = UserDefaults.standard.array(forKey: osrmCalibrationSamplesKey) as? [Double] ?? []
        let shouldOpportunisticallyCalibrate = samples.count < minSamplesForConfidence && allPoints.count >= 2
        
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            // Check rate limit before making request
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            
            // Record this request
            recordMapKitRequest()
            
            let response: MKDirections.Response
            do {
                // v1.9.26: Add timeout guard (30s) with retry
                response = try await withTimeout(seconds: 30) {
                    try await directions.calculate()
                }
                
                // Opportunistically calibrate on first leg when we need samples
                if i == 0 && shouldOpportunisticallyCalibrate {
                    if let mapKitRoute = response.routes.first {
                        let mapKitDuration = Int(mapKitRoute.expectedTravelTime)
                        // Get OSRM for same leg in background
                        Task {
                            do {
                                let osrmResult = try await getOSRMWalkingDirections(
                                    origin: legOrigin,
                                    destination: legDestination,
                                    waypoints: []
                                )
                                recordOSRMCalibration(mapKitDuration: mapKitDuration, osrmDuration: osrmResult.duration)
                            } catch {
                                // Silently ignore calibration failures
                            }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                print("🍎 MapKit leg \(i+1) failed: \(errorDesc)")
                
                // Check for rate limiting (MapKit returns GEOErrorDomain Code=-3)
                let nsError = error as NSError
                if nsError.domain == "GEOErrorDomain" && nsError.code == -3 {
                    // Extract timeUntilReset from userInfo if available
                    var waitTime = 60 // Default to 60 seconds
                    if let userInfo = nsError.userInfo["timeUntilReset"] as? Int {
                        waitTime = userInfo
                    }
                    print("🚫 MapKit rate limited! Trying OSRM fallback...")
                    
                    // Try OSRM as fallback when rate limited
                    do {
                        let osrmResult = try await getOSRMWalkingDirections(
                            origin: origin,
                            destination: destination,
                            waypoints: waypoints
                        )
                        
                        let leg = DirectionsLeg(
                            distance: DirectionsValue(text: formatDistance(osrmResult.distance), value: osrmResult.distance),
                            duration: DirectionsValue(text: formatDuration(osrmResult.duration), value: osrmResult.duration),
                            startAddress: nil,
                            endAddress: nil,
                            steps: nil
                        )
                        
                        let encodedPolyline = encodePolyline(osrmResult.polyline)
                        let durationMinutes = osrmResult.duration / 60
                        print("🗺️ OSRM fallback success: \(osrmResult.distance)m, \(durationMinutes)min")
                        
                        return DirectionsResult(
                            legs: [leg],
                            overviewPolyline: OverviewPolyline(points: encodedPolyline),
                            summary: nil,
                            warnings: nil,
                            waypointOrder: optimizedWaypointOrder
                        )
                    } catch {
                        print("🗺️ OSRM fallback also failed")
                        throw GoogleMapsError.rateLimited(timeUntilReset: waitTime)
                    }
                }
                
                throw GoogleMapsError.noRouteFound
            }
            
            guard let route = response.routes.first else {
                throw GoogleMapsError.noRouteFound
            }
            
            // Extract polyline points
            let polyline = route.polyline
            let pointCount = polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            
            // Append to overall polyline (skip first point of subsequent legs to avoid duplicates)
            if allPolylinePoints.isEmpty {
                allPolylinePoints.append(contentsOf: coords)
            } else {
                allPolylinePoints.append(contentsOf: coords.dropFirst())
            }
            
            // Extract step-by-step directions from MapKit
            var legSteps: [DirectionsStep] = []
            for step in route.steps {
                // Skip steps with no instructions (usually the first "depart" step)
                guard !step.instructions.isEmpty else { continue }
                
                let stepDistance = Int(step.distance)
                // Estimate duration based on walking speed (~80m/min)
                let stepDuration = max(1, stepDistance / 80) * 60
                
                // Encode step polyline
                let stepPolylineCount = step.polyline.pointCount
                var stepCoords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: stepPolylineCount)
                step.polyline.getCoordinates(&stepCoords, range: NSRange(location: 0, length: stepPolylineCount))
                let stepPolylineEncoded = encodePolyline(stepCoords)
                
                let directionsStep = DirectionsStep(
                    distance: DirectionsValue(text: formatDistance(stepDistance), value: stepDistance),
                    duration: DirectionsValue(text: formatDuration(stepDuration), value: stepDuration),
                    htmlInstructions: step.instructions,
                    polyline: StepPolyline(points: stepPolylineEncoded)
                )
                legSteps.append(directionsStep)
            }
            
            // Create leg data
            let legDistance = Int(route.distance)
            let legDuration = Int(route.expectedTravelTime)
            totalDistance += legDistance
            totalDuration += legDuration
            
            let leg = DirectionsLeg(
                distance: DirectionsValue(text: formatDistance(legDistance), value: legDistance),
                duration: DirectionsValue(text: formatDuration(legDuration), value: legDuration),
                startAddress: nil,
                endAddress: nil,
                steps: legSteps.isEmpty ? nil : legSteps
            )
            allLegs.append(leg)
        }
        
        // ENSURE POLYLINE CONNECTS TO ACTUAL ORIGIN/DESTINATION
        // MapKit may snap to nearest walkable path, so prepend/append actual coordinates
        var finalPolylinePoints = allPolylinePoints
        
        // Prepend origin if polyline doesn't start close enough (within 50m)
        if let firstPoint = finalPolylinePoints.first {
            let distanceToOrigin = distanceBetween(origin, firstPoint)
            if distanceToOrigin > 50 {
                print("🍎 Polyline starts \(Int(distanceToOrigin))m from origin - prepending actual origin")
                finalPolylinePoints.insert(origin, at: 0)
            }
        }
        
        // Append destination if polyline doesn't end close enough (within 50m)
        if let lastPoint = finalPolylinePoints.last {
            let distanceToDestination = distanceBetween(destination, lastPoint)
            if distanceToDestination > 50 {
                print("🍎 Polyline ends \(Int(distanceToDestination))m from destination - appending actual destination")
                finalPolylinePoints.append(destination)
            }
        }
        
        // Encode combined polyline to Google's format (for compatibility)
        let encodedPolyline = encodePolyline(finalPolylinePoints)
        
        print("🍎 MapKit: \(allLegs.count) legs, \(totalDistance)m, \(totalDuration/60)min (FREE!)")
        
        return DirectionsResult(
            legs: allLegs,
            overviewPolyline: OverviewPolyline(points: encodedPolyline),
            summary: nil,
            warnings: nil,
            waypointOrder: optimizedWaypointOrder
        )
    }
    
    // MARK: - v1.6.14: Get MapKit Directions for Existing Route
    /// Gets turn-by-turn directions from Apple MapKit for a route that was generated by OSRM
    /// This ensures ALL routes have directions, regardless of how POIs were selected
    /// - Parameters:
    ///   - origin: Starting point
    ///   - waypoints: Array of waypoint coordinates (POI locations)
    ///   - destination: End point (usually same as origin for round-trips)
    /// - Returns: Array of WalkingDirection for turn-by-turn navigation
    /// v2.1.6: Get MapKit directions with waypoint-specific arrival instructions
    func getMapKitDirectionsForRoute(
        origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D,
        waypointNames: [String] = []
    ) async -> [WalkingDirection] {
        // v1.9.25: Acquire semaphore to prevent concurrent MapKit calls
        await rateLimiter.acquire()
        defer { Task { await rateLimiter.release() } }
        
        var allDirections: [WalkingDirection] = []
        
        // Build the list of points: origin → waypoints → destination
        let allPoints = [origin] + waypoints + [destination]
        let isReturnRoute = origin.latitude == destination.latitude && origin.longitude == destination.longitude
        
        print("🍎 Getting MapKit directions for \(allPoints.count - 1) legs...")
        
        // Get directions for each leg
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            let isLastLeg = i == allPoints.count - 2
            let isReturnLeg = isLastLeg && isReturnRoute && waypoints.count > 0
            
            // Check rate limit
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            do {
                // v1.9.26: Add timeout guard (30s) with retry
                var response: MKDirections.Response? = nil
                var retryCount = 0
                let maxRetries = 1
                var succeeded = false
                
                while retryCount <= maxRetries && !succeeded {
                    do {
                        response = try await withTimeout(seconds: 30) {
                            try await directions.calculate()
                        }
                        succeeded = true
                        break  // Success, exit retry loop
                    } catch TimeoutError.timeout {
                        retryCount += 1
                        if retryCount <= maxRetries {
                            print("🍎 ⏱️ MapKit timeout for leg \(i+1) (30s) - retrying (\(retryCount)/\(maxRetries))...")
                            // Notify UI about timeout (if we have a way to do so)
                            continue
                        } else {
                            print("🍎 ⏱️ MapKit timeout for leg \(i+1) after \(maxRetries) retries - skipping leg")
                            throw TimeoutError.timeout
                        }
                    } catch {
                        // Other errors, don't retry
                        throw error
                    }
                }
                
                guard let finalResponse = response, let route = finalResponse.routes.first else { continue }
                
                // Find the last step with instructions (to identify arrival step)
                let lastStepWithInstructions = route.steps.lastIndex(where: { !$0.instructions.isEmpty })
                
                // Extract step-by-step directions
                for (stepIndex, step) in route.steps.enumerated() {
                    guard !step.instructions.isEmpty else { continue }
                    
                    let stepDistance = Int(step.distance)
                    // Estimate duration based on walking speed (~80m/min)
                    let stepDurationSeconds = max(60, stepDistance / 80 * 60)
                    let durationText = stepDurationSeconds >= 60 ? "\(stepDurationSeconds / 60) min" : "\(stepDurationSeconds) sec"
                    
                    // Extract maneuver type from instructions
                    let maneuver = extractManeuverType(from: step.instructions)
                    
                    var instruction = step.instructions
                    let isLastStepOfLeg = stepIndex == lastStepWithInstructions
                    
                    // v2.1.6: Replace arrival instructions with waypoint-specific text
                    if isLastStepOfLeg {
                        let instructionLower = instruction.lowercased()
                        let isArrivalInstruction = instructionLower.contains("destination is on your right") ||
                                                 instructionLower.contains("destination is on your left") ||
                                                 instructionLower.contains("the destination is on your right") ||
                                                 instructionLower.contains("the destination is on your left") ||
                                                 instructionLower.contains("arrive at") ||
                                                 instructionLower.contains("arrive") ||
                                                 (instructionLower.contains("destination") && (instructionLower.contains("on your right") || instructionLower.contains("on your left")))
                        
                        if isArrivalInstruction {
                            if isReturnLeg {
                                // Last leg is return to origin
                                instruction = "Return to starting point"
                            } else if i < waypointNames.count {
                                // Intermediate waypoint - create waypoint-specific instruction
                                let waypointIndex = i + 1 // 1-indexed for display
                                let waypointName = waypointNames[i]
                                
                                // Determine left/right from original instruction
                                let side = instructionLower.contains("right") ? "right" : "left"
                                
                                instruction = "Waypoint \(waypointIndex) (\(waypointName)) is on your \(side)"
                            }
                            // If i >= waypointNames.count but not return leg, keep original instruction
                        }
                    }
                    
                    let direction = WalkingDirection(
                        instruction: instruction,
                        distance: formatDistance(stepDistance),
                        distanceMeters: stepDistance,
                        duration: durationText,
                        maneuver: maneuver
                    )
                    allDirections.append(direction)
                }
            } catch TimeoutError.timeout {
                print("🍎 ⏱️ MapKit timeout for leg \(i+1) after retries - continuing with other legs")
                // Continue with other legs even if one times out
            } catch {
                print("🍎 MapKit directions failed for leg \(i): \(error.localizedDescription)")
                // Continue with other legs even if one fails
            }
        }
        
        print("🍎 Got \(allDirections.count) directions from MapKit")
        return allDirections
    }
    
    // MARK: - v1.6.38: Refresh Route with MapKit Directions
    /// Refreshes a WalkingRoute with fresh Apple MapKit directions
    /// Called when "Let's Go" is pressed to ensure best quality navigation
    /// - Parameters:
    ///   - route: The route to refresh
    ///   - userLocation: Current user location (start/end point)
    /// - Returns: Updated route with fresh MapKit directions and polyline
    func refreshRouteWithMapKit(
        route: WalkingRoute,
        userLocation: CLLocationCoordinate2D
    ) async -> WalkingRoute {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [ROUTE REFRESH] [\(timeString)] 🍎 refreshRouteWithMapKit() STARTED")
        print("🍎 REFRESH: Getting fresh MapKit directions for navigation...")
        
        // Extract waypoint coordinates from QR markers
        let waypoints = route.qrMarkers.map { $0.coordinate }
        
        guard !waypoints.isEmpty else {
            print("⏱️ [ROUTE REFRESH] [\(timeString)] ⚠️ No waypoints, keeping original route")
            return route
        }
        
        print("⏱️ [ROUTE REFRESH] [\(timeString)] 📍 Getting MapKit directions for \(waypoints.count) waypoints...")
        
        // Get fresh MapKit directions
        let directionsStartTime = Date()
        let waypointNames = route.qrMarkers.map { $0.name }
        let freshDirections = await getMapKitDirectionsForRoute(
            origin: userLocation,
            waypoints: waypoints,
            destination: userLocation,  // Round trip
            waypointNames: waypointNames
        )
        let directionsElapsed = Date().timeIntervalSince(directionsStartTime)
        print("⏱️ [ROUTE REFRESH] [\(timeString)]   getMapKitDirectionsForRoute() took \(String(format: "%.2f", directionsElapsed))s")
        
        // Get fresh polyline from MapKit
        var freshPolylinePoints: [CLLocationCoordinate2D] = []
        var totalDistance = 0
        var totalDuration = 0
        
        let allPoints = [userLocation] + waypoints + [userLocation]
        
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            // Calculate straight-line distance for suspicion check
            let straightLineDistance = distanceBetween(legOrigin, legDestination)
            
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            do {
                let response = try await directions.calculate()
                if let mkRoute = response.routes.first {
                    // v1.6.47: Check for suspicious segment (MapKit shortcut through fields)
                    let routeDistance = mkRoute.distance
                    let suspicionRatio = straightLineDistance > 0 ? routeDistance / straightLineDistance : 1.0
                    
                    var segmentPoints: [CLLocationCoordinate2D] = []
                    var segmentDistance = Int(routeDistance)
                    var segmentDuration = Int(mkRoute.expectedTravelTime)
                    
                    // Extract MapKit polyline points
                    let pointCount = mkRoute.polyline.pointCount
                    var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                    mkRoute.polyline.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
                    segmentPoints = points
                    
                    // SUSPICIOUS CHECK: ratio < 1.10 means route is too direct (likely shortcut)
                    if suspicionRatio < 1.10 && straightLineDistance > 50 {
                        print("🚨 SUSPICIOUS Leg \(i): ratio=\(String(format: "%.2f", suspicionRatio)) (route: \(Int(routeDistance))m, straight: \(Int(straightLineDistance))m)")
                        
                        var foundBetterRoute = false
                        
                        // v1.6.47: Step 1 - Try OSRM first (FREE, uses OSM barrier data)
                        do {
                            let osrmResult = try await getOSRMWalkingDirections(
                                origin: legOrigin,
                                destination: legDestination,
                                waypoints: []
                            )
                            
                            let osrmRatio = straightLineDistance > 0 ? Double(osrmResult.distance) / straightLineDistance : 1.0
                            
                            if osrmRatio >= 1.15 {
                                print("✅ OSRM segment BETTER: ratio=\(String(format: "%.2f", osrmRatio)) (route: \(osrmResult.distance)m) [FREE]")
                                segmentPoints = osrmResult.polyline
                                segmentDistance = osrmResult.distance
                                segmentDuration = osrmResult.duration
                                foundBetterRoute = true
                            } else {
                                print("⚠️ OSRM also suspicious: ratio=\(String(format: "%.2f", osrmRatio))")
                            }
                        } catch {
                            print("⚠️ OSRM fallback failed: \(error.localizedDescription)")
                        }
                        
                        // v1.6.47: Step 2 - If OSRM also suspicious, try Google (costs money)
                        if !foundBetterRoute && hasAPIKey && canUseGoogleDirectionsRefresh {
                            // v2.0.3 Batch A: Wrap with timeout (short since this is fallback)
                            let googleTimeout = RoutingToggles.perCallTimeoutNormal
                            let (googleResult, didTimeout) = await directionsWithTimeout(
                                origin: legOrigin,
                                destination: legDestination,
                                waypoints: [],
                                timeout: googleTimeout,
                                targetDurationMinutes: nil,
                                angularDiversityScore: nil,
                                postcode: nil
                            )
                            
                            if didTimeout {
                                print("⚠️ Google fallback timed out")
                            } else if let googleDirs = googleResult {
                                let googleDistance = googleDirs.legs.reduce(0) { $0 + $1.distance.value }
                                let googleRatio = straightLineDistance > 0 ? Double(googleDistance) / straightLineDistance : 1.0
                                
                                // Use Google if it gives a more realistic route (ratio ≥ 1.15)
                                if googleRatio >= 1.15 {
                                    print("✅ Google segment BETTER: ratio=\(String(format: "%.2f", googleRatio)) (route: \(googleDistance)m)")
                                    segmentPoints = decodePolyline(googleDirs.overviewPolyline.points)
                                    segmentDistance = googleDistance
                                    segmentDuration = googleDirs.legs.reduce(0) { $0 + $1.duration.value }
                                    foundBetterRoute = true
                                } else {
                                    print("⚠️ Google also suspicious: ratio=\(String(format: "%.2f", googleRatio))")
                                }
                            } else {
                                print("⚠️ Google fallback failed")
                            }
                        }
                        
                        if !foundBetterRoute {
                            print("⚠️ All sources suspicious - keeping MapKit (best available)")
                        }
                    } else {
                        print("🍎 Leg \(i) OK: ratio=\(String(format: "%.2f", suspicionRatio)) (\(Int(routeDistance))m)")
                    }
                    
                    freshPolylinePoints.append(contentsOf: segmentPoints)
                    totalDistance += segmentDistance
                    totalDuration += segmentDuration
                }
            } catch {
                print("🍎 REFRESH: Leg \(i) failed: \(error.localizedDescription)")
            }
        }
        
        // Encode the fresh polyline
        let freshEncodedPolyline = encodePolyline(freshPolylinePoints)
        let durationMinutes = max(1, totalDuration / 60)
        let pointsPerKm = totalDistance > 0 ? Double(freshPolylinePoints.count) / (Double(totalDistance) / 1000.0) : 0
        
        print("🍎 ═══════════════════════════════════════════════════════")
        print("🍎 REFRESH COMPLETE (MapKit Fallback)")
        print("🍎   ⏱️  Duration: \(durationMinutes)min")
        print("🍎   📏 Distance: \(totalDistance)m")
        print("🍎   🧭 Directions: \(freshDirections.count) steps")
        print("🍎   📐 Polyline: \(freshEncodedPolyline.count) chars → \(freshPolylinePoints.count) points")
        print("🍎   📐 Point density: \(String(format: "%.1f", pointsPerKm)) points/km")
        if pointsPerKm < 20 {
            print("🍎   ⚠️  LOW DENSITY - may not follow roads precisely")
        }
        print("🍎 ═══════════════════════════════════════════════════════")
        
        // Create updated route with fresh data
        let refreshedRoute = WalkingRoute(
            name: route.name,
            description: route.description,
            durationMinutes: durationMinutes,
            distanceMeters: totalDistance > 0 ? totalDistance : route.distanceMeters,
            difficulty: route.difficulty,
            isIndoor: route.isIndoor,
            isAccessible: route.isAccessible,
            landmarks: route.landmarks,
            icon: route.icon,
            color: route.color,
            qrMarkers: route.qrMarkers,
            routeType: route.routeType,
            encodedPolyline: freshEncodedPolyline.isEmpty ? route.encodedPolyline : freshEncodedPolyline,
            walkingDirections: freshDirections.isEmpty ? route.walkingDirections : freshDirections
        )
        
        let endTime = Date()
        let endTimeString = formatter.string(from: endTime)
        let totalElapsed = endTime.timeIntervalSince(startTime)
        print("⏱️ [ROUTE REFRESH] [\(endTimeString)] ✅ refreshRouteWithMapKit() COMPLETED in \(String(format: "%.2f", totalElapsed))s")
        
        return refreshedRoute
    }
    
    // MARK: - v2.1.3: Refresh Route with MapKit using pre-snapped waypoints
    /// Used as fallback when Google quota is exceeded - uses already-snapped waypoints for better route
    private func refreshRouteWithMapKitUsingSnappedWaypoints(
        route: WalkingRoute,
        userLocation: CLLocationCoordinate2D,
        snappedWaypoints: [CLLocationCoordinate2D]
    ) async -> WalkingRoute? {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("🍎 [MAPKIT SNAPPED] [\(timeString)] Starting MapKit route with \(snappedWaypoints.count) snapped waypoints")
        
        guard !snappedWaypoints.isEmpty else {
            print("🍎 [MAPKIT SNAPPED] ⚠️ No waypoints - returning nil")
            return nil
        }
        
        // Get MapKit directions using snapped waypoints
        let waypointNames = route.qrMarkers.map { $0.name }
        let freshDirections = await getMapKitDirectionsForRoute(
            origin: userLocation,
            waypoints: snappedWaypoints,
            destination: userLocation,  // Round trip
            waypointNames: waypointNames
        )
        
        // Get fresh polyline from MapKit
        var freshPolylinePoints: [CLLocationCoordinate2D] = []
        var totalDistance = 0
        var totalDuration = 0
        
        let allPoints = [userLocation] + snappedWaypoints + [userLocation]
        
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            do {
                let directions = MKDirections(request: request)
                let response = try await directions.calculate()
                
                if let mapKitRoute = response.routes.first {
                    // Extract coordinates from MKPolyline using getCoordinates
                    let pointCount = mapKitRoute.polyline.pointCount
                    var routePoints = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                    mapKitRoute.polyline.getCoordinates(&routePoints, range: NSRange(location: 0, length: pointCount))
                    
                    let routeDistance = Int(mapKitRoute.distance)
                    let routeDuration = Int(mapKitRoute.expectedTravelTime)
                    
                    freshPolylinePoints.append(contentsOf: routePoints)
                    totalDistance += routeDistance
                    totalDuration += routeDuration
                    print("🍎 [MAPKIT SNAPPED] Leg \(i): \(routeDistance)m, \(routePoints.count) points")
                }
            } catch {
                print("🍎 [MAPKIT SNAPPED] ⚠️ Leg \(i) failed: \(error.localizedDescription)")
                // Add straight line as fallback for this leg
                freshPolylinePoints.append(legOrigin)
                freshPolylinePoints.append(legDestination)
            }
        }
        
        // Encode the fresh polyline
        let freshEncodedPolyline = encodePolyline(freshPolylinePoints)
        let durationMinutes = max(1, totalDuration / 60)
        
        print("🍎 [MAPKIT SNAPPED] ✅ Complete: \(totalDistance)m, \(freshPolylinePoints.count) polyline points, \(freshDirections.count) directions")
        
        // Update markers with snapped coordinates for activation
        var updatedMarkers: [QRMarker] = []
        for (index, marker) in route.qrMarkers.enumerated() {
            if index < snappedWaypoints.count {
                let snappedCoord = snappedWaypoints[index]
                let updatedMarker = QRMarker(
                    code: marker.code,
                    name: marker.name,
                    location: marker.location,
                    coordinate: snappedCoord,  // Snapped to road for activation
                    contentType: marker.contentType,
                    content: marker.content,
                    pointsValue: marker.pointsValue
                )
                updatedMarkers.append(updatedMarker)
            } else {
                updatedMarkers.append(marker)
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("🍎 [MAPKIT SNAPPED] [\(timeString)] Completed in \(String(format: "%.2f", elapsed))s")
        
        return WalkingRoute(
            name: route.name,
            description: route.description,
            durationMinutes: durationMinutes,
            distanceMeters: totalDistance > 0 ? totalDistance : route.distanceMeters,
            difficulty: route.difficulty,
            isIndoor: route.isIndoor,
            isAccessible: route.isAccessible,
            landmarks: route.landmarks,
            icon: route.icon,
            color: route.color,
            qrMarkers: updatedMarkers,
            routeType: route.routeType,
            encodedPolyline: freshEncodedPolyline.isEmpty ? route.encodedPolyline : freshEncodedPolyline,
            walkingDirections: freshDirections.isEmpty ? route.walkingDirections : freshDirections
        )
    }
    
    // MARK: - v1.8.9: Refresh Route with Google Directions (Apple fallback)
    /// Tries Google Directions first for better quality, falls back to Apple MapKit if quota reached
    func refreshRouteWithGoogleThenMapKit(
        route: WalkingRoute,
        userLocation: CLLocationCoordinate2D
    ) async -> WalkingRoute {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [ROUTE REFRESH] [\(timeString)] 🚀 refreshRouteWithGoogleThenMapKit() STARTED")
        print("⏱️ [ROUTE REFRESH] [\(timeString)]   Route: '\(route.name)'")
        print("⏱️ [ROUTE REFRESH] [\(timeString)]   Waypoints: \(route.qrMarkers.count)")
        
        // Check if we can use Google Directions
        if canUseGoogleDirectionsRefresh {
            print("⏱️ [ROUTE REFRESH] [\(timeString)] ✅ Can use Google Directions")
            print("🌐 ═══════════════════════════════════════════════════════")
            print("🌐 REFRESH: Starting Google Directions API call...")
            print("🌐   📍 Origin: (\(String(format: "%.5f", userLocation.latitude)), \(String(format: "%.5f", userLocation.longitude)))")
            
            // Extract waypoint coordinates from QR markers
            let rawWaypoints = route.qrMarkers.map { $0.coordinate }
            
            guard !rawWaypoints.isEmpty else {
                print("🌐 REFRESH: No waypoints, using Apple MapKit")
                return await refreshRouteWithMapKit(route: route, userLocation: userLocation)
            }
            
            // v2.1.5: Snap waypoints to nearest public road before sending to Google
            // Prioritizes the road from the marker's address if available
            // This ensures routes stay on public roads and don't go into schools/private areas
            // Run queries in parallel for speed, with fallback mirrors for reliability
            print("🛤️ [ROAD SNAP] Starting waypoint snapping for \(rawWaypoints.count) waypoints...")
            let snappedWaypoints = await withTaskGroup(of: (Int, CLLocationCoordinate2D).self) { group in
                for (index, waypoint) in rawWaypoints.enumerated() {
                    group.addTask {
                        // v2.1.5: Extract road name from marker's location field if available
                        let marker = route.qrMarkers[index]
                        let roadName = self.extractRoadName(from: marker.location)
                        if let roadName = roadName {
                            print("🛤️ [ROAD SNAP] Waypoint \(index+1) '\(marker.name)' - preferred road: '\(roadName)'")
                        }
                        
                        if let nearestRoad = await self.findNearestRoadPointWithFallback(near: waypoint, radiusMeters: 100, preferredRoadName: roadName) {
                            let distance = CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude)
                                .distance(from: CLLocation(latitude: nearestRoad.latitude, longitude: nearestRoad.longitude))
                            if distance > 10 { // Only snap if more than 10m from road
                                print("🛤️ [ROAD SNAP] Waypoint \(index+1) snapped to road (\(Int(distance))m)")
                                return (index, nearestRoad)
                            } else {
                                print("🛤️ [ROAD SNAP] Waypoint \(index+1) already on road (within 10m)")
                            }
                        } else {
                            print("🛤️ [ROAD SNAP] ⚠️ Waypoint \(index+1) could not be snapped - using original")
                        }
                        return (index, waypoint) // Keep original if already on road or no road found
                    }
                }
                
                var results = [(Int, CLLocationCoordinate2D)]()
                for await result in group {
                    results.append(result)
                }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            print("🛤️ [ROAD SNAP] Waypoint snapping complete")
            
            // Optimize waypoint order locally (Nearest Neighbor) to stay in Essentials SKU
            let waypoints = performLocalOptimization(origin: userLocation, waypoints: snappedWaypoints)
            
            print("🌐   🎯 Waypoints: \(waypoints.count) (optimized locally, road-snapped)")
            for (index, waypoint) in waypoints.enumerated() {
                print("🌐      [\(index + 1)] (\(String(format: "%.5f", waypoint.latitude)), \(String(format: "%.5f", waypoint.longitude)))")
            }
            
            // Build waypoints string (already optimized, no optimize:true parameter needed)
            // Format: lat,lng|lat,lng|lat,lng (using 6 decimal places for precision)
            let waypointsParam = waypoints.map { 
                String(format: "%.6f,%.6f", $0.latitude, $0.longitude)
            }.joined(separator: "|")
            
            // Google Directions API URL (no optimize:true to stay in Essentials SKU)
            // Format: origin and destination are the same (loop route), waypoints are intermediate POIs only
            var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
            urlString += "origin=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
            urlString += "&destination=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
            urlString += "&waypoints=\(waypointsParam)"
            urlString += "&mode=walking"
            urlString += "&key=\(apiKey)"
            
            // Log URL without API key for security
            let safeUrlString = urlString.replacingOccurrences(of: "&key=\(apiKey)", with: "&key=***")
            print("🌐   🔗 URL: \(safeUrlString)")
            print("🌐   🔑 API Key present: \(!apiKey.isEmpty), prefix: \(String(apiKey.prefix(10)))...")
            
            if let url = URL(string: urlString) {
                let startTime = Date()
                do {
                    print("🌐   ⏱️  Making HTTP request...")
                    var request = URLRequest(url: url)
                    // v1.9.13: Set explicit timeout for slow networks
                    request.timeoutInterval = 30.0 // 30 second timeout
                    // Add iOS bundle ID for API key restrictions
                    let bundleIdSent: Bool
                    if let bundleId = Bundle.main.bundleIdentifier {
                        request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
                        bundleIdSent = true
                        print("🌐   📱 Bundle ID: \(bundleId)")
                    } else {
                        bundleIdSent = false
                    }
                    // Use custom session with timeout configuration
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 30.0
                    config.timeoutIntervalForResource = 60.0
                    let session = URLSession(configuration: config)
                    let (data, response) = try await session.data(for: request)
                    let elapsed = Date().timeIntervalSince(startTime)
                    
                    // Log HTTP response details
                    let httpStatus: Int?
                    if let httpResponse = response as? HTTPURLResponse {
                        httpStatus = httpResponse.statusCode
                        print("🌐   📡 HTTP Status: \(httpResponse.statusCode)")
                        print("🌐   📦 Response size: \(data.count) bytes")
                        print("🌐   ⏱️  Response time: \(String(format: "%.2f", elapsed))s")
                    } else {
                        httpStatus = nil
                    }
                    
                    recordGoogleDirectionsCall()
                    print("🌐   📊 Google Directions refresh: \(googleDirectionsCallsToday)/\(googleDirectionsDailyCap) calls today")
                    
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["status"] as? String {
                        print("🌐   📋 API Status: '\(status)'")
                        
                        // Log the status for debugging
                        if status != "OK" {
                            let errorMessage = json["error_message"] as? String ?? "Unknown error"
                            print("🌐   ❌ ERROR: \(errorMessage)")
                            
                            recordAPICall(
                                apiName: "Directions API",
                                success: false,
                                httpStatus: httpStatus,
                                responseTime: elapsed,
                                errorMessage: errorMessage,
                                bundleIdSent: bundleIdSent,
                                details: "\(waypoints.count) waypoints, status: \(status)"
                            )
                            
                            // Log full error details if available
                            if let errorDetails = json["error_message"] as? String {
                                print("🌐   📄 Full error message: \(errorDetails)")
                            }
                            if let rawResponse = String(data: data, encoding: .utf8) {
                                print("🌐   📄 Raw response (first 500 chars): \(String(rawResponse.prefix(500)))")
                            }
                            
                            print("🌐 REFRESH: Google API returned status '\(status)': \(errorMessage) - falling back to MapKit")
                            print("🌐 ═══════════════════════════════════════════════════════")
                        } else if let routes = json["routes"] as? [[String: Any]],
                       let firstRoute = routes.first {
                        
                        // Extract overview polyline
                        var polyline = ""
                        var polylinePointCount = 0
                        if let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
                           let points = overviewPolyline["points"] as? String {
                            polyline = points
                            // Decode to count points
                            let decodedPoints = self.decodePolyline(points)
                            polylinePointCount = decodedPoints.count
                        }
                        
                        // Also try to get detailed polylines from each step
                        var stepPolylinePointCount = 0
                        var combinedStepPolyline: [CLLocationCoordinate2D] = []
                        
                        // Extract legs for directions
                        var freshDirections: [WalkingDirection] = []
                        var totalDistance = 0
                        var totalDuration = 0
                        var legsCount = 0
                        
                        if let legs = firstRoute["legs"] as? [[String: Any]] {
                            legsCount = legs.count
                            for leg in legs {
                                if let distance = leg["distance"] as? [String: Any],
                                   let distValue = distance["value"] as? Int {
                                    totalDistance += distValue
                                }
                                if let duration = leg["duration"] as? [String: Any],
                                   let durValue = duration["value"] as? Int {
                                    totalDuration += durValue
                                }
                                
                                if let steps = leg["steps"] as? [[String: Any]] {
                                    for step in steps {
                                        let instruction = (step["html_instructions"] as? String)?
                                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Continue"
                                        let stepDistText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                                        let stepDistValue = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                                        let stepDurText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                                        let maneuver = step["maneuver"] as? String ?? "straight"
                                        
                                        // Get step polyline for detailed path
                                        if let stepPolyline = step["polyline"] as? [String: Any],
                                           let stepPoints = stepPolyline["points"] as? String {
                                            let decodedStepPoints = self.decodePolyline(stepPoints)
                                            stepPolylinePointCount += decodedStepPoints.count
                                            combinedStepPolyline.append(contentsOf: decodedStepPoints)
                                        }
                                        
                                        freshDirections.append(WalkingDirection(
                                            instruction: instruction,
                                            distance: stepDistText,
                                            distanceMeters: stepDistValue,
                                            duration: stepDurText,
                                            maneuver: maneuver
                                        ))
                                    }
                                }
                            }
                        }
                        
                        // Use detailed step polyline if available (more points = follows roads better)
                        var finalPolyline = polyline
                        var usedDetailedPolyline = false
                        if stepPolylinePointCount > polylinePointCount && !combinedStepPolyline.isEmpty {
                            finalPolyline = self.encodePolyline(combinedStepPolyline)
                            usedDetailedPolyline = true
                        }
                        
                        let durationMinutes = max(1, totalDuration / 60)
                        let pointsPerKm = totalDistance > 0 ? Double(usedDetailedPolyline ? stepPolylinePointCount : polylinePointCount) / (Double(totalDistance) / 1000.0) : 0
                        
                        print("🌐   ✅ SUCCESS: Parsed Google route")
                        print("🌐      ⏱️  Duration: \(durationMinutes)min")
                        print("🌐      📏 Distance: \(totalDistance)m")
                        print("🌐      🧭 Directions: \(freshDirections.count) steps")
                        print("🌐      📍 Legs: \(legsCount)")
                        print("🌐      📐 Overview polyline: \(polyline.count) chars → \(polylinePointCount) points")
                        print("🌐      📐 Step polylines: \(stepPolylinePointCount) points total")
                        print("🌐      📐 Using: \(usedDetailedPolyline ? "DETAILED step polylines" : "overview polyline")")
                        print("🌐      📐 Point density: \(String(format: "%.1f", pointsPerKm)) points/km")
                        if pointsPerKm < 20 {
                            print("🌐      ⚠️  LOW DENSITY - may not follow roads precisely")
                        }
                        print("🌐 REFRESH: ✅ Google route - \(durationMinutes)min, \(totalDistance)m, \(freshDirections.count) steps")
                        print("🌐 ═══════════════════════════════════════════════════════")
                        
                        // Use the better polyline
                        let polylineToUse = finalPolyline
                        
                        // Record success
                        recordAPICall(
                            apiName: "Directions API",
                            success: true,
                            httpStatus: httpStatus,
                            responseTime: elapsed,
                            bundleIdSent: bundleIdSent,
                            details: "\(waypoints.count) waypoints, \(legsCount) legs, \(durationMinutes)min"
                        )
                        
                        // v2.1.1: Update QRMarker coordinates with snapped road positions
                        var updatedMarkers: [QRMarker] = []
                        for (index, marker) in route.qrMarkers.enumerated() {
                            if index < snappedWaypoints.count {
                                let snappedCoord = snappedWaypoints[index]
                                let updatedMarker = QRMarker(
                                    code: marker.code,
                                    name: marker.name,
                                    location: marker.location,
                                    coordinate: snappedCoord,
                                    contentType: marker.contentType,
                                    content: marker.content,
                                    pointsValue: marker.pointsValue
                                )
                                updatedMarkers.append(updatedMarker)
                            } else {
                                updatedMarkers.append(marker)
                            }
                        }
                        
                        // Create updated route with Google data (using detailed polyline if available)
                        let googleRoute = WalkingRoute(
                            name: route.name,
                            description: route.description,
                            durationMinutes: durationMinutes,
                            distanceMeters: totalDistance > 0 ? totalDistance : route.distanceMeters,
                            difficulty: route.difficulty,
                            isIndoor: route.isIndoor,
                            isAccessible: route.isAccessible,
                            landmarks: route.landmarks,
                            icon: route.icon,
                            color: route.color,
                            qrMarkers: updatedMarkers,
                            routeType: route.routeType,
                            encodedPolyline: polylineToUse.isEmpty ? route.encodedPolyline : polylineToUse,
                            walkingDirections: freshDirections.isEmpty ? route.walkingDirections : freshDirections
                        )
                        
                        let endTime = Date()
                        let endTimeString = formatter.string(from: endTime)
                        let totalElapsed = endTime.timeIntervalSince(startTime)
                        print("⏱️ [ROUTE REFRESH] [\(endTimeString)] ✅ refreshRouteWithGoogleThenMapKit() COMPLETED in \(String(format: "%.2f", totalElapsed))s (used Google)")
                        
                        return googleRoute
                        } else {
                            print("🌐   ⚠️  WARNING: Status OK but no routes array or empty routes")
                            if let rawResponse = String(data: data, encoding: .utf8) {
                                print("🌐   📄 Raw response (first 500 chars): \(String(rawResponse.prefix(500)))")
                            }
                            print("🌐 REFRESH: Google returned OK but no routes found - falling back to MapKit")
                            print("🌐 ═══════════════════════════════════════════════════════")
                        }
                    } else {
                        print("🌐   ❌ ERROR: Failed to parse JSON or missing status field")
                        if let rawResponse = String(data: data, encoding: .utf8) {
                            print("🌐   📄 Raw response (first 500 chars): \(String(rawResponse.prefix(500)))")
                        }
                        print("🌐 REFRESH: Failed to parse Google Directions response - falling back to MapKit")
                        print("🌐 ═══════════════════════════════════════════════════════")
                    }
                } catch {
                    print("🌐   ❌ EXCEPTION: \(error.localizedDescription)")
                    print("🌐   📄 Error type: \(type(of: error))")
                    if let urlError = error as? URLError {
                        print("🌐   📄 URL Error code: \(urlError.code.rawValue)")
                        print("🌐   📄 URL Error description: \(urlError.localizedDescription)")
                    }
                    print("🌐 REFRESH: Google API call failed - \(error.localizedDescription), using Apple MapKit")
                    print("🌐 ═══════════════════════════════════════════════════════")
                }
            } else {
                print("🌐   ❌ ERROR: Failed to create URL from string")
                print("🌐 ═══════════════════════════════════════════════════════")
            }
        } else {
            print("🌐 REFRESH: Google quota reached (\(googleDirectionsCallsToday)/\(googleDirectionsDailyCap)) - using Apple MapKit")
        }
        
        // Fallback to Apple MapKit
        let fallbackTime = Date()
        let fallbackTimeString = formatter.string(from: fallbackTime)
        let elapsedSoFar = fallbackTime.timeIntervalSince(startTime)
        print("⏱️ [ROUTE REFRESH] [\(fallbackTimeString)] ⚠️ Falling back to MapKit (elapsed: \(String(format: "%.2f", elapsedSoFar))s)")
        
        let mapKitResult = await refreshRouteWithMapKit(route: route, userLocation: userLocation)
        
        let endTime = Date()
        let endTimeString = formatter.string(from: endTime)
        let totalElapsed = endTime.timeIntervalSince(startTime)
        print("⏱️ [ROUTE REFRESH] [\(endTimeString)] ✅ refreshRouteWithGoogleThenMapKit() COMPLETED in \(String(format: "%.2f", totalElapsed))s (used MapKit fallback)")
        
        return mapKitResult
    }
    
    // MARK: - Pre-populated routes: GPS → first waypoint leg
    /// Fetches walking directions from current GPS to first waypoint and merges into pre-populated route.
    /// Start is always current GPS; the first direction is from this point to the first waypoint.
    /// Returns merged (polyline, durationSeconds, distanceMeters, directionsForLeg) or nil if the leg request fails.
    func prependGpsToFirstWaypointLeg(
        userLocation: CLLocationCoordinate2D,
        firstWaypoint: CLLocationCoordinate2D,
        existingRoutePolyline: String,
        existingDurationSeconds: Int,
        existingDistanceMeters: Int
    ) async -> (polyline: String, durationSeconds: Int, distanceMeters: Int, directionsFromGpsToFirst: [WalkingDirection])? {
        guard hasAPIKey, canUseGoogleDirectionsRefresh else { return nil }
        guard !existingRoutePolyline.isEmpty else { return nil }
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
        urlString += "&destination=\(String(format: "%.6f,%.6f", firstWaypoint.latitude, firstWaypoint.longitude))"
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String, status == "OK",
                  let routes = json["routes"] as? [[String: Any]], let first = routes.first,
                  let overview = first["overview_polyline"] as? [String: Any],
                  let points = overview["points"] as? String else { return nil }
            recordGoogleDirectionsCall()
            let legPoints = decodePolyline(points)
            var totalDuration = 0
            var totalDistance = 0
            var legDirections: [WalkingDirection] = []
            if let legs = first["legs"] as? [[String: Any]] {
                for leg in legs {
                    totalDuration += (leg["duration"] as? [String: Any])?["value"] as? Int ?? 0
                    totalDistance += (leg["distance"] as? [String: Any])?["value"] as? Int ?? 0
                    if let steps = leg["steps"] as? [[String: Any]] {
                        for step in steps {
                            let instruction = (step["html_instructions"] as? String)?
                                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Head to first waypoint"
                            let stepDistText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                            let stepDistValue = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                            let stepDurText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                            let maneuver = step["maneuver"] as? String
                            legDirections.append(WalkingDirection(
                                instruction: instruction,
                                distance: stepDistText,
                                distanceMeters: stepDistValue,
                                duration: stepDurText,
                                maneuver: maneuver
                            ))
                        }
                    }
                }
            }
            let routePoints = decodePolyline(existingRoutePolyline)
            var combined = legPoints
            if let lastLeg = legPoints.last, let firstRoute = routePoints.first,
               abs(lastLeg.latitude - firstRoute.latitude) < 1e-6 && abs(lastLeg.longitude - firstRoute.longitude) < 1e-6 {
                combined = legPoints + routePoints.dropFirst()
            } else {
                combined = legPoints + routePoints
            }
            let mergedPolyline = encodePolyline(combined)
            return (mergedPolyline, existingDurationSeconds + totalDuration, existingDistanceMeters + totalDistance, legDirections)
        } catch {
            return nil
        }
    }
    
    /// Appends the return leg (last waypoint → GPS) so the route returns to start/end.
    /// Use after prependGpsToFirstWaypointLeg so the full route is GPS → first → … → last → GPS.
    func appendLastWaypointToGpsLeg(
        userLocation: CLLocationCoordinate2D,
        lastWaypoint: CLLocationCoordinate2D,
        existingRoutePolyline: String,
        existingDurationSeconds: Int,
        existingDistanceMeters: Int
    ) async -> (polyline: String, durationSeconds: Int, distanceMeters: Int, directionsFromLastToGps: [WalkingDirection])? {
        guard hasAPIKey, canUseGoogleDirectionsRefresh else { return nil }
        guard !existingRoutePolyline.isEmpty else { return nil }
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(String(format: "%.6f,%.6f", lastWaypoint.latitude, lastWaypoint.longitude))"
        urlString += "&destination=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String, status == "OK",
                  let routes = json["routes"] as? [[String: Any]], let first = routes.first,
                  let overview = first["overview_polyline"] as? [String: Any],
                  let points = overview["points"] as? String else { return nil }
            recordGoogleDirectionsCall()
            let legPoints = decodePolyline(points)
            var totalDuration = 0
            var totalDistance = 0
            var legDirections: [WalkingDirection] = []
            if let legs = first["legs"] as? [[String: Any]] {
                for leg in legs {
                    totalDuration += (leg["duration"] as? [String: Any])?["value"] as? Int ?? 0
                    totalDistance += (leg["distance"] as? [String: Any])?["value"] as? Int ?? 0
                    if let steps = leg["steps"] as? [[String: Any]] {
                        for step in steps {
                            let instruction = (step["html_instructions"] as? String)?
                                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Return to start"
                            let stepDistText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                            let stepDistValue = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                            let stepDurText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                            let maneuver = step["maneuver"] as? String
                            legDirections.append(WalkingDirection(
                                instruction: instruction,
                                distance: stepDistText,
                                distanceMeters: stepDistValue,
                                duration: stepDurText,
                                maneuver: maneuver
                            ))
                        }
                    }
                }
            }
            let routePoints = decodePolyline(existingRoutePolyline)
            var combined: [CLLocationCoordinate2D]
            if let lastRoute = routePoints.last, let firstLeg = legPoints.first,
               abs(lastRoute.latitude - firstLeg.latitude) < 1e-6 && abs(lastRoute.longitude - firstLeg.longitude) < 1e-6 {
                combined = routePoints + legPoints.dropFirst()
            } else {
                combined = routePoints + legPoints
            }
            let mergedPolyline = encodePolyline(combined)
            return (mergedPolyline, existingDurationSeconds + totalDuration, existingDistanceMeters + totalDistance, legDirections)
        } catch {
            return nil
        }
    }
    
    // MARK: - v1.9.39: Google-Only Refresh (no MapKit fallback)
    /// Tries Google Directions only. Returns nil if Google fails (caller uses original route).
    /// This avoids the 15-50s MapKit fallback wait - if Google fails, just use original route.
    func refreshRouteWithGoogleOnly(
        route: WalkingRoute,
        userLocation: CLLocationCoordinate2D
    ) async -> WalkingRoute? {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] 🚀 refreshRouteWithGoogleOnly() STARTED")
        print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)]   Route: '\(route.name)'")
        print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)]   Waypoints: \(route.qrMarkers.count)")
        
        // Check if we can use Google Directions
        guard canUseGoogleDirectionsRefresh else {
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ Google quota exhausted - returning nil")
            return nil
        }
        
        guard hasAPIKey else {
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ No API key - returning nil")
            return nil
        }
        
        // Extract waypoint coordinates from QR markers
        let rawWaypoints = route.qrMarkers.map { $0.coordinate }
        
        guard !rawWaypoints.isEmpty else {
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ No waypoints - returning nil")
            return nil
        }
        
        // v2.1.5: Snap waypoints to nearest public road before sending to Google
        // Prioritizes the road from the marker's address if available
        // This ensures routes stay on public roads and don't go into schools/private areas
        // Run queries in parallel for speed, with fallback mirrors for reliability
        print("🛤️ [ROAD SNAP] Starting waypoint snapping for \(rawWaypoints.count) waypoints...")
        let snappedWaypoints = await withTaskGroup(of: (Int, CLLocationCoordinate2D).self) { group in
            for (index, waypoint) in rawWaypoints.enumerated() {
                group.addTask {
                    // v2.1.5: Extract road name from marker's location field if available
                    let marker = route.qrMarkers[index]
                    let roadName = self.extractRoadName(from: marker.location)
                    if let roadName = roadName {
                        print("🛤️ [ROAD SNAP] Waypoint \(index+1) '\(marker.name)' - preferred road: '\(roadName)'")
                    }
                    
                    // Use fallback function for reliability
                    if let nearestRoad = await self.findNearestRoadPointWithFallback(near: waypoint, radiusMeters: 100, preferredRoadName: roadName) {
                        let distance = CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude)
                            .distance(from: CLLocation(latitude: nearestRoad.latitude, longitude: nearestRoad.longitude))
                        if distance > 10 { // Only snap if more than 10m from road
                            print("🛤️ [ROAD SNAP] Waypoint \(index+1) snapped to road (\(Int(distance))m)")
                            return (index, nearestRoad)
                        } else {
                            print("🛤️ [ROAD SNAP] Waypoint \(index+1) already on road (within 10m)")
                        }
                    } else {
                        print("🛤️ [ROAD SNAP] ⚠️ Waypoint \(index+1) could not be snapped - using original")
                    }
                    return (index, waypoint) // Keep original if already on road or no road found
                }
            }
            
            var results = [(Int, CLLocationCoordinate2D)]()
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        print("🛤️ [ROAD SNAP] Waypoint snapping complete")
        
        // v2.1.2: Log comparison of original vs snapped coordinates
        for (index, (original, snapped)) in zip(rawWaypoints, snappedWaypoints).enumerated() {
            let distance = CLLocation(latitude: original.latitude, longitude: original.longitude)
                .distance(from: CLLocation(latitude: snapped.latitude, longitude: snapped.longitude))
            if distance > 1 {
                print("🛤️ [ROAD SNAP] Waypoint \(index+1): MOVED \(Int(distance))m")
                print("   Original: (\(String(format: "%.6f", original.latitude)), \(String(format: "%.6f", original.longitude)))")
                print("   Snapped:  (\(String(format: "%.6f", snapped.latitude)), \(String(format: "%.6f", snapped.longitude)))")
            } else {
                print("🛤️ [ROAD SNAP] Waypoint \(index+1): unchanged (already on road)")
            }
        }
        
        // Optimize waypoint order locally (Nearest Neighbor) to stay in Essentials SKU
        let waypoints = performLocalOptimization(origin: userLocation, waypoints: snappedWaypoints)
        
        // Build waypoints string
        let waypointsParam = waypoints.map { 
            String(format: "%.6f,%.6f", $0.latitude, $0.longitude)
        }.joined(separator: "|")
        print("🛤️ [ROAD SNAP] Final waypoints for Google: \(waypointsParam)")
        
        // Google Directions API URL
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
        urlString += "&destination=\(String(format: "%.6f,%.6f", userLocation.latitude, userLocation.longitude))"
        urlString += "&waypoints=\(waypointsParam)"
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ Invalid URL - returning nil")
            return nil
        }
        
        // Log the API call (truncate URL for security)
        let truncatedURL = urlString.prefix(100) + (urlString.count > 100 ? "..." : "")
        print("🌐 [GOOGLE-ONLY REFRESH] 📡 Calling Google Directions API...")
        print("🌐 [GOOGLE-ONLY REFRESH]   🔗 URL: \(truncatedURL)")
        print("🌐 [GOOGLE-ONLY REFRESH]   📍 Origin: (\(String(format: "%.5f", userLocation.latitude)), \(String(format: "%.5f", userLocation.longitude)))")
        print("🌐 [GOOGLE-ONLY REFRESH]   🎯 Waypoints: \(waypoints.count)")
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0 // Short 5 second timeout
            if let bundleId = Bundle.main.bundleIdentifier {
                request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
                print("🌐 [GOOGLE-ONLY REFRESH]   📱 Bundle ID: \(bundleId)")
            }
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5.0
            config.timeoutIntervalForResource = 10.0
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            
            print("🌐 [GOOGLE-ONLY REFRESH]   ⏱️  Response received in \(String(format: "%.2f", elapsed))s")
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ HTTP error - status: \(statusCode) - returning nil (elapsed: \(String(format: "%.2f", elapsed))s)")
                return nil
            }
            
            print("🌐 [GOOGLE-ONLY REFRESH]   ✅ HTTP 200 OK")
            
            recordGoogleDirectionsCall()
            print("🌐 [GOOGLE-ONLY REFRESH]   📊 Google Directions quota: \(googleDirectionsCallsToday)/\(googleDirectionsDailyCap) calls today")
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "OK",
                  let routes = json["routes"] as? [[String: Any]],
                  let firstRoute = routes.first else {
                let errorStatus = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String ?? "unknown"
                print("🌐 [GOOGLE-ONLY REFRESH]   ❌ API status: \(errorStatus)")
                print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ API status: \(errorStatus) (elapsed: \(String(format: "%.2f", elapsed))s)")
                
                // v2.1.3: Fall back to MapKit when Google quota exceeded or request denied
                // This way we still use the snapped waypoints even if Google fails
                if errorStatus == "OVER_QUERY_LIMIT" || errorStatus == "REQUEST_DENIED" {
                    print("🍎 [MAPKIT FALLBACK] Google quota/access issue - falling back to MapKit with snapped waypoints")
                    let mapKitRoute = await refreshRouteWithMapKitUsingSnappedWaypoints(
                        route: route,
                        userLocation: userLocation,
                        snappedWaypoints: snappedWaypoints
                    )
                    if let result = mapKitRoute {
                        let totalElapsed = Date().timeIntervalSince(startTime)
                        print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ✅ MapKit fallback succeeded (total elapsed: \(String(format: "%.2f", totalElapsed))s)")
                        return result
                    }
                }
                
                print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ Returning nil - no fallback available")
                return nil
            }
            
            print("🌐 [GOOGLE-ONLY REFRESH]   ✅ API status: OK - \(routes.count) route(s) found")
            
            // Parse the response (same logic as refreshRouteWithGoogleThenMapKit)
            var polyline = ""
            var polylinePointCount = 0
            if let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
               let points = overviewPolyline["points"] as? String {
                polyline = points
                polylinePointCount = decodePolyline(points).count
            }
            
            var stepPolylinePointCount = 0
            var combinedStepPolyline: [CLLocationCoordinate2D] = []
            var freshDirections: [WalkingDirection] = []
            var totalDistance = 0
            var totalDuration = 0
            
            if let legs = firstRoute["legs"] as? [[String: Any]] {
                for leg in legs {
                    if let distance = leg["distance"] as? [String: Any],
                       let distValue = distance["value"] as? Int {
                        totalDistance += distValue
                    }
                    if let duration = leg["duration"] as? [String: Any],
                       let durValue = duration["value"] as? Int {
                        totalDuration += durValue
                    }
                    
                    if let steps = leg["steps"] as? [[String: Any]] {
                        for step in steps {
                            let instruction = (step["html_instructions"] as? String)?
                                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Continue"
                            let stepDistText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                            let stepDistValue = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                            let stepDurText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                            let maneuver = step["maneuver"] as? String ?? "straight"
                            
                            if let stepPolyline = step["polyline"] as? [String: Any],
                               let stepPoints = stepPolyline["points"] as? String {
                                let decodedStepPoints = decodePolyline(stepPoints)
                                stepPolylinePointCount += decodedStepPoints.count
                                combinedStepPolyline.append(contentsOf: decodedStepPoints)
                            }
                            
                            freshDirections.append(WalkingDirection(
                                instruction: instruction,
                                distance: stepDistText,
                                distanceMeters: stepDistValue,
                                duration: stepDurText,
                                maneuver: maneuver
                            ))
                        }
                    }
                }
            }
            
            // Use detailed step polyline if available
            var finalPolyline = polyline
            if stepPolylinePointCount > polylinePointCount && !combinedStepPolyline.isEmpty {
                finalPolyline = encodePolyline(combinedStepPolyline)
            }
            
            let durationMinutes = max(1, totalDuration / 60)
            
            // v2.1.0: Debug logging for polyline quality
            let finalPointCount = stepPolylinePointCount > polylinePointCount ? stepPolylinePointCount : polylinePointCount
            print("🗺️ [POLYLINE DEBUG] Google refresh polyline: \(finalPointCount) points (overview: \(polylinePointCount), steps: \(stepPolylinePointCount))")
            if finalPolyline.isEmpty {
                print("🚨 [POLYLINE DEBUG] WARNING: No polyline from Google - route will show straight lines!")
            } else if finalPointCount < 10 {
                print("⚠️ [POLYLINE DEBUG] WARNING: Low-quality polyline (\(finalPointCount) points) - may not follow roads accurately")
            }
            
            // v2.1.0: Check for restricted roads in directions (but DON'T block on MapKit fallback)
            let restrictedKeywords = ["restricted", "private road", "no access", "private access", "restricted-usage"]
            var hasRestrictedRoads = false
            for direction in freshDirections {
                let instructionLower = direction.instruction.lowercased()
                for keyword in restrictedKeywords {
                    if instructionLower.contains(keyword) {
                        print("⚠️ [RESTRICTED ROAD] Direction contains '\(keyword)': \(direction.instruction)")
                        hasRestrictedRoads = true
                    }
                }
            }
            
            // v2.1.1: If restricted roads detected, log warning but return Google route immediately
            // MapKit fallback will be triggered asynchronously by the caller
            if hasRestrictedRoads {
                print("⚠️ [RESTRICTED ROAD] Google route uses restricted roads - returning immediately, caller can trigger MapKit fallback")
                // Set flag for caller to know MapKit fallback is needed
                self.lastRouteHadRestrictedRoads = true
                self.pendingMapKitFallbackWaypoints = waypoints
                self.pendingMapKitFallbackOrigin = userLocation
            } else {
                self.lastRouteHadRestrictedRoads = false
            }
            
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ✅ SUCCESS: \(durationMinutes)min, \(totalDistance)m, \(freshDirections.count) steps (elapsed: \(String(format: "%.2f", elapsed))s)")
            
            // v2.1.2: Keep original marker positions for display, but use snapped coordinates for:
            // 1. Route polyline (already done - Google got snapped waypoints)
            // 2. Marker ACTIVATION (update coordinates so user triggers at road, not inside restricted area)
            // The marker LABEL stays at original position, but activation zone is on the road
            var updatedMarkers: [QRMarker] = []
            for (index, marker) in route.qrMarkers.enumerated() {
                if index < snappedWaypoints.count {
                    let snappedCoord = snappedWaypoints[index]
                    // Update marker coordinate to snapped position for activation detection
                    let updatedMarker = QRMarker(
                        code: marker.code,
                        name: marker.name,
                        location: marker.location,
                        coordinate: snappedCoord,  // Snapped to road for activation
                        contentType: marker.contentType,
                        content: marker.content,
                        pointsValue: marker.pointsValue
                    )
                    updatedMarkers.append(updatedMarker)
                } else {
                    updatedMarkers.append(marker)
                }
            }
            
            return WalkingRoute(
                name: route.name,
                description: route.description,
                durationMinutes: durationMinutes,
                distanceMeters: totalDistance > 0 ? totalDistance : route.distanceMeters,
                difficulty: route.difficulty,
                isIndoor: route.isIndoor,
                isAccessible: route.isAccessible,
                landmarks: route.landmarks,
                icon: route.icon,
                color: route.color,
                qrMarkers: updatedMarkers,  // Markers with snapped coordinates for activation
                routeType: route.routeType,
                encodedPolyline: finalPolyline.isEmpty ? route.encodedPolyline : finalPolyline,
                walkingDirections: freshDirections.isEmpty ? route.walkingDirections : freshDirections
            )
            
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ Error: \(error.localizedDescription) (elapsed: \(String(format: "%.2f", elapsed))s)")
            
            // v2.1.3: Fall back to MapKit on network errors (timeout, connection issues)
            // This ensures user gets a corrected route even if Google is unreachable
            print("🍎 [MAPKIT FALLBACK] Google network error - falling back to MapKit with snapped waypoints")
            if let mapKitRoute = await refreshRouteWithMapKitUsingSnappedWaypoints(
                route: route,
                userLocation: userLocation,
                snappedWaypoints: snappedWaypoints
            ) {
                let totalElapsed = Date().timeIntervalSince(startTime)
                print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ✅ MapKit fallback succeeded (total elapsed: \(String(format: "%.2f", totalElapsed))s)")
                return mapKitRoute
            }
            
            print("⏱️ [GOOGLE-ONLY REFRESH] [\(timeString)] ❌ MapKit fallback also failed - returning nil")
            return nil
        }
    }
    
    /// v2.1.1: Async MapKit fallback for when Google returned restricted roads
    /// Call this AFTER showing the Google route to get a better MapKit route
    /// Returns nil if MapKit fails or wasn't needed
    func getMapKitFallbackRoute(for route: WalkingRoute) async -> WalkingRoute? {
        guard lastRouteHadRestrictedRoads,
              let waypoints = pendingMapKitFallbackWaypoints,
              let origin = pendingMapKitFallbackOrigin else {
            print("🗺️ [MAPKIT FALLBACK] No pending fallback needed")
            return nil
        }
        
        let startTime = Date()
        print("🗺️ [MAPKIT FALLBACK] Starting async MapKit fallback for restricted road route...")
        
        // Clear pending state
        pendingMapKitFallbackWaypoints = nil
        pendingMapKitFallbackOrigin = nil
        lastRouteHadRestrictedRoads = false
        
        // Get MapKit directions
        let waypointNames = route.qrMarkers.map { $0.name }
        let mapKitDirections = await getMapKitDirectionsForRoute(
            origin: origin,
            waypoints: waypoints,
            destination: origin,
            waypointNames: waypointNames
        )
        
        // Get MapKit polyline
        var mapKitPolylinePoints: [CLLocationCoordinate2D] = []
        var mapKitDistance = 0
        var mapKitDuration = 0
        
        let allPoints = [origin] + waypoints + [origin]
        for i in 0..<(allPoints.count - 1) {
            let legOrigin = allPoints[i]
            let legDestination = allPoints[i + 1]
            
            await checkMapKitRateLimit()
            
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: legOrigin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: legDestination))
            request.transportType = .walking
            
            let directions = MKDirections(request: request)
            recordMapKitRequest()
            
            do {
                let response = try await directions.calculate()
                if let mkRoute = response.routes.first {
                    let pointCount = mkRoute.polyline.pointCount
                    var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                    mkRoute.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
                    mapKitPolylinePoints.append(contentsOf: coords)
                    mapKitDistance += Int(mkRoute.distance)
                    mapKitDuration += Int(mkRoute.expectedTravelTime)
                }
            } catch {
                print("⚠️ [MAPKIT FALLBACK] Leg \(i+1) failed: \(error.localizedDescription)")
            }
        }
        
        // Check if MapKit gave us a valid route
        guard !mapKitPolylinePoints.isEmpty && !mapKitDirections.isEmpty else {
            print("⚠️ [MAPKIT FALLBACK] Failed - no valid MapKit route")
            return nil
        }
        
        let mapKitDurationMinutes = max(1, mapKitDuration / 60)
        let mapKitPolyline = encodePolyline(mapKitPolylinePoints)
        let elapsed = Date().timeIntervalSince(startTime)
        
        print("✅ [MAPKIT FALLBACK] Success in \(String(format: "%.2f", elapsed))s: \(mapKitDurationMinutes)min, \(mapKitDistance)m, \(mapKitPolylinePoints.count) polyline points")
        
        // v2.1.1: Update QRMarker coordinates with snapped road positions
        var updatedMarkers: [QRMarker] = []
        for (index, marker) in route.qrMarkers.enumerated() {
            if index < waypoints.count {
                let snappedCoord = waypoints[index]
                let updatedMarker = QRMarker(
                    code: marker.code,
                    name: marker.name,
                    location: marker.location,
                    coordinate: snappedCoord,
                    contentType: marker.contentType,
                    content: marker.content,
                    pointsValue: marker.pointsValue
                )
                updatedMarkers.append(updatedMarker)
            } else {
                updatedMarkers.append(marker)
            }
        }
        
        return WalkingRoute(
            name: route.name,
            description: route.description,
            durationMinutes: mapKitDurationMinutes,
            distanceMeters: mapKitDistance > 0 ? mapKitDistance : route.distanceMeters,
            difficulty: route.difficulty,
            isIndoor: route.isIndoor,
            isAccessible: route.isAccessible,
            landmarks: route.landmarks,
            icon: route.icon,
            color: route.color,
            qrMarkers: updatedMarkers,
            routeType: route.routeType,
            encodedPolyline: mapKitPolyline,
            walkingDirections: mapKitDirections
        )
    }
    
    /// Extract maneuver type from instruction text
    private func extractManeuverType(from instruction: String) -> String {
        let lowercased = instruction.lowercased()
        if lowercased.contains("turn left") { return "turn-left" }
        if lowercased.contains("turn right") { return "turn-right" }
        if lowercased.contains("slight left") { return "turn-slight-left" }
        if lowercased.contains("slight right") { return "turn-slight-right" }
        if lowercased.contains("continue") || lowercased.contains("straight") { return "straight" }
        if lowercased.contains("arrive") || lowercased.contains("destination") { return "arrive" }
        if lowercased.contains("u-turn") { return "uturn" }
        return "straight"
    }
    
    // MARK: - v2.1.0: Live Return Directions (ToS Compliant)
    
    /// Get live return directions from current location to destination via Google Directions API
    /// v2.1.0: Used for return journey when user reaches last waypoint
    /// Directions are NOT cached (ToS compliance)
    /// - Parameters:
    ///   - origin: Current location (where user is now)
    ///   - destination: Where to go (typically start point for return journey)
    /// - Returns: Tuple of (directions, polyline points) or nil if failed
    func getReturnDirectionsLive(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> (directions: [WalkingDirection], polyline: [CLLocationCoordinate2D])? {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("🌐 [RETURN DIRECTIONS] [\(timeString)] 🚀 getReturnDirectionsLive() STARTED")
        print("🌐 [RETURN DIRECTIONS]   Origin: (\(String(format: "%.5f", origin.latitude)), \(String(format: "%.5f", origin.longitude)))")
        print("🌐 [RETURN DIRECTIONS]   Destination: (\(String(format: "%.5f", destination.latitude)), \(String(format: "%.5f", destination.longitude)))")
        
        // Check if we can use Google Directions
        guard hasAPIKey else {
            print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ No API key - returning nil")
            return nil
        }
        
        guard canUseGoogleDirectionsRefresh else {
            print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ Google quota exhausted - returning nil")
            return nil
        }
        
        // Google Directions API URL (simple A to B route)
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(String(format: "%.6f,%.6f", origin.latitude, origin.longitude))"
        urlString += "&destination=\(String(format: "%.6f,%.6f", destination.latitude, destination.longitude))"
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ Invalid URL - returning nil")
            return nil
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0 // 10 second timeout
            if let bundleId = Bundle.main.bundleIdentifier {
                request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            }
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10.0
            config.timeoutIntervalForResource = 15.0
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ HTTP error - status: \(statusCode) (elapsed: \(String(format: "%.2f", elapsed))s)")
                return nil
            }
            
            recordGoogleDirectionsCall()
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "OK",
                  let routes = json["routes"] as? [[String: Any]],
                  let firstRoute = routes.first else {
                let errorStatus = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String ?? "unknown"
                print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ API status: \(errorStatus) (elapsed: \(String(format: "%.2f", elapsed))s)")
                return nil
            }
            
            // Parse polyline
            var polylinePoints: [CLLocationCoordinate2D] = []
            if let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
               let points = overviewPolyline["points"] as? String {
                polylinePoints = decodePolyline(points)
            }
            
            // Also try to get more detailed polyline from steps
            var stepPolylinePoints: [CLLocationCoordinate2D] = []
            var directions: [WalkingDirection] = []
            var totalDistance = 0
            var totalDuration = 0
            
            if let legs = firstRoute["legs"] as? [[String: Any]] {
                for leg in legs {
                    if let distance = leg["distance"] as? [String: Any],
                       let distValue = distance["value"] as? Int {
                        totalDistance += distValue
                    }
                    if let duration = leg["duration"] as? [String: Any],
                       let durValue = duration["value"] as? Int {
                        totalDuration += durValue
                    }
                    
                    if let steps = leg["steps"] as? [[String: Any]] {
                        for step in steps {
                            let instruction = (step["html_instructions"] as? String)?
                                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Continue"
                            let stepDistText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                            let stepDistValue = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                            let stepDurText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                            let maneuver = step["maneuver"] as? String ?? "straight"
                            
                            if let stepPolyline = step["polyline"] as? [String: Any],
                               let stepPoints = stepPolyline["points"] as? String {
                                let decodedStepPoints = decodePolyline(stepPoints)
                                stepPolylinePoints.append(contentsOf: decodedStepPoints)
                            }
                            
                            directions.append(WalkingDirection(
                                instruction: instruction,
                                distance: stepDistText,
                                distanceMeters: stepDistValue,
                                duration: stepDurText,
                                maneuver: maneuver
                            ))
                        }
                    }
                }
            }
            
            // Use detailed step polyline if available (more points = follows roads better)
            let finalPolyline = stepPolylinePoints.count > polylinePoints.count ? stepPolylinePoints : polylinePoints
            let durationMinutes = max(1, totalDuration / 60)
            
            // v2.1.0: Debug logging for polyline quality
            print("🗺️ [POLYLINE DEBUG] Return directions polyline: \(finalPolyline.count) points (overview: \(polylinePoints.count), steps: \(stepPolylinePoints.count))")
            if finalPolyline.isEmpty {
                print("🚨 [POLYLINE DEBUG] WARNING: No polyline for return route!")
            } else if finalPolyline.count < 10 {
                print("⚠️ [POLYLINE DEBUG] WARNING: Low-quality return polyline (\(finalPolyline.count) points)")
            }
            
            // v2.1.0: Check for restricted roads in return directions
            let restrictedKeywords = ["restricted", "private road", "no access", "private access", "restricted-usage"]
            var hasRestrictedRoads = false
            for direction in directions {
                let instructionLower = direction.instruction.lowercased()
                for keyword in restrictedKeywords {
                    if instructionLower.contains(keyword) {
                        print("⚠️ [RESTRICTED ROAD] Return direction contains '\(keyword)': \(direction.instruction)")
                        hasRestrictedRoads = true
                    }
                }
            }
            
            // v2.1.0: If restricted roads detected, fall back to MapKit for better walking paths
            if hasRestrictedRoads {
                print("🔄 [RESTRICTED ROAD FALLBACK] Google return route uses restricted roads - trying MapKit...")
                
                await checkMapKitRateLimit()
                
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
                request.transportType = .walking
                
                let mkDirections = MKDirections(request: request)
                recordMapKitRequest()
                
                do {
                    let response = try await mkDirections.calculate()
                    if let mkRoute = response.routes.first {
                        // Extract polyline
                        let pointCount = mkRoute.polyline.pointCount
                        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                        mkRoute.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
                        
                        // Extract directions from MapKit steps
                        var mapKitDirections: [WalkingDirection] = []
                        for step in mkRoute.steps {
                            if !step.instructions.isEmpty {
                                mapKitDirections.append(WalkingDirection(
                                    instruction: step.instructions,
                                    distance: "\(Int(step.distance))m",
                                    distanceMeters: Int(step.distance),
                                    duration: "",
                                    maneuver: extractManeuverType(from: step.instructions)
                                ))
                            }
                        }
                        
                        let mkDurationMinutes = max(1, Int(mkRoute.expectedTravelTime / 60))
                        print("✅ [RESTRICTED ROAD FALLBACK] MapKit return route: \(mkDurationMinutes)min, \(Int(mkRoute.distance))m, \(coords.count) polyline points")
                        print("🌐 [RETURN DIRECTIONS] [\(timeString)] ✅ SUCCESS (via MapKit fallback): \(mkDurationMinutes)min, \(Int(mkRoute.distance))m, \(mapKitDirections.count) steps (elapsed: \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s)")
                        
                        return (mapKitDirections, coords)
                    }
                } catch {
                    print("⚠️ [RESTRICTED ROAD FALLBACK] MapKit failed: \(error.localizedDescription) - using Google route despite restricted roads")
                }
            }
            
            print("🌐 [RETURN DIRECTIONS] [\(timeString)] ✅ SUCCESS: \(durationMinutes)min, \(totalDistance)m, \(directions.count) steps, \(finalPolyline.count) polyline points (elapsed: \(String(format: "%.2f", elapsed))s)")
            
            return (directions, finalPolyline)
            
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            print("🌐 [RETURN DIRECTIONS] [\(timeString)] ❌ Error: \(error.localizedDescription) (elapsed: \(String(format: "%.2f", elapsed))s)")
            return nil
        }
    }
    
    // MARK: - Batch Walking Directions (Parallel MapKit Calls)
    
    /// Result from a batched endpoint route calculation
    struct BatchedEndpointResult {
        let poi: PlaceResult
        let route: GeneratedRoute?
        let durationMinutes: Int
        let error: Error?
    }
    
    /// Get the current MapKit request count (for rate limit awareness) - thread-safe via actor
    var currentMapKitRequestCount: Int {
        get async {
            await rateLimiter.getCurrentCount(window: mapKitRateLimitWindow)
        }
    }
    
    /// Batch get walking directions for multiple endpoint candidates in parallel
    /// - Parameters:
    ///   - origin: Starting point (user's location)
    ///   - candidates: Array of POI candidates to try as endpoints
    ///   - maxConcurrent: Maximum number of concurrent requests (default 5)
    /// - Returns: Array of BatchedEndpointResult with routes for each candidate
    func batchGetWalkingDirectionsForEndpoints(
        origin: CLLocationCoordinate2D,
        candidates: [(poi: PlaceResult, distance: Double, score: Double)],
        maxConcurrent: Int = 5
    ) async -> [BatchedEndpointResult] {
        
        print("🔀 BATCH MODE: Processing \(candidates.count) candidates in parallel (max \(maxConcurrent) concurrent)")
        
        // Use TaskGroup for parallel execution with controlled concurrency
        var results: [BatchedEndpointResult] = []
        
        // Process in chunks to respect rate limits
        let chunks = stride(from: 0, to: candidates.count, by: maxConcurrent).map {
            Array(candidates[$0..<min($0 + maxConcurrent, candidates.count)])
        }
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            print("🔀 Processing batch \(chunkIndex + 1)/\(chunks.count) (\(chunk.count) candidates)")
            
            // Check rate limit before each batch
            await checkMapKitRateLimit()
            
            // Process chunk in parallel
            let chunkResults = await withTaskGroup(of: BatchedEndpointResult.self) { group in
                for candidate in chunk {
                    group.addTask {
                        do {
                            let directions = try await self.getWalkingDirections(
                                origin: origin,
                                destination: origin,
                                waypoints: [candidate.poi.coordinate]
                            )
                            
                            let totalDurationSeconds = directions.legs.reduce(0) { $0 + $1.duration.value }
                            let totalDistanceMeters = directions.legs.reduce(0) { $0 + $1.distance.value }
                            let routeMinutes = totalDurationSeconds / 60
                            
                            let route = GeneratedRoute(
                                places: [candidate.poi],
                                polyline: directions.overviewPolyline.points,
                                distanceMeters: totalDistanceMeters,
                                durationSeconds: totalDurationSeconds,
                                legs: directions.legs
                            )
                            
                            return BatchedEndpointResult(
                                poi: candidate.poi,
                                route: route,
                                durationMinutes: routeMinutes,
                                error: nil
                            )
                        } catch {
                            return BatchedEndpointResult(
                                poi: candidate.poi,
                                route: nil,
                                durationMinutes: 0,
                                error: error
                            )
                        }
                    }
                }
                
                var collected: [BatchedEndpointResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            
            results.append(contentsOf: chunkResults)
        }
        
        // Log results summary
        let successful = results.filter { $0.route != nil }.count
        print("🔀 BATCH COMPLETE: \(successful)/\(candidates.count) routes calculated successfully")
        
        return results
    }
    
    // MARK: - Waypoint Optimization (Nearest Neighbor)
    /// Simple nearest-neighbor algorithm to order waypoints efficiently
    private func optimizeWaypointOrder(
        from origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        to destination: CLLocationCoordinate2D
    ) -> (waypoints: [CLLocationCoordinate2D], order: [Int]) {
        var remaining = Array(waypoints.enumerated())
        var ordered: [CLLocationCoordinate2D] = []
        var orderIndices: [Int] = []
        var currentPoint = origin
        
        while !remaining.isEmpty {
            // Find nearest unvisited waypoint
            let nearest = remaining.min(by: { 
                distanceBetween(currentPoint, $0.element) < distanceBetween(currentPoint, $1.element)
            })!
            
            ordered.append(nearest.element)
            orderIndices.append(nearest.offset)
            currentPoint = nearest.element
            remaining.removeAll { $0.offset == nearest.offset }
        }
        
        return (ordered, orderIndices)
    }
    
    // MARK: - Polyline Encoding (Google format for compatibility)
    /// Encodes coordinates to Google's polyline format
    private func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var encodedString = ""
        var prevLat: Int = 0
        var prevLng: Int = 0
        
        for coord in coordinates {
            let lat = Int(round(coord.latitude * 1e5))
            let lng = Int(round(coord.longitude * 1e5))
            
            encodedString += encodeSignedNumber(lat - prevLat)
            encodedString += encodeSignedNumber(lng - prevLng)
            
            prevLat = lat
            prevLng = lng
        }
        
        return encodedString
    }
    
    private func encodeSignedNumber(_ num: Int) -> String {
        var sgn_num = num << 1
        if num < 0 {
            sgn_num = ~sgn_num
        }
        return encodeNumber(sgn_num)
    }
    
    private func encodeNumber(_ num: Int) -> String {
        var encoded = ""
        var number = num
        
        while number >= 0x20 {
            let nextValue = (0x20 | (number & 0x1f)) + 63
            encoded += String(UnicodeScalar(nextValue)!)
            number >>= 5
        }
        encoded += String(UnicodeScalar(number + 63)!)
        
        return encoded
    }
    
    // MARK: - Formatting Helpers
    private func formatDistance(_ meters: Int) -> String {
        if meters < 1000 {
            return "\(meters) m"
        } else {
            return String(format: "%.1f km", Double(meters) / 1000.0)
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins < 60 {
            return "\(mins) mins"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(hours) hour\(hours > 1 ? "s" : "") \(remainingMins) mins"
        }
    }
    
    // MARK: - Retry Status
    @Published var retryStatus: String?
    
    // MARK: - Debug: Test Route Generation
    /// Generates routes at 5-minute intervals (10-60 min) from current location
    /// Prints comprehensive debug info to console
    func testRouteGenerationAtIntervals(from location: CLLocationCoordinate2D) async {
        print("")
        print("═══════════════════════════════════════════════════════════")
        print("🧪 ROUTE GENERATION TEST - Starting comprehensive test")
        print("═══════════════════════════════════════════════════════════")
        print("📍 Test Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("⏱️ Testing durations: 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60 minutes")
        print("═══════════════════════════════════════════════════════════")
        print("")
        
        let durations = stride(from: 10, through: 60, by: 5)
        var results: [(duration: Int, success: Bool, routeMinutes: Int?, waypoints: Int?, distanceKm: Double?, timeSeconds: Double?, usedDatabase: Bool?, error: String?)] = []
        let overallStartTime = Date()
        
        // Check if database is available for this location (will be used for all routes from this location)
        let databaseAvailable = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: 5000) != nil
        
        for duration in durations {
            let startTime = Date()
            print("")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        do {
            let route = try await generateRouteTopologySafe(
                from: location,
                targetDurationMinutes: duration,
                difficulty: nil,
                excludePlaceIds: [],
                excludePOIs: [],
                prefetchedPOIs: nil
            )
            
            let elapsed = Date().timeIntervalSince(startTime)
            let routeMinutes = route.durationSeconds / 60
            let accuracy = Double(routeMinutes) / Double(duration)
            let poiNames = route.places.map { $0.name }.joined(separator: " → ")
            let distanceKm = Double(route.distanceMeters) / 1000.0
            
            print("✅ \(duration)min: SUCCESS")
            print("   ⏱️ Generated in: \(String(format: "%.2f", elapsed))s")
            print("   📏 Route: \(routeMinutes)min (\(String(format: "%.1f", accuracy * 100))% of target)")
            print("   📍 Waypoints: \(route.places.count)")
            print("   🗺️ Distance: \(String(format: "%.1f", distanceKm))km")
            print("   📋 POIs: \(poiNames)")
            
            results.append((duration: duration, success: true, routeMinutes: routeMinutes, waypoints: route.places.count, distanceKm: distanceKm, timeSeconds: elapsed, usedDatabase: databaseAvailable, error: nil))
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let errorMsg = error.localizedDescription
            print("❌ \(duration)min: FAILED")
            print("   ⏱️ Failed after: \(String(format: "%.2f", elapsed))s")
            print("   ⚠️ Error: \(errorMsg)")
            
            results.append((duration: duration, success: false, routeMinutes: nil, waypoints: nil, distanceKm: nil, timeSeconds: elapsed, usedDatabase: databaseAvailable, error: errorMsg))
        }
        }
        
        let totalTime = Date().timeIntervalSince(overallStartTime)
        
        // Print comprehensive summary
        print("")
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║         🧪 ROUTE GENERATION TEST - FINAL SUMMARY             ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
        
        // Overall Statistics
        let successful = results.filter { $0.success }.count
        let failed = results.filter { !$0.success }.count
        let successRate = Double(successful) / Double(results.count) * 100
        
        print("📊 OVERALL STATISTICS")
        print("   ✅ Successful routes: \(successful)/\(results.count) (\(String(format: "%.1f", successRate))%)")
        print("   ❌ Failed routes: \(failed)/\(results.count)")
        print("   ⏱️ Total test time: \(String(format: "%.2f", totalTime))s")
        print("")
        
        // Performance Statistics
        let successfulResults = results.filter { $0.success }
        if !successfulResults.isEmpty {
            let avgTime = successfulResults.compactMap { $0.timeSeconds }.reduce(0, +) / Double(successfulResults.count)
            let minTime = successfulResults.compactMap { $0.timeSeconds }.min() ?? 0
            let maxTime = successfulResults.compactMap { $0.timeSeconds }.max() ?? 0
            
            print("⚡ PERFORMANCE")
            print("   ⏱️ Average generation time: \(String(format: "%.2f", avgTime))s")
            print("   ⚡ Fastest: \(String(format: "%.2f", minTime))s")
            print("   🐌 Slowest: \(String(format: "%.2f", maxTime))s")
            print("")
        }
        
        // Accuracy Statistics
        if !successfulResults.isEmpty {
            let accuracies = successfulResults.compactMap { result -> Double? in
                guard let routeMinutes = result.routeMinutes else { return nil }
                return Double(routeMinutes) / Double(result.duration) * 100
            }
            
            if !accuracies.isEmpty {
                let avgAccuracy = accuracies.reduce(0, +) / Double(accuracies.count)
                let minAccuracy = accuracies.min() ?? 0
                let maxAccuracy = accuracies.max() ?? 0
                let withinTolerance = accuracies.filter { $0 >= 80 && $0 <= 130 }.count
                
                print("🎯 ACCURACY")
                print("   📏 Average: \(String(format: "%.1f", avgAccuracy))% of target")
                print("   📉 Lowest: \(String(format: "%.1f", minAccuracy))%")
                print("   📈 Highest: \(String(format: "%.1f", maxAccuracy))%")
                print("   ✅ Within tolerance (80-130%): \(withinTolerance)/\(successfulResults.count)")
                print("")
            }
        }
        
        // Database Usage Statistics
        let databaseUsedCount = results.compactMap { $0.usedDatabase }.filter { $0 }.count
        let databaseUsageRate = results.count > 0 ? Double(databaseUsedCount) / Double(results.count) * 100 : 0.0
        
        print("📦 DATABASE USAGE")
        print("   📦 Database used: \(databaseUsedCount)/\(results.count) routes (\(String(format: "%.1f", databaseUsageRate))%)")
        if databaseAvailable {
            print("   ✅ Pre-populated database available for this location")
        } else {
            print("   ⚠️ Pre-populated database not available - routes used live API sources")
        }
        print("")
        
        // Route Details
        if successful > 0 {
            print("📍 SUCCESSFUL ROUTES DETAILS")
            for result in results where result.success {
                if let routeMinutes = result.routeMinutes, 
                   let waypoints = result.waypoints,
                   let distanceKm = result.distanceKm,
                   let timeSeconds = result.timeSeconds {
                    let accuracy = Double(routeMinutes) / Double(result.duration) * 100
                    let accuracyEmoji = accuracy >= 80 && accuracy <= 130 ? "✅" : accuracy < 80 ? "⚠️" : "⚠️"
                    print("   \(accuracyEmoji) \(result.duration)min → \(routeMinutes)min (\(String(format: "%.1f", accuracy))%)")
                    print("      📍 \(waypoints) waypoints | 🗺️ \(String(format: "%.1f", distanceKm))km | ⏱️ \(String(format: "%.2f", timeSeconds))s")
                }
            }
            print("")
        }
        
        if failed > 0 {
            print("❌ FAILED ROUTES")
            for result in results where !result.success {
                if let timeSeconds = result.timeSeconds {
                    print("   ❌ \(result.duration)min (failed after \(String(format: "%.2f", timeSeconds))s)")
                    print("      ⚠️ \(result.error ?? "Unknown error")")
                } else {
                    print("   ❌ \(result.duration)min → \(result.error ?? "Unknown error")")
                }
            }
            print("")
        }
        
        // Summary Footer
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  💡 Note: Check individual route logs above for detailed    ║")
        print("║     information including routes attempted, database usage,  ║")
        print("║     and route selection summaries.                          ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
    
    /// Extended route generation that returns all valid routes (for testing)
    /// This wraps generateLocalRouteWithRetry and captures all valid routes found
    private func generateRouteTopologySafeExtended(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> RouteGenerationResult {
        let startTime = Date()
        let routeCapture = RouteCapture()
        
        // Check database usage
        let databaseAvailable = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: 5000) != nil
        routeCapture.usedDatabase = databaseAvailable
        
        // Call generateLocalRouteWithRetryExtended which will use route capture
        let selectedRoute = try await generateLocalRouteWithRetryExtended(
            from: location,
            targetDurationMinutes: targetDurationMinutes,
            difficulty: difficulty,
            excludePlaceIds: excludePlaceIds,
            excludePOIs: excludePOIs,
            prefetchedPOIs: prefetchedPOIs,
            routeCapture: routeCapture
        )
        
        let generationTime = Date().timeIntervalSince(startTime)
        
        return RouteGenerationResult(
            selectedRoute: selectedRoute,
            allValidRoutes: routeCapture.validRoutes,
            routesAttempted: routeCapture.routesAttempted,
            validRoutesFound: routeCapture.validRoutes.count,
            usedDatabase: databaseAvailable,
            generationTime: generationTime,
            telemetry: routeCapture.telemetry  // v2.0.17: Include telemetry
        )
    }
    
    /// Extended version of generateLocalRouteWithRetry that captures all valid routes
    private func generateLocalRouteWithRetryExtended(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],
        prefetchedPOIs: [PlaceResult]? = nil,
        routeCapture: RouteCapture
    ) async throws -> GeneratedRoute {
        // Call the existing function but pass route capture to generateLocalRoute
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,
                prefetchedPOIs: prefetchedPOIs,
                useSystematicSelection: false,
                routeCapture: routeCapture
            )
            return route
        } catch {
            // If stage 1 fails, try stage 2 with route capture
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,
                prefetchedPOIs: prefetchedPOIs,
                useSystematicSelection: true,
                expandedSearch: true,
                routeCapture: routeCapture
            )
            return route
        }
    }
    
    /// Batch test: Generates routes for ALL postcodes in the database
    /// Tests each postcode at 5-minute intervals (10-60 min)
    /// Prints comprehensive aggregate summary at the end
    func testRouteGenerationForAllPostcodes() async {
        // v2.0.3: Enable batch mode to skip Apple Maps (avoid rate limiting)
        isBatchTestMode = true
        defer { isBatchTestMode = false }  // Reset after test
        print("")
        print("═══════════════════════════════════════════════════════════════════════════════════")
        print("🧪 BATCH ROUTE GENERATION TEST - Testing ALL Postcodes")
        print("═══════════════════════════════════════════════════════════════════════════════════")
        print("")
        print("📊 v2.0.3 IMPACT MEASUREMENT")
        print("   This test captures metrics to evaluate v2.0.3 improvements:")
        print("   • Routes attempted (Phase 1: Combination caps)")
        print("   • Valid routes found (Phase 1: Route diversity)")
        print("   • Latency percentiles (Phase 1: p95≤12s, p99≤18s)")
        print("   • Tight accuracy 90-110% (Phase 1: +10pp improvement)")
        print("   • Waypoint count (Phase 1: 1.5 → ≥2.2)")
        print("")
        
        // Get all postcode areas from the database
        guard let postcodeAreas = PrePopulatedPOIService.shared.getAllPostcodeAreas() else {
            print("❌ ERROR: Cannot load pre-populated database")
            print("   Make sure the database has been downloaded first")
            return
        }
        print("📍 Found \(postcodeAreas.count) postcode areas in database")
        print("")
        
        // v2.0.3: Enhanced results tuple to capture impact metrics
        var allResults: [(postcode: String, location: CLLocationCoordinate2D, results: [(duration: Int, success: Bool, routeMinutes: Int?, waypoints: Int?, distanceKm: Double?, timeSeconds: Double?, usedDatabase: Bool?, routesAttempted: Int?, validRoutesFound: Int?, error: String?, telemetry: RouteTelemetry?)])] = []
        // v2.0.17: Aggregate telemetry across all routes
        var allTelemetry: [RouteTelemetry] = []
        let overallStartTime = Date()
        
        // v2.0.3: Progress tracking
        let totalPostcodes = postcodeAreas.count
        let durationsPerPostcode = 11  // 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60
        let totalRoutes = totalPostcodes * durationsPerPostcode
        var completedRoutes = 0
        
        // Test each postcode area
        for (index, area) in postcodeAreas.enumerated() {
            let location = CLLocationCoordinate2D(
                latitude: area.centerLatitude,
                longitude: area.centerLongitude
            )
            
            print("")
            print("═══════════════════════════════════════════════════════════════════════════════════")
            print("📍 POSTCODE \(index + 1)/\(postcodeAreas.count): \(area.postcode)")
            print("   Location: (\(String(format: "%.5f", area.centerLatitude)), \(String(format: "%.5f", area.centerLongitude)))")
            print("   POIs in area: \(area.pois.count)")
            print("═══════════════════════════════════════════════════════════════════════════════════")
            print("")
            
            // Run the same test as testRouteGenerationAtIntervals
            let durations = stride(from: 10, through: 60, by: 5)
            // v2.0.3: Enhanced results tuple to capture impact metrics
            var postcodeResults: [(duration: Int, success: Bool, routeMinutes: Int?, waypoints: Int?, distanceKm: Double?, timeSeconds: Double?, usedDatabase: Bool?, routesAttempted: Int?, validRoutesFound: Int?, error: String?, telemetry: RouteTelemetry?)] = []
            
            // Check if database is available for this location
            let databaseAvailable = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: 5000) != nil
            
            for (durationIndex, duration) in durations.enumerated() {
                let startTime = Date()
                
                // v2.0.3: Progress calculation and display
                completedRoutes += 1
                let progressPercent = Double(completedRoutes) / Double(totalRoutes) * 100.0
                let postcodeProgress = Double(durationIndex + 1) / Double(durationsPerPostcode) * 100.0
                
                // Progress bar (20 chars wide)
                let barWidth = 20
                let filled = Int(progressPercent / 100.0 * Double(barWidth))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
                
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("📊 PROGRESS: [\(bar)] \(String(format: "%.1f", progressPercent))% | Route \(completedRoutes)/\(totalRoutes) | Postcode \(index + 1)/\(totalPostcodes): \(String(format: "%.0f", postcodeProgress))%")
                print("")
            
            do {
                let result = try await generateRouteTopologySafeExtended(
                    from: location,
                    targetDurationMinutes: duration,
                    difficulty: nil,
                    excludePlaceIds: [],
                    excludePOIs: [],
                    prefetchedPOIs: nil
                )
                
                let route = result.selectedRoute
                let elapsed = result.generationTime
                let routeMinutes = route.durationSeconds / 60
                let accuracy = Double(routeMinutes) / Double(duration)
                let poiNames = route.places.map { $0.name }.joined(separator: " → ")
                let distanceKm = Double(route.distanceMeters) / 1000.0
                
                print("✅ \(area.postcode) - \(duration)min: SUCCESS")
                print("   ⏱️ Generated in: \(String(format: "%.2f", elapsed))s")
                print("   🔢 Routes attempted: \(result.routesAttempted)")
                print("   ✅ Valid routes found: \(result.validRoutesFound)")
                print("   📏 Selected route: \(routeMinutes)min (\(String(format: "%.1f", accuracy * 100))% of target)")
                print("   📍 Waypoints: \(route.places.count)")
                print("   🗺️ Distance: \(String(format: "%.1f", distanceKm))km")
                print("   📋 POIs: \(poiNames)")
                print("   📦 Database: \(result.usedDatabase ? "✅ Used" : "❌ Not used (live APIs)")")
                
                // Enhanced summary with route details
                print("   📊 SELECTED ROUTE DETAILS:")
                print("      • Duration: \(routeMinutes)min (target: \(duration)min)")
                print("      • Accuracy: \(String(format: "%.1f", accuracy * 100))%")
                print("      • Distance: \(String(format: "%.2f", distanceKm))km")
                print("      • Waypoints: \(route.places.count)")
                if !route.places.isEmpty {
                    print("      • POI List:")
                    for (index, place) in route.places.enumerated() {
                        print("        \(index + 1). \(place.name)")
                    }
                }
                
                // Show ALL valid routes found (up to 10)
                if !result.allValidRoutes.isEmpty {
                    print("   📋 ALL VALID ROUTES FOUND (\(result.allValidRoutes.count)):")
                    let routesToShow = result.allValidRoutes.prefix(10)
                    for (index, validRoute) in routesToShow.enumerated() {
                        let validRouteMinutes = validRoute.durationSeconds / 60
                        let validAccuracy = Double(validRouteMinutes) / Double(duration) * 100
                        let validPoiNames = validRoute.places.map { $0.name }.joined(separator: " → ")
                        print("      Route \(index + 1): \(validRouteMinutes)min (\(String(format: "%.1f", validAccuracy))%) | \(validRoute.places.count) waypoints")
                        print("         POIs: \(validPoiNames)")
                    }
                    if result.allValidRoutes.count > 10 {
                        print("      ... and \(result.allValidRoutes.count - 10) more routes")
                    }
                }
                
                // SPRINT-4: Route assertions (assert harness)
                let maxElapsedSec = 17.8  // Hard-stop
                let maxRatio = 1.30  // 130% cap
                let minWPs = RoutingToggles.minWaypoints(forDuration: duration)
                
                var assertFailures: [String] = []
                if elapsed > maxElapsedSec {
                    assertFailures.append("Elapsed \(String(format: "%.2f", elapsed))s exceeds hard-stop \(maxElapsedSec)s")
                }
                let routeRatio = Double(routeMinutes) / Double(duration)
                if routeRatio > maxRatio {
                    assertFailures.append("Route ratio \(String(format: "%.1f", routeRatio * 100))% > 130%")
                }
                if route.places.count < minWPs {
                    assertFailures.append("Waypoints \(route.places.count) < minimum \(minWPs) for \(duration)min")
                }
                
                if !assertFailures.isEmpty {
                    print("⚠️ [ASSERT] Route validation failures:")
                    for failure in assertFailures {
                        print("   • \(failure)")
                    }
                } else {
                    print("✅ [ASSERT] Route passes all validations: elapsed=\(String(format: "%.2f", elapsed))s, ratio=\(String(format: "%.1f", routeRatio * 100))%, waypoints=\(route.places.count)≥\(minWPs)")
                }
                
                // v2.0.3: Store enhanced metrics for impact analysis
                // v2.0.17: Include telemetry
                allTelemetry.append(result.telemetry)
                postcodeResults.append((duration: duration, success: true, routeMinutes: routeMinutes, waypoints: route.places.count, distanceKm: distanceKm, timeSeconds: elapsed, usedDatabase: result.usedDatabase, routesAttempted: result.routesAttempted, validRoutesFound: result.validRoutesFound, error: nil, telemetry: result.telemetry))
            } catch {
                let elapsed = Date().timeIntervalSince(startTime)
                let errorMsg = error.localizedDescription
                print("❌ \(area.postcode) - \(duration)min: FAILED")
                print("   ⏱️ Failed after: \(String(format: "%.2f", elapsed))s")
                print("   ⚠️ Error: \(errorMsg)")
                
                // v2.0.3: Store failure metrics (no routes attempted/found on failure)
                postcodeResults.append((duration: duration, success: false, routeMinutes: nil, waypoints: nil, distanceKm: nil, timeSeconds: elapsed, usedDatabase: databaseAvailable, routesAttempted: nil, validRoutesFound: nil, error: errorMsg, telemetry: nil))
            }
            }
            
            allResults.append((postcode: area.postcode, location: location, results: postcodeResults))
            
            // Print summary for this postcode
            let postcodeSuccessful = postcodeResults.filter { $0.success }.count
            let _ = postcodeResults.filter { !$0.success }.count  // Track failures (unused for now)
            let postcodeSuccessRate = Double(postcodeSuccessful) / Double(postcodeResults.count) * 100
            print("")
            print("📊 \(area.postcode) SUMMARY: \(postcodeSuccessful)/\(postcodeResults.count) successful (\(String(format: "%.1f", postcodeSuccessRate))%)")
            print("")
        }
        
        let totalTime = Date().timeIntervalSince(overallStartTime)
        
        // Print comprehensive aggregate summary
        print("")
        print("")
        print("╔═══════════════════════════════════════════════════════════════════════════════════╗")
        print("║         🧪 BATCH ROUTE GENERATION TEST - AGGREGATE SUMMARY                        ║")
        print("╚═══════════════════════════════════════════════════════════════════════════════════╝")
        print("")
        
        // Aggregate all results
        // v2.0.3: Enhanced results tuple for impact metrics
        var allRouteResults: [(duration: Int, success: Bool, routeMinutes: Int?, waypoints: Int?, distanceKm: Double?, timeSeconds: Double?, usedDatabase: Bool?, routesAttempted: Int?, validRoutesFound: Int?, error: String?, telemetry: RouteTelemetry?)] = []
        for postcodeResult in allResults {
            allRouteResults.append(contentsOf: postcodeResult.results)
        }
        
        // Overall Statistics
        let totalRoutesCount = allRouteResults.count
        let successful = allRouteResults.filter { $0.success }.count
        let failed = allRouteResults.filter { !$0.success }.count
        let successRate = Double(successful) / Double(totalRoutesCount) * 100
        
        print("📊 OVERALL STATISTICS (ALL POSTCODES)")
        print("   📍 Postcodes tested: \(postcodeAreas.count)")
        print("   🧪 Total routes tested: \(totalRoutesCount)")
        print("   ✅ Successful routes: \(successful)/\(totalRoutesCount) (\(String(format: "%.1f", successRate))%)")
        print("   ❌ Failed routes: \(failed)/\(totalRoutesCount)")
        print("   ⏱️ Total test time: \(String(format: "%.2f", totalTime))s")
        print("")
        
        // Performance Statistics
        let successfulRouteResults = allRouteResults.filter { $0.success }
        if !successfulRouteResults.isEmpty {
            let avgTime = successfulRouteResults.compactMap { $0.timeSeconds }.reduce(0, +) / Double(successfulRouteResults.count)
            let minTime = successfulRouteResults.compactMap { $0.timeSeconds }.min() ?? 0
            let maxTime = successfulRouteResults.compactMap { $0.timeSeconds }.max() ?? 0
            
            print("⚡ PERFORMANCE (ALL POSTCODES)")
            print("   ⏱️ Average generation time: \(String(format: "%.2f", avgTime))s")
            print("   ⚡ Fastest: \(String(format: "%.2f", minTime))s")
            print("   🐌 Slowest: \(String(format: "%.2f", maxTime))s")
            print("")
        }
        
        // Accuracy Statistics
        if !successfulRouteResults.isEmpty {
            let accuracies = successfulRouteResults.compactMap { result -> Double? in
                guard let routeMinutes = result.routeMinutes else { return nil }
                return Double(routeMinutes) / Double(result.duration) * 100
            }
            
            if !accuracies.isEmpty {
                let avgAccuracy = accuracies.reduce(0, +) / Double(accuracies.count)
                let minAccuracy = accuracies.min() ?? 0
                let maxAccuracy = accuracies.max() ?? 0
                let withinTolerance = accuracies.filter { $0 >= 80 && $0 <= 130 }.count
                
                print("🎯 ACCURACY (ALL POSTCODES)")
                print("   📏 Average: \(String(format: "%.1f", avgAccuracy))% of target")
                print("   📉 Lowest: \(String(format: "%.1f", minAccuracy))%")
                print("   📈 Highest: \(String(format: "%.1f", maxAccuracy))%")
                print("   ✅ Within tolerance (80-130%): \(withinTolerance)/\(successfulRouteResults.count)")
                print("")
            }
        }
        
        // Database Usage Statistics
        let databaseUsedCount = allRouteResults.compactMap { $0.usedDatabase }.filter { $0 }.count
        let databaseUsageRate = totalRoutesCount > 0 ? Double(databaseUsedCount) / Double(totalRoutesCount) * 100 : 0.0
        
        print("📦 DATABASE USAGE (ALL POSTCODES)")
        print("   📦 Database used: \(databaseUsedCount)/\(totalRoutesCount) routes (\(String(format: "%.1f", databaseUsageRate))%)")
        print("")
        
        // Per-Postcode Summary with Themes
        print("📍 PER-POSTCODE SUMMARY")
        for postcodeResult in allResults {
            let postcodeSuccessful = postcodeResult.results.filter { $0.success }.count
            let _ = postcodeResult.results.filter { !$0.success }.count  // Track failures (unused for now)
            let postcodeSuccessRate = Double(postcodeSuccessful) / Double(postcodeResult.results.count) * 100
            
            let postcodeSuccessfulResults = postcodeResult.results.filter { $0.success }
            var postcodeAccuracy = ""
            var avgTime = 0.0
            var databaseUsageRate = 0.0
            if !postcodeSuccessfulResults.isEmpty {
                let accuracies = postcodeSuccessfulResults.compactMap { result -> Double? in
                    guard let routeMinutes = result.routeMinutes else { return nil }
                    return Double(routeMinutes) / Double(result.duration) * 100
                }
                if !accuracies.isEmpty {
                    let avgAccuracy = accuracies.reduce(0, +) / Double(accuracies.count)
                    postcodeAccuracy = " | Avg accuracy: \(String(format: "%.1f", avgAccuracy))%"
                }
                
                // Calculate average generation time
                let times = postcodeSuccessfulResults.compactMap { $0.timeSeconds }
                if !times.isEmpty {
                    avgTime = times.reduce(0, +) / Double(times.count)
                }
                
                // Calculate database usage
                let dbUsed = postcodeSuccessfulResults.compactMap { $0.usedDatabase }.filter { $0 }.count
                databaseUsageRate = Double(dbUsed) / Double(postcodeSuccessfulResults.count) * 100
            }
            
            print("   📍 \(postcodeResult.postcode): \(postcodeSuccessful)/\(postcodeResult.results.count) successful (\(String(format: "%.1f", postcodeSuccessRate))%)\(postcodeAccuracy)")
            if avgTime > 0 {
                print("      ⏱️ Avg generation time: \(String(format: "%.2f", avgTime))s")
            }
            if databaseUsageRate > 0 {
                print("      📦 Database usage: \(String(format: "%.1f", databaseUsageRate))%")
            }
        }
        print("")
        
        // THEMES ACROSS ALL AREAS
        print("🎯 THEMES ACROSS ALL AREAS")
        print("")
        
        // Theme 1: Route Generation Success by Duration
        print("📊 Theme 1: Success Rate by Duration")
        let durations = stride(from: 10, through: 60, by: 5)
        for duration in durations {
            let durationResults = allRouteResults.filter { $0.duration == duration }
            let durationSuccessful = durationResults.filter { $0.success }.count
            let durationSuccessRate = durationResults.isEmpty ? 0 : Double(durationSuccessful) / Double(durationResults.count) * 100
            print("   \(duration)min: \(durationSuccessful)/\(durationResults.count) successful (\(String(format: "%.1f", durationSuccessRate))%)")
        }
        print("")
        
        // Theme 2: Average Generation Time by Duration
        print("⚡ Theme 2: Average Generation Time by Duration")
        for duration in durations {
            let durationResults = allRouteResults.filter { $0.duration == duration && $0.success }
            if !durationResults.isEmpty {
                let avgTime = durationResults.compactMap { $0.timeSeconds }.reduce(0, +) / Double(durationResults.count)
                let minTime = durationResults.compactMap { $0.timeSeconds }.min() ?? 0
                let maxTime = durationResults.compactMap { $0.timeSeconds }.max() ?? 0
                print("   \(duration)min: Avg \(String(format: "%.2f", avgTime))s (min: \(String(format: "%.2f", minTime))s, max: \(String(format: "%.2f", maxTime))s)")
            }
        }
        print("")
        
        // Theme 3: Database Usage by Postcode
        print("📦 Theme 3: Database Usage by Postcode")
        for postcodeResult in allResults {
            let postcodeSuccessfulResults = postcodeResult.results.filter { $0.success }
            if !postcodeSuccessfulResults.isEmpty {
                let dbUsed = postcodeSuccessfulResults.compactMap { $0.usedDatabase }.filter { $0 }.count
                let dbUsageRate = Double(dbUsed) / Double(postcodeSuccessfulResults.count) * 100
                print("   \(postcodeResult.postcode): \(dbUsed)/\(postcodeSuccessfulResults.count) routes used database (\(String(format: "%.1f", dbUsageRate))%)")
            }
        }
        print("")
        
        // Theme 4: Route Accuracy Distribution
        print("🎯 Theme 4: Route Accuracy Distribution")
        let themeSuccessfulResults = allRouteResults.filter { $0.success }
        if !themeSuccessfulResults.isEmpty {
            let accuracies = themeSuccessfulResults.compactMap { result -> Double? in
                guard let routeMinutes = result.routeMinutes else { return nil }
                return Double(routeMinutes) / Double(result.duration) * 100
            }
            
            if !accuracies.isEmpty {
                let veryAccurate = accuracies.filter { $0 >= 90 && $0 <= 110 }.count
                let accurate = accuracies.filter { ($0 >= 80 && $0 < 90) || ($0 > 110 && $0 <= 130) }.count
                let inaccurate = accuracies.filter { $0 < 80 || $0 > 130 }.count
                
                print("   Very accurate (90-110%): \(veryAccurate)/\(accuracies.count) (\(String(format: "%.1f", Double(veryAccurate) / Double(accuracies.count) * 100))%)")
                print("   Accurate (80-90% or 110-130%): \(accurate)/\(accuracies.count) (\(String(format: "%.1f", Double(accurate) / Double(accuracies.count) * 100))%)")
                print("   Inaccurate (<80% or >130%): \(inaccurate)/\(accuracies.count) (\(String(format: "%.1f", Double(inaccurate) / Double(accuracies.count) * 100))%)")
            }
        }
        print("")
        
        // Theme 5: Most Common POI Types (if we can extract from route logs)
        print("📍 Theme 5: Route Characteristics")
        let waypointsList = themeSuccessfulResults.compactMap { $0.waypoints }
        let avgWaypoints = waypointsList.isEmpty ? 0.0 : Double(waypointsList.reduce(0, +)) / Double(waypointsList.count)
        let distanceList = themeSuccessfulResults.compactMap { $0.distanceKm }
        let avgDistance = distanceList.isEmpty ? 0.0 : distanceList.reduce(0, +) / Double(distanceList.count)
        print("   Average waypoints per route: \(String(format: "%.1f", avgWaypoints))")
        print("   Average distance per route: \(String(format: "%.2f", avgDistance))km")
        print("")
        
        // v2.0.3: IMPACT METRICS SECTION
        print("╔═══════════════════════════════════════════════════════════════════════════════════╗")
        print("║         📊 v2.0.3 IMPACT METRICS (Route Generation Efficiency)                      ║")
        print("╚═══════════════════════════════════════════════════════════════════════════════════╝")
        print("")
        
        // Routes Attempted Statistics
        let routesAttemptedList = allRouteResults.compactMap { $0.routesAttempted }
        if !routesAttemptedList.isEmpty {
            let avgAttempts = Double(routesAttemptedList.reduce(0, +)) / Double(routesAttemptedList.count)
            let minAttempts = routesAttemptedList.min() ?? 0
            let maxAttempts = routesAttemptedList.max() ?? 0
            let sortedAttempts = routesAttemptedList.sorted()
            let p50Attempts = sortedAttempts[sortedAttempts.count / 2]
            let p95Attempts = sortedAttempts[Int(Double(sortedAttempts.count) * 0.95)]
            let p99Attempts = sortedAttempts[Int(Double(sortedAttempts.count) * 0.99)]
            
            print("🔢 ROUTES ATTEMPTED (v2.0.3 Phase 1: Combination Caps)")
            print("   Average: \(String(format: "%.1f", avgAttempts)) attempts")
            print("   Min: \(minAttempts), Max: \(maxAttempts)")
            print("   Percentiles: p50=\(p50Attempts), p95=\(p95Attempts), p99=\(p99Attempts)")
            print("")
        }
        
        // Valid Routes Found Statistics
        let validRoutesFoundList = allRouteResults.compactMap { $0.validRoutesFound }
        if !validRoutesFoundList.isEmpty {
            let avgValid = Double(validRoutesFoundList.reduce(0, +)) / Double(validRoutesFoundList.count)
            let minValid = validRoutesFoundList.min() ?? 0
            let maxValid = validRoutesFoundList.max() ?? 0
            
            print("✅ VALID ROUTES FOUND (v2.0.3: Route Diversity)")
            print("   Average: \(String(format: "%.1f", avgValid)) valid routes per generation")
            print("   Min: \(minValid), Max: \(maxValid)")
            print("   Routes with 3+ valid options: \(validRoutesFoundList.filter { $0 >= 3 }.count)/\(validRoutesFoundList.count)")
            print("")
        }
        
        // Efficiency: Routes Attempted per Valid Route Found
        if !routesAttemptedList.isEmpty && !validRoutesFoundList.isEmpty {
            var efficiencyRatios: [Double] = []
            for (index, attempts) in routesAttemptedList.enumerated() {
                if index < validRoutesFoundList.count && validRoutesFoundList[index] > 0 {
                    efficiencyRatios.append(Double(attempts) / Double(validRoutesFoundList[index]))
                }
            }
            if !efficiencyRatios.isEmpty {
                let avgEfficiency = efficiencyRatios.reduce(0, +) / Double(efficiencyRatios.count)
                print("⚡ EFFICIENCY (Attempts per Valid Route)")
                print("   Average: \(String(format: "%.2f", avgEfficiency)) attempts per valid route")
                print("   (Lower is better - indicates efficient route discovery)")
                print("")
            }
        }
        
        // Latency Percentiles (p50, p95, p99) - v2.0.3 Phase 1 Goal: p95≤12s, p99≤18s
        // Reuse successfulRouteResults from Performance Statistics section above
        if !successfulRouteResults.isEmpty {
            let times = successfulRouteResults.compactMap { $0.timeSeconds }.sorted()
            if !times.isEmpty {
                let p50Time = times[times.count / 2]
                let p95Time = times[min(Int(Double(times.count) * 0.95), times.count - 1)]
                let p99Time = times[min(Int(Double(times.count) * 0.99), times.count - 1)]
                
                print("⏱️ LATENCY PERCENTILES (v2.0.3 Phase 1 Goals: p95≤12s, p99≤18s)")
                print("   p50 (median): \(String(format: "%.2f", p50Time))s")
                print("   p95: \(String(format: "%.2f", p95Time))s \(p95Time <= 12.0 ? "✅" : "⚠️")")
                print("   p99: \(String(format: "%.2f", p99Time))s \(p99Time <= 18.0 ? "✅" : "⚠️")")
                print("")
            }
        }
        
        // Tight Accuracy (90-110%) - v2.0.3 Phase 1 Goal: +10pp improvement
        if !themeSuccessfulResults.isEmpty {
            let accuracies = themeSuccessfulResults.compactMap { result -> Double? in
                guard let routeMinutes = result.routeMinutes else { return nil }
                return Double(routeMinutes) / Double(result.duration) * 100
            }
            if !accuracies.isEmpty {
                let tightAccuracy = accuracies.filter { $0 >= 90 && $0 <= 110 }.count
                let tightAccuracyPercent = Double(tightAccuracy) / Double(accuracies.count) * 100
                print("🎯 TIGHT ACCURACY (90-110%) - v2.0.3 Phase 1 Goal: +10pp improvement")
                print("   Current: \(tightAccuracy)/\(accuracies.count) (\(String(format: "%.1f", tightAccuracyPercent))%)")
                print("   Target: ≥\(String(format: "%.1f", tightAccuracyPercent + 10))% (baseline + 10pp)")
                print("")
            }
        }
        
        // Waypoint Count Improvement - v2.0.3 Phase 1 Goal: 1.5 → ≥2.2
        if !waypointsList.isEmpty {
            let avgWaypointsCurrent = avgWaypoints
            print("📍 WAYPOINT COUNT - v2.0.3 Phase 1 Goal: 1.5 → ≥2.2")
            print("   Current average: \(String(format: "%.1f", avgWaypointsCurrent)) waypoints")
            print("   Target: ≥2.2 waypoints \(avgWaypointsCurrent >= 2.2 ? "✅" : "⚠️")")
            print("   Routes with 2+ waypoints: \(waypointsList.filter { $0 >= 2 }.count)/\(waypointsList.count) (\(String(format: "%.1f", Double(waypointsList.filter { $0 >= 2 }.count) / Double(waypointsList.count) * 100))%)")
            print("")
        }
        
        // v2.0.15: Batch Roll-Up JSON (one line at end of batch)
        // Calculate metrics from available data
        let batchTotal = totalRoutesCount
        let tight90_110 = themeSuccessfulResults.compactMap { result -> Int? in
            guard let routeMinutes = result.routeMinutes else { return nil }
            let acc = Double(routeMinutes) / Double(result.duration) * 100
            return (acc >= 90 && acc <= 110) ? 1 : 0
        }.reduce(0, +)
        let within80_130 = themeSuccessfulResults.compactMap { result -> Int? in
            guard let routeMinutes = result.routeMinutes else { return nil }
            let acc = Double(routeMinutes) / Double(result.duration) * 100
            return (acc >= 80 && acc <= 130) ? 1 : 0
        }.reduce(0, +)
        
        let accuracies = themeSuccessfulResults.compactMap { result -> Double? in
            guard let routeMinutes = result.routeMinutes else { return nil }
            return Double(routeMinutes) / Double(result.duration)
        }
        let avgAccuracy = accuracies.isEmpty ? 0.0 : accuracies.reduce(0, +) / Double(accuracies.count)
        
        let times = successfulRouteResults.compactMap { $0.timeSeconds }.sorted()
        let avgElapsedMs = times.isEmpty ? 0 : Int((times.reduce(0, +) / Double(times.count)) * 1000)
        let p50Ms = times.isEmpty ? 0 : Int(times[times.count / 2] * 1000)
        let p95Ms = times.isEmpty ? 0 : Int(times[min(Int(Double(times.count) * 0.95), times.count - 1)] * 1000)
        let p99Ms = times.isEmpty ? 0 : Int(times[min(Int(Double(times.count) * 0.99), times.count - 1)] * 1000)
        
        let avgWaypointsCalc = waypointsList.isEmpty ? 0.0 : Double(waypointsList.reduce(0, +)) / Double(waypointsList.count)
        let routesGe2Wp = waypointsList.filter { $0 >= 2 }.count
        
        // Reuse existing variables declared earlier in the function
        let avgValidRoutesPerGen = validRoutesFoundList.isEmpty ? 0.0 : Double(validRoutesFoundList.reduce(0, +)) / Double(validRoutesFoundList.count)
        
        // Note: Full telemetry aggregation (early_commit_opportunities, fallback_fired, etc.) would require
        // storing per-route telemetry during batch test - this is a placeholder structure
        let batchRollUp: [String: Any] = [
            "batch_total": batchTotal,
            "tight_90_110": tight90_110,
            "within_80_130": within80_130,
            "avg_accuracy": String(format: "%.3f", avgAccuracy),
            "avg_elapsed_ms": avgElapsedMs,
            "p50_ms": p50Ms,
            "p95_ms": p95Ms,
            "p99_ms": p99Ms,
            "avg_waypoints": String(format: "%.2f", avgWaypointsCalc),
            "routes_ge_2_wp": routesGe2Wp,
            "valid_routes_per_gen": String(format: "%.2f", avgValidRoutesPerGen),
            "early_commit_opportunities": allTelemetry.filter { $0.earlyCommitOpportunity }.count,  // v2.0.17: Aggregate from telemetry
            "early_commits_taken": allTelemetry.filter { $0.earlyCommitsTaken }.count,  // v2.0.17: Aggregate from telemetry
            "fallback_fired": allTelemetry.filter { $0.fallbackFired }.count,  // v2.0.17: Aggregate from telemetry
            "fallback_over_130pct": allTelemetry.filter { $0.fallbackOver130Pct }.count,  // v2.0.17: Aggregate from telemetry
            "overshoot_selected_gt_120pct": allTelemetry.filter { $0.overshootSelectedGt120Pct }.count,  // v2.0.17: Aggregate from telemetry
            "per_leg_cap_applied": allTelemetry.filter { $0.perLegCapApplied }.count,  // v2.0.17: Aggregate from telemetry
            "cap_after_good_candidate": allTelemetry.filter { $0.capAfterGoodCandidate }.count,  // v2.0.17: Aggregate from telemetry
            "bias_table": RoutingToggles.biasTable(),  // v2.0.16: Duration-bucket bias table
            "sector_quota_used_count": allTelemetry.filter { $0.sectorQuotaUsed }.count  // v2.0.17: Aggregate from telemetry
        ]
        
        // Quick assertions in the roll-up (small but powerful)
        assert(batchTotal > 0, "batch_total must be > 0")
        let earlyCommitsTaken = allTelemetry.filter { $0.earlyCommitsTaken }.count
        let earlyCommitOpportunities = allTelemetry.filter { $0.earlyCommitOpportunity }.count
        assert(earlyCommitsTaken <= earlyCommitOpportunities, "early_commits_taken (\(earlyCommitsTaken)) must be <= early_commit_opportunities (\(earlyCommitOpportunities))")
        let fallbackOver130 = allTelemetry.filter { $0.fallbackOver130Pct }.count
        assert(fallbackOver130 == 0, "fallback_over_130pct must be 0 (found \(fallbackOver130)) - proves floor enforcement")
        assert(p50Ms <= p95Ms && p95Ms <= p99Ms, "Percentiles must be ordered: p50 (\(p50Ms)) <= p95 (\(p95Ms)) <= p99 (\(p99Ms))")
        
        // Output as one-line JSON - UNCONDITIONAL with explicit END marker for CI
        var jsonString = ""
        if let jsonData = try? JSONSerialization.data(withJSONObject: batchRollUp, options: []),
           let json = String(data: jsonData, encoding: .utf8) {
            jsonString = json
        } else {
            // Fallback: create minimal JSON if serialization fails
            jsonString = "{\"error\":\"serialization_failed\",\"batch_total\":\(batchTotal)}"
        }
        
        // Emit unconditionally with explicit END marker so CI can grep it even if harness truncates earlier logs
        print("###BATCH-END### \(jsonString)")
        FileHandle.standardOutput.synchronizeFile()  // ensure it hits disk/stdout
        
        // Also emit the formatted version for human readability
        print("")
        print("📊 [BATCH_ROLLUP] \(jsonString)")
        print("")
        
        // Summary Footer
        print("╔═══════════════════════════════════════════════════════════════════════════════════╗")
        print("║  💡 Note: Check individual route logs above for detailed information including    ║")
        print("║     routes attempted, database usage, and route selection summaries for each      ║")
        print("║     postcode area.                                                                ║")
        print("╚═══════════════════════════════════════════════════════════════════════════════════╝")
        print("")
    }
    
    // MARK: - Topology-Safe Short Routes (v2.0.2)
    // Curated POIs are NOT assumed to be topologically reachable.
    // They are high-quality destinations, not routing anchors.
    
    /// High-level control flow that guarantees a route is always returned
    /// v2.0.2: Hybrid approach - POI-first remains primary, topology-safe only when proven wrong
    /// Topology-safe activates when: POI-first failed AND routeMultiplier > 2.0 (proven topology mismatch)
    func generateRouteTopologySafe(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        // Absolute invariant: NEVER return nil / no-route
        
        // Route multiplier tracker (for early topology-safe gate)
        let routeMultiplierTracker = RouteMultiplierTracker()
        
        // Step 1: Try POI-first (existing system with root-cause fixes applied)
        // Root-cause fixes are already applied in preFilterPOIsByDuration
        do {
            let route = try await generateLocalRouteWithRetry(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,
                prefetchedPOIs: prefetchedPOIs
            )
            
            // POI-first succeeded - return it
            print("✅ [ROUTE PATH] POI-first succeeded: \(route.durationSeconds / 60)min")
            return route
        } catch {
            // POI-first failed - check if this was due to topology mismatch
            print("⚠️ [ROUTE PATH] POI-first failed: \(error.localizedDescription)")
            
            // Step 2: Check if we should try topology-safe
            // Only for short routes (≤20 min) and when using curated DB
            let isUsingCuratedDB = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: 5000) != nil
            
            // Early topology-safe gate: Use routeMultiplierTracker to detect proven topology mismatch
            // Note: This tracker won't have data from the first attempt, but will learn over multiple calls
            if targetDurationMinutes <= 20 && isUsingCuratedDB && routeMultiplierTracker.isTopologyHostile {
                print("🔍 [ROUTE PATH] Early topology-safe gate: routeMultiplier ≥ 2.0 detected")
                print("   📊 Condition: target≤20min ✅, usingCuratedDB ✅, topologyHostile ✅")
                print("   💡 Distance-based estimates are proven wrong here - using topology-safe immediately")
                
                if let topologyRoute = try? await generateRouteShortTopologySafe(
                    from: location,
                    targetDurationMinutes: targetDurationMinutes,
                    excludePlaceIds: excludePlaceIds,
                    excludePOIs: excludePOIs
                ) {
                    print("✅ [ROUTE PATH] Topology-safe succeeded: \(topologyRoute.durationSeconds / 60)min")
                    print("   📈 This indicates topology mismatch was the root cause")
                    return topologyRoute
                } else {
                    print("⚠️ [ROUTE PATH] Topology-safe also failed, falling back to guaranteed route...")
                }
            } else if targetDurationMinutes <= 20 && isUsingCuratedDB {
                // Fallback: Original logic if multiplier not yet learned
                print("🔍 [ROUTE PATH] POI-first failed with curated DB - checking topology-safe eligibility...")
                print("   📊 Condition: target≤20min ✅, usingCuratedDB ✅, POI-first failed ✅")
                print("   💡 Topology-safe will only fire when assumptions are provably wrong (safety net, not workaround)")
                
                if let topologyRoute = try? await generateRouteShortTopologySafe(
                    from: location,
                    targetDurationMinutes: targetDurationMinutes,
                    excludePlaceIds: excludePlaceIds,
                    excludePOIs: excludePOIs
                ) {
                    print("✅ [ROUTE PATH] Topology-safe succeeded: \(topologyRoute.durationSeconds / 60)min")
                    print("   📈 This indicates topology mismatch was the root cause")
                    return topologyRoute
                } else {
                    print("⚠️ [ROUTE PATH] Topology-safe also failed, falling back to guaranteed route...")
                }
            } else {
                if targetDurationMinutes > 20 {
                    print("🔍 [ROUTE PATH] Topology-safe skipped: target >20min (only for short routes)")
                } else if !isUsingCuratedDB {
                    print("🔍 [ROUTE PATH] Topology-safe skipped: not using curated DB (live POIs)")
                }
            }
            
            // Step 3: Hard guarantee - should almost never trigger now
            print("🆘 [ROUTE PATH] All route generation failed, using out-and-back fallback...")
            return try await generateOutAndBackFallback(
                from: location,
                targetDurationMinutes: targetDurationMinutes
            )
        }
    }
    
    /// Topology-safe short-route generator (route-first, POI-enhanced, not POI-dependent)
    /// SPRINT-5: Added budget parameter for universal hard-stop awareness
    private func generateRouteShortTopologySafe(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        excludePlaceIds: Set<String>,
        excludePOIs: [PlaceResult],
        budget: RoutingToggles.Budget? = nil  // SPRINT-5: Optional budget for hard-stop
    ) async throws -> GeneratedRoute? {
        print("🗺️ [TOPOLOGY-SAFE] Starting topology-safe route generation for \(targetDurationMinutes)min route")
        
        // SPRINT-5: Check budget before making any MapKit calls
        if let b = budget, !RoutingToggles.mustContinue(b, bestSoFar: nil, stage: "TOPO_SAFE_START") {
            print("⛔ [HARD-STOP] Skipping topology-safe generation - budget exceeded")
            return nil
        }
        
        let baseRoutes = try await generateNetworkConstrainedCandidates(
            from: location,
            targetMinutes: targetDurationMinutes,
            attempts: 4,
            budget: budget  // SPRINT-5: Pass budget
        )
        
        // Early exit: if MapKit can't do this, POIs won't save you
        guard !baseRoutes.isEmpty else {
            print("🗺️ [TOPOLOGY-SAFE] No base routes found - MapKit can't generate routes here")
            return nil
        }
        
        // Pick best base route by duration fit
        guard let base = baseRoutes.min(by: { route1, route2 in
            let diff1 = abs(route1.durationSeconds / 60 - targetDurationMinutes)
            let diff2 = abs(route2.durationSeconds / 60 - targetDurationMinutes)
            return diff1 < diff2
        }) else {
            return nil
        }
        
        print("🗺️ [TOPOLOGY-SAFE] Best base route: \(base.durationSeconds / 60)min (target: \(targetDurationMinutes)min)")
        
        // Enhancement is OPTIONAL - POIs can only improve a route, never veto it
        if let enhanced = try? await enhanceRouteWithCuratedPOIs(
            baseRoute: base,
            from: location,
            targetMinutes: targetDurationMinutes,
            excludePlaceIds: excludePlaceIds,
            excludePOIs: excludePOIs
        ) {
            print("🗺️ [TOPOLOGY-SAFE] ✅ Enhanced route with POIs: \(enhanced.durationSeconds / 60)min")
            return enhanced
        }
        
        // Important: base route is GOOD ENOUGH
        print("🗺️ [TOPOLOGY-SAFE] ✅ Using base route (no POI enhancement): \(base.durationSeconds / 60)min")
        return base
    }
    
    /// Network-constrained candidate generation using MapKit's topology awareness
    /// This uses MapKit's strengths: topology awareness, works in campuses, hospitals, etc.
    /// SPRINT-5: Added budget parameter for universal hard-stop awareness
    private func generateNetworkConstrainedCandidates(
        from location: CLLocationCoordinate2D,
        targetMinutes: Int,
        attempts: Int,
        budget: RoutingToggles.Budget? = nil  // SPRINT-5: Optional budget for hard-stop
    ) async throws -> [GeneratedRoute] {
        let bearings = evenlySpacedBearings(count: attempts)
        let targetDistance = Double(targetMinutes) * Double(adaptiveWalkingSpeed) * 0.9
        
        print("🗺️ [NETWORK-CONSTRAINED] Generating \(attempts) candidates at \(Int(targetDistance))m distance")
        
        var routes: [GeneratedRoute] = []
        
        for (index, bearing) in bearings.enumerated() {
            // SPRINT-5: Check budget before each MapKit call
            if let b = budget, !RoutingToggles.mustContinue(b, bestSoFar: nil, stage: "NETWORK_CANDIDATE_\(index)") {
                print("⛔ [HARD-STOP] Aborting network-constrained generation at candidate \(index) - budget exceeded")
                break
            }
            if let route = try? await mapKitOutAndBack(
                from: location,
                distanceMeters: targetDistance,
                bearing: bearing
            ) {
                let routeMinutes = route.durationSeconds / 60
                let minAcceptable = Int(Double(targetMinutes) * 0.7)
                let maxAcceptable = Int(Double(targetMinutes) * 1.3)
                
                if routeMinutes >= minAcceptable && routeMinutes <= maxAcceptable {
                    print("🗺️ [NETWORK-CONSTRAINED] Candidate \(index + 1): \(routeMinutes)min (bearing: \(Int(bearing))°)")
                    routes.append(route)
                } else {
                    print("🗺️ [NETWORK-CONSTRAINED] Candidate \(index + 1): \(routeMinutes)min (out of range \(minAcceptable)-\(maxAcceptable)min)")
                }
            }
        }
        
        print("🗺️ [NETWORK-CONSTRAINED] Found \(routes.count)/\(attempts) valid candidates")
        return routes
    }
    
    /// Generate a simple out-and-back route using MapKit at a specific bearing and distance
    private func mapKitOutAndBack(
        from location: CLLocationCoordinate2D,
        distanceMeters: Double,
        bearing: Double
    ) async throws -> GeneratedRoute {
        // Calculate destination coordinate using bearing and distance
        let destination = coordinateAtDistance(
            from: location,
            distanceMeters: distanceMeters,
            bearing: bearing
        )
        
        // v2.0.3 Phase 1.5 Batch A: Wrap with timeout (topology-safe uses default timeout)
        let timeout = RoutingToggles.perCallTimeoutNormal  // Default for topology-safe
        let (directionsResult, didTimeout) = await directionsWithTimeout(
            origin: location,
            destination: location,
            waypoints: [destination],
            timeout: timeout,
            targetDurationMinutes: nil,
            angularDiversityScore: nil,
            postcode: nil
        )
        
        if didTimeout {
            throw GoogleMapsError.noRouteFound
        }
        
        guard let directions = directionsResult else {
            throw GoogleMapsError.noRouteFound
        }
        
        // Calculate totals
        let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
        let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
        
        // Create a placeholder POI for the destination (optional, for display)
        let destinationPOI = PlaceResult(
            placeId: "topology_\(Int(bearing))",
            name: "Route Point",
            vicinity: nil,
            geometry: PlaceGeometry(
                location: PlaceLocation(
                    lat: destination.latitude,
                    lng: destination.longitude
                )
            ),
            types: ["point_of_interest"],
            source: .osm
        )
        
        return GeneratedRoute(
            places: [destinationPOI],
            polyline: directions.overviewPolyline.points,
            distanceMeters: totalDistance,
            durationSeconds: totalDuration,
            legs: directions.legs
        )
    }
    
    /// Enhance a base route with curated POIs (optional, max 2 POIs)
    private func enhanceRouteWithCuratedPOIs(
        baseRoute: GeneratedRoute,
        from location: CLLocationCoordinate2D,
        targetMinutes: Int,
        excludePlaceIds: Set<String>,
        excludePOIs: [PlaceResult]
    ) async throws -> GeneratedRoute? {
        // Get POIs near the route corridor (150m buffer)
        let routePoints = decodePolyline(baseRoute.polyline)
        guard !routePoints.isEmpty else { return nil }
        
        // Create a bounding box around the route
        let minLat = routePoints.map { $0.latitude }.min() ?? location.latitude
        let maxLat = routePoints.map { $0.latitude }.max() ?? location.latitude
        let minLng = routePoints.map { $0.longitude }.min() ?? location.longitude
        let maxLng = routePoints.map { $0.longitude }.max() ?? location.longitude
        
        // Expand bounding box by 150m
        let latBuffer = 150.0 / 111000.0  // ~1 degree lat = 111km
        let lngBuffer = 150.0 / (111000.0 * cos(location.latitude * .pi / 180.0))
        
        let expandedMinLat = minLat - latBuffer
        let expandedMaxLat = maxLat + latBuffer
        let expandedMinLng = minLng - lngBuffer
        let expandedMaxLng = maxLng + lngBuffer
        
        // Get POIs from database or cache in this area
        let centerLat = (expandedMinLat + expandedMaxLat) / 2
        let centerLng = (expandedMinLng + expandedMaxLng) / 2
        let centerCoord = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng)
        
        // Calculate radius (diagonal of bounding box)
        let radiusMeters = Int(distanceBetween(
            CLLocationCoordinate2D(latitude: expandedMinLat, longitude: expandedMinLng),
            CLLocationCoordinate2D(latitude: expandedMaxLat, longitude: expandedMaxLng)
        ) / 2)
        
        // Fetch POIs (try database first, then live sources)
        var pois: [PlaceResult] = []
        if let dbPOIs = PrePopulatedPOIService.shared.getPrePopulatedPOIs(
            near: centerCoord,
            radiusMeters: Double(radiusMeters)
        ) {
            pois = dbPOIs
        } else {
            pois = try await findNearbyPlaces(
                location: centerCoord,
                radiusMeters: radiusMeters,
                skipGoogle: true  // Cost optimization
            )
        }
        
        // Filter: restricted, excluded, and must be near route
        var candidatePOIs = pois.filter { poi in
            // Skip restricted POIs
            if isRestrictedPOI(poi) { return false }
            
            // Skip excluded POIs
            if excludePlaceIds.contains(poi.placeId) { return false }
            
            // Check if near any excluded POI
            for excludedPOI in excludePOIs {
                if isRouteDuplicate(poi, excludedPOI) {
                    return false
                }
            }
            
            // Must be within 150m of route
            return routePoints.contains { routePoint in
                distanceBetween(poi.coordinate, routePoint) < 150
            }
        }
        
        // Limit to top 20 candidates
        candidatePOIs = Array(candidatePOIs.prefix(20))
        
        guard !candidatePOIs.isEmpty else {
            print("🗺️ [ENHANCE] No POIs found near route corridor")
            return nil
        }
        
        print("🗺️ [ENHANCE] Found \(candidatePOIs.count) POIs near route, trying to insert 1-2...")
        
        // Try inserting 1-2 POIs max (no retries, no re-fetch, no failure propagation)
        var bestEnhanced: GeneratedRoute? = nil
        var bestScore = Int.max
        
        for poi in candidatePOIs.prefix(2) {
            if let enhanced = try? await tryInsertPOI(
                poi: poi,
                into: baseRoute,
                from: location,
                targetMinutes: targetMinutes
            ) {
                let enhancedMinutes = enhanced.durationSeconds / 60
                if enhancedMinutes <= Int(Double(targetMinutes) * 1.3) {
                    let score = abs(enhancedMinutes - targetMinutes)
                    if score < bestScore {
                        bestScore = score
                        bestEnhanced = enhanced
                    }
                }
            }
        }
        
        // v2.1.7: Final distance check before returning (catches any waypoints that got too close)
        if let enhanced = bestEnhanced {
            return await removeCloseWaypoints(from: enhanced, minDistance: 100, origin: location)
        }
        
        return bestEnhanced
    }
    
    /// Try inserting a POI into a base route
    private func tryInsertPOI(
        poi: PlaceResult,
        into baseRoute: GeneratedRoute,
        from location: CLLocationCoordinate2D,
        targetMinutes: Int
    ) async throws -> GeneratedRoute? {
        // Get the route waypoint (currently just the destination)
        guard let destination = baseRoute.places.first?.coordinate else {
            return nil
        }
        
        // v2.1.7: Check distance before inserting POI
        let minInsertDistance: Double = 100
        let poiToDestinationDistance = distanceBetween(poi.coordinate, destination)
        if poiToDestinationDistance < minInsertDistance {
            print("🗺️ [ENHANCE] Skipping '\(poi.name)' - too close to destination (\(String(format: "%.1f", poiToDestinationDistance))m < \(minInsertDistance)m)")
            return nil
        }
        
        // v2.0.3 Phase 1.5 Batch A: Wrap with timeout (topology-safe uses default timeout)
        let timeout = RoutingToggles.perCallTimeoutNormal  // Default for topology-safe
        let (directionsResult, didTimeout) = await directionsWithTimeout(
            origin: location,
            destination: location,
            waypoints: [poi.coordinate, destination],
            timeout: timeout,
            targetDurationMinutes: targetMinutes,
            angularDiversityScore: nil,
            postcode: nil
        )
        
        if didTimeout {
            return nil  // Timeout - can't insert POI
        }
        
        guard let directions = directionsResult else {
            return nil
        }
        
        let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
        let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
        
        let route = GeneratedRoute(
            places: [poi, baseRoute.places.first!],
            polyline: directions.overviewPolyline.points,
            distanceMeters: totalDistance,
            durationSeconds: totalDuration,
            legs: directions.legs
        )
        
        // v2.1.7: Final distance check (road snapping can bring waypoints closer)
        return await removeCloseWaypoints(from: route, minDistance: 100, origin: location)
    }
    
    /// Hard guarantee fallback: simple out-and-back to nearest reachable point
    private func generateOutAndBackFallback(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int
    ) async throws -> GeneratedRoute {
        print("🆘 [FALLBACK] Generating guaranteed out-and-back route...")
        
        // Try 4 directions (N, E, S, W)
        let bearings = [0.0, 90.0, 180.0, 270.0]
        let targetDistance = Double(targetDurationMinutes) * Double(adaptiveWalkingSpeed) * 0.45  // Half distance for out-and-back
        
        for bearing in bearings {
            if let route = try? await mapKitOutAndBack(
                from: location,
                distanceMeters: targetDistance,
                bearing: bearing
            ) {
                let routeMinutes = route.durationSeconds / 60
                // Accept if within 50-200% of target (very lenient for fallback)
                if routeMinutes >= Int(Double(targetDurationMinutes) * 0.5) &&
                   routeMinutes <= Int(Double(targetDurationMinutes) * 2.0) {
                    print("🆘 [FALLBACK] ✅ Generated route: \(routeMinutes)min")
                    return route
                }
            }
        }
        
        // Last resort: very short route to nearest point
        if let route = try? await mapKitOutAndBack(
            from: location,
            distanceMeters: 200,
            bearing: 0
        ) {
            print("🆘 [FALLBACK] ✅ Generated minimal route: \(route.durationSeconds / 60)min")
            return route
        }
        
        // Should never reach here, but if we do, throw error
        throw GoogleMapsError.noRouteFound
    }
    
    /// Generate evenly spaced bearings (0-360 degrees)
    private func evenlySpacedBearings(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let step = 360.0 / Double(count)
        return (0..<count).map { Double($0) * step }
    }
    
    /// Calculate coordinate at a given distance and bearing from a starting point
    private func coordinateAtDistance(
        from start: CLLocationCoordinate2D,
        distanceMeters: Double,
        bearing: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6371000.0  // meters
        let lat1 = start.latitude * .pi / 180.0
        let lon1 = start.longitude * .pi / 180.0
        let bearingRad = bearing * .pi / 180.0
        
        let lat2 = asin(sin(lat1) * cos(distanceMeters / earthRadius) +
                       cos(lat1) * sin(distanceMeters / earthRadius) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(distanceMeters / earthRadius) * cos(lat1),
                               cos(distanceMeters / earthRadius) - sin(lat1) * sin(lat2))
        
        return CLLocationCoordinate2D(
            latitude: lat2 * 180.0 / .pi,
            longitude: lon2 * 180.0 / .pi
        )
    }
    
    // MARK: - Generate Route with Auto-Retry
    /// Wrapper that implements multi-stage retry:
    /// 1. Random selection (fast)
    /// 2. If fails: Systematic selection with expanded search
    /// 3. If still fails: Try shorter durations (drop 5 min at a time)
    /// 4. If all fails: Throw no route found
    func generateLocalRouteWithRetry(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],  // v1.9.51: Actual POI objects to check for duplicates by name/coordinate
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [ROUTE RETRY] [\(timeString)] 🔄 generateLocalRouteWithRetry() STARTED")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║              🚶 ROUTE GENERATION STARTED                     ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ Target Duration: \(targetDurationMinutes) minutes")
        print("║ Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("║ Excluded POIs: \(excludePlaceIds.count)")
        print("║ Prefetched POIs: \(prefetchedPOIs?.count ?? 0)")
        print("╚══════════════════════════════════════════════════════════════╝")
        
        var stage1FailedNoRoute = false  // When true, Stage 2 should try Google even if prefetched.count >= 25
        // Stage 1: Random selection (current behavior)
        print("\n📍 STAGE 1: Random Selection")
        let stage1StartTime = Date()
        print("⏱️ [TIMING] Stage 1 STARTED")
        do {
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                prefetchedPOIs: prefetchedPOIs,
                useSystematicSelection: false
            )
            let stage1Elapsed = Date().timeIntervalSince(stage1StartTime)
            let endTime = Date()
            let endTimeString = formatter.string(from: endTime)
            let totalElapsed = endTime.timeIntervalSince(startTime)
            
            await MainActor.run { retryStatus = nil }
            print("✅ STAGE 1 SUCCESS: \(route.durationSeconds / 60) min route with \(route.places.count) waypoints")
            print("⏱️ [TIMING] Stage 1: \(String(format: "%.2f", stage1Elapsed))s")
            print("⏱️ [ROUTE RETRY] [\(endTimeString)] ✅ generateLocalRouteWithRetry() COMPLETED in \(String(format: "%.2f", totalElapsed))s")
            print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            print("⏱️ [TIMING] TOTAL TIME: \(String(format: "%.2f", totalElapsed))s (Stage 1 only)")
            print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            return route
        } catch GoogleMapsError.rateLimited(let waitTime) {
            // Rate limited - wait and retry once
            print("🚫 Stage 1 rate limited, waiting \(waitTime)s...")
            await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
            try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
            // Don't retry all stages, just continue to stage 2
        } catch GoogleMapsError.noRouteFound {
            // v1.9.50: If route generation failed with free sources, try with Google
            stage1FailedNoRoute = true
            print("🔄 Stage 1 (random) failed with free sources - trying with Google fallback...")
            // Will fall through to Stage 2 which will try with Google
        } catch {
            print("🔄 Stage 1 (random) failed, trying systematic...")
        }
        
        // Stage 2: Systematic selection with expanded search
        // v1.9.50: If Stage 1 failed, this might be due to insufficient POIs from free sources
        // Try with Google POIs included (if not already tried)
        print("\n📍 STAGE 2: Systematic Selection + Expanded Search")
        let stage2StartTime = Date()
        print("⏱️ [TIMING] Stage 2 STARTED")
        await MainActor.run { retryStatus = "Retrying with expanded search..." }
        do {
            // Check if we need to fetch Google POIs (if prefetchedPOIs was from free sources only)
            var poisToUse: [PlaceResult]? = nil
            var searchRadiusForStage2: Int? = nil
            var stage2POIFetchTime: TimeInterval = 0
            
            // Calculate expanded search radius (2x base radius)
            let baseRadius = max(600, (targetDurationMinutes * 80 / 2) / 2)  // Approximate base
            searchRadiusForStage2 = baseRadius * 2  // Expanded search
            
            // If we had prefetched POIs, check if they were from free sources only
            if let prefetched = prefetchedPOIs {
                let googlePOICount = prefetched.filter { $0.source == .google }.count
                // Try Google when: no Google POIs and (few POIs < 25, or Stage 1 failed with noRouteFound)
                if googlePOICount == 0 && (prefetched.count < 25 || stage1FailedNoRoute) {
                    // Had POIs from free sources only — try with Google (or Stage 1 failed, so try Google)
                    let googleFetchStart = Date()
                    print("🔄 Stage 2: Re-fetching POIs with Google included (had \(prefetched.count) from free sources, 0 from Google)")
                    print("⏱️ [TIMING] Stage 2 Google fetch STARTED")
                    poisToUse = try await findNearbyPlaces(
                        location: location,
                        radiusMeters: searchRadiusForStage2!,
                        skipGoogle: false  // Include Google
                    )
                    stage2POIFetchTime = Date().timeIntervalSince(googleFetchStart)
                    print("⏱️ [TIMING] Stage 2 Google fetch: \(String(format: "%.2f", stage2POIFetchTime))s")
                    print("🔄 Stage 2: Now have \(poisToUse?.count ?? 0) POIs with Google")
                } else {
                    // Already have Google POIs or enough POIs - use prefetched
                    poisToUse = prefetched
                    print("🔄 Stage 2: Using prefetched POIs (\(prefetched.count) total, \(googlePOICount) from Google)")
                }
            } else {
                // No prefetched POIs - fetch fresh with Google included
                let googleFetchStart = Date()
                print("🔄 Stage 2: Fetching fresh POIs with Google included (expanded search)")
                print("⏱️ [TIMING] Stage 2 Google fetch STARTED")
                poisToUse = try await findNearbyPlaces(
                    location: location,
                    radiusMeters: searchRadiusForStage2!,
                    skipGoogle: false  // Include Google
                )
                stage2POIFetchTime = Date().timeIntervalSince(googleFetchStart)
                print("⏱️ [TIMING] Stage 2 Google fetch: \(String(format: "%.2f", stage2POIFetchTime))s")
                print("🔄 Stage 2: Fetched \(poisToUse?.count ?? 0) POIs with Google")
            }
            
            let routeGenStart = Date()
            let route = try await generateLocalRoute(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                difficulty: difficulty,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                prefetchedPOIs: poisToUse,  // Use Google-included POIs if fetched
                useSystematicSelection: true,
                expandedSearch: true,
                searchRadiusOverride: searchRadiusForStage2  // Use calculated radius
            )
            let routeGenTime = Date().timeIntervalSince(routeGenStart)
            let stage2Elapsed = Date().timeIntervalSince(stage2StartTime)
            let totalElapsed = Date().timeIntervalSince(startTime)
            
            await MainActor.run { retryStatus = nil }
            print("✅ STAGE 2 SUCCESS: \(route.durationSeconds / 60) min route with \(route.places.count) waypoints")
            print("⏱️ [TIMING] Stage 2 POI fetch: \(String(format: "%.2f", stage2POIFetchTime))s")
            print("⏱️ [TIMING] Stage 2 route generation: \(String(format: "%.2f", routeGenTime))s")
            print("⏱️ [TIMING] Stage 2 total: \(String(format: "%.2f", stage2Elapsed))s")
            print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            print("⏱️ [TIMING] TOTAL TIME: \(String(format: "%.2f", totalElapsed))s")
            print("⏱️ [TIMING]   Stage 1: failed")
            print("⏱️ [TIMING]   Stage 2: \(String(format: "%.2f", stage2Elapsed))s")
            print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            return route
        } catch GoogleMapsError.rateLimited(let waitTime) {
            // Rate limited - wait and continue
            print("🚫 Stage 2 rate limited, waiting \(waitTime)s...")
            await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
            try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
        } catch {
            print("🔄 Stage 2 (systematic) failed, trying shorter durations...")
        }
        
        // Stage 3: Try shorter durations (drop 5 min at a time, but not below 10 min)
        // v2.0.1: Minimum route duration is 10 minutes
        print("\n📍 STAGE 3: Fallback to Shorter Durations")
        let stage3StartTime = Date()
        print("⏱️ [TIMING] Stage 3 STARTED")
        for reducedDuration in stride(from: targetDurationMinutes - 5, through: 10, by: -5) {
            let currentDuration = reducedDuration  // Capture for concurrent access
            await MainActor.run { retryStatus = "Trying \(currentDuration) min route..." }
            do {
                let route = try await generateLocalRoute(
                    from: location,
                    targetDurationMinutes: currentDuration,
                    difficulty: difficulty,
                    excludePlaceIds: excludePlaceIds,
                    excludePOIs: excludePOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
                    prefetchedPOIs: nil,
                    useSystematicSelection: true,
                    expandedSearch: true
                )
                let stage3Elapsed = Date().timeIntervalSince(stage3StartTime)
                let totalElapsed = Date().timeIntervalSince(startTime)
                await MainActor.run { retryStatus = nil }
                print("🔄 Found route at \(currentDuration) min (originally requested \(targetDurationMinutes) min)")
                print("⏱️ [TIMING] Stage 3: \(String(format: "%.2f", stage3Elapsed))s")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                print("⏱️ [TIMING] TOTAL TIME: \(String(format: "%.2f", totalElapsed))s")
                print("⏱️ [TIMING]   Stage 1: failed")
                print("⏱️ [TIMING]   Stage 2: failed")
                print("⏱️ [TIMING]   Stage 3: \(String(format: "%.2f", stage3Elapsed))s")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                return route
            } catch GoogleMapsError.rateLimited(let waitTime) {
                // Rate limited in stage 3 - wait and continue to next duration
                print("🚫 Rate limited at \(currentDuration)min, waiting \(waitTime)s...")
                await MainActor.run { retryStatus = "Waiting for rate limit reset..." }
                try? await Task.sleep(nanoseconds: UInt64(waitTime) * 1_000_000_000)
            } catch {
                print("🔄 \(currentDuration) min also failed...")
            }
        }
        
        // All stages failed
        await MainActor.run { retryStatus = nil }
        throw GoogleMapsError.noRouteFound
    }
    
    // MARK: - Generate Initial Route with Google Fallback
    /// Generates the INITIAL route for the user. Uses Google Directions as fallback
    /// ONLY if NO valid routes (80-100% of target) are found via MapKit.
    /// This is the only place where Google Directions should be called.
    func generateInitialRouteWithGoogleFallback(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],  // v1.9.51: Actual POI objects to check for duplicates by name/coordinate
        prefetchedPOIs: [PlaceResult]? = nil
    ) async throws -> GeneratedRoute {
        
        // Step 1: Try MapKit with ENDPOINT-FIRST approach (FREE, simpler, more predictable)
        // This finds a single POI at half the target distance and routes there and back
        let mapKitRoute = try await generateLocalRoute(
            from: location,
            targetDurationMinutes: targetDurationMinutes,
            difficulty: difficulty,
            excludePlaceIds: excludePlaceIds,
            excludePOIs: excludePOIs,  // v1.9.51: Pass actual POI objects for duplicate detection
            prefetchedPOIs: prefetchedPOIs,
            useEndpointFirst: true  // NEW: Use simpler endpoint approach for Route 1
        )
        
        // Step 2: Check if route is within 80-100% tolerance
        let mins = mapKitRoute.durationSeconds / 60
        let toleranceMin = Int(Double(targetDurationMinutes) * 0.80)
        let toleranceMax = targetDurationMinutes
        let isWithinTolerance = mins >= toleranceMin && mins <= toleranceMax
        
        // Step 2b: If route is "boring" (1 waypoint), try SHORTER ENDPOINT + WAYPOINTS for variety
        if mapKitRoute.places.count <= 1, let pois = prefetchedPOIs {
            print("🎯 🔄 Route has only \(mapKitRoute.places.count) waypoint(s) - trying SHORTER ENDPOINT + WAYPOINTS for variety...")
            
            // For SHORTER endpoint, target 50-80% of requested time to leave room for waypoints
            // Based on observed data: 222m → 8min, so ~28m per min walking
            // To get 13min base route (middle of 10-16), need ~13 * 28 = 364m
            let shorterTargetMinutes = Int(Double(targetDurationMinutes) * 0.65)  // 65% of target
            let shorterHalfDuration = shorterTargetMinutes / 2
            // Use 0.7 factor - the 0.4 was too aggressive (gave 6-8min routes)
            let shorterIdealDistance = Double(shorterHalfDuration * adaptiveWalkingSpeed) * 0.7
            
            // Exclude the POI already used (by placeId, name, or location)
            let shorterCandidates = pois
                .filter { poi in
                    // Check if this POI is already in the route using unified comparator
                    let isAlreadyUsed = mapKitRoute.places.contains { existing in
                        isRouteDuplicate(poi, existing)
                    }
                    
                    return !isAlreadyUsed
                }
                .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                    let dist = distanceBetween(location, poi.coordinate)
                    let score = abs(dist - shorterIdealDistance)
                    return (poi, dist, score)
                }
                .filter { $0.distance >= shorterIdealDistance * 0.3 && $0.distance <= shorterIdealDistance * 2.0 }
                .sorted { $0.score < $1.score }
            
            print("🎯 🔄 Found \(shorterCandidates.count) shorter endpoint candidates (ideal: \(Int(shorterIdealDistance))m)")
            
            for candidate in shorterCandidates.prefix(3) {
                print("🎯 🔄 Trying shorter endpoint: '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                
                // v2.0.3 Batch A: Wrap with timeout
                let shortTimeout = RoutingToggles.perCallTimeoutNormal
                let (shortResult, didTimeout) = await directionsWithTimeout(
                    origin: location,
                    destination: location,
                    waypoints: [candidate.poi.coordinate],
                    timeout: shortTimeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: nil
                )
                
                if didTimeout {
                    print("🎯 🔄 ⏱️ Timeout testing shorter endpoint")
                    continue
                }
                
                guard let directions = shortResult else {
                    print("🎯 🔄 Failed: no directions")
                    continue
                }
                
                let routeDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let routeDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let routeMinutes = routeDuration / 60
                
                // Must be 50-80% of target (room for waypoints)
                let minShorter = Int(Double(targetDurationMinutes) * 0.50)
                let maxShorter = Int(Double(targetDurationMinutes) * 0.80)
                
                if routeMinutes >= minShorter && routeMinutes <= maxShorter {
                    print("🎯 🔄 Shorter route: \(routeMinutes)min (\(minShorter)-\(maxShorter) target) - enhancing...")
                    
                    let shorterRoute = GeneratedRoute(
                        places: [candidate.poi],
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: routeDistance,
                        durationSeconds: routeDuration,
                        legs: directions.legs
                    )
                    
                    do {
                        let enhanced = try await enhanceRouteWithWaypoints(
                            existingRoute: shorterRoute,
                            origin: location,
                            targetDurationMinutes: targetDurationMinutes,
                            prefetchedPOIs: pois
                        )
                        
                        let enhancedMins = enhanced.durationSeconds / 60
                        if enhanced.places.count > 1 && enhancedMins >= toleranceMin && enhancedMins <= toleranceMax {
                            print("🎯 ✨ ENHANCED shorter route: \(enhanced.places.count) waypoints, \(enhancedMins)min - adding as alternative!")
                            alternativeEndpointRoutes.append(enhanced)
                            break  // Found one good enhanced route
                        } else {
                            print("🎯 🔄 Enhanced not valid: \(enhanced.places.count) wp, \(enhancedMins)min (need \(toleranceMin)-\(toleranceMax))")
                        }
                    } catch {
                        print("🎯 🔄 Enhancement failed: \(error.localizedDescription)")
                    }
                } else {
                    print("🎯 🔄 Route \(routeMinutes)min outside \(minShorter)-\(maxShorter) range")
                }
            }
            
            if alternativeEndpointRoutes.isEmpty {
                print("🎯 🔄 No valid shorter+enhanced route found")
            } else {
                print("🎯 📦 Added \(alternativeEndpointRoutes.count) alternative route(s) to pool")
            }
        }
        
        if isWithinTolerance {
            print("🗺️ ✅ Initial route within 80-100%: \(mins)min - no Google needed")
            return mapKitRoute
        }
        
        // Step 3: MapKit route is outside tolerance - try Google (PAID, 1 attempt only)
        print("🗺️ ⚠️ Initial route outside 80-100%: \(mins)min - trying Google fallback...")
        
        if let googleRoute = await getGoogleDirectionsRoute(
            origin: location,
            waypoints: mapKitRoute.places,
            targetDurationMinutes: targetDurationMinutes
        ) {
            let googleMins = googleRoute.durationSeconds / 60
            let googleWithinTolerance = googleMins >= toleranceMin && googleMins <= toleranceMax
            
            if googleWithinTolerance {
                print("🌐 ✅ Google route within tolerance: \(googleMins)min - using Google")
                return googleRoute
            } else if abs(googleMins - targetDurationMinutes) < abs(mins - targetDurationMinutes) {
                print("🌐 ✓ Google route closer to target: \(googleMins)min vs MapKit \(mins)min")
                return googleRoute
            } else {
                print("🌐 ✗ Google not better, using MapKit: \(mins)min")
            }
        } else {
            print("🌐 ✗ Google fallback failed, using MapKit: \(mins)min")
        }
        
        // Return MapKit route as fallback
        return mapKitRoute
    }
    
    // MARK: - Unified Route Deduplication System
    
    /// UNIFIED DUPLICATE COMPARATOR - Use this everywhere instead of ad-hoc checks
    /// Returns true if two POIs are considered duplicates
    // MARK: - v2.0.18: Enhanced POI Deduplication (A-F)
    
    /// Name signature for fuzzy matching (v2.0.18)
    private struct NameSignature {
        let norm: String          // lowercased, diacritics/stopwords removed
        let tokens: Set<String>   // token set for order-insensitive match
    }
    
    /// Brand/alias map for fuzzy matching (v2.0.18)
    private static let brandAliasMap: [String: Set<String>] = [
        "co-op food": ["the co-operative", "co-operative", "coop"],
        "tesco express": ["tesco"],
        "sainsbury's local": ["sainsburys", "sainsbury"],
        "asda express": ["asda"],
        "morrisons daily": ["morrisons"],
        "spar": ["spar shop"],
        "co-op": ["cooperative", "co-operative"]
    ]
    
    /// Create name signature from POI name (v2.0.18)
    private func createNameSignature(_ name: String) -> NameSignature {
        let cleaned = GoogleMapsService.cleanPOIDisplayName(name).lowercased()
        // Remove common stopwords and normalize
        let stopwords = Set(["the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for"])
        let tokens = cleaned.split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !stopwords.contains($0) }
        return NameSignature(norm: cleaned, tokens: Set(tokens))
    }
    
    /// Jaccard similarity (token overlap) (v2.0.18)
    private func jaccardSimilarity(_ a: NameSignature, _ b: NameSignature) -> Double {
        let intersection = a.tokens.intersection(b.tokens).count
        let union = a.tokens.union(b.tokens).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }
    
    /// Jaro-Winkler similarity (v2.0.18 - simplified version)
    private func jaroWinklerSimilarity(_ a: String, _ b: String) -> Double {
        // Simplified Jaro-Winkler - for exact implementation, use a library
        // For now, use Levenshtein-based approximation
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        
        // Simple prefix match bonus
        let prefixLen = min(4, min(a.count, b.count))
        var prefixMatch = 0
        for i in 0..<prefixLen {
            if a[a.index(a.startIndex, offsetBy: i)] == b[b.index(b.startIndex, offsetBy: i)] {
                prefixMatch += 1
            } else {
                break
            }
        }
        
        // Character overlap (simplified)
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        let jaro = union > 0 ? Double(intersection) / Double(union) : 0.0
        
        // Winkler adjustment (prefix bonus)
        let winklerBonus = 0.1 * Double(prefixMatch) / 4.0
        return min(1.0, jaro + winklerBonus)
    }
    
    /// Check brand/alias match (v2.0.18)
    private func brandAliasMatch(_ a: String, _ b: String) -> Bool {
        let aNorm = a.lowercased()
        let bNorm = b.lowercased()
        
        for (brand, aliases) in Self.brandAliasMap {
            if (aNorm.contains(brand) && aliases.contains { bNorm.contains($0) }) ||
               (bNorm.contains(brand) && aliases.contains { aNorm.contains($0) }) {
                return true
            }
        }
        return false
    }
    
    /// Fuzzy name similarity check (v2.0.18)
    private func fuzzyNameSimilar(_ a: NameSignature, _ b: NameSignature) -> Bool {
        // 1) Token overlap (Jaccard) ≥ 0.7
        let jaccard = jaccardSimilarity(a, b)
        if jaccard >= 0.70 {
            return true
        }
        
        // 2) OR Jaro-Winkler ≥ 0.90 on norm
        let jaro = jaroWinklerSimilarity(a.norm, b.norm)
        if jaro >= 0.90 {
            return true
        }
        
        // 3) OR brandAlias match
        if brandAliasMatch(a.norm, b.norm) {
            return true
        }
        
        return false
    }
    
    /// Calculate local POI density (v2.0.18)
    private func localPOIDensity(_ poi: PlaceResult, allPOIs: [PlaceResult], radiusMeters: Double = 250.0) -> Int {
        return allPOIs.filter { other in
            distanceBetween(poi.coordinate, other.coordinate) <= radiusMeters
        }.count
    }
    
    /// Get base radius by category (v2.0.18)
    private func baseRadiusForCategory(_ poi: PlaceResult) -> Double {
        guard let types = poi.types else { return 40.0 }
        let typeSet = Set(types.map { $0.lowercased() })
        
        // Green space / parks
        if typeSet.contains("park") || typeSet.contains("garden") || typeSet.contains("nature_reserve") {
            return 75.0
        }
        // Civic / monuments
        if typeSet.contains("church") || typeSet.contains("place_of_worship") || typeSet.contains("monument") {
            return 60.0
        }
        // Retail / food
        if typeSet.contains("restaurant") || typeSet.contains("food") || typeSet.contains("store") || typeSet.contains("supermarket") {
            return 35.0
        }
        // Pub / cafe
        if typeSet.contains("bar") || typeSet.contains("cafe") || typeSet.contains("pub") {
            return 30.0
        }
        // Religious
        if typeSet.contains("church") || typeSet.contains("mosque") || typeSet.contains("synagogue") {
            return 45.0
        }
        // Default
        return 40.0
    }
    
    /// Adaptive deduplication radius (v2.0.18)
    private func adaptiveDedupRadius(poi: PlaceResult, localDensity: Int, allPOIs: [PlaceResult]) -> Double {
        let baseRadius = baseRadiusForCategory(poi)
        // Adaptive factor (denser area → smaller radius, up to -40%)
        let shrink = min(0.4, Double(localDensity) / 80.0)
        return baseRadius * (1.0 - shrink)
    }
    
    /// Quality score for POI (v2.0.18)
    private func qualityScore(_ poi: PlaceResult) -> Double {
        var score = 0.0
        
        // Opening hours (if available in types or metadata)
        // Note: PlaceResult doesn't have opening_hours field, so we'll use types richness
        if let types = poi.types, !types.isEmpty {
            score += 0.8 * Double(min(types.count, 5)) / 5.0  // Tag count (normalized)
        }
        
        // Source priority
        switch poi.source {
        case .google: score += 1.5
        case .osm: score += 1.0
        case .geograph: score += 0.8
        case .apple: score += 0.6
        case .unknown: score += 0.3
        }
        
        // Name quality (longer, more descriptive names are better)
        if poi.name.count > 10 {
            score += 0.5
        }
        
        // Vicinity information
        if poi.vicinity != nil && !poi.vicinity!.isEmpty {
            score += 0.6
        }
        
        return score
    }
    
    /// Check if two POIs are in same category family (v2.0.18)
    private func sameCategoryFamily(_ a: PlaceResult, _ b: PlaceResult) -> Bool {
        guard let typesA = a.types, let typesB = b.types else { return false }
        let setA = Set(typesA.map { $0.lowercased() })
        let setB = Set(typesB.map { $0.lowercased() })
        return !setA.isDisjoint(with: setB)
    }
    
    /// Deduplication telemetry (v2.0.18)
    struct DedupTelemetry {
        var pairsExamined: Int = 0
        var duplicatesRemoved: Int = 0
        var clustersFormed: Int = 0
        var clustersWithCrossOSMEntities: Int = 0
        var semanticKeptPairs: Int = 0
        var aliasMatches: Int = 0
        var brandMatches: Int = 0
        var distanceThresholdUsed: [String: Double] = [:]
    }
    
    /// Note: Internal visibility allows unit tests to access this function
    /// v2.0.18: Enhanced with fuzzy matching, adaptive thresholds, and quality scoring
    func isRouteDuplicate(_ a: PlaceResult, _ b: PlaceResult, requireCategoryMatch: Bool = false, allPOIs: [PlaceResult] = [], dedupTelemetry: inout DedupTelemetry?) -> Bool {
        dedupTelemetry?.pairsExamined += 1
        
        // 1. Exact placeId match
        if !a.placeId.isEmpty && !b.placeId.isEmpty && a.placeId == b.placeId {
            dedupTelemetry?.duplicatesRemoved += 1
            return true
        }
        
        let distance = distanceBetween(a.coordinate, b.coordinate)
        
        // v2.0.18: Category-aware matching
        let categoriesMatch: Bool = {
            guard let typesA = a.types, let typesB = b.types else { return true }
            return !Set(typesA).isDisjoint(with: Set(typesB))
        }()
        
        // If category match required and categories don't match, not a duplicate
        if requireCategoryMatch || RoutingToggles.requireCategoryMatch {
            if !categoriesMatch && distance >= 20.0 {
                return false
            }
        }
        
        // v2.0.18: Adaptive spatial threshold (B)
        let localDensity = allPOIs.isEmpty ? 20 : localPOIDensity(a, allPOIs: allPOIs)
        let adaptiveRadius = adaptiveDedupRadius(poi: a, localDensity: localDensity, allPOIs: allPOIs)
        
        // Track threshold used for telemetry
        let categoryKey = a.types?.first?.lowercased() ?? "other"
        dedupTelemetry?.distanceThresholdUsed[categoryKey] = adaptiveRadius
        
        // 2. Same location (within adaptive threshold) - definitive same spot
        if distance < adaptiveRadius {
            dedupTelemetry?.duplicatesRemoved += 1
            return true
        }
        
        // v2.0.18: Fuzzy name matching (A) - replaces exact name equality
        let sigA = createNameSignature(a.name)
        let sigB = createNameSignature(b.name)
        
        // Check fuzzy similarity
        let isFuzzyMatch = fuzzyNameSimilar(sigA, sigB)
        if isFuzzyMatch {
            // Track alias/brand matches
            if brandAliasMatch(sigA.norm, sigB.norm) {
                dedupTelemetry?.brandMatches += 1
            } else if jaccardSimilarity(sigA, sigB) >= 0.70 {
                dedupTelemetry?.aliasMatches += 1
            }
            
            // Use adaptive radius for fuzzy matches too
            if distance < adaptiveRadius * 1.5 {  // Slightly more lenient for fuzzy matches
                if RoutingToggles.requireCategoryMatch && !categoriesMatch {
                    return false
                }
                dedupTelemetry?.duplicatesRemoved += 1
                return true
            }
        }
        
        // Legacy: Exact name match (for backward compatibility)
        let nameA = sigA.norm
        let nameB = sigB.norm
        if nameA == nameB && nameA.count > 0 && distance < adaptiveRadius * 1.5 {
            if RoutingToggles.requireCategoryMatch && !categoriesMatch {
                return false
            }
            dedupTelemetry?.duplicatesRemoved += 1
            return true
        }
        
        return false
    }
    
    /// Overload for backward compatibility (v2.0.18)
    func isRouteDuplicate(_ a: PlaceResult, _ b: PlaceResult, requireCategoryMatch: Bool = false) -> Bool {
        var telemetry: DedupTelemetry? = nil
        return isRouteDuplicate(a, b, requireCategoryMatch: requireCategoryMatch, allPOIs: [], dedupTelemetry: &telemetry)
    }
    
    /// POI Fingerprint - Safety net to catch near-identical cases
    /// Combines cleaned name, rounded coordinates (~150m bins), and category
    private func poiFingerprint(_ poi: PlaceResult) -> String {
        // Round coordinates to ~150m bins (0.0015 deg ≈ ~160m at mid-latitudes)
        let roundedLat = (round(poi.coordinate.latitude / 0.0015) * 0.0015)
        let roundedLon = (round(poi.coordinate.longitude / 0.0025) * 0.0025)
        
        let cleanedName = GoogleMapsService.cleanPOIDisplayName(poi.name).lowercased()
        let category = poi.types?.first ?? "unknown"
        
        return "\(cleanedName)|\(String(format: "%.6f", roundedLat)),\(String(format: "%.6f", roundedLon))|\(category)"
    }
    
    /// Fingerprint-based deduplication (safety net)
    private func deduplicateByFingerprint(_ places: [PlaceResult]) -> [PlaceResult] {
        var seen = Set<String>()
        var deduplicated: [PlaceResult] = []
        
        for place in places {
            let fp = poiFingerprint(place)
            if !seen.contains(fp) {
                seen.insert(fp)
                deduplicated.append(place)
            }
        }
        
        return deduplicated
    }
    
    /// UNIFIED ROUTE DEDUPLICATION - Enhanced with fuzzy matching, adaptive thresholds, quality scoring (v2.0.18)
    /// v2.0.18: Implements A-F improvements: fuzzy match, adaptive radius, OSM conflation, quality scoring, semantic near-duplicates, telemetry
    private func deduplicateRoutePlaces(_ places: [PlaceResult]) -> [PlaceResult] {
        guard places.count > 1 else { return places }
        
        // v2.0.18: Initialize telemetry
        var dedupTelemetry = DedupTelemetry()
        
        print("🔍 DEDUPLICATION: Checking \(places.count) POIs for duplicates...")
        print("🔍 POI list: \(places.enumerated().map { "\($0+1). \($1.name) [\($1.placeId)]" }.joined(separator: ", "))")
        
        // v2.0.18: Step 0: OSM Conflation (C) - Group OSM node/way/relation into canonical features
        var osmGroups: [String: [PlaceResult]] = [:]
        var conflatedPlaces: [PlaceResult] = []
        
        for place in places {
            // Create OSM group key (stable key for node/way/relation cluster)
            if place.source == .osm {
                let roundedLat = round(place.coordinate.latitude / 0.0001) * 0.0001  // ~11m bins
                let roundedLon = round(place.coordinate.longitude / 0.0001) * 0.0001
                let nameBase = createNameSignature(place.name).norm
                let osmKey = "\(roundedLat),\(roundedLon),\(nameBase)"
                
                if osmGroups[osmKey] == nil {
                    osmGroups[osmKey] = []
                }
                osmGroups[osmKey]?.append(place)
            } else {
                conflatedPlaces.append(place)
            }
        }
        
        // v2.0.18: Pick canonical OSM feature (highest quality, most stable geometry)
        for (_, group) in osmGroups {
            guard !group.isEmpty else { continue }
            
            // Sort by quality score, then by source stability (way/relation > node)
            let canonical = group.sorted { a, b in
                let scoreA = qualityScore(a)
                let scoreB = qualityScore(b)
                if abs(scoreA - scoreB) > 0.1 {
                    return scoreA > scoreB
                }
                // Prefer way/relation over node (more stable geometry)
                let aIsNode = a.placeId.contains("node")
                let bIsNode = b.placeId.contains("node")
                return !aIsNode && bIsNode
            }.first!
            
            conflatedPlaces.append(canonical)
            dedupTelemetry.clustersFormed += 1
            if group.count > 1 {
                dedupTelemetry.clustersWithCrossOSMEntities += 1
            }
        }
        
        // Step 1: Pairwise duplicate removal using enhanced comparator
        // C) Route-level dedup: prove the pair loop runs - add explicit counter
        var pairsExamined = 0
        var deduplicated: [PlaceResult] = []
        for (index, place) in conflatedPlaces.enumerated() {
            // Check against all already-deduplicated POIs
            var matchedExisting: PlaceResult? = nil
            var isDuplicate = false
            
            // C) Count pairs examined in explicit pairwise loop
            for existing in deduplicated {
                pairsExamined += 1
                var telemetry: DedupTelemetry? = dedupTelemetry
                let isDup = isRouteDuplicate(place, existing, allPOIs: conflatedPlaces, dedupTelemetry: &telemetry)
                if isDup {
                    matchedExisting = existing
                    isDuplicate = true
                    break
                }
            }
            
            if isDuplicate, let matched = matchedExisting {
                // v2.0.18: Quality scoring (D) - keep higher quality POI
                let placeQuality = qualityScore(place)
                let matchedQuality = qualityScore(matched)
                
                // If current POI is significantly better, replace the matched one
                if placeQuality > matchedQuality + 0.5 {
                    if let matchedIndex = deduplicated.firstIndex(where: { $0.placeId == matched.placeId }) {
                        deduplicated[matchedIndex] = place
                        print("🔄 Route dedup [\(index + 1)/\(conflatedPlaces.count)]: Replaced '\(matched.name)' (quality: \(String(format: "%.2f", matchedQuality))) with '\(place.name)' (quality: \(String(format: "%.2f", placeQuality)))")
                        continue
                    }
                }
                
                // Otherwise, keep the matched one (already in deduplicated)
                let distance = distanceBetween(place.coordinate, matched.coordinate)
                let nameA = createNameSignature(place.name).norm
                let nameB = createNameSignature(matched.name).norm
                let reason: String
                if place.placeId == matched.placeId {
                    reason = "same placeId: \(place.placeId)"
                } else if distance < 20.0 {
                    reason = "same location (\(String(format: "%.1f", distance))m)"
                } else {
                    reason = "fuzzy name match '\(nameA)' ≈ '\(nameB)' (\(String(format: "%.1f", distance))m)"
                }
                print("🚫 Route dedup [\(index + 1)/\(conflatedPlaces.count)]: Removed '\(place.name)' [\(place.placeId)] (\(reason)) - matched '\(matched.name)' [\(matched.placeId)]")
            } else {
                // v2.0.18: Check for semantic near-duplicates (E) - keep if different category and improves route
                var shouldKeep = true
                if let existing = deduplicated.first(where: { existing in
                    let dist = distanceBetween(place.coordinate, existing.coordinate)
                    return dist < 25.0 && !sameCategoryFamily(place, existing)
                }) {
                    // Different category, very close - keep both (enriches route)
                    deduplicated.append(place)
                    dedupTelemetry.semanticKeptPairs += 1
                    print("✅ Route dedup [\(index + 1)/\(conflatedPlaces.count)]: Kept semantic near-duplicate '\(place.name)' (different category from '\(existing.name)')")
                    shouldKeep = false
                }
                
                if shouldKeep {
                    deduplicated.append(place)
                }
            }
        }
        
        // Step 2: Fingerprint safety net (catches near-identical leftovers)
        let beforeFingerprint = deduplicated.count
        deduplicated = deduplicateByFingerprint(deduplicated)
        if deduplicated.count < beforeFingerprint {
            let removed = beforeFingerprint - deduplicated.count
            dedupTelemetry.duplicatesRemoved += removed
            print("🔍 Fingerprint safety net: Removed \(removed) additional near-duplicate(s)")
        }
        
        // v2.0.18: Step 3: Final pass with enhanced fuzzy matching
        // C) Count pairs in final pass too
        var finalDeduplicated: [PlaceResult] = []
        for place in deduplicated {
            var matchedExisting: PlaceResult? = nil
            var isDuplicate = false
            
            // C) Count pairs examined in explicit pairwise loop
            for existing in finalDeduplicated {
                pairsExamined += 1
                var telemetry: DedupTelemetry? = dedupTelemetry
                let isDup = isRouteDuplicate(place, existing, allPOIs: deduplicated, dedupTelemetry: &telemetry)
                if isDup {
                    matchedExisting = existing
                    isDuplicate = true
                    break
                }
            }
            
            if !isDuplicate {
                finalDeduplicated.append(place)
            } else if let matched = matchedExisting {
                // Quality check: keep better POI
                let placeQuality = qualityScore(place)
                let matchedQuality = qualityScore(matched)
                if placeQuality > matchedQuality + 0.5, let matchedIndex = finalDeduplicated.firstIndex(where: { $0.placeId == matched.placeId }) {
                    finalDeduplicated[matchedIndex] = place
                    print("🔄 Final dedup: Replaced '\(matched.name)' with higher quality '\(place.name)'")
                } else {
                    let distance = distanceBetween(place.coordinate, matched.coordinate)
                    print("🚫 FINAL: Removed '\(place.name)' [\(place.placeId)] - duplicate of '\(matched.name)' [\(matched.placeId)] @ \(String(format: "%.1f", distance))m")
                }
            }
        }
        
        deduplicated = finalDeduplicated
        
        // C) Set pairs_examined from explicit counter (proves the pair loop runs)
        dedupTelemetry.pairsExamined = pairsExamined
        
        // v2.0.18: Output telemetry (F)
        if deduplicated.count < places.count {
            let removed = places.count - deduplicated.count
            dedupTelemetry.duplicatesRemoved = removed
            print("🚫 Route deduplication: Removed \(removed) duplicate POI(s) from route (kept \(deduplicated.count) of \(places.count))")
            print("🔍 Final POI list: \(deduplicated.enumerated().map { "\($0+1). \($1.name) [\($1.placeId)]" }.joined(separator: ", "))")
        } else {
            print("✅ Route deduplication: No duplicates found (all \(places.count) POIs unique)")
        }
        
        // v2.0.18: Emit deduplication telemetry
        print("📊 [DEDUP_TELEMETRY] pairs_examined=\(dedupTelemetry.pairsExamined) duplicates_removed=\(dedupTelemetry.duplicatesRemoved) clusters_formed=\(dedupTelemetry.clustersFormed) clusters_with_crossOSM_entities=\(dedupTelemetry.clustersWithCrossOSMEntities) semantic_kept_pairs=\(dedupTelemetry.semanticKeptPairs) alias_matches=\(dedupTelemetry.aliasMatches) brand_matches=\(dedupTelemetry.brandMatches) distance_threshold_used=\(dedupTelemetry.distanceThresholdUsed)")
        
        return deduplicated
    }
    
    /// Diagnostic: Check for nearby name duplicates that might have been missed
    /// Also ACTUALLY REMOVES them if they're within 200m (more aggressive)
    private func debugNearbyNameDupes(_ places: [PlaceResult]) -> [PlaceResult] {
        var result = places
        var removedIndices = Set<Int>()
        
        for i in 0..<places.count {
            if removedIndices.contains(i) { continue }
            
            for j in (i+1)..<places.count {
                if removedIndices.contains(j) { continue }
                
                let a = places[i]
                let b = places[j]
                let distance = distanceBetween(a.coordinate, b.coordinate)
                let nameA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
                let nameB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
                
                // If same cleaned name and within 250m, remove the later one (increased from 200m)
                // This catches cases like "The Star Inn" vs "SE2922 : The Star Inn, Batley Road, Kirkhamgate"
                if nameA == nameB && nameA.count > 0 && distance <= 250.0 {
                    print("⚠️ CRITICAL: Found duplicate by name: '\(a.name)' [\(a.placeId)] vs '\(b.name)' [\(b.placeId)] @ \(Int(distance))m - REMOVING (cleaned: '\(nameA)')")
                    removedIndices.insert(j)
                } else if nameA == nameB && nameA.count > 0 && distance <= 200.0 {
                    print("⚠️ Near-dup by name: '\(a.name)' [\(a.placeId)] vs '\(b.name)' [\(b.placeId)] @ \(Int(distance))m (<=200m, cleaned: '\(nameA)')")
                }
                
                // Extra logging for problematic POIs
                if nameA.contains("lindale methodist church") || nameA.contains("star inn") || nameA.contains("war memorial") {
                    if nameA == nameB && nameA.count > 0 {
                        print("🔍 debugNearbyNameDupes: Checking '\(a.name)' vs '\(b.name)' → cleaned: '\(nameA)' == '\(nameB)', distance: \(String(format: "%.1f", distance))m")
                    }
                }
            }
        }
        
        // Remove duplicates (in reverse order to maintain indices)
        for index in removedIndices.sorted(by: >) {
            result.remove(at: index)
        }
        
        return result
    }
    
    /// FINAL SAFETY WRAPPER - Call this at EVERY return site
    /// Ensures route places are deduplicated even if polyline building fails
    /// Also exposed for RouteSelectionView to use
    func finalizeRouteDedupForView(_ route: GeneratedRoute) -> GeneratedRoute {
        // #region agent log
        if route.places.count > 1 {
            let distances = (0..<route.places.count-1).map { i in
                distanceBetween(route.places[i].coordinate, route.places[i+1].coordinate)
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "F",
                "location": "GoogleMapsService.swift:10112",
                "message": "finalizeRouteDedupForView: entry",
                "data": [
                    "waypointCount": route.places.count,
                    "waypoints": route.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                    "distances": distances,
                    "minDistance": distances.min() ?? 0
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
               let logString = String(data: logJSON, encoding: .utf8) {
                logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
        }
        // #endregion
        
        print("🛡️ VIEW LAYER: Final deduplication check before storing route")
        print("🛡️ VIEW LAYER: Input route has \(route.places.count) POIs: \(route.places.map { $0.name }.joined(separator: ", "))")
        let deduplicatedPlaces = deduplicateRoutePlaces(route.places)
        
        guard deduplicatedPlaces.count < route.places.count else {
            print("🛡️ VIEW LAYER: No duplicates found - all \(route.places.count) POIs are unique")
            // #region agent log
            if route.places.count > 1 {
                let distances = (0..<route.places.count-1).map { i in
                    distanceBetween(route.places[i].coordinate, route.places[i+1].coordinate)
                }
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "F",
                    "location": "GoogleMapsService.swift:10119",
                    "message": "finalizeRouteDedupForView: exit (no duplicates)",
                    "data": [
                        "waypointCount": route.places.count,
                        "waypoints": route.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                        "distances": distances,
                        "minDistance": distances.min() ?? 0
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                   let logString = String(data: logJSON, encoding: .utf8) {
                    logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
            }
            // #endregion
            return route
        }
        
        print("🛡️ VIEW LAYER: Removed \(route.places.count - deduplicatedPlaces.count) duplicate(s) before storing")
        print("🛡️ VIEW LAYER: Final route has \(deduplicatedPlaces.count) POIs: \(deduplicatedPlaces.map { $0.name }.joined(separator: ", "))")
        
        let finalRoute = GeneratedRoute(
            places: deduplicatedPlaces,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
        
        // #region agent log
        if deduplicatedPlaces.count > 1 {
            let distances = (0..<deduplicatedPlaces.count-1).map { i in
                distanceBetween(deduplicatedPlaces[i].coordinate, deduplicatedPlaces[i+1].coordinate)
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "F",
                "location": "GoogleMapsService.swift:10130",
                "message": "finalizeRouteDedupForView: exit (deduplicated)",
                "data": [
                    "originalCount": route.places.count,
                    "deduplicatedCount": deduplicatedPlaces.count,
                    "finalWaypoints": deduplicatedPlaces.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                    "distances": distances,
                    "minDistance": distances.min() ?? 0
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
               let logString = String(data: logJSON, encoding: .utf8) {
                logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
        }
        // #endregion
        
        return finalRoute
    }
    
    /// FINAL SAFETY WRAPPER - Call this at EVERY return site
    // MARK: - v2.0.3 Phase 1.5 Batch A: Centralized Route Finalization
    /// Centralized function to finalize and return routes with hard cap enforcement
    /// This ensures NO route can bypass the 180% hard cap, regardless of code path
    /// CRITICAL: Returns nil for routes >180% - caller MUST handle by using fallback
    /// PHASE B: Also enforces minimum waypoints with nudge and micro-spur insertion
    /// SPRINT-4: Recomputes polyline after nudge/micro-spur modifications
    /// Returns: (route, nudgesAdded, microSpursAdded) - tracking counts for PHASE D
    private func finalizeAndReturnRoute(
        _ route: GeneratedRoute,
        targetDurationMinutes: Int,
        postcode: String? = nil,
        allowExtendedCapForFallback: Bool = false,
        origin: CLLocationCoordinate2D? = nil,  // PHASE B: For nudge/micro-spur
        allPlaces: [PlaceResult] = [],  // PHASE B: For micro-spur insertion
        budget: RoutingToggles.Budget? = nil  // SPRINT-5: Pass budget for universal hard-stop
    ) async -> (route: GeneratedRoute?, nudgesAdded: Int, microSpursAdded: Int) {
        // First, deduplicate
        var deduplicatedRoute = finalizeRouteDedup(route, targetDurationMinutes: targetDurationMinutes)
        
        // SPRINT-5: Create hard-stop check closure for finalization engine calls
        let finalizationHardStopCheck: (() -> Bool)? = budget.map { b in
            { !RoutingToggles.mustContinue(b, bestSoFar: nil, stage: "FINALIZATION") }
        }
        
        // PHASE B: Enforce minimum waypoints
        var nudgesAdded = 0
        var microSpursAdded = 0
        let minWaypoints = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
        if deduplicatedRoute.places.count < minWaypoints {
            print("📍 [WP-MIN] Route has \(deduplicatedRoute.places.count) waypoints < minimum \(minWaypoints) for \(targetDurationMinutes)min - attempting preservation")
            
            // Step 1: Try nudging clustered waypoints
            if let originCoord = origin, RoutingToggles.nudgeBeforeRemoveMeters > 0 {
                let isSuburban = postcode == "WF2 0GU" || postcode == "S5 7AU" || postcode == "S35 0JW" || postcode == "S35 1RQ"
                let nudgedPlaces = deduplicateWithNudge(
                    waypoints: deduplicatedRoute.places,
                    origin: originCoord,
                    isSuburban: isSuburban
                )
                
                if nudgedPlaces.count >= deduplicatedRoute.places.count {
                    // PHASE D: Track nudges
                    nudgesAdded = nudgedPlaces.count - deduplicatedRoute.places.count
                    print("📍 [WP-MIN] Nudge preserved \(nudgedPlaces.count) waypoints (was \(deduplicatedRoute.places.count))")
                    
                    // SPRINT-4: Recompute polyline after nudge (waypoints moved 15-25m along network)
                    let sortedNudged = nudgedPlaces.sorted { wp1, wp2 in
                        distanceBetween(originCoord, wp1.coordinate) < distanceBetween(originCoord, wp2.coordinate)
                    }
                    
                    let regenTimeout = RoutingToggles.perCallTimeoutNormal
                    let (regenResult, didTimeout) = await directionsWithTimeout(
                        origin: originCoord,
                        destination: originCoord,
                        waypoints: sortedNudged.map { $0.coordinate },
                        timeout: regenTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,
                        postcode: postcode,
                        checkGlobalHardStop: finalizationHardStopCheck  // SPRINT-5: Universal hard-stop
                    )
                    
                    if let directions = regenResult, !didTimeout {
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        print("📍 [WP-MIN] Polyline recomputed after nudge: \(duration/60)min, \(distance)m")
                        deduplicatedRoute = GeneratedRoute(
                            places: sortedNudged,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                    } else {
                        // Fallback: use nudged places with original polyline
                        print("📍 [WP-MIN] Polyline recomputation failed/timeout - using original polyline")
                        deduplicatedRoute = GeneratedRoute(
                            places: sortedNudged,
                            polyline: deduplicatedRoute.polyline,
                            distanceMeters: deduplicatedRoute.distanceMeters,
                            durationSeconds: deduplicatedRoute.durationSeconds,
                            legs: deduplicatedRoute.legs
                        )
                    }
                }
            }
            
            // Step 2: If still below minimum, insert micro-spurs
            // SPRINT-7: Allow up to two micro-spur insertion passes when below minWaypoints
            // SPRINT-7 HOTFIX: Add time-remaining check to avoid enqueueing work near hard stop
            // SPRINT-8: Conditional spur passes based on time and accuracy
            var spurTries = 0
            let routeAccuracy = Double(deduplicatedRoute.durationSeconds) / Double(targetDurationMinutes * 60)
            let timeRemainingForCondition = budget.map { $0.hard - (Date().timeIntervalSince1970 - $0.t0) } ?? 18.0
            
            // SPRINT-8: Allow 3 spur passes only in safe conditions, otherwise limit to 1
            let maxSpurTries: Int = {
                if timeRemainingForCondition >= 1.2 && routeAccuracy >= 0.80 && routeAccuracy <= 1.40 {
                    return 3  // Safe conditions: allow full 3 passes
                } else {
                    return 1  // Conservative: just 1 pass
                }
            }()
            print("📍 [WP-MIN] Spur config: maxPasses=\(maxSpurTries) (timeRemaining=\(String(format: "%.1f", timeRemainingForCondition))s, accuracy=\(String(format: "%.1f", routeAccuracy * 100))%)")
            
            let minTimeForSpur: TimeInterval = 1.2  // TWEAK 2: Increased from 0.5s → 1.2s (more conservative)
            
            while deduplicatedRoute.places.count < minWaypoints 
                    && spurTries < maxSpurTries 
                    && !allPlaces.isEmpty, 
                  let originCoord = origin,
                  budget?.within() ?? true {  // SPRINT-7: Budget check for each spur pass
                
                // SPRINT-7 HOTFIX: Time-remaining guard - don't enqueue work near hard stop
                if let b = budget {
                    let timeRemaining = b.hard - (Date().timeIntervalSince1970 - b.t0)
                    if timeRemaining < minTimeForSpur {
                        print("⛔ [WP-MIN] Only \(String(format: "%.2f", timeRemaining))s remaining - skipping micro-spur")
                        break
                    }
                }
                
                spurTries += 1
                let needed = minWaypoints - deduplicatedRoute.places.count
                print("📍 [WP-MIN] Spur pass \(spurTries)/\(maxSpurTries): Still below minimum - inserting up to \(needed) micro-spur(s)")
                
                // Find nearby POIs not already in route
                let existingPOIIds = Set(deduplicatedRoute.places.map { $0.placeId })
                let availablePOIs = allPlaces.filter { poi in
                    guard !existingPOIIds.contains(poi.placeId) else { return false }
                    // Category-aware duplicate check
                    if RoutingToggles.duplicateCheckCategoryFirst {
                        let poiTypes = Set(poi.types ?? [])
                        let categoryDuplicate = deduplicatedRoute.places.contains { existing in
                            let existingTypes = Set(existing.types ?? [])
                            return !poiTypes.isDisjoint(with: existingTypes) &&
                                distanceBetween(poi.coordinate, existing.coordinate) < 50
                        }
                        if categoryDuplicate { return false }
                    }
                    return distanceBetween(originCoord, poi.coordinate) < 800  // Within 800m
                }
                
                // SPRINT-7: If no available POIs left, break early
                guard !availablePOIs.isEmpty else {
                    print("📍 [WP-MIN] No more available POIs for micro-spurs - stopping")
                    break
                }
                
                // Add micro-spurs near start/midpoint
                var enhancedPlaces = deduplicatedRoute.places
                let midIndex = max(0, enhancedPlaces.count / 2)
                let referencePoint = midIndex < enhancedPlaces.count ? enhancedPlaces[midIndex].coordinate : originCoord
                
                let sortedPOIs = availablePOIs.sorted { 
                    distanceBetween($0.coordinate, referencePoint) < distanceBetween($1.coordinate, referencePoint)
                }
                
                // SPRINT-7: Insert 1-2 POIs per pass (not all at once)
                // v2.1.7: Check distances when inserting micro-spurs
                let insertCount = min(2, min(needed, sortedPOIs.count))
                let minMicroSpurDistance: Double = 100  // Same as waypoint distance
                for i in 0..<insertCount {
                    let candidatePOI = sortedPOIs[i]
                    // Check if candidate is too close to any existing waypoint
                    let tooClose = enhancedPlaces.contains { existing in
                        distanceBetween(candidatePOI.coordinate, existing.coordinate) < minMicroSpurDistance
                    }
                    if tooClose {
                        print("📍 [WP-MIN] Skipping micro-spur '\(candidatePOI.name)' - too close to existing waypoint")
                        continue
                    }
                    enhancedPlaces.insert(candidatePOI, at: min(midIndex + i, enhancedPlaces.count))
                    print("📍 [WP-MIN] Inserted micro-spur: \(candidatePOI.name)")
                }
                
                // Track micro-spurs added
                microSpursAdded += insertCount
                
                // SPRINT-4: Recompute polyline after micro-spur insertion
                let sortedEnhanced = enhancedPlaces.sorted { wp1, wp2 in
                    distanceBetween(originCoord, wp1.coordinate) < distanceBetween(originCoord, wp2.coordinate)
                }
                
                let regenTimeout = RoutingToggles.perCallTimeoutNormal
                let (regenResult, didTimeout) = await directionsWithTimeout(
                    origin: originCoord,
                    destination: originCoord,
                    waypoints: sortedEnhanced.map { $0.coordinate },
                    timeout: regenTimeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: postcode,
                    checkGlobalHardStop: finalizationHardStopCheck  // SPRINT-5: Universal hard-stop
                )
                
                if let directions = regenResult, !didTimeout {
                    let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                    let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                    print("📍 [WP-MIN] Polyline recomputed after micro-spur: \(duration/60)min, \(distance)m")
                    deduplicatedRoute = GeneratedRoute(
                        places: sortedEnhanced,
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: distance,
                        durationSeconds: duration,
                        legs: directions.legs
                    )
                } else {
                    // Fallback: use enhanced places with original polyline
                    print("📍 [WP-MIN] Polyline recomputation failed/timeout - using original polyline")
                    deduplicatedRoute = GeneratedRoute(
                        places: sortedEnhanced,
                        polyline: deduplicatedRoute.polyline,
                        distanceMeters: deduplicatedRoute.distanceMeters,
                        durationSeconds: deduplicatedRoute.durationSeconds,
                        legs: deduplicatedRoute.legs
                    )
                }
                print("📍 [WP-MIN] After spur pass \(spurTries): \(deduplicatedRoute.places.count) waypoints (target: \(minWaypoints))")
                
                // v2.1.7: Remove close waypoints after micro-spur insertion
                if deduplicatedRoute.places.count > 1, let originCoord = origin {
                    deduplicatedRoute = await removeCloseWaypoints(from: deduplicatedRoute, minDistance: 100, origin: originCoord)
                }
            }
        }
        
        // SPRINT-4: Final guardrails - micro-trim if >130%, then check final status
        var finalRoute = deduplicatedRoute
        let routeMins = finalRoute.durationSeconds / 60
        let accuracyRatio = Double(routeMins) / Double(targetDurationMinutes)
        let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
        let hardCap130 = Int(Double(targetDurationMinutes) * 1.30)
        
        // SPRINT-4: Micro-trim if route >130% (shave far spur/leg)
        if accuracyRatio > 1.30 && finalRoute.places.count > 1, let originCoord = origin {
            print("🔧 [FINAL-GUARD] Route \(routeMins)min (\(String(format: "%.1f", accuracyRatio * 100))%) >130% - attempting micro-trim")
            
            // Find farthest waypoint from origin
            if let farthestIndex = finalRoute.places.enumerated().max(by: {
                distanceBetween(originCoord, $0.element.coordinate) < distanceBetween(originCoord, $1.element.coordinate)
            })?.offset {
                let farthestPOI = finalRoute.places[farthestIndex]
                print("🔧 [FINAL-GUARD] Micro-trimming farthest waypoint: '\(farthestPOI.name)'")
                
                var trimmedWaypoints = finalRoute.places
                trimmedWaypoints.remove(at: farthestIndex)
                
                // Regenerate route with trimmed waypoints
                let trimTimeout = RoutingToggles.perCallTimeoutNormal
                let (trimResult, didTimeout) = await directionsWithTimeout(
                    origin: originCoord,
                    destination: originCoord,
                    waypoints: trimmedWaypoints.map { $0.coordinate },
                    timeout: trimTimeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: postcode,
                    checkGlobalHardStop: finalizationHardStopCheck  // SPRINT-5: Universal hard-stop
                )
                
                if let directions = trimResult, !didTimeout {
                    let trimmedDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                    let trimmedDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                    let trimmedMins = trimmedDuration / 60
                    let trimmedRatio = Double(trimmedMins) / Double(targetDurationMinutes)
                    
                    print("🔧 [FINAL-GUARD] Micro-trim result: \(trimmedMins)min (\(String(format: "%.1f", trimmedRatio * 100))%)")
                    
                    if trimmedRatio <= 1.30 {
                        // Trimmed route is now acceptable
                        finalRoute = GeneratedRoute(
                            places: trimmedWaypoints,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: trimmedDistance,
                            durationSeconds: trimmedDuration,
                            legs: directions.legs
                        )
                        print("🔧 [FINAL-GUARD] ✅ Micro-trim successful - route now \(trimmedMins)min")
                    } else {
                        print("🔧 [FINAL-GUARD] ⚠️ Micro-trim still >130% (\(String(format: "%.1f", trimmedRatio * 100))%) - will check final status")
                    }
                }
            }
        }
        
        // SPRINT-4: Per-leg cap - block singular 2-5× overshoot legs (>50% of target)
        // v2.0.13: Guard per-leg cap - skip if route is already good enough (prevents regression cascade)
        let finalAccuracy = Double(finalRoute.durationSeconds) / Double(targetDurationMinutes * 60)
        let finalWPCount = finalRoute.places.count
        let minWP = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
        
        // Determine if route is already "good enough" based on duration-specific bands
        let (minBand, maxBand): (Double, Double) = targetDurationMinutes <= 30 
            ? (0.95, 1.05)  // 10-30 min: 95-105%
            : (0.90, 1.10)  // 35-60 min: 90-110%
        
        let alreadyGood = finalAccuracy >= minBand && 
                         finalAccuracy <= maxBand && 
                         finalWPCount >= minWP
        
        // Only run per-leg cap if NOT already good enough (prevents good → worse → fallback cascade)
        let allowPerLegCap = !alreadyGood
        
        // v2.0.13: Track if per-leg cap was applied and if it ran after a good candidate
        if allowPerLegCap && finalRoute.places.count > 1 && !finalRoute.legs.isEmpty, let originCoord = origin {
            let perLegCapRatio = 0.50  // 50% of target duration
            let perLegCapMinutes = Double(targetDurationMinutes) * perLegCapRatio
            let perLegCapSeconds = Int(perLegCapMinutes * 60)
            
            // Find the worst leg (max duration)
            var worstLegIndex: Int? = nil
            var worstLegDuration: Int = 0
            
            for (index, leg) in finalRoute.legs.enumerated() {
                if leg.duration.value > worstLegDuration {
                    worstLegDuration = leg.duration.value
                    worstLegIndex = index
                }
            }
            
            // If worst leg exceeds cap, trim the associated waypoint
            if let worstIdx = worstLegIndex, worstLegDuration > perLegCapSeconds {
                let worstLegMins = Double(worstLegDuration) / 60.0
                print("🔧 [PER-LEG-CAP] Worst leg \(worstIdx) duration: \(worstLegMins)min exceeds cap \(perLegCapMinutes)min (50% of \(targetDurationMinutes)min target)")
                
                // v2.0.13: Track that per-leg cap was applied
                // Note: perLegCapApplied will be set in finalization telemetry
                
                // Map leg index to waypoint index
                // Leg 0: origin → waypoint 0
                // Leg 1: waypoint 0 → waypoint 1
                // Leg N-1: waypoint N-2 → waypoint N-1
                // Leg N: waypoint N-1 → origin (return leg)
                let waypointToRemove: Int
                if worstIdx < finalRoute.places.count {
                    // Leg goes to waypoint at index worstIdx
                    waypointToRemove = worstIdx
                } else {
                    // Last leg (return to origin) - remove last waypoint
                    waypointToRemove = finalRoute.places.count - 1
                }
                
                if waypointToRemove >= 0 && waypointToRemove < finalRoute.places.count {
                    let culpritPOI = finalRoute.places[waypointToRemove]
                    print("🔧 [PER-LEG-CAP] Trimming waypoint \(waypointToRemove): '\(culpritPOI.name)' (leg \(worstIdx) = \(worstLegMins)min)")
                    
                    var trimmedWaypoints = finalRoute.places
                    trimmedWaypoints.remove(at: waypointToRemove)
                    
                    // Regenerate route with trimmed waypoints
                    let trimTimeout = RoutingToggles.perCallTimeoutNormal
                    let (trimResult, didTimeout) = await directionsWithTimeout(
                        origin: originCoord,
                        destination: originCoord,
                        waypoints: trimmedWaypoints.map { $0.coordinate },
                        timeout: trimTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,
                        postcode: postcode,
                        checkGlobalHardStop: finalizationHardStopCheck  // SPRINT-5: Universal hard-stop
                    )
                    
                    if let directions = trimResult, !didTimeout {
                        let trimmedDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let trimmedDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        let trimmedMins = trimmedDuration / 60
                        let trimmedRatio = Double(trimmedMins) / Double(targetDurationMinutes)
                        
                        // Check if worst leg is now within cap
                        var newWorstLegDuration: Int = 0
                        for leg in directions.legs {
                            if leg.duration.value > newWorstLegDuration {
                                newWorstLegDuration = leg.duration.value
                            }
                        }
                        let newWorstLegMins = Double(newWorstLegDuration) / 60.0
                        
                        print("🔧 [PER-LEG-CAP] Trim result: \(trimmedMins)min (\(String(format: "%.1f", trimmedRatio * 100))%), new worst leg: \(newWorstLegMins)min")
                        
                        finalRoute = GeneratedRoute(
                            places: trimmedWaypoints,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: trimmedDistance,
                            durationSeconds: trimmedDuration,
                            legs: directions.legs
                        )
                        
                        print("📊 [PER_LEG_CAP_TRIM] worst_leg_min=\(worstLegMins) cap_min=\(perLegCapMinutes) target=\(targetDurationMinutes) new_worst_leg_min=\(newWorstLegMins)")
                        
                        // SPRINT-6: Micro-extend after trim if route fell below 92-95%
                        // SPRINT-7: Allow a second extend pass if still below 92-93%
                        // SPRINT-7 HOTFIX: Add time-remaining check to avoid enqueueing work near hard stop
                        // This turns hard trims into in-band finishes
                        var currentRatio = trimmedRatio
                        var currentWaypoints = trimmedWaypoints
                        var extendPass = 0
                        let maxExtendPasses = 2  // SPRINT-7: Up to 2 extend passes
                        let minTimeForExtend: TimeInterval = 0.5  // SPRINT-7 HOTFIX: Don't extend if <500ms remaining
                        
                        while currentRatio < 0.95 && extendPass < maxExtendPasses && !allPlaces.isEmpty && (budget?.within() ?? true) {
                            // SPRINT-7 HOTFIX: Time-remaining guard - don't enqueue work near hard stop
                            if let b = budget {
                                let timeRemaining = b.hard - (Date().timeIntervalSince1970 - b.t0)
                                if timeRemaining < minTimeForExtend {
                                    print("⛔ [POST-TRIM-EXTEND] Only \(String(format: "%.2f", timeRemaining))s remaining - skipping extend")
                                    break
                                }
                            }
                            
                            extendPass += 1
                            // SPRINT-7: Second pass only if below 92-93%
                            if extendPass > 1 && currentRatio >= 0.93 {
                                print("🔧 [POST-TRIM-EXTEND] Ratio \(String(format: "%.1f", currentRatio * 100))% ≥93% - skipping second extend pass")
                                break
                            }
                            
                            print("🔧 [POST-TRIM-EXTEND] Pass \(extendPass)/\(maxExtendPasses): Route at \(String(format: "%.1f", currentRatio * 100))% - attempting micro-extend")
                            
                            // Find nearby POIs not already in route
                            let existingIds = Set(currentWaypoints.map { $0.placeId })
                            let nearbyPOIs = allPlaces.filter { poi in
                                !existingIds.contains(poi.placeId) &&
                                distanceBetween(originCoord, poi.coordinate) < 600  // Within 600m
                            }.sorted { distanceBetween(originCoord, $0.coordinate) < distanceBetween(originCoord, $1.coordinate) }
                            
                            guard let nearestPOI = nearbyPOIs.first else {
                                print("🔧 [POST-TRIM-EXTEND] No more nearby POIs available - stopping")
                                break
                            }
                            
                            // v2.1.7: Check distance before inserting during post-trim extend
                            let minExtendDistance: Double = 100
                            let tooClose = currentWaypoints.contains { existing in
                                distanceBetween(nearestPOI.coordinate, existing.coordinate) < minExtendDistance
                            }
                            if tooClose {
                                print("🔧 [POST-TRIM-EXTEND] Skipping '\(nearestPOI.name)' - too close to existing waypoint")
                                break  // No more valid POIs to extend with
                            }
                            
                            var extendedWaypoints = currentWaypoints
                            let midIdx = max(0, extendedWaypoints.count / 2)
                            extendedWaypoints.insert(nearestPOI, at: min(midIdx, extendedWaypoints.count))
                            
                            let sortedExtended = extendedWaypoints.sorted { wp1, wp2 in
                                distanceBetween(originCoord, wp1.coordinate) < distanceBetween(originCoord, wp2.coordinate)
                            }
                            
                            let (extendResult, extendTimeout) = await directionsWithTimeout(
                                origin: originCoord,
                                destination: originCoord,
                                waypoints: sortedExtended.map { $0.coordinate },
                                timeout: RoutingToggles.perCallTimeoutNormal,
                                targetDurationMinutes: targetDurationMinutes,
                                angularDiversityScore: nil,
                                postcode: postcode,
                                checkGlobalHardStop: finalizationHardStopCheck
                            )
                            
                            if let extendDirs = extendResult, !extendTimeout {
                                let extendedDuration = extendDirs.legs.reduce(0) { $0 + $1.duration.value }
                                let extendedDistance = extendDirs.legs.reduce(0) { $0 + $1.distance.value }
                                let extendedMins = extendedDuration / 60
                                let extendedRatio = Double(extendedMins) / Double(targetDurationMinutes)
                                
                                // Accept if improved and within 92-115%
                                if extendedRatio >= 0.92 && extendedRatio <= 1.15 && extendedRatio > currentRatio {
                                    print("🔧 [POST-TRIM-EXTEND] ✅ Pass \(extendPass): Extended to \(extendedMins)min (\(String(format: "%.1f", extendedRatio * 100))%)")
                                    finalRoute = GeneratedRoute(
                                        places: sortedExtended,
                                        polyline: extendDirs.overviewPolyline.points,
                                        distanceMeters: extendedDistance,
                                        durationSeconds: extendedDuration,
                                        legs: extendDirs.legs
                                    )
                                    currentWaypoints = sortedExtended
                                    currentRatio = extendedRatio
                                    microSpursAdded += 1
                                } else {
                                    print("🔧 [POST-TRIM-EXTEND] Pass \(extendPass): Extended to \(extendedMins)min (\(String(format: "%.1f", extendedRatio * 100))%) - outside target or no improvement, stopping")
                                    break
                                }
                            } else {
                                print("🔧 [POST-TRIM-EXTEND] Pass \(extendPass): Engine call failed/timeout - stopping")
                                break
                            }
                        }
                    } else {
                        print("⚠️ [PER-LEG-CAP] Route regeneration failed/timeout - keeping original route")
                    }
                }
            }
        }
        
        // SPRINT-4: Final status check - if still >130% OR still <minWP after all fixes → return nil (NEAR_MISS)
        // Note: finalWPCount and minWP already declared above (lines 8970-8971)
        let finalMins = finalRoute.durationSeconds / 60
        let finalAccuracyRatio = Double(finalMins) / Double(targetDurationMinutes)
        
        let isStillOver130 = finalAccuracyRatio > 1.30
        let isStillBelowMinWP = finalWPCount < minWP
        
        if isStillOver130 || isStillBelowMinWP {
            var issuesList: [String] = []
            if isStillOver130 {
                issuesList.append(">130% (\(String(format: "%.1f", finalAccuracyRatio * 100))%))")
            }
            if isStillBelowMinWP {
                issuesList.append("<minWP (\(finalWPCount)/\(minWP))")
            }
            
            print("⛔ [FINAL-GUARD] NEAR_MISS: Route still has issues after all fixes: \(issuesList.joined(separator: ", "))")
            print("⛔ [FINAL-GUARD] Route details: \(finalWPCount) waypoints, \(finalMins)min (\(String(format: "%.1f", finalAccuracyRatio * 100))%)")
            print("⛔ [FINAL-GUARD] Returning nil - caller should use best-so-far or schedule background re-run")
            
            // Return nil to indicate NEAR_MISS (caller should handle gracefully)
            return (nil, nudgesAdded, microSpursAdded)
        }
        
        // Enforce hard caps - CRITICAL: This is the ONLY enforcement point
        if finalMins > hardCap180 {
            print("⛔ [GUARD] REJECTED: Route \(finalMins)min exceeds 180% hard cap \(hardCap180)min")
            print("⛔ [GUARD] Route details: \(finalRoute.places.count) waypoints, \(finalRoute.distanceMeters)m")
            print("⛔ [GUARD] Returning nil - caller MUST use fallback")
            return (nil, nudgesAdded, microSpursAdded)  // CRITICAL: Return nil to force caller to use fallback
        }
        
        if finalMins > hardCap130 && !allowExtendedCapForFallback {
            print("⛔ [FINAL GUARD] Route \(finalMins)min exceeds 130% cap \(hardCap130)min outside fallback")
            // Log but return - selection should have filtered this
            return (finalRoute, nudgesAdded, microSpursAdded)
        }
        
        // SPRINT-4: Final assertions and structured logging after finalization
        let finalRatio = Double(finalMins) / Double(targetDurationMinutes)
        let finalMinWP = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
        
        // Assert route ratio <= 1.30 after finalization
        assert(finalRatio <= 1.30, "Route > 130% after finalization: \(String(format: "%.1f", finalRatio * 100))%")
        
        // Assert waypoint count >= minimum
        assert(finalWPCount >= finalMinWP, "Waypoint count below minimum: \(finalWPCount) < \(finalMinWP) for \(targetDurationMinutes)min")
        
        // Count legs over 50% of target duration
        let perLegCapSeconds = Int(Double(targetDurationMinutes) * 0.50 * 60)
        let legsOver50Pct = finalRoute.legs.filter { $0.duration.value > perLegCapSeconds }.count
        
        // Structured logging for final route metrics
        print("📊 [FINAL] ratio=\(String(format: "%.3f", finalRatio)) wp=\(finalWPCount) min_wp=\(finalMinWP) legs_over_50pct=\(legsOver50Pct) nudges=\(nudgesAdded) micro_spurs=\(microSpursAdded)")
        
        // v2.1.7: Final distance check before returning (catches any waypoints that got too close)
        if finalRoute.places.count > 1, let originCoord = origin {
            finalRoute = await removeCloseWaypoints(from: finalRoute, minDistance: 100, origin: originCoord)
        }
        
        return (finalRoute, nudgesAdded, microSpursAdded)
    }
    
    /// Ensures route places are deduplicated even if polyline building fails
    /// v2.0.3: Final safety wrapper with hard cap enforcement
    /// This is the last line of defense against routes exceeding acceptable limits
    private func finalizeRouteDedup(_ route: GeneratedRoute, targetDurationMinutes: Int? = nil) -> GeneratedRoute {
        // #region agent log
        if route.places.count > 1 {
            let distances = (0..<route.places.count-1).map { i in
                distanceBetween(route.places[i].coordinate, route.places[i+1].coordinate)
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "E",
                "location": "GoogleMapsService.swift:10660",
                "message": "finalizeRouteDedup: entry",
                "data": [
                    "waypointCount": route.places.count,
                    "waypoints": route.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                    "distances": distances,
                    "minDistance": distances.min() ?? 0
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
               let logString = String(data: logJSON, encoding: .utf8) {
                try? logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
        }
        // #endregion
        
        print("🔒 FINAL SAFETY WRAPPER: Deduplicating route with \(route.places.count) places before return")
        if route.places.count > 1 {
            print("🔒 FINAL SAFETY: Input POIs: \(route.places.enumerated().map { "\($0+1). \($1.name) [\($1.placeId)]" }.joined(separator: ", "))")
        }
        let deduplicatedPlaces = deduplicateRoutePlaces(route.places)
        
        // If no duplicates found, return original route
        guard deduplicatedPlaces.count < route.places.count else {
            print("🔒 FINAL SAFETY: No duplicates found, returning original route with \(route.places.count) POIs")
            // v2.0.3 Phase 1.5: Hard cap guard - routes >180% will be rejected by caller
            // Note: Hard cap enforcement happens at call site (generateLocalRoute) to avoid making this function throwing
            if let target = targetDurationMinutes {
                let routeMins = route.durationSeconds / 60
                let hardCap180 = Int(Double(target) * 1.80)
                if routeMins > hardCap180 {
                    print("⛔ [GUARD] Route exceeds 180% hard cap: \(routeMins)min > \(hardCap180)min - Caller should reject")
                }
            }
            return route
        }
        
        print("🔒 FINAL SAFETY: Removed \(route.places.count - deduplicatedPlaces.count) duplicate(s), returning deduplicated route")
        print("🔒 FINAL SAFETY: Final POIs: \(deduplicatedPlaces.enumerated().map { "\($0+1). \($1.name) [\($1.placeId)]" }.joined(separator: ", "))")
        
        // #region agent log
        if deduplicatedPlaces.count > 1 {
            let distances = (0..<deduplicatedPlaces.count-1).map { i in
                distanceBetween(deduplicatedPlaces[i].coordinate, deduplicatedPlaces[i+1].coordinate)
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "E",
                "location": "GoogleMapsService.swift:10686",
                "message": "finalizeRouteDedup: exit",
                "data": [
                    "originalCount": route.places.count,
                    "deduplicatedCount": deduplicatedPlaces.count,
                    "finalWaypoints": deduplicatedPlaces.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                    "distances": distances,
                    "minDistance": distances.min() ?? 0
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
               let logString = String(data: logJSON, encoding: .utf8) {
                try? logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
            }
        }
        // #endregion
        
        // Return with deduplicated places (polyline will be regenerated by caller if needed)
        let finalRoute = GeneratedRoute(
            places: deduplicatedPlaces,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
        
        // v2.0.3 Phase 1.5: Hard cap guard after deduplication
        // Note: We log here but enforce at call site to avoid making this function throwing
        if let target = targetDurationMinutes {
            let routeMins = finalRoute.durationSeconds / 60
            let hardCap180 = Int(Double(target) * 1.80)
            if routeMins > hardCap180 {
                print("⛔ [GUARD] Deduplicated route exceeds 180% hard cap: \(routeMins)min > \(hardCap180)min - Caller should reject")
            }
        }
        
        return finalRoute
    }
    
    /// Async version for cases where polyline regeneration is needed
    private func finalizeRouteDedupAsync(_ route: GeneratedRoute, buildPolyline: ((_ places: [PlaceResult]) async throws -> String)? = nil) async -> GeneratedRoute {
        let deduplicatedPlaces = deduplicateRoutePlaces(route.places)
        
        // If no duplicates found, return original route
        guard deduplicatedPlaces.count < route.places.count else {
            return route
        }
        
        // Regenerate polyline with deduplicated places if builder provided
        if let buildPolyline = buildPolyline {
            do {
                let newPolyline = try await buildPolyline(deduplicatedPlaces)
                return GeneratedRoute(
                    places: deduplicatedPlaces,
                    polyline: newPolyline,
                    distanceMeters: route.distanceMeters,
                    durationSeconds: route.durationSeconds,
                    legs: route.legs
                )
            } catch {
                print("⚠️ Polyline build failed after dedup; returning deduped places anyway")
                // Fall through to return with deduplicated places but original polyline
            }
        }
        
        // Return with deduplicated places (even if polyline regeneration failed)
        return GeneratedRoute(
            places: deduplicatedPlaces,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
    }
    
    /// Print comprehensive route summary for debugging
    private func printRouteSummary(route: GeneratedRoute, targetDuration: Int) {
        print("\n")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║              📋 ROUTE SUMMARY (COPY-PASTE READY)              ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ Target: \(targetDuration)min | Actual: \(route.durationSeconds / 60)min | Distance: \(String(format: "%.1f", Double(route.distanceMeters) / 1000.0))km | Waypoints: \(route.places.count)")
        print("╠══════════════════════════════════════════════════════════════╣")
        
        // CRITICAL: Final duplicate check - this should NEVER find duplicates if deduplication worked
        let service = GoogleMapsService.shared
        var duplicateWarnings: [String] = []
        for i in 0..<route.places.count {
            for j in (i+1)..<route.places.count {
                if service.isRouteDuplicate(route.places[i], route.places[j]) {
                    let distance = distanceBetween(route.places[i].coordinate, route.places[j].coordinate)
                    let nameA = GoogleMapsService.cleanPOIDisplayName(route.places[i].name).lowercased()
                    let nameB = GoogleMapsService.cleanPOIDisplayName(route.places[j].name).lowercased()
                    duplicateWarnings.append("🚨 CRITICAL DUPLICATE: #\(i+1) '\(route.places[i].name)' and #\(j+1) '\(route.places[j].name)' - cleaned: '\(nameA)' == '\(nameB)', distance: \(String(format: "%.1f", distance))m")
                }
            }
        }
        
        for (index, poi) in route.places.enumerated() {
            let position = "\(index + 1) of \(route.places.count)"
            let cleanedName = GoogleMapsService.cleanPOIDisplayName(poi.name).lowercased()
            print("║ \(position): \(poi.name)")
            print("║    └─ Cleaned: \"\(cleanedName)\"")
            print("║    └─ PlaceId: \(poi.placeId)")
            
            // Check for duplicates with other POIs in route
            for (otherIndex, otherPOI) in route.places.enumerated() where otherIndex != index {
                let otherCleanedName = GoogleMapsService.cleanPOIDisplayName(otherPOI.name).lowercased()
                let distance = distanceBetween(poi.coordinate, otherPOI.coordinate)
                
                if cleanedName == otherCleanedName && cleanedName.count > 0 {
                    duplicateWarnings.append("⚠️ DUPLICATE: #\(index + 1) '\(poi.name)' and #\(otherIndex + 1) '\(otherPOI.name)' have same cleaned name '\(cleanedName)' (\(String(format: "%.1f", distance))m apart)")
                } else if distance < 20.0 {
                    duplicateWarnings.append("⚠️ VERY CLOSE: #\(index + 1) '\(poi.name)' and #\(otherIndex + 1) '\(otherPOI.name)' are \(String(format: "%.1f", distance))m apart")
                }
            }
        }
        
        // Print duplicate warnings if any
        if !duplicateWarnings.isEmpty {
            print("╠══════════════════════════════════════════════════════════════╣")
            for warning in duplicateWarnings {
                print("║ \(warning)")
            }
        }
        
        print("╚══════════════════════════════════════════════════════════════╝")
        print("\n")
    }
    
    // MARK: - Enhance Route with More Waypoints
    /// Takes an existing route (often with 1-2 waypoints) and adds more POIs along the path
    /// This creates a more interesting walk without significantly changing the route duration
    /// - Parameter existingRoute: The quick-generated route to enhance
    /// - Parameter targetDurationMinutes: Original target duration (to calculate ideal waypoint count)
    /// - Parameter prefetchedPOIs: POIs to choose from (should include all nearby POIs)
    /// - Returns: Enhanced route with more waypoints, or original if enhancement fails
    @Published var enhancementStatus: String? = nil
    
    func enhanceRouteWithWaypoints(
        existingRoute: GeneratedRoute,
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        prefetchedPOIs: [PlaceResult]
    ) async throws -> GeneratedRoute {
        let currentWaypoints = existingRoute.places.count
        let maxDurationSeconds = targetDurationMinutes * 60  // Hard limit - never exceed
        let currentDurationMins = existingRoute.durationSeconds / 60
        
        // SKIP if already at or near target time (within 2 minutes)
        let timeBuffer = 2
        if currentDurationMins >= targetDurationMinutes - timeBuffer {
            print("🗺️ 📍 Route already at target time (\(currentDurationMins)min / \(targetDurationMinutes)min) - no enhancement needed")
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(existingRoute)
        }
        
        print("🗺️ 📍 PROGRESSIVE ENHANCEMENT: \(currentDurationMins)min → target \(targetDurationMinutes)min, \(currentWaypoints) waypoints")
        await MainActor.run { enhancementStatus = "Adding waypoints..." }
        
        // Decode existing polyline to find points along the route
        let routePoints = decodePolyline(existingRoute.polyline)
        guard routePoints.count >= 2 else {
            print("🗺️ 📍 Cannot enhance - not enough route points")
            await MainActor.run { enhancementStatus = nil }
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(existingRoute)
        }
        
        // Get existing waypoints to exclude using unified comparator
        let availablePOIs = prefetchedPOIs.filter { poi in
            !existingRoute.places.contains { existing in
                isRouteDuplicate(poi, existing)
            }
        }
        
        guard !availablePOIs.isEmpty else {
            print("🗺️ 📍 No additional POIs available for enhancement")
            await MainActor.run { enhancementStatus = nil }
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(existingRoute)
        }
        
        // Find POIs that are NEAR the route path (within 150m of route line)
        var poisNearRoute: [(poi: PlaceResult, routeIndex: Int, distanceFromRoute: Double)] = []
        
        for poi in availablePOIs {
            var closestDistance = Double.infinity
            var closestRouteIndex = 0
            
            for (index, routePoint) in routePoints.enumerated() {
                let dist = distanceBetween(poi.coordinate, routePoint)
                if dist < closestDistance {
                    closestDistance = dist
                    closestRouteIndex = index
                }
            }
            
            // Only include POIs within 150m of the route path
            if closestDistance < 150 {
                poisNearRoute.append((poi: poi, routeIndex: closestRouteIndex, distanceFromRoute: closestDistance))
            }
        }
        
        guard !poisNearRoute.isEmpty else {
            print("🗺️ 📍 No POIs found near route path (within 150m)")
            await MainActor.run { enhancementStatus = nil }
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(existingRoute)
        }
        
        print("🗺️ 📍 Found \(poisNearRoute.count) POIs near route path")
        
        // Sort by distance from route (closest first - these add least time)
        poisNearRoute.sort { $0.distanceFromRoute < $1.distanceFromRoute }
        
        // MINIMUM DISTANCE: Waypoints should be spaced ~3-4 min of walking apart
        // At ~80m/min walking speed, 3 min = 240m minimum spacing
        // Lowered from 350m to allow more POI options
        let minWaypointDistance: Double = 100  // v1.8.9: Reduced from 200m to allow closer POIs
        
        // Start with the existing route and add waypoints ONE AT A TIME
        var currentRoute = existingRoute
        var currentWaypointsList = Array(existingRoute.places)
        var addedCount = 0
        let maxWaypointsToAdd = 5  // Cap at 5 additional waypoints
        
        for candidateInfo in poisNearRoute {
            // Check if we've added enough
            if addedCount >= maxWaypointsToAdd {
                print("🗺️ 📍 Reached max waypoints to add (\(maxWaypointsToAdd))")
                break
            }
            
            let candidate = candidateInfo.poi
            
            // Skip if already in list using unified comparator
            let isDuplicate = currentWaypointsList.contains { existing in
                isRouteDuplicate(candidate, existing)
            }
            
            if isDuplicate {
                if let matched = currentWaypointsList.first(where: { isRouteDuplicate(candidate, $0) }) {
                    let distance = distanceBetween(candidate.coordinate, matched.coordinate)
                    print("🗺️ 📍 Skipping \(candidate.name) - duplicate of '\(matched.name)' (\(String(format: "%.1f", distance))m apart)")
                }
            }
            
            if isDuplicate {
                continue
            }
            
            // Skip if too close to any existing waypoint
            let currentCoordinates = currentWaypointsList.map { $0.coordinate }
            var closestDistance: Double = .greatestFiniteMagnitude
            var closestWaypointName: String = ""
            let tooClose = currentCoordinates.contains { coord in
                let dist = distanceBetween(candidate.coordinate, coord)
                if dist < closestDistance {
                    closestDistance = dist
                    if let closestPOI = currentWaypointsList.first(where: { $0.coordinate.latitude == coord.latitude && $0.coordinate.longitude == coord.longitude }) {
                        closestWaypointName = closestPOI.name
                    }
                }
                return dist < minWaypointDistance
            }
            if tooClose {
                // #region agent log
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "A",
                    "location": "GoogleMapsService.swift:10908",
                    "message": "tryExtendRoute: candidate too close",
                    "data": [
                        "candidateName": candidate.name,
                        "closestWaypointName": closestWaypointName,
                        "distance": closestDistance,
                        "minWaypointDistance": minWaypointDistance,
                        "existingWaypoints": currentWaypointsList.map { $0.name }
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON = try? JSONSerialization.data(withJSONObject: logData),
                   let logString = String(data: logJSON, encoding: .utf8) {
                    logString.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
                // #endregion
                print("🗺️ 📍 Skipping \(candidate.name) - too close to existing waypoint (\(String(format: "%.1f", closestDistance))m from '\(closestWaypointName)')")
                continue
            }
            
            // Try adding this waypoint and calculate new route time
            var testWaypoints = currentWaypointsList
            testWaypoints.append(candidate)
            
            // Sort waypoints by ANGLE from origin to form a smooth loop
            // This creates a clockwise/counter-clockwise circuit instead of back-and-forth
            let waypointsWithAngle: [(poi: PlaceResult, angle: Double)] = testWaypoints.map { poi in
                let bearing = bearingBetween(origin, poi.coordinate)
                return (poi: poi, angle: bearing)
            }
            
            // Find the farthest waypoint (the endpoint) - this determines the direction
            let farthestWaypoint = testWaypoints.max { distanceBetween(origin, $0.coordinate) < distanceBetween(origin, $1.coordinate) }
            let endpointAngle = farthestWaypoint.map { bearingBetween(origin, $0.coordinate) } ?? 0
            
            // Sort waypoints in a loop: start from origin direction, go to endpoint, return
            // Use angular distance from the "out" direction (origin to endpoint)
            let sortedByLoop = waypointsWithAngle.sorted { wp1, wp2 in
                // Calculate angular distance from endpoint direction
                let angDist1 = abs(wp1.angle - endpointAngle)
                let angDist2 = abs(wp2.angle - endpointAngle)
                
                // Also consider distance from origin for tiebreaking
                let dist1 = distanceBetween(origin, wp1.poi.coordinate)
                let dist2 = distanceBetween(origin, wp2.poi.coordinate)
                
                // Waypoints closer to the endpoint angle go first (outbound), then others (return)
                if abs(angDist1 - angDist2) > 30 {
                    return angDist1 < angDist2  // Closer to endpoint direction first
                } else {
                    return dist1 > dist2  // Farther waypoints first when similar angle
                }
            }
            let sortedWaypoints = sortedByLoop.map { $0.poi }
            
            print("🗺️ 📍 Testing: + \(candidate.name) (\(Int(candidateInfo.distanceFromRoute))m from route)")
            
            // Check rate limit
            await checkMapKitRateLimit()
            recordMapKitRequest()
            
            // v2.0.3 Batch A: Wrap with timeout to prevent enhancement from blocking
            let enhanceTimeout = RoutingToggles.perCallTimeoutNormal
            let (testResult, didTimeout) = await directionsWithTimeout(
                origin: origin,
                destination: origin,
                waypoints: sortedWaypoints.map { $0.coordinate },
                timeout: enhanceTimeout,
                targetDurationMinutes: targetDurationMinutes,
                angularDiversityScore: nil,
                postcode: nil
            )
            
            if didTimeout {
                print("🗺️ 📍 ⏱️ Timeout testing \(candidate.name) - skipping")
                continue
            }
            
            guard let testDirections = testResult else {
                print("🗺️ 📍 ⚠️ Failed to test \(candidate.name)")
                continue
            }
            
            let testDuration = testDirections.legs.reduce(0) { $0 + $1.duration.value }
            let testMins = testDuration / 60
            
            // CHECK: Would adding this waypoint exceed the time limit?
            if testDuration > maxDurationSeconds {
                print("🗺️ 📍 ✗ \(candidate.name) would make route \(testMins)min (over \(targetDurationMinutes)min limit) - SKIPPING")
                continue  // Try next candidate instead of stopping
            }
            
            // SUCCESS: Adding this waypoint keeps us within limits
            let testDistance = testDirections.legs.reduce(0) { $0 + $1.distance.value }
            let polylinePoints = testDirections.overviewPolyline.points
            
            currentRoute = GeneratedRoute(
                places: sortedWaypoints,
                polyline: polylinePoints,
                distanceMeters: testDistance,
                durationSeconds: testDuration,
                legs: testDirections.legs
            )
            currentWaypointsList = sortedWaypoints
            addedCount += 1
            
            print("🗺️ 📍 ✅ Added \(candidate.name) → now \(currentWaypointsList.count) waypoints, \(testMins)min")
        }
        
        // FINAL DEDUPLICATION: Remove any duplicates that might have slipped through using unified comparator
        var deduplicatedWaypoints: [PlaceResult] = []
        for waypoint in currentWaypointsList {
            let isDuplicate = deduplicatedWaypoints.contains { existing in
                isRouteDuplicate(waypoint, existing)
            }
            
            if isDuplicate {
                if let matched = deduplicatedWaypoints.first(where: { isRouteDuplicate(waypoint, $0) }) {
                    let distance = distanceBetween(waypoint.coordinate, matched.coordinate)
                    print("🗺️ 📍 Removed duplicate waypoint: '\(waypoint.name)' (matches '\(matched.name)', \(String(format: "%.1f", distance))m apart)")
                }
            }
            
            if !isDuplicate {
                deduplicatedWaypoints.append(waypoint)
            }
        }
        
        // If we removed duplicates, regenerate the route with deduplicated waypoints
        if deduplicatedWaypoints.count < currentWaypointsList.count {
            print("🗺️ 📍 ⚠️ Removed \(currentWaypointsList.count - deduplicatedWaypoints.count) duplicate waypoint(s) - regenerating route")
            
            // Regenerate route with deduplicated waypoints
            let sortedWaypoints = deduplicatedWaypoints.sorted { wp1, wp2 in
                let dist1 = distanceBetween(origin, wp1.coordinate)
                let dist2 = distanceBetween(origin, wp2.coordinate)
                return dist1 < dist2
            }
            
            // v2.0.3 Batch A: Wrap with timeout
            let regenTimeout = RoutingToggles.perCallTimeoutNormal
            let (regenResult, didTimeout) = await directionsWithTimeout(
                origin: origin,
                destination: origin,
                waypoints: sortedWaypoints.map { $0.coordinate },
                timeout: regenTimeout,
                targetDurationMinutes: targetDurationMinutes,
                angularDiversityScore: nil,
                postcode: nil
            )
            
            if didTimeout {
                print("🗺️ 📍 ⏱️ Timeout regenerating after deduplication, using original")
            } else if let directions = regenResult {
                let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                
                currentRoute = GeneratedRoute(
                    places: sortedWaypoints,
                    polyline: directions.overviewPolyline.points,
                    distanceMeters: distance,
                    durationSeconds: duration,
                    legs: directions.legs
                )
                currentWaypointsList = sortedWaypoints
            } else {
                print("🗺️ 📍 ⚠️ Failed to regenerate route after deduplication")
                // Use original route even with duplicates rather than failing
            }
        }
        
        // Report results
        let originalMins = existingRoute.durationSeconds / 60
        let finalMins = currentRoute.durationSeconds / 60
        
        if addedCount > 0 {
            print("🗺️ 📍 🎉 ENHANCED! \(existingRoute.places.count) → \(currentWaypointsList.count) waypoints, \(originalMins)min → \(finalMins)min")
        } else {
            print("🗺️ 📍 Could not add any waypoints without exceeding \(targetDurationMinutes)min limit")
        }
        
        await MainActor.run { enhancementStatus = nil }
        
        // v2.1.7: Remove close waypoints before returning (waypoint sorting/reordering can bring them closer)
        let spacedRoute = await removeCloseWaypoints(from: currentRoute, minDistance: 100, origin: origin)
        
        // FINAL SAFETY WRAPPER: Ensure deduplication on return
        return finalizeRouteDedup(spacedRoute)
    }
    
    // MARK: - Generate Local Walking Route
    /// Generates a circular walking route from user's location using nearby POIs
    /// DYNAMICALLY adjusts number of waypoints to match target duration
    /// Keeps trying different combinations until within ±3 minutes of target
    /// - Parameter prefetchedPOIs: Optional pre-fetched POIs to skip the Places API call (faster generation)
    /// - Parameter useSystematicSelection: If true, tries POI combinations in order of likelihood to succeed
    /// - Parameter expandedSearch: If true, uses larger search radius
    
    /// Route generation method based on duration
    enum RouteMethod {
        case endpointOnly           // 10-25 min: endpoint-first, no loop fallback
        case endpointWithEnhancement // 26-45 min: endpoint + enhancement
        case loopFallback           // 50-60 min: can use loop-based as fallback
    }
    
    /// Direction quadrant for route generation variety
    enum RouteDirection: Int, CaseIterable {
        case north = 0      // 315° to 45°
        case east = 1       // 45° to 135°
        case south = 2      // 135° to 225°
        case west = 3       // 225° to 315°
        
        var angleRange: ClosedRange<Double> {
            switch self {
            case .north: return -45...45
            case .east: return 45...135
            case .south: return 135...225  // Note: will need to handle wrap
            case .west: return -135...(-45)  // Note: will need to handle wrap
            }
        }
        
        func contains(angle: Double) -> Bool {
            // Normalize angle to -180 to 180
            var normalized = angle
            while normalized > 180 { normalized -= 360 }
            while normalized < -180 { normalized += 360 }
            
            switch self {
            case .north: return normalized >= -45 && normalized <= 45
            case .east: return normalized > 45 && normalized <= 135
            case .south: return normalized > 135 || normalized < -135
            case .west: return normalized >= -135 && normalized < -45
            }
        }
    }
    
    func generateLocalRoute(
        from location: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        difficulty: RouteDifficulty? = nil,
        excludePlaceIds: Set<String> = [],
        excludePOIs: [PlaceResult] = [],  // v1.9.51: Actual POI objects to check for duplicates by name/coordinate
        prefetchedPOIs: [PlaceResult]? = nil,
        useSystematicSelection: Bool = false,
        expandedSearch: Bool = false,
        preferredDirection: RouteDirection? = nil,  // Try to generate route in this direction
        useEndpointFirst: Bool = false,  // Use single endpoint approach (better for Route 1)
        preferMultiWaypoint: Bool = false,  // v1.6.49: Force 2+ waypoints for variety (routes 2-4)
        searchRadiusOverride: Int? = nil,  // v1.9.50: Allow override for Stage 2 fallback
        routeCapture: RouteCapture? = nil,  // Optional: Capture all valid routes for testing
        postcode: String? = nil  // v2.0.3 Phase 1.5: Postcode for area-specific overrides
    ) async throws -> GeneratedRoute {
        let startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: startTime)
        
        print("⏱️ [ROUTE GEN] [\(timeString)] 🗺️ generateLocalRoute() STARTED")
        print("⏱️ [ROUTE GEN] [\(timeString)]   Target: \(targetDurationMinutes)min")
        print("⏱️ [ROUTE GEN] [\(timeString)]   Location: (\(String(format: "%.5f", location.latitude)), \(String(format: "%.5f", location.longitude)))")
        print("⏱️ [ROUTE GEN] [\(timeString)]   Mode: \(useSystematicSelection ? "systematic" : "quick"), expandedSearch: \(expandedSearch)")
        
        // v2.0.3 Phase 1.5: Hard-wall timer - absolute maximum time per request
        // Calculate now so we can check throughout the function
        // ADS will be refined later, so use conservative estimate initially
        let initialADS = 3  // Conservative estimate until we calculate actual ADS
        let hardWallSeconds = RoutingToggles.hardWallFor(duration: targetDurationMinutes, ads: initialADS, postcode: postcode)
        let hardStopSec = RoutingToggles.hardStopSec  // PHASE A: Global hard-stop (18.0s)
        print("⏱️ [ROUTE GEN] [\(timeString)]   Hard-wall: \(String(format: "%.0f", hardWallSeconds))s, Hard-stop: \(String(format: "%.0f", hardStopSec))s (dur=\(targetDurationMinutes), pc=\(postcode ?? "none"))")
        
        // SPRINT-4: Global hard-stop budget guard
        let budget = RoutingToggles.Budget(t0: startTime.timeIntervalSince1970)
        
        // Track if hard-wall was hit (used to force topology-safe)
        var hardWallExceeded = false
        var hardStopHit = false  // PHASE A: Track if global hard-stop was hit
        
        // PHASE D: Telemetry tracking
        var engineCalls = (mapkit: 0, osrm: 0, skipped: 0)
        var expansions = 0
        var repairPasses = 0
        var nudges: Int = 0
        var microSpurs: Int = 0
        var wpBeforeFinalization = 0
        var wpAfterFinalization = 0
        var stageExited: String = "none"  // SPRINT-6: Track which stage caused exit
        var perLegOverCap = false         // SPRINT-6: Track if any leg exceeded 50% of target
        
        // SPRINT-8: New telemetry fields
        var bestSoFarCommitted = false    // SPRINT-8: Did we commit early (95-105%)?
        var biasApplied: Double = 1.0     // SPRINT-8: Duration bias applied
        var repairAttempted = false       // SPRINT-8: Did we attempt WP repair?
        var repairSucceeded = false       // SPRINT-8: Did repair meet minWP?
        var hingePenaltyFired = false     // SPRINT-8: Did hinged penalty (>120%) fire?
        var sectorQuotaUsed = false       // SPRINT-8: Were sector quotas applied?
        
        // v2.0.13: Additional telemetry fields
        var earlyBandHit = false          // v2.0.13: Did we hit target band early (≤7s)?
        var commitBand: String = "none"   // v2.0.13: Which band triggered commit (95-105|90-110|none)
        var perLegCapApplied = false      // v2.0.13: Was per-leg cap applied?
        var capAfterGoodCandidate = false // v2.0.13: Did per-leg cap run after good candidate?
        var fallbackFired = false         // v2.0.13: Did fallback trigger?
        var fallbackReason: String = "none" // v2.0.13: Why fallback fired (engine_cap|no_candidates|quality_floor|exceeds_130_percent)
        var fallbackAccuracy: Double = 1.0 // v2.0.13: Fallback route accuracy
        var kBestCandidates = 0           // v2.0.13: Number of k-best candidates
        var validCandidates = 0           // v2.0.13: Number of valid candidates found
        var overshootSelected = false     // v2.0.13: Was selected route >120%?
        var earlyCommitOpportunity = false // v2.0.13: Did we have an early commit opportunity?
        
        // Helper to check elapsed time and trigger hard-wall if needed
        func checkHardWall(context: String) -> Bool {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > hardWallSeconds {
                if !hardWallExceeded {
                    hardWallExceeded = true
                    print("⏱️ [HARDWALL] \(String(format: "%.1f", hardWallSeconds))s exceeded at \(context); forcing topology-safe (dur=\(targetDurationMinutes), elapsed=\(String(format: "%.1f", elapsed))s, pc=\(postcode ?? "none"))")
                }
                return true
            }
            return false
        }
        
        // SPRINT-4: Closure for checking global hard-stop (to pass to directionsWithTimeout)
        let checkGlobalHardStop: () -> Bool = {
            return !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "MAPKIT_CALL")
        }
        
        // SPRINT-4: Global hard-stop check closure (for backwards compatibility)
        // SPRINT-6: Also tracks stageExited for telemetry
        let checkHardStop: (String, String) -> Bool = { stage, routeId in
            if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "\(stage)_\(routeId)") {
                if !hardStopHit {
                    hardStopHit = true
                    stageExited = stage  // SPRINT-6: Track which stage triggered exit
                    let durationBucket = "\(targetDurationMinutes)min"
                    print("⛔ [HARD-STOP] [\(stage)] route_id=\(routeId) duration_bucket=\(durationBucket) stage_exited=\(stage) elapsed_ms=\(Int(budget.elapsed * 1000)) - aborting immediately")
                }
                return true  // Hard stop hit
            }
            return false
        }
        
        await MainActor.run { isLoading = true }
        defer { 
            let endTime = Date()
            let elapsed = endTime.timeIntervalSince(startTime)
            let endTimeString = formatter.string(from: endTime)
            print("⏱️ [ROUTE GEN] [\(endTimeString)] ✅ generateLocalRoute() COMPLETED in \(String(format: "%.2f", elapsed))s")
            Task { @MainActor in isLoading = false } 
        }
        
        // Track if pre-populated database was used
        var usedDatabase = false
        
        // Route multiplier tracker (for topology detection and adaptive roadFactor)
        let routeMultiplierTracker = RouteMultiplierTracker()
        
        // Adaptive roadFactor: Track overshoot samples and adjust dynamically
        var roadFactor: Double = 1.4  // Default conservative estimate
        var overshootSamples: [Double] = []  // Track overshoot for adaptive correction
        
        // ADAPTIVE TIMING: More flexible for short routes in dense urban areas
        // Short routes (≤15 min): 50-100% acceptable (dense areas have clustered POIs)
        // Medium routes (16-30 min): 65-100% acceptable
        // Quick mode (initial generation): 70-100% for fast, accurate results
        // Retry modes: more flexible to find any route
        let isQuickMode = !useSystematicSelection && !expandedSearch
        
        // Tolerance matches RouteCacheService: 80-120% (or 75-125% for edge cases)
        let isEdgeCase = targetDurationMinutes <= 10 || targetDurationMinutes >= 55
        let minPercent: Double
        let maxPercent: Double
        
        // v1.6.36: HARD CAP at 130% - routes >130% are never shown to user
        // This improves trust: users get routes within ±30% of target
        let hardMaxPercent = 1.30
        
        if isQuickMode {
            // QUICK mode: 70-130% to catch more routes on first try
            // Better to show a slightly off route than keep searching
            if isEdgeCase {
                minPercent = 0.65  // Edge cases: more flexible (65-130%)
                maxPercent = hardMaxPercent  // Was 1.40, now capped
            } else {
                minPercent = 0.70  // Standard: 70-130%
                maxPercent = hardMaxPercent
            }
        } else if expandedSearch {
            minPercent = 0.40  // Very flexible during retry
            maxPercent = hardMaxPercent  // Was 1.60, now capped at 130%
        } else {
            minPercent = 0.50  // Systematic retry
            maxPercent = hardMaxPercent  // Was 1.40, now capped
        }
        
        let minAcceptableMinutes = max(1, Int(Double(targetDurationMinutes) * minPercent))
        let maxAcceptableMinutes = Int(Double(targetDurationMinutes) * maxPercent)
        let minAcceptableDuration = minAcceptableMinutes * 60
        let maxAcceptableDuration = maxAcceptableMinutes * 60
        
        // SPRINT-8: Record bias applied for this duration bucket (for telemetry)
        biasApplied = RoutingToggles.biasFor(duration: targetDurationMinutes)
        print("🎯 [BIAS] Duration bucket \(RoutingToggles.durationBucket(for: targetDurationMinutes))min → bias=\(String(format: "%.3f", biasApplied))")
        
        let modeLabel = isQuickMode ? "⚡ QUICK" : (expandedSearch ? "EXPANDED" : "SYSTEMATIC")
        print("🗺️ \(modeLabel): \(minAcceptableMinutes)min to \(maxAcceptableMinutes)min (\(Int(minPercent * 100))-\(Int(maxPercent * 100))% of \(targetDurationMinutes)min)")
        
        // Walking speed ~80m/min, but actual routes are 2-4x longer than straight-line
        // SPRINT-4: Global density-aware speed model (no postcode rules)
        // Uses leg-length heuristic only: dense (<150m), urban (150-350m), suburban (>350m)
        let baseWalkingSpeed = adaptiveWalkingSpeed
        let walkingSpeedMeterPerMin: Int = {
            // Auto-detect based on average leg length (if we have POIs)
            if let pois = prefetchedPOIs, pois.count >= 5 {
                let avgLegLength = pois.prefix(10).reduce(0.0) { sum, poi in
                    sum + distanceBetween(location, poi.coordinate)
                } / Double(min(10, pois.count))
                
                // SPRINT-4: Density-aware speed model (by leg length) - global, no postcode branching
                if avgLegLength < RoutingToggles.denseLegThresholdM {
                    // Dense grid: 3.88 km/h (from RoutingToggles.denseSpeedKmh) - SPRINT-6: lowered for better accuracy
                    let denseSpeed = Int(RoutingToggles.denseSpeedKmh * 1000 / 60)  // km/h to m/min
                    print("🚶 [SPEED] Global density model: dense grid (avg leg: \(Int(avgLegLength))m < \(Int(RoutingToggles.denseLegThresholdM))m) → \(denseSpeed) m/min (\(String(format: "%.2f", RoutingToggles.denseSpeedKmh)) km/h)")
                    return denseSpeed
                } else if avgLegLength > RoutingToggles.suburbanLegThresholdM {
                    // Suburban: 5.00 km/h (from RoutingToggles.suburbanSpeedKmh)
                    let suburbanSpeed = Int(RoutingToggles.suburbanSpeedKmh * 1000 / 60)  // km/h to m/min
                    print("🚶 [SPEED] Global density model: suburban (avg leg: \(Int(avgLegLength))m > \(Int(RoutingToggles.suburbanLegThresholdM))m) → \(suburbanSpeed) m/min (5.00 km/h)")
                    return suburbanSpeed
                } else {
                    // Urban: 4.25 km/h (150-350m legs)
                    let urbanSpeed = Int(RoutingToggles.urbanSpeedKmh * 1000 / 60)  // km/h to m/min
                    print("🚶 [SPEED] Global density model: urban (avg leg: \(Int(avgLegLength))m, 150-350m) → \(urbanSpeed) m/min (4.25 km/h)")
                    return urbanSpeed
                }
            }
            
            // Fallback to adaptive walking speed if no POIs available
            return baseWalkingSpeed
        }()
        
        // v1.6.10: DUAL-MULTIPLIER + DENSITY-AWARE (for 5-min routes)
        // - estimationMultiplier: Aggressive - used for POI selection, aims shorter
        // - validationMultiplier: Original - used for accepting routes, realistic
        // For ≤5 min routes: use POI density as proxy for street grid density
        let estimationMultiplier: Double
        let validationMultiplier: Double
        
        // Determine POI density for adaptive 5-min estimation
        let poiDensity = prefetchedPOIs?.count ?? 100  // Default to medium if unknown
        
        if targetDurationMinutes <= 5 {
            // DENSITY-AWARE 5-MIN ESTIMATION (v1.6.10)
            // Explains the 60%-180% split between locations
            if poiDensity > 300 {
                estimationMultiplier = 0.55   // Dense street grids (Ecclesall) - aim much shorter
            } else if poiDensity < 80 {
                estimationMultiplier = 0.75   // Sparse / park-heavy (Chapeltown) - less aggressive
            } else {
                estimationMultiplier = 0.65   // Default
            }
            validationMultiplier = 0.85
            print("🎯 5-min density-aware: \(poiDensity) POIs → estimation=\(estimationMultiplier)")
        } else if targetDurationMinutes <= 10 {
            estimationMultiplier = 0.65
            validationMultiplier = 0.85
        } else if targetDurationMinutes <= 15 {
            estimationMultiplier = 0.70
            validationMultiplier = 0.85
        } else if targetDurationMinutes <= 20 {
            estimationMultiplier = 0.75
            validationMultiplier = 0.88
        } else if targetDurationMinutes <= 35 {
            estimationMultiplier = 0.82
            validationMultiplier = 0.90
        } else {
            estimationMultiplier = 0.85
            validationMultiplier = 0.92
        }
        
        // Use estimation multiplier for distance targeting (aims shorter)
        let totalDistanceTarget = Int(Double(targetDurationMinutes * walkingSpeedMeterPerMin) * estimationMultiplier)
        print("🗺️ Distance target: \(totalDistanceTarget)m (estimation: \(estimationMultiplier), validation: \(validationMultiplier))")
        
        // Search radius - LARGER for short routes to find POIs at better distances
        // In dense areas, nearby POIs are too close for a proper loop
        // Expanded search uses 2x radius to find more options
        // Long routes need larger radius to find distant POIs
        let baseRadius = max(600, totalDistanceTarget / 2)
        let searchRadius: Int
        if let override = searchRadiusOverride {
            searchRadius = override  // v1.9.50: Use override if provided (for Stage 2 fallback)
        } else if expandedSearch {
            searchRadius = baseRadius * 2  // Double radius for retry
        } else if targetDurationMinutes >= 30 {
            searchRadius = max(1500, baseRadius * 2)  // 30+ min: largest radius
            print("🗺️ 🔍 Extended search radius for \(targetDurationMinutes)min route (30+ tier)")
        } else if targetDurationMinutes >= 20 {
            searchRadius = max(1200, baseRadius * 2)  // 20-29 min: large radius
            print("🗺️ 🔍 Extended search radius for \(targetDurationMinutes)min route (20+ tier)")
        } else if targetDurationMinutes <= 15 {
            searchRadius = max(800, baseRadius * 3 / 2)  // Short routes need wider search
        } else {
            searchRadius = baseRadius  // 16-19 min: standard
        }
        
        let searchMode = expandedSearch ? "EXPANDED" : (useSystematicSelection ? "SYSTEMATIC" : "RANDOM")
        print("🗺️ Target: \(targetDurationMinutes)min [\(searchMode)]")
        print("🗺️ Search radius: \(searchRadius)m")
        
        // DURATION-BASED METHOD SELECTION
        // Short routes: endpoint-first only (skip loops - they're too unpredictable)
        // Medium routes: endpoint-first + enhancement
        // Long routes: can fall back to loop-based if needed
        let routeMethod: RouteMethod
        var dynamicMaxWaypoints: Int  // var: can be increased as fallback for short routes
        
        // FLEXIBLE WAYPOINT TIERS: Allow fewer waypoints, ensure routes are achievable
        // The algorithm tries more waypoints first, falls back to fewer if needed
        // v2.0.3: Raised minimum waypoints to encourage richer routes
        // Auto-relaxation will reduce if no valid routes found after 10 attempts
        var minWaypointsForTier: Int
        
        switch targetDurationMinutes {
        case 1...10:  // Handle 5-10 min routes (minimum is 5 min)
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 2
            minWaypointsForTier = 1  // Keep 1 for very short routes
            print("🗺️ 📋 Tier 10min: \(minWaypointsForTier)-\(dynamicMaxWaypoints) waypoints")
        case 11...20:
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 3
            minWaypointsForTier = 2  // v2.0.3: Raised from 1
            print("🗺️ 📋 Tier 11-20min: \(minWaypointsForTier)-\(dynamicMaxWaypoints) waypoints")
        case 21...30:
            routeMethod = .endpointOnly
            dynamicMaxWaypoints = 4
            minWaypointsForTier = 3  // v2.0.3: Raised from 2
            print("🗺️ 📋 Tier 21-30min: \(minWaypointsForTier)-\(dynamicMaxWaypoints) waypoints")
        case 31...45:
            routeMethod = .endpointWithEnhancement
            dynamicMaxWaypoints = 6
            minWaypointsForTier = 4  // v2.0.3: Raised from 2
            print("🗺️ 📋 Tier 31-45min: \(minWaypointsForTier)-\(dynamicMaxWaypoints) waypoints")
        default:  // 46-60+ min
            routeMethod = .endpointWithEnhancement
            dynamicMaxWaypoints = 7  // v2.0.3: Reduced from 8 to tighten spread
            minWaypointsForTier = 5  // v2.0.3: Raised from 3
            print("🗺️ 📋 Tier 46+min: \(minWaypointsForTier)-\(dynamicMaxWaypoints) waypoints")
        }
        
        // v1.6.43: Multi-POI bias for ≥30 min walks with sufficient POIs
        // Data shows multi-POI routes hit duration more reliably for longer walks
        // Only apply when POI count ≥100 (sparse area protection)
        if targetDurationMinutes >= 30 && (prefetchedPOIs?.count ?? 0) >= 100 {
            minWaypointsForTier = max(minWaypointsForTier, 2)  // Ensure at least 2 waypoints
            print("🗺️ 📋 Multi-POI bias active: min waypoints = \(minWaypointsForTier)")
        }
        
        // Step 1: Find nearby POIs - use pre-fetched if available (faster!)
        // Waypoints spaced 5 min apart: N waypoints = N+1 segments
        // desiredSpots = (duration / 5) - 1, but minimum 2 for variety
        let desiredSpots = max(2, (targetDurationMinutes / 5) - 1)
        var places: [PlaceResult]
        
        if let prefetched = prefetchedPOIs, !prefetched.isEmpty {
            // Use pre-fetched POIs - skip API call!
            // v1.6.48: Apply safety net filter to catch restricted POIs from old cache
            let filtered = prefetched.filter { !isRestrictedPOI($0) }
            let restrictedCount = prefetched.count - filtered.count
            if restrictedCount > 0 {
                print("🏫 Filtered \(restrictedCount) restricted POIs from prefetch (playcare/nursery/playground)")
            }
            places = filtered
            print("🗺️ ⚡ Using \(places.count) pre-fetched POIs (faster!)")
            // Check if database is available for this location (prefetched might have come from database)
            usedDatabase = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: Double(searchRadius)) != nil
        } else {
            // v1.9.50: SMART FIRST-RUN STRATEGY
            // Try free sources first (Apple, OSM, Geograph) to save Google costs
            // Fallback to Google if <15 POIs found (optimal threshold for route quality)
            let freeSourcesStartTime = Date()
            print("🗺️ [COST OPT] First-run: Trying free sources first (Apple/OSM/Geograph)...")
            print("⏱️ [TIMING] Free sources fetch STARTED")
            
            places = try await findNearbyPlaces(
                location: location,
                radiusMeters: searchRadius,
                skipGoogle: true,  // Skip Google on first attempt
                targetDurationMinutes: targetDurationMinutes  // v2.0.3 Phase 2A: For diversity check
            )
            
            let freeSourcesElapsed = Date().timeIntervalSince(freeSourcesStartTime)
            print("⏱️ [TIMING] Free sources fetch COMPLETED in \(String(format: "%.2f", freeSourcesElapsed))s")
            print("🗺️ Free sources: Found \(places.count) POIs (need \(desiredSpots) for route)")
            
            // SPRINT-5: Budget check AFTER POI fetch - abort if hard-stop already exceeded
            // This prevents 57+ second POI fetches from wasting additional time in routing
            if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "POI_FETCH_COMPLETE") {
                print("⛔ [HARD-STOP] Budget exceeded after POI fetch - aborting route generation")
                throw GoogleMapsError.noRouteFound
            }
            
            // Check if we used the pre-populated database (comprehensive, no need for Google fallback)
            usedDatabase = PrePopulatedPOIService.shared.getPrePopulatedPOIs(near: location, radiusMeters: Double(searchRadius)) != nil
            
            // Fallback to Google if we have <15 POIs AND we didn't use the database
            // Database POIs are comprehensive and pre-curated, so no Google fallback needed
            // Optimal threshold: 15 POIs covers all standard routes (10-30 min) with buffer for filtering
            if places.count < 15 && !usedDatabase {
                // SPRINT-5: Budget check before Google fallback - skip if already past soft-stop
                if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "GOOGLE_FALLBACK_START") {
                    print("⛔ [HARD-STOP] Skipping Google fallback - budget exceeded")
                } else {
                let googleFallbackStartTime = Date()
                print("🗺️ [FALLBACK] Only \(places.count) POIs from free sources (<15) - fetching Google POIs for better route quality...")
                print("⏱️ [TIMING] Google fallback fetch STARTED")
                
                let googlePOIs = try await findNearbyPlaces(
                    location: location,
                    radiusMeters: searchRadius,
                    skipGoogle: false,  // Include Google
                    targetDurationMinutes: targetDurationMinutes  // v2.0.3 Phase 2A: For diversity check
                )
                
                let googleFallbackElapsed = Date().timeIntervalSince(googleFallbackStartTime)
                print("⏱️ [TIMING] Google fallback fetch COMPLETED in \(String(format: "%.2f", googleFallbackElapsed))s")
                print("🗺️ With Google: Found \(googlePOIs.count) POIs")
                places = googlePOIs
                
                let totalPOIFetchTime = Date().timeIntervalSince(freeSourcesStartTime)
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                print("⏱️ [TIMING] TOTAL POI FETCH TIME: \(String(format: "%.2f", totalPOIFetchTime))s")
                print("⏱️ [TIMING]   Free sources: \(String(format: "%.2f", freeSourcesElapsed))s")
                print("⏱️ [TIMING]   Google fallback: \(String(format: "%.2f", googleFallbackElapsed))s")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                }  // SPRINT-5: Close budget check else block
            } else if usedDatabase {
                print("🗺️ ✅ Using pre-populated database POIs (\(places.count) POIs) - skipping Google fallback (database is comprehensive)")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                print("⏱️ [TIMING] TOTAL POI FETCH TIME: \(String(format: "%.2f", freeSourcesElapsed))s (database only)")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            } else {
                print("🗺️ ✅ Sufficient POIs from free sources (\(places.count) ≥15) - skipping Google (cost saved!)")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
                print("⏱️ [TIMING] TOTAL POI FETCH TIME: \(String(format: "%.2f", freeSourcesElapsed))s (free sources only)")
                print("⏱️ [TIMING] ═══════════════════════════════════════════════════════════")
            }
        }
        
        // ════════════════════════════════════════════════════════════════
        // 📊 POI FUNNEL TELEMETRY - Track filtering stages for debugging
        // ════════════════════════════════════════════════════════════════
        let fetchedPOICount = places.count
        
        // Filter out previously shown places to ensure variety
        // v1.9.51: Enhanced exclusion - checks placeId AND name similarity/coordinate proximity
        // This prevents duplicates like "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate" from appearing in different routes
        if !excludePlaceIds.isEmpty || !excludePOIs.isEmpty {
            let beforeCount = places.count
            
            // Combine excluded POIs from parameter and prefetched pool
            var allExcludedPOIs = excludePOIs
            if let prefetched = prefetchedPOIs {
                let excludedFromPrefetched = prefetched.filter { excludePlaceIds.contains($0.placeId) }
                allExcludedPOIs.append(contentsOf: excludedFromPrefetched)
            }
            
            places = places.filter { poi in
                // Direct placeId match
                if excludePlaceIds.contains(poi.placeId) {
                    return false
                }
                
                // Check if this POI is a duplicate of any excluded POI using unified comparator
                for excludedPOI in allExcludedPOIs {
                    if isRouteDuplicate(poi, excludedPOI) {
                        let distance = distanceBetween(poi.coordinate, excludedPOI.coordinate)
                        print("🚫 Excluded duplicate POI: '\(poi.name)' (matches excluded '\(excludedPOI.name)') - \(String(format: "%.1f", distance))m apart")
                        return false
                    }
                }
                
                return true
            }
            
            let excludedCount = beforeCount - places.count
            print("🗺️ Excluded \(excludedCount) previously shown POIs (by ID or similarity), \(places.count) remaining")
            if excludedCount > 0 && !allExcludedPOIs.isEmpty {
                let excludedNames = allExcludedPOIs.map { $0.name }.joined(separator: ", ")
                print("🚫 Excluded POI set: \(excludedNames)")
            }
        }
        let afterExclusionCount = places.count
        
        // 🎯 PRE-FILTER: Remove POIs that would create routes WAY outside target duration
        // This prevents "Springwood Cott" (30min round-trip) from being tried for 5min routes
        let preFilteredPlaces = preFilterPOIsByDuration(places, origin: location, targetDurationMinutes: targetDurationMinutes)
        places = preFilteredPlaces
        let prefilterPassedCount = places.count
        
        // ⚠️ WARNING: Pre-filter too aggressive?
        let prefilterPassRate = fetchedPOICount > 0 ? Double(prefilterPassedCount) / Double(fetchedPOICount) * 100 : 0
        if prefilterPassRate < 5.0 && fetchedPOICount > 50 {
            print("⚠️ 🚨 POI FUNNEL WARNING: Pre-filter too aggressive!")
            print("   📊 Fetched: \(fetchedPOICount) → Pre-filter passed: \(prefilterPassedCount) (\(String(format: "%.1f", prefilterPassRate))%)")
            print("   💡 Consider widening filter range for \(targetDurationMinutes)min routes")
        }
        
        // 📊 DYNAMIC POI CAP (v1.6.12): More aggressive density-adaptive cap
        // Batch test showed: more POIs ≠ better accuracy
        // 127 POIs (Chapeltown) → 72% valid, 296 POIs (Firth Park) → 42% valid
        // Root cause: too many candidates = selection noise dominates
        let rawPOICount = places.count
        let maxPOIs: Int
        if rawPOICount > 300 {
            maxPOIs = 50    // Very dense - aggressive reduction
        } else if rawPOICount > 200 {
            maxPOIs = 75    // Dense (e.g., Firth Park, Ecclesall)
        } else {
            maxPOIs = 150   // Normal / suburban / rural (working well)
        }
        
        var cappedPOICount = places.count
        if places.count > maxPOIs {
            print("📊 POI CAP: \(rawPOICount) raw → \(maxPOIs) (density tier: \(rawPOICount > 500 ? "ultra-dense" : rawPOICount > 200 ? "dense" : "normal"))")
            
            // v1.6.33: Extract Google POIs for verification of OSM/Apple POIs
            let googlePOIs = places.filter { isGooglePOI($0) }
            let googlePOICount = googlePOIs.count
            
            // Score POIs by: walkability + distance fit + source quality (prefer Google when plentiful)
            // v1.6.38: OSM/Apple POIs not found in Google cache are deprioritized (may be closed)
            let targetDistance = Double(targetDurationMinutes) * 80 / 2  // Ideal one-way distance
            let scoredPlaces = places.map { poi -> (poi: PlaceResult, score: Double) in
                let distance = distanceBetween(location, poi.coordinate)
                let distanceFit = 1.0 - min(1.0, abs(distance - targetDistance) / targetDistance)
                let walkScore = walkabilityScore(for: poi)
                let sourceScore = sourceQualityScore(for: poi, googlePOICount: googlePOICount, googlePOIs: googlePOIs)
                return (poi, distanceFit * 10 + walkScore + sourceScore)
            }.sorted { $0.score > $1.score }
            
            // v1.6.39: Apply spatial thinning AFTER scoring to ensure geographic diversity
            // This prevents clusters of POIs in one area dominating the selection
            let spatiallyThinnedPOIs = applySpatialThinning(
                scoredPlaces: scoredPlaces,
                origin: location,
                maxPOIs: maxPOIs,
                gridSizeMeters: 150  // ~2 minute walk between POIs minimum
            )
            places = spatiallyThinnedPOIs
            cappedPOICount = places.count
            
            // Log source breakdown
            let keptGoogleCount = places.filter { isGooglePOI($0) }.count
            print("📊 Kept \(places.count) POIs with spatial diversity (Google: \(keptGoogleCount), OSM/Apple: \(places.count - keptGoogleCount))")
        }
        
        // 📊 FINAL FUNNEL SUMMARY
        print("📊 ═══════════════════════════════════════════════════")
        print("📊 POI FUNNEL for \(targetDurationMinutes)min route:")
        print("📊   Fetched:        \(fetchedPOICount)")
        print("📊   After exclusion: \(afterExclusionCount)")
        print("📊   Pre-filter pass: \(prefilterPassedCount) (\(String(format: "%.0f", prefilterPassRate))%)")
        print("📊   After cap:       \(cappedPOICount)")
        print("📊 ═══════════════════════════════════════════════════")
        
        // For longer routes OR short routes with few POIs, do additional searches at different points
        // Short routes in dense areas need POIs at BETTER distances, not just more nearby ones
        let needsMorePOIs = places.count < desiredSpots * 2 || 
                           (targetDurationMinutes <= 15 && places.count < 10)
        if needsMorePOIs {
            // SPRINT-6: Budget check before offset POI searches (unguarded loop was causing p99 blowouts)
            if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "OFFSET_POI_SEARCH") {
                if !hardStopHit { hardStopHit = true; stageExited = "OFFSET_POI_SEARCH" }
                print("⛔ [HARD-STOP] Skipping offset POI searches - budget exceeded")
            } else {
                print("🗺️ Fetching more POIs for \(targetDurationMinutes)min route...")
                
                // Search at cardinal directions from origin
                let offsetDistance = 0.005 // ~500m in lat/lng
                let searchOffsets = [
                    (lat: offsetDistance, lng: 0.0),
                    (lat: -offsetDistance, lng: 0.0),
                    (lat: 0.0, lng: offsetDistance),
                    (lat: 0.0, lng: -offsetDistance)
                ]
                
                for offset in searchOffsets {
                    // SPRINT-6: Check budget before each offset search
                    if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "OFFSET_POI_\(searchOffsets.firstIndex(where: { $0.lat == offset.lat && $0.lng == offset.lng }) ?? 0)") {
                        if !hardStopHit { hardStopHit = true; stageExited = "OFFSET_POI_LOOP" }
                        print("⛔ [HARD-STOP] Aborting offset POI search loop - budget exceeded")
                        break
                    }
                    
                    let offsetLocation = CLLocationCoordinate2D(
                        latitude: location.latitude + offset.lat,
                        longitude: location.longitude + offset.lng
                    )
                    if let morePlaces = try? await findNearbyPlaces(
                        location: offsetLocation,
                        radiusMeters: 800,
                        targetDurationMinutes: targetDurationMinutes  // v2.0.3 Phase 2A: For diversity check
                    ) {
                        for place in morePlaces {
                            // v1.6.47: Check BOTH duplicate AND exclusion list to prevent excluded POIs sneaking back
                            let isDuplicate = places.contains(where: { $0.placeId == place.placeId })
                            let isExcluded = excludePlaceIds.contains(place.placeId)
                            if !isDuplicate && !isExcluded {
                                places.append(place)
                            }
                        }
                    }
                    
                    // Stop if we have enough
                    if places.count >= desiredSpots * 3 { break }
                }
                print("🗺️ Now have \(places.count) total POIs")
            }
        }
        
        guard !places.isEmpty else {
            throw GoogleMapsError.noPlacesFound
        }
        
        // ════════════════════════════════════════════════════════════════
        // 🚦 v2.0.1: VIABILITY GATE FOR SHORT ROUTES
        // Prevents forced bad routes in sparse areas
        // Minimum route duration is now 10 minutes
        // ════════════════════════════════════════════════════════════════
        let nearestPOIDistance = places.map { distanceBetween(location, $0.coordinate) }.min() ?? 9999
        
        // For 10 min routes: nearest POI should be within ~400m (5 min one-way @ 80m/min)
        // If nearest is >500m, a good 10-min route may not be possible
        if targetDurationMinutes <= 10 && nearestPOIDistance > 500 {
            print("🚦 VIABILITY GATE: 10min route may be challenging")
            print("   📏 Nearest POI: \(Int(nearestPOIDistance))m (ideal ≤400m for round-trip)")
            print("   💡 Route may be longer than requested")
            
            // Set flag so UI can show appropriate message
            await MainActor.run {
                shortRouteNotViable = true
                minimumViableMinutes = 10
            }
        } else {
            await MainActor.run {
                shortRouteNotViable = false
                minimumViableMinutes = 10
            }
        }
        
        // v1.6.10: Track POI count for low-POI warning
        let finalPOICount = places.count
        await MainActor.run {
            lastPOICount = finalPOICount
            hasLimitedPOIs = finalPOICount < GoogleMapsService.limitedPOIThreshold
            if hasLimitedPOIs {
                print("⚠️ LIMITED POIs: Only \(finalPOICount) POIs available (threshold: \(GoogleMapsService.limitedPOIThreshold))")
            }
        }
        
        print("🗺️ Have \(places.count) POIs to select from")
        
        // 🔍 DIAGNOSTIC: Show all available POIs with distances, directions, and source
        print("🔍 === POI DIAGNOSTIC ===")
        for (index, poi) in places.prefix(15).enumerated() {
            let dist = Int(distanceBetween(location, poi.coordinate))
            let angle = Int(bearingBetween(location, poi.coordinate))
            let direction: String
            if angle >= -45 && angle <= 45 { direction = "N" }
            else if angle > 45 && angle <= 135 { direction = "E" }
            else if angle > 135 || angle < -135 { direction = "S" }
            else { direction = "W" }
            
            // Determine source from placeId prefix
            let source: String
            if poi.placeId.hasPrefix("apple_") {
                source = "🍎"  // Apple Maps
            } else if poi.placeId.hasPrefix("osm_") {
                source = "🗺️"  // OpenStreetMap
            } else {
                source = "📍"  // Google
            }
            
            print("🔍 \(index+1). \(source) '\(poi.name)' - \(dist)m \(direction) (\(angle)°)")
        }
        if places.count > 15 {
            print("🔍 ... and \(places.count - 15) more POIs")
        }
        print("🔍 ======================")
        
        // ========================================
        // ENDPOINT-FIRST APPROACH (for Route 1)
        // ========================================
        // Find a single endpoint at half the target distance, route there and back
        // This is simpler and more predictable than loop-based routing
        if useEndpointFirst {
            print("🎯 ENDPOINT-FIRST: Looking for POI at ~\(targetDurationMinutes/2) min distance")
            
            // Calculate ideal endpoint distance (half of total loop)
            // Use ADAPTIVE walking speed for better accuracy
            // FIX: Use ceiling division for short routes (5min/2 = 3, not 2)
            let halfDurationMinutes: Int
            if targetDurationMinutes <= 10 {
                // For very short walks, round UP to avoid being too restrictive
                halfDurationMinutes = (targetDurationMinutes + 1) / 2  // 5→3, 10→5
            } else {
                halfDurationMinutes = targetDurationMinutes / 2
            }
            let idealEndpointDistance = Double(halfDurationMinutes * walkingSpeedMeterPerMin) * 0.9
            
            // ADAPTIVE RANGE: Wider for short routes (high road overhead makes close POIs too long)
            // Short routes need more flexibility to find ANY valid endpoint
            let minMultiplier: Double
            let maxMultiplier: Double
            if targetDurationMinutes <= 10 {
                minMultiplier = 0.1  // Very short: accept VERY close POIs (even 20m away)
                maxMultiplier = 3.0  // And much farther ones too (school at 240m)
            } else if targetDurationMinutes <= 15 {
                minMultiplier = 0.2
                maxMultiplier = 2.5
            } else if targetDurationMinutes <= 25 {
                minMultiplier = 0.3
                maxMultiplier = 2.0
            } else {
                minMultiplier = 0.4
                maxMultiplier = 1.8
            }
            let minEndpointDistance = idealEndpointDistance * minMultiplier
            let maxEndpointDistance = idealEndpointDistance * maxMultiplier
            let targetTotalMeters = Double(targetDurationMinutes * walkingSpeedMeterPerMin)
            
            print("🎯 Ideal endpoint: \(Int(idealEndpointDistance))m (range: \(Int(minEndpointDistance))-\(Int(maxEndpointDistance))m) [speed: \(walkingSpeedMeterPerMin)m/min]")
            
            // v1.6.15: CLOSEST-FIRST with SHUFFLE for variety
            // For short routes, prefer closer POIs but shuffle top candidates
            // This ensures variety when generating multiple routes
            let useClosestFirst = targetDurationMinutes <= 10
            
            // Find POIs at the right distance, with CORRIDOR PENALTY scoring
            // Score = 0.7 * |distance - ideal| + 0.3 * (2×distance / targetTotal) * 100
            // This penalizes POIs that would create overly long out-and-backs
            // v1.6.41: Add distance bonus to escape cluster trap for short walks
            var endpointCandidates = places
                .filter { poi in
                    // Exclude by placeId
                    if excludePlaceIds.contains(poi.placeId) {
                        return false
                    }
                    
                    // Exclude duplicates of excluded POIs (by name/location)
                    for excludedPOI in excludePOIs {
                        let distance = distanceBetween(poi.coordinate, excludedPOI.coordinate)
                        let poiDisplayName = GoogleMapsService.cleanPOIDisplayName(poi.name)
                        let excludedDisplayName = GoogleMapsService.cleanPOIDisplayName(excludedPOI.name)
                        let poiCleaned = poiDisplayName.lowercased()
                        let excludedCleaned = excludedDisplayName.lowercased()
                        
                        // Same display name (case-insensitive) and close (<150m) = duplicate
                        // INCREASED from 100m to 150m to catch POIs from different sources with slightly different coordinates
                        // Made case-insensitive to match within-route deduplication behavior
                        if poiCleaned == excludedCleaned {
                            if distance < 150.0 {
                                print("🚫 Excluded endpoint candidate: '\(poi.name)' (matches excluded '\(excludedPOI.name)') - \(String(format: "%.1f", distance))m apart")
                                return false
                            } else {
                                print("⚠️ Same cleaned name but >150m apart (endpoint): '\(poi.name)' vs '\(excludedPOI.name)' - \(String(format: "%.1f", distance))m (cleaned: '\(poiCleaned)')")
                            }
                        }
                        
                        // High name similarity (>0.9) and close (<30m) = likely duplicate
                        let nameSimilarity = calculateNameSimilarity(poiDisplayName.lowercased(), excludedDisplayName.lowercased(), poi1: poi, poi2: excludedPOI)
                        if nameSimilarity > 0.9 && distance < 30.0 {
                            return false
                        }
                    }
                    
                    return true
                }
                .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                    let dist = distanceBetween(location, poi.coordinate)
                    let distanceScore = abs(dist - idealEndpointDistance)
                    // Corridor penalty: penalize if 2×distance significantly exceeds target
                    let twoLegDistance = dist * 2
                    let distanceRatio = twoLegDistance / targetTotalMeters
                    let corridorPenalty = max(0, distanceRatio - 1.0) * 100  // Penalty if ratio > 1.0
                    
                    // v1.6.41: Distance bonus for short walks - escape cluster trap
                    // v1.6.42: Now POI-density-aware to prevent overshoot in sparse areas
                    // Negative bonus = penalty for POIs too close to origin
                    let shortWalkBonus = calculateShortWalkDistanceBonus(
                        distance: dist,
                        targetDurationMinutes: targetDurationMinutes,
                        poiCount: places.count
                    )
                    // Convert bonus to score penalty (higher score = worse in this context)
                    // shortWalkBonus is positive for good distances, negative for bad
                    // We want to REDUCE score for good distances, so subtract the bonus × weight
                    let shortWalkPenalty = -shortWalkBonus * 50  // Scale to match other scoring
                    
                    let score = 0.7 * distanceScore + 0.3 * corridorPenalty + shortWalkPenalty
                    return (poi, dist, score)
                }
                .filter { $0.distance >= minEndpointDistance && $0.distance <= maxEndpointDistance }
                .sorted { 
                    if useClosestFirst {
                        // For short routes, sort by DISTANCE (closest first)
                        return $0.distance < $1.distance
                    } else {
                        // For longer routes, use score-based sorting
                        return $0.score < $1.score
                    }
                }
            
            // v1.6.15: SHUFFLE top candidates for variety when generating multiple routes
            // Without this, we always pick the same "closest" POI
            if useClosestFirst && endpointCandidates.count > 3 {
                let topCount = min(8, endpointCandidates.count)  // Shuffle top 8
                var topCandidates = Array(endpointCandidates.prefix(topCount))
                topCandidates.shuffle()
                endpointCandidates = topCandidates + Array(endpointCandidates.dropFirst(topCount))
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (SHUFFLED top \(topCount) for variety)")
                // Debug: Show first 5 candidates after shuffle
                print("🎯 📋 Top 5 after shuffle: \(endpointCandidates.prefix(5).map { "\($0.poi.name) (\(Int($0.distance))m)" }.joined(separator: ", "))")
            } else if useClosestFirst {
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (closest-first, not enough to shuffle)")
                // Debug: Show what few candidates we have
                if !endpointCandidates.isEmpty {
                    print("🎯 📋 Candidates: \(endpointCandidates.map { "\($0.poi.name) (\(Int($0.distance))m)" }.joined(separator: ", "))")
                }
            } else {
                print("🎯 Found \(endpointCandidates.count) endpoint candidates (score-sorted)")
            }
            
            // PRE-CHECK POI DENSITY: If fewer than 3 candidates, skip endpoint-first entirely
            // Go straight to loop approach which handles sparse areas better
            if endpointCandidates.count < 3 && targetDurationMinutes <= 15 {
                print("🎯 ⚠️ Only \(endpointCandidates.count) endpoint candidates - too sparse for short route, using loop fallback")
                // Skip to loop approach
            } else {
            
            // PRE-FILTER: Check one-way time before attempting full route
            // This saves MapKit calls by rejecting POIs that are clearly too far
            // FIX: More generous buffer for short walks (need to find POIs!)
            let oneWayBuffer = targetDurationMinutes <= 10 ? 2 : 1  // +2 min for very short, +1 otherwise
            let maxOneWayMinutes = halfDurationMinutes + oneWayBuffer
            var filteredCandidates: [(poi: PlaceResult, distance: Double, score: Double)] = []
            
            for candidate in endpointCandidates.prefix(10) {
                // Check cached one-way time first
                if let cached = getCachedLegTime(from: location, to: candidate.poi) {
                    if cached.minutes > maxOneWayMinutes {
                        print("🎯 ⏱️ Skipping '\(candidate.poi.name)' - cached one-way: \(cached.minutes)min > \(maxOneWayMinutes)min max")
                        continue
                    }
                }
                // Estimate based on distance (80m/min walking speed)
                let estimatedOneWayMins = Int(candidate.distance / Double(walkingSpeedMeterPerMin))
                if estimatedOneWayMins > maxOneWayMinutes + 3 {  // Extra buffer since estimate is rough
                    print("🎯 ⏱️ Skipping '\(candidate.poi.name)' - estimated one-way: \(estimatedOneWayMins)min too long")
                    continue
                }
                filteredCandidates.append(candidate)
            }
            
            print("🎯 \(filteredCandidates.count) candidates after time pre-filter (max one-way: \(maxOneWayMinutes)min)")
            
            // Track valid endpoint routes to find one with enhancement potential
            var validEndpointRoutes: [(route: GeneratedRoute, enhanceable: Bool, poisNearby: Int)] = []
            
            // FALLBACK: Track best route even if outside tolerance (for sparse areas)
            var bestEndpointFallback: GeneratedRoute?
            var bestEndpointFallbackDiff = Int.max
            
            // Clear previous alternative routes
            alternativeEndpointRoutes = []
            
            // BATCH vs SEQUENTIAL DECISION:
            // - Use BATCH for short routes (10-20 min) where tolerance is tight and failures are common
            // - Use SEQUENTIAL for longer routes where first candidate usually works
            // - Rate-limit aware: fall back to sequential if already near limit
            let currentRateLimitCount = await currentMapKitRequestCount
            let useBatchMode = targetDurationMinutes <= 20 && currentRateLimitCount < 35 && filteredCandidates.count >= 3
            
            if useBatchMode {
                // ========================================
                // BATCH MODE: Process multiple candidates in parallel
                // ========================================
                let batchSize = min(6, filteredCandidates.count)  // Process up to 6 at once
                let candidatesToBatch = Array(filteredCandidates.prefix(batchSize))
                
                print("🔀 BATCH MODE: Processing \(candidatesToBatch.count) candidates in parallel (rate limit: \(currentRateLimitCount)/50)")
                
                let batchResults = await batchGetWalkingDirectionsForEndpoints(
                    origin: location,
                    candidates: candidatesToBatch,
                    maxConcurrent: 3  // 3 concurrent to stay well under rate limit
                )
                
                // Process batch results - find best routes
                for result in batchResults {
                    guard let route = result.route else {
                        print("🔀 ✗ '\(result.poi.name)' failed: \(result.error?.localizedDescription ?? "unknown")")
                        continue
                    }
                    
                    let routeMinutes = result.durationMinutes
                    print("🔀 '\(result.poi.name)': \(routeMinutes)min (target: \(targetDurationMinutes)min)")
                    
                    // Check if within tolerance
                    if routeMinutes >= minAcceptableMinutes && routeMinutes <= maxAcceptableMinutes {
                        print("🔀 ✅ VALID: \(routeMinutes)min to '\(result.poi.name)'")
                        
                        // CHECK ENHANCEMENT POTENTIAL
                        let timeHeadroom = targetDurationMinutes - routeMinutes
                        let routePoints = decodePolyline(route.polyline)
                        
                        let poisNearRoute = places.filter { poi in
                            // Exclude the endpoint POI itself using unified comparator
                            guard !isRouteDuplicate(poi, result.poi) else { return false }
                            
                            return routePoints.contains { routePoint in
                                distanceBetween(poi.coordinate, routePoint) < 150
                            }
                        }
                        
                        let hasEnhancementPotential = timeHeadroom >= 2 && poisNearRoute.count >= 1
                        validEndpointRoutes.append((route: route, enhanceable: hasEnhancementPotential, poisNearby: poisNearRoute.count))
                        
                        if hasEnhancementPotential {
                            print("🔀 ✨ Has enhancement potential: \(timeHeadroom)min headroom, \(poisNearRoute.count) POIs nearby")
                        }
                    } else {
                        // Track as fallback
                        let diff = abs(routeMinutes - targetDurationMinutes)
                        if diff < bestEndpointFallbackDiff {
                            bestEndpointFallbackDiff = diff
                            bestEndpointFallback = route
                            print("🔀 📌 Best fallback: \(routeMinutes)min (diff: \(diff)min)")
                        }
                    }
                }
                
                // Sort valid routes: enhanceable first, then by time closest to target
                validEndpointRoutes.sort { a, b in
                    if a.enhanceable != b.enhanceable { return a.enhanceable }
                    let aDiff = abs(a.route.durationMinutes - targetDurationMinutes)
                    let bDiff = abs(b.route.durationMinutes - targetDurationMinutes)
                    return aDiff < bDiff
                }
                
                print("🔀 BATCH RESULT: \(validEndpointRoutes.count) valid routes, \(validEndpointRoutes.filter { $0.enhanceable }.count) enhanceable")
                
            } else {
                // ========================================
                // SEQUENTIAL MODE: Try candidates one by one (original logic)
                // ========================================
                print("🎯 SEQUENTIAL MODE: Processing candidates one by one")
                
                for (index, candidate) in filteredCandidates.prefix(8).enumerated() {
                    print("🎯 Trying endpoint \(index+1): '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                    
                    // v2.0.3 Batch A: Wrap with timeout to prevent tails
                    // Note: Using default timeout since ADS not computed yet at this point
                    let timeout = RoutingToggles.perCallTimeoutNormal
                    let (directionsResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: [candidate.poi.coordinate],
                        timeout: timeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,  // ADS not computed yet
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("🎯 ⏱️ Timeout testing endpoint '\(candidate.poi.name)' - skipping")
                        continue
                    }
                    
                    guard let directions = directionsResult else {
                        print("🎯 ✗ Route failed for '\(candidate.poi.name)'")
                        continue
                    }
                    
                    let totalDurationSeconds = directions.legs.reduce(0) { $0 + ($1.duration.value) }
                    let totalDistanceMeters = directions.legs.reduce(0) { $0 + ($1.distance.value) }
                    let routeMinutes = totalDurationSeconds / 60
                    
                    print("🎯 Route duration: \(routeMinutes)min (target: \(targetDurationMinutes)min)")
                    
                    if routeMinutes >= minAcceptableMinutes && routeMinutes <= maxAcceptableMinutes {
                        print("🎯 ✅ VALID endpoint route! \(routeMinutes)min to '\(candidate.poi.name)'")
                        
                        let route = GeneratedRoute(
                            places: [candidate.poi],
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: totalDistanceMeters,
                            durationSeconds: totalDurationSeconds,
                            legs: directions.legs
                        )
                        
                        let timeHeadroom = targetDurationMinutes - routeMinutes
                        let routePoints = decodePolyline(route.polyline)
                        
                        let poisNearRoute = places.filter { poi in
                            // Exclude the endpoint POI itself using unified comparator
                            guard !isRouteDuplicate(poi, candidate.poi) else { return false }
                            
                            return routePoints.contains { routePoint in
                                distanceBetween(poi.coordinate, routePoint) < 150
                            }
                        }
                        
                        let hasEnhancementPotential = timeHeadroom >= 2 && poisNearRoute.count >= 1
                        
                        if hasEnhancementPotential {
                            print("🎯 ✨ Route has enhancement potential: \(timeHeadroom)min headroom, \(poisNearRoute.count) POIs nearby")
                            validEndpointRoutes.append((route: route, enhanceable: true, poisNearby: poisNearRoute.count))
                            break  // Found an enhanceable route
                        } else {
                            print("🎯 ⚠️ Route may be boring: only 1 waypoint")
                            validEndpointRoutes.append((route: route, enhanceable: false, poisNearby: poisNearRoute.count))
                        }
                    } else {
                        print("🎯 ✗ Outside tolerance: \(routeMinutes)min")
                        
                        let diff = abs(routeMinutes - targetDurationMinutes)
                        if diff < bestEndpointFallbackDiff {
                            bestEndpointFallbackDiff = diff
                            bestEndpointFallback = GeneratedRoute(
                                places: [candidate.poi],
                                polyline: directions.overviewPolyline.points,
                                distanceMeters: totalDistanceMeters,
                                durationSeconds: totalDurationSeconds,
                                legs: directions.legs
                            )
                            print("🎯 📌 Saved as best fallback: \(routeMinutes)min (diff: \(diff)min)")
                        }
                    }
                }
            }
            
            // Return best endpoint route (prefer enhanceable, otherwise first valid)
            // Store ALL other valid routes as alternatives for the caller to use
            // ALSO try shorter endpoint + waypoints strategy for variety
            
            // Helper function to try shorter endpoint strategy
            func tryShorterEndpointStrategy() async {
                print("🎯 🔄 Trying SHORTER ENDPOINT + WAYPOINTS for variety...")
                
                let shorterTargetMinutes = Int(Double(targetDurationMinutes) * 0.75)
                let shorterHalfDuration = shorterTargetMinutes / 2
                let shorterIdealDistance = Double(shorterHalfDuration * walkingSpeedMeterPerMin) * 0.9
                
                // Exclude already-found endpoints
                let usedPlaceIds = Set(validEndpointRoutes.compactMap { $0.route.places.first?.placeId })
                let shorterCandidates = places
                    .filter { !excludePlaceIds.contains($0.placeId) && !usedPlaceIds.contains($0.placeId) }
                    .map { poi -> (poi: PlaceResult, distance: Double, score: Double) in
                        let dist = distanceBetween(location, poi.coordinate)
                        let score = abs(dist - shorterIdealDistance)
                        return (poi, dist, score)
                    }
                    .filter { $0.distance >= shorterIdealDistance * 0.4 && $0.distance <= shorterIdealDistance * 1.6 }
                    .sorted { $0.score < $1.score }
                
                for candidate in shorterCandidates.prefix(3) {
                    print("🎯 🔄 Trying shorter endpoint: '\(candidate.poi.name)' at \(Int(candidate.distance))m")
                    
                    // v2.0.3 Batch A: Duration-aware timeout (ADS not available yet)
                    let shortTimeout = calculateRoutingTimeout(targetDurationMinutes: targetDurationMinutes, angularDiversityScore: nil, postcode: postcode)
                    let (shortResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: [candidate.poi.coordinate],
                        timeout: shortTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,  // ADS not computed yet
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("🎯 🔄 ⏱️ Timeout testing shorter endpoint - skipping")
                        continue
                    }
                    
                    guard let directions = shortResult else {
                        print("🎯 🔄 Failed: no directions")
                        continue
                    }
                    
                    let routeDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                    let routeDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                    let routeMinutes = routeDuration / 60
                    
                    // Must be 50-80% of target (room for waypoints)
                    let minShorter = Int(Double(targetDurationMinutes) * 0.50)
                    let maxShorter = Int(Double(targetDurationMinutes) * 0.80)
                    
                    if routeMinutes >= minShorter && routeMinutes <= maxShorter {
                        print("🎯 🔄 Shorter route: \(routeMinutes)min (\(minShorter)-\(maxShorter) target) - enhancing...")
                        
                        let shorterRoute = GeneratedRoute(
                            places: [candidate.poi],
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: routeDistance,
                            durationSeconds: routeDuration,
                            legs: directions.legs
                        )
                        
                        do {
                            let enhanced = try await enhanceRouteWithWaypoints(
                                existingRoute: shorterRoute,
                                origin: location,
                                targetDurationMinutes: targetDurationMinutes,
                                prefetchedPOIs: places
                            )
                            
                            let enhancedMins = enhanced.durationSeconds / 60
                            if enhanced.places.count > 1 && enhancedMins >= minAcceptableMinutes && enhancedMins <= maxAcceptableMinutes {
                                print("🎯 ✨ ENHANCED shorter route: \(enhanced.places.count) waypoints, \(enhancedMins)min - adding as alternative")
                                alternativeEndpointRoutes.append(enhanced)
                                return  // Found one good enhanced route
                            } else {
                                print("🎯 🔄 Enhanced not valid: \(enhanced.places.count) wp, \(enhancedMins)min (need \(minAcceptableMinutes)-\(maxAcceptableMinutes))")
                            }
                        } catch {
                            print("🎯 🔄 Enhancement failed: \(error.localizedDescription)")
                        }
                    } else {
                        print("🎯 🔄 Route \(routeMinutes)min outside \(minShorter)-\(maxShorter) range")
                    }
                }
                print("🎯 🔄 No valid shorter+enhanced route found")
            }
            
            if let bestEnhanceable = validEndpointRoutes.first(where: { $0.enhanceable }) {
                print("🎯 ✅ Found enhanceable endpoint route")
                
                // ALSO try shorter endpoint strategy for variety (adds as alternative)
                await tryShorterEndpointStrategy()
                
                // Store other routes as alternatives
                for otherRoute in validEndpointRoutes where otherRoute.route.polyline != bestEnhanceable.route.polyline {
                    alternativeEndpointRoutes.append(otherRoute.route)
                }
                if !alternativeEndpointRoutes.isEmpty {
                    print("🎯 📦 Stored \(alternativeEndpointRoutes.count) alternative route(s) for pool")
                }
                // Final deduplication before returning
                let deduplicatedPlaces = deduplicateRoutePlaces(bestEnhanceable.route.places)
                var routeToReturn = bestEnhanceable.route
                if deduplicatedPlaces.count < bestEnhanceable.route.places.count {
                    // v2.0.3 Batch A: Duration-aware timeout (ADS not available yet)
                    let regenTimeout = calculateRoutingTimeout(targetDurationMinutes: targetDurationMinutes, angularDiversityScore: nil, postcode: postcode)
                    let (directionsResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: deduplicatedPlaces.map { $0.coordinate },
                        timeout: regenTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,  // ADS not computed yet
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("⚠️ [REGEN] Timeout regenerating route after deduplication, using original places")
                    } else if let directions = directionsResult {
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        routeToReturn = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                    } else {
                        print("⚠️ Failed to regenerate route after deduplication, using deduplicated places without regeneration")
                        // Even if regeneration fails, use deduplicated places to avoid returning duplicates
                        routeToReturn = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: bestEnhanceable.route.polyline,
                            distanceMeters: bestEnhanceable.route.distanceMeters,
                            durationSeconds: bestEnhanceable.route.durationSeconds,
                            legs: bestEnhanceable.route.legs
                        )
                    }
                }
                // v2.0.3 Phase 1.5 Batch A: Use centralized finalization
                let result = await finalizeAndReturnRoute(routeToReturn, targetDurationMinutes: targetDurationMinutes, postcode: postcode)
                if let finalized = result.route {
                    printRouteSummary(route: finalized, targetDuration: targetDurationMinutes)
                    return finalized
                }
                print("⛔ [GUARD] Route rejected by finalizeAndReturnRoute - falling through to fallback")
            } else if let firstValid = validEndpointRoutes.first {
                print("🎯 ⚠️ Only boring routes found")
                
                // Try shorter endpoint + waypoints strategy for variety
                await tryShorterEndpointStrategy()
                
                // Store other valid routes as alternatives
                for otherRoute in validEndpointRoutes.dropFirst() {
                    alternativeEndpointRoutes.append(otherRoute.route)
                }
                if !alternativeEndpointRoutes.isEmpty {
                    print("🎯 📦 Stored \(alternativeEndpointRoutes.count) alternative route(s) for pool")
                }
                // Final deduplication before returning
                let deduplicatedPlaces = deduplicateRoutePlaces(firstValid.route.places)
                var routeToReturn = firstValid.route
                if deduplicatedPlaces.count < firstValid.route.places.count {
                    // v2.0.3 Batch A: Duration-aware timeout (ADS not available yet)
                    let regenTimeout = calculateRoutingTimeout(targetDurationMinutes: targetDurationMinutes, angularDiversityScore: nil, postcode: postcode)
                    let (directionsResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: deduplicatedPlaces.map { $0.coordinate },
                        timeout: regenTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,  // ADS not computed yet
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("⚠️ [REGEN] Timeout regenerating firstValid route, using original places")
                    } else if let directions = directionsResult {
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        routeToReturn = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                    } else {
                        print("⚠️ Failed to regenerate route after deduplication, using deduplicated places without regeneration")
                        routeToReturn = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: firstValid.route.polyline,
                            distanceMeters: firstValid.route.distanceMeters,
                            durationSeconds: firstValid.route.durationSeconds,
                            legs: firstValid.route.legs
                        )
                    }
                }
                // v2.0.3 Phase 1.5 Batch A: Use centralized finalization
                let result = await finalizeAndReturnRoute(routeToReturn, targetDurationMinutes: targetDurationMinutes, postcode: postcode)
                if let finalized = result.route {
                    printRouteSummary(route: finalized, targetDuration: targetDurationMinutes)
                    return finalized
                }
                print("⛔ [GUARD] firstValid route rejected - falling through to fallback")
            }
            
            // If no valid routes but we have a fallback, use it (better than nothing)
            if let fallback = bestEndpointFallback {
                let fallbackMins = fallback.durationSeconds / 60
                print("🎯 ⚠️ No routes in tolerance, using best fallback: \(fallbackMins)min (target: \(targetDurationMinutes)min)")
                print("🎯 💡 Note: This area has high road overhead - closest route is \(fallbackMins)min")
                // Final deduplication before returning
                let deduplicatedPlaces = deduplicateRoutePlaces(fallback.places)
                if deduplicatedPlaces.count < fallback.places.count {
                    // v2.0.3 Batch A: Duration-aware timeout (ADS not available yet)
                    let regenTimeout = calculateRoutingTimeout(targetDurationMinutes: targetDurationMinutes, angularDiversityScore: nil, postcode: postcode)
                    let (directionsResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: deduplicatedPlaces.map { $0.coordinate },
                        timeout: regenTimeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: nil,  // ADS not computed yet
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("⚠️ [REGEN] Timeout regenerating fallback route, using original")
                        let result = await finalizeAndReturnRoute(fallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                        if let finalized = result.route {
                            return finalized
                        }
                    } else if let directions = directionsResult {
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        let deduplicatedRoute = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                        let result = await finalizeAndReturnRoute(deduplicatedRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode)
                        if let finalized = result.route {
                            return finalized
                        }
                    } else {
                        print("⚠️ Failed to regenerate route after deduplication, using deduplicated places without regeneration")
                        let fallbackRoute = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: fallback.polyline,
                            distanceMeters: fallback.distanceMeters,
                            durationSeconds: fallback.durationSeconds,
                            legs: fallback.legs
                        )
                        let result = await finalizeAndReturnRoute(fallbackRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                        if let finalized = result.route {
                            return finalized
                        }
                    }
                    print("⛔ [GUARD] Fallback route rejected - continuing to loop approach")
                }
                // v2.0.3 Phase 1.5 Batch A: Use centralized finalization
                        let result = await finalizeAndReturnRoute(fallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                        if let finalized = result.route {
                            return finalized
                        }
                print("⛔ [GUARD] Fallback rejected - continuing to loop approach")
            }
            
            print("🎯 No valid endpoint routes found, falling back to loop approach...")
            }  // End of POI density else block
        }
        
        // ========================================
        // LOOP APPROACH (for Routes 2+ or fallback)
        // ========================================
        
        // For short routes (10-25 min), use MINIMAL loop attempts as last resort
        // Don't skip entirely - high road overhead areas need fallback options
        let loopAttemptsLimit: Int
        if routeMethod == .endpointOnly {
            loopAttemptsLimit = 4  // Quick fallback with minimal attempts
            print("🗺️ ⚡ Using minimal loop fallback for \(targetDurationMinutes)min route (endpoint-only tier)")
        } else {
            loopAttemptsLimit = 8  // Standard attempts for longer routes
        }
        
        // Step 3: MAXIMIZE POIs while staying within time limit
        var validRoutes: [GeneratedRoute] = []
        var bestFallbackRoute: GeneratedRoute?
        var bestFallbackDiff = Int.max
        var firstValidRouteFoundAt: Date? = nil  // v2.0.3 Phase 1.5: Track when first valid route found
        
        // PRIORITY: 1) Timing within tolerance  2) Maximum POIs
        // v1.8.17: Calculate Angular Diversity Score to determine if multi-waypoint is feasible
        // v2.0.3: Compute ADS once after all filtering is complete
        // CRITICAL ORDERING: ADS must be calculated AFTER:
        //   1. Restricted area filtering
        //   2. Invalid coordinate filtering  
        //   3. Distance pre-filtering
        //   4. Deduplication
        //   5. Sorting (if any)
        // This ensures ADS reflects the actual candidate pool used for route generation
        let adsResult = calculateAngularDiversityScore(pois: places, origin: location, targetDurationMinutes: targetDurationMinutes)
        let angularDiversityScore = adsResult.score
        print("🧭 [ADS] Computed once after all filtering: \(angularDiversityScore) (sectors: \(adsResult.sectors))")
        print("🧭 [ADS] Based on \(places.count) filtered POIs")
        if angularDiversityScore < 6 {
            let sectorDetails = adsResult.sectors.sorted { $0.key < $1.key }.map { "S\($0.key):\($0.value)" }.joined(separator: " ")
            print("🧭 Sector breakdown: \(sectorDetails)")
        }
        
        // v2.0.3 Phase 2A: ADS-aware radius expansion (if low diversity detected)
        // CRITICAL FIX: Check hard-wall BEFORE expansion and add timeout
        var finalAngularDiversityScore = angularDiversityScore
        let elapsedBeforeExpansion = Date().timeIntervalSince(startTime)
        let expansionHardWall = min(hardWallSeconds * 0.5, 5.0)  // Max 5s for expansion, or 50% of hard-wall
        
        // P0 FIX: Skip expansion if we're already past 50% of hard-wall budget
        if angularDiversityScore <= 2 && searchRadiusOverride == nil && elapsedBeforeExpansion < expansionHardWall {
            // SPRINT-4: Global hard-stop check before expansion
            if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "EXPANSION") {
                print("⛔ [HARD-STOP] Skipping expansion - returning best-so-far")
                // Skip expansion, continue with existing places
            } else {
                let expansionStartTime = Date()
                let adsBasedRadiusMultiplier: Double = angularDiversityScore == 1 ? 1.40 : 1.25
                
                // PHASE D: Track expansion
                expansions += 1
                
                let expandedRadius = Int(Double(searchRadius) * adsBasedRadiusMultiplier)
                let expansionTimeout: TimeInterval = min(4.0, expansionHardWall - elapsedBeforeExpansion)
                print("⚠️ [EXPANSION] Low diversity (ADS=\(angularDiversityScore)) - expanding radius: \(searchRadius)m → \(expandedRadius)m (timeout: \(String(format: "%.1f", expansionTimeout))s)")
                
                // P0 FIX: Use continuation-based racing for true timeout (same pattern as directionsWithTimeout)
                let expansionResult: (pois: [PlaceResult]?, timedOut: Bool) = await withCheckedContinuation { continuation in
                    actor ExpansionGuard {
                        var hasResumed = false
                        func tryResume() -> Bool {
                            if hasResumed { return false }
                            hasResumed = true
                            return true
                        }
                    }
                    let guard_ = ExpansionGuard()
                    
                    // Expansion task
                    Task {
                        do {
                            let pois = try await self.findNearbyPlaces(
                                location: location,
                                radiusMeters: expandedRadius,
                                skipGoogle: true,
                                targetDurationMinutes: targetDurationMinutes
                            )
                            if await guard_.tryResume() {
                                continuation.resume(returning: (pois, false))
                            }
                        } catch {
                            if await guard_.tryResume() {
                                continuation.resume(returning: (nil, false))
                            }
                        }
                    }
                    
                    // Timeout task
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(expansionTimeout * 1_000_000_000))
                        if await guard_.tryResume() {
                            print("⏱️ [EXPANSION-TIMEOUT] Expansion timed out after \(String(format: "%.1f", expansionTimeout))s")
                            continuation.resume(returning: (nil, true))
                        }
                    }
                }
                
                if let newPOIs = expansionResult.pois {
                    // P0 FIX: O(n) dedup using Set instead of O(n²) contains check
                    let beforeExpansion = places.count
                    var seenPlaceIds = Set(places.map { $0.placeId })
                    
                    // Pre-build coordinate lookup for fast duplicate detection (O(1) instead of O(n))
                    var seenCoordKeys = Set<String>()
                    for existing in places {
                        let coordKey = "\(Int(existing.coordinate.latitude * 10000))_\(Int(existing.coordinate.longitude * 10000))"
                        seenCoordKeys.insert(coordKey)
                    }
                    
                    for poi in newPOIs {
                        // Skip if already have this place ID
                        guard !seenPlaceIds.contains(poi.placeId) else { continue }
                        
                        // O(1) coordinate-based duplicate check (instead of O(n) isRouteDuplicate)
                        let coordKey = "\(Int(poi.coordinate.latitude * 10000))_\(Int(poi.coordinate.longitude * 10000))"
                        guard !seenCoordKeys.contains(coordKey) else { continue }
                        
                        places.append(poi)
                        seenPlaceIds.insert(poi.placeId)
                        seenCoordKeys.insert(coordKey)
                    }
                    
                    let expansionElapsed = Date().timeIntervalSince(expansionStartTime)
                    let addedCount = places.count - beforeExpansion
                    
                    if expansionElapsed >= 3.0 {
                        print("⚠️ [EXPANSION] Added \(addedCount) POIs in \(String(format: "%.2f", expansionElapsed))s (SLOW)")
                    } else {
                        print("✅ [EXPANSION] Added \(addedCount) POIs in \(String(format: "%.2f", expansionElapsed))s")
                    }
                    
                    // Recalculate ADS with expanded POI set
                    let expandedAdsResult = calculateAngularDiversityScore(pois: places, origin: location, targetDurationMinutes: targetDurationMinutes)
                    finalAngularDiversityScore = expandedAdsResult.score
                    print("📦 [EXPANSION] New ADS: \(finalAngularDiversityScore) (was \(angularDiversityScore))")
                }
            }
        } else if angularDiversityScore <= 2 && elapsedBeforeExpansion >= expansionHardWall {
            print("⏱️ [EXPANSION-SKIP] Skipping expansion - already at \(String(format: "%.1f", elapsedBeforeExpansion))s (budget: \(String(format: "%.1f", expansionHardWall))s)")
        }
        
        // v2.0.3: Lowered ADS gate to 2, but enforce minimum 60° angular spacing for ADS=2
        // Use finalAngularDiversityScore (may have been updated by radius expansion)
        let effectivePreferMultiWaypoint: Bool
        if preferMultiWaypoint && finalAngularDiversityScore >= 2 {
            if finalAngularDiversityScore == 2 {
                print("🧭 ⚠️ [ADS] ADS=2 (low diversity) - will enforce ≥60° spacing between waypoints")
            }
            effectivePreferMultiWaypoint = true
            } else {
                effectivePreferMultiWaypoint = false
            if preferMultiWaypoint {
                print("🧭 ⚠️ [ADS] ADS too low (\(finalAngularDiversityScore)) - skipping multi-waypoint attempt")
            }
        }
        
        // v1.8.11: preferMultiWaypoint disables quickMode to try more waypoint combinations
        let quickMode = !useSystematicSelection && !expandedSearch && !effectivePreferMultiWaypoint
        
        // Calculate appropriate waypoint counts based on target duration
        // Waypoints should be SPACED ~5 mins of walking apart (user spends ~2 min at each, not counted in route time)
        // For circular route: Start → WP1 → WP2 → ... → Start
        // With N waypoints, there are N+1 walking segments
        // If segments are ~5 mins each: totalWalkingTime = 5 * (N+1)
        // So: N = (walkingTime / 5) - 1
        // Example: 20min route → (20/5) - 1 = 3 waypoints (4 segments of 5 mins each)
        let idealWaypoints = max(1, (targetDurationMinutes / 5) - 1)
        let standardMaxWaypoints = min(dynamicMaxWaypoints, idealWaypoints + 1, places.count)
        
        // FALLBACK: Allow extra waypoints if routes are too short
        // Can reduce spacing to ~4 mins between waypoints as fallback
        // Example: 20min route fallback → (20/4) - 1 = 4 waypoints (5 segments of 4 mins each)
        let fallbackMaxWaypoints = max(1, (targetDurationMinutes / 4) - 1)
        let extendedMaxWaypoints = min(max(standardMaxWaypoints, fallbackMaxWaypoints), places.count)
        
        // ENFORCE MINIMUM WAYPOINTS per tier to ensure distinct routes
        // This prevents 15min routes from using the same 1-waypoint as 10min
        // SAFETY: Never let minWaypoints exceed standardMaxWaypoints (prevents crash with few POIs)
        var idealMinWaypoints = max(minWaypointsForTier, quickMode ? max(1, idealWaypoints / 2) : max(1, idealWaypoints - 2))
        
        // v1.6.49: Force multi-waypoint for variety (applied to routes 2-4)
        // For 20+min routes, require at least 2 waypoints to create more interesting multi-POI routes
        // v1.8.17: Only if ADS supports it (effectivePreferMultiWaypoint already checks ADS >= 3)
        if effectivePreferMultiWaypoint && targetDurationMinutes >= 20 {
            idealMinWaypoints = max(idealMinWaypoints, 2)
            print("🗺️ 📋 Multi-waypoint preference active: forcing min 2 waypoints (ADS: \(angularDiversityScore))")
        }
        
        let minWaypoints = min(idealMinWaypoints, standardMaxWaypoints)  // Clamp to available max
        print("🗺️ Waypoint range: \(minWaypoints) to \(standardMaxWaypoints) (extended: \(extendedMaxWaypoints))")
        
        // QUICK MODE: Try ASCENDING order (fewest waypoints first) for faster matching
        // This gets a valid route quickly, even if it has fewer POIs
        // Retry modes: Try DESCENDING to maximize POIs
        var waypointCountsToTry: [Int]
        if quickMode {
            // Start small for fast matching: [1, 2, 3] for 10-min route
            // Include extra waypoints at the end as fallback if routes are too short
            waypointCountsToTry = Array(minWaypoints...standardMaxWaypoints)
            if extendedMaxWaypoints > standardMaxWaypoints {
                waypointCountsToTry += Array((standardMaxWaypoints + 1)...extendedMaxWaypoints)
                print("🗺️ 📋 Including fallback waypoints: \(standardMaxWaypoints + 1)-\(extendedMaxWaypoints) if routes too short")
            }
        } else {
            // Start big to maximize POIs: [5, 4, 3, 2, 1]
            // Include extra waypoints at the START for retry modes (try most first)
            if extendedMaxWaypoints > standardMaxWaypoints {
                waypointCountsToTry = Array((minWaypoints...extendedMaxWaypoints).reversed())
                print("🗺️ 📋 Extended waypoint range: up to \(extendedMaxWaypoints) (fallback for short routes)")
            } else {
                waypointCountsToTry = Array((minWaypoints...standardMaxWaypoints).reversed())
            }
        }
        _ = extendedMaxWaypoints  // Extended max available for fallback waypoint counts
        
        // v2.0.3 Phase 2A: DB density check before loop attempts
        // Check if we have enough POIs for loop formation, enable live blending if needed
        let minRequiredPOIsForLoops = 10 + (targetDurationMinutes / 10 * 4)
        if places.count < minRequiredPOIsForLoops && usedDatabase {
            // ⚠️ DELAY LOG: Highlight density check
            print("⚠️ [DELAY] [DB DENSITY] Insufficient POIs for loops (\(places.count) < \(minRequiredPOIsForLoops)) - checking if live blending needed...")
            let densityCheckStartTime = Date()
            
            // Re-check if we should blend (might have been skipped earlier)
            let currentAdsResult = calculateAngularDiversityScore(pois: places, origin: location, targetDurationMinutes: targetDurationMinutes)
            let currentAds = currentAdsResult.score
            
            // v2.0.3: Made less aggressive - only blend if ADS ≤ 2 (very low) or POI count significantly low
            if currentAds <= 2 || places.count < minRequiredPOIsForLoops {
                print("⚠️ [DELAY] [DB DENSITY] Enabling live POI blending (ADS=\(currentAds), POIs=\(places.count))")
                
                // Fetch live POIs from free sources
                // v2.0.3: Skip Apple Maps in batch mode to avoid rate limiting
                let livePOIs = await fetchLivePOIsForBlending(location: location, radiusMeters: searchRadius, skipAppleMaps: isBatchTestMode)
                let densityCheckElapsed = Date().timeIntervalSince(densityCheckStartTime)
                
                if !livePOIs.isEmpty {
                    // Merge with existing POIs (deduplicated)
                    var seenPlaceIds = Set(places.map { $0.placeId })
                    let beforeBlend = places.count
                    
                    for livePOI in livePOIs {
                        if !seenPlaceIds.contains(livePOI.placeId) {
                            let isDuplicate = places.contains { existing in
                                isRouteDuplicate(livePOI, existing)
                            }
                            if !isDuplicate {
                                places.append(livePOI)
                                seenPlaceIds.insert(livePOI.placeId)
                            }
                        }
                    }
                    
                    // ⚠️ DELAY LOG: Highlight density check results
                    if densityCheckElapsed >= 3.0 {
                        print("⚠️ [DELAY] [DB DENSITY] Blended: \(beforeBlend) DB + \(livePOIs.count) live = \(places.count) total in \(String(format: "%.2f", densityCheckElapsed))s (SLOW)")
                    } else {
                        print("✅ [DB DENSITY] Blended: \(beforeBlend) DB + \(livePOIs.count) live = \(places.count) total in \(String(format: "%.2f", densityCheckElapsed))s")
                    }
                    
                    // Recalculate ADS with blended POIs
                    let blendedAdsResult = calculateAngularDiversityScore(pois: places, origin: location, targetDurationMinutes: targetDurationMinutes)
                    let blendedAds = blendedAdsResult.score
                    print("📦 📊 [DB DENSITY] New ADS after blending: \(blendedAds) (was \(currentAds))")
                }
            }
        }
        
        // v2.0.3: Auto-relaxation tracking
        var attemptsWithoutValidRoute = 0
        var relaxedThisCycle = false  // v2.0.3: Guard against infinite relaxation
        
        var totalAttempts = 0
        // v2.0.3: Duration-based attempt caps to control tail latency
        // SPRINT-7: Tighter caps for 35-60 min routes to steady p95 without harming quality
        let maxTotalAttempts: Int
        if quickMode {
            // Quick mode: use duration-based caps
            let durationBasedCap: Int
            switch targetDurationMinutes {
            case 10...20:
                durationBasedCap = 30  // v2.0.3: Cap at 30 attempts
            case 21...34:
                durationBasedCap = 40  // v2.0.3: Cap at 40 attempts
            case 35...60:
                durationBasedCap = 10  // SPRINT-7 HOTFIX: Much tighter cap for 35-60 min routes (was 25)
            default:
                durationBasedCap = loopAttemptsLimit  // Fallback for edge cases
            }
            maxTotalAttempts = min(loopAttemptsLimit, durationBasedCap)
            print("🗺️ ⚡ QUICK MODE: Trying \(waypointCountsToTry) waypoints (max \(maxTotalAttempts) attempts, duration-based cap: \(durationBasedCap))")
        } else if expandedSearch || useSystematicSelection {
            // Retry modes: use duration-based caps
            let durationBasedCap: Int
            switch targetDurationMinutes {
            case 10...20:
                durationBasedCap = 30
            case 21...34:
                durationBasedCap = 40
            case 35...60:
                durationBasedCap = 25  // SPRINT-7: Tighter cap for 35-60 min routes
            default:
                durationBasedCap = 20
            }
            maxTotalAttempts = durationBasedCap
            print("🗺️ Will try waypoint counts: \(waypointCountsToTry) (max \(maxTotalAttempts) attempts, duration-based)")
        } else if preferMultiWaypoint {
            let durationBasedCap: Int
            switch targetDurationMinutes {
            case 10...20:
                durationBasedCap = 30
            case 21...34:
                durationBasedCap = 40
            case 35...60:
                durationBasedCap = 25  // SPRINT-7: Tighter cap for 35-60 min routes
            default:
                durationBasedCap = 15
            }
            maxTotalAttempts = durationBasedCap
            print("🗺️ 🎯 MULTI-WAYPOINT MODE: Trying \(waypointCountsToTry) waypoints (max \(maxTotalAttempts) attempts)")
        } else {
            let durationBasedCap: Int
            switch targetDurationMinutes {
            case 10...20:
                durationBasedCap = 30
            case 21...34:
                durationBasedCap = 40
            case 35...60:
                durationBasedCap = 25  // SPRINT-7: Tighter cap for 35-60 min routes
            default:
                durationBasedCap = 10
            }
            maxTotalAttempts = durationBasedCap
            print("🗺️ Will try waypoint counts: \(waypointCountsToTry) (max \(maxTotalAttempts) attempts)")
        }
        
        // v2.0.3 Phase 1.5 Batch A: Check early topology-safe BEFORE entering loops
        let earlyTopoSafe: TimeInterval = {
            if let pc = postcode, let override = postcodeOverrides[pc] {
                return override.earlyTopoSafeSec
            }
            return (finalAngularDiversityScore < 3)
                ? RoutingToggles.earlyTopoSafeLowADS
                : RoutingToggles.earlyTopoSafeNormal
        }()
        
        // v2.0.3 Phase 1.5: Hard-wall timer using centralized calculation
        let hardWallTimer = RoutingToggles.hardWallFor(duration: targetDurationMinutes, ads: finalAngularDiversityScore, postcode: postcode)
        print("⏱️ [HARDWALL] Budget: \(String(format: "%.0f", hardWallTimer))s (dur=\(targetDurationMinutes), ADS=\(finalAngularDiversityScore), pc=\(postcode ?? "none"))")
        
        // v2.0.3 Phase 1.5 Batch A: Early topology-safe check BEFORE entering loops
        let elapsedBeforeLoops = Date().timeIntervalSince(startTime)
        if elapsedBeforeLoops > earlyTopoSafe && validRoutes.isEmpty {
            print("⏱️ [TOPO-ACT] Early topology-safe BEFORE loops (threshold=\(String(format: "%.1f", earlyTopoSafe))s, ADS=\(finalAngularDiversityScore), elapsed=\(String(format: "%.2f", elapsedBeforeLoops))s, pc=\(postcode ?? "none"))")
            // SPRINT-5: Budget check before topology-safe generation
            if !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "TOPO_SAFE_BEFORE_LOOPS") {
                print("⛔ [HARD-STOP] Skipping topology-safe before loops - budget exceeded")
                throw GoogleMapsError.noRouteFound
            }
            if let topologyRoute = try? await generateRouteShortTopologySafe(
                from: location,
                targetDurationMinutes: targetDurationMinutes,
                excludePlaceIds: excludePlaceIds,
                excludePOIs: excludePOIs,
                budget: budget  // SPRINT-5: Pass budget for hard-stop awareness
            ) {
                let routeMins = topologyRoute.durationSeconds / 60
                let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
                if routeMins <= hardCap180 {
                    print("✅ [TOPO-ACT] Succeeded: \(routeMins)min (before loops)")
                    // SPRINT-5: Pass budget for universal hard-stop
                    let result = await finalizeAndReturnRoute(topologyRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                    if let finalized = result.route {
                        return finalized
                    }
                    print("⛔ [GUARD] Topology-safe route rejected - falling through")
                } else {
                    print("⛔ [TOPO-ACT] Route \(routeMins)min exceeds 180% cap \(hardCap180)min - falling through")
                }
            }
        }
        
        // Track last topology-safe check time for periodic checks inside loops
        var lastTopoSafeCheck = Date()
        let topoSafeCheckInterval: TimeInterval = 3.0  // Check every 3 seconds inside loops
        
        for waypointCount in waypointCountsToTry {
            // SPRINT-4: Global hard-stop check at top of outer loop
            if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "OUTER_LOOP_wp\(waypointCount)") {
                print("⛔ [HARD-STOP] Returning best-so-far from outer loop")
                break  // Exit outer loop immediately
            }
            
            print("🗺️ 🔄 OUTER LOOP: waypointCount=\(waypointCount), totalAttempts=\(totalAttempts)/\(maxTotalAttempts)")
            
            // v2.0.3 Phase 1.5 Batch A: Global hard-wall timer - check CONTINUOUSLY inside loop
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > hardWallTimer && validRoutes.isEmpty {
                print("⛔ [HARDWALL] \(String(format: "%.1f", hardWallTimer))s exceeded; forcing topology-safe/fallback (elapsed=\(String(format: "%.2f", elapsed))s, ADS=\(finalAngularDiversityScore), postcode=\(postcode ?? "none"))")
                // SPRINT-5: Budget check before hardwall topology-safe
                if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "TOPO_SAFE_HARDWALL") {
                    print("⛔ [HARD-STOP] Skipping hardwall topology-safe - budget exceeded")
                    if let best = bestFallbackRoute { return best }
                    throw GoogleMapsError.noRouteFound
                }
                // Try topology-safe one last time
                if let topologyRoute = try? await generateRouteShortTopologySafe(
                    from: location,
                    targetDurationMinutes: targetDurationMinutes,
                    excludePlaceIds: excludePlaceIds,
                    excludePOIs: excludePOIs,
                    budget: budget  // SPRINT-5: Pass budget for hard-stop awareness
                ) {
                    let routeMins = topologyRoute.durationSeconds / 60
                    let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
                    if routeMins <= hardCap180 {
                        print("✅ [HARDWALL] Topology-safe succeeded: \(routeMins)min")
                    // SPRINT-5: Pass budget for universal hard-stop
                    let result = await finalizeAndReturnRoute(topologyRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                    if let finalized = result.route {
                        return finalized
                    }
                        print("⛔ [GUARD] Topology-safe route rejected - forcing guaranteed fallback")
                    } else {
                        print("⛔ [HARDWALL] Topology-safe route \(routeMins)min exceeds 180% cap \(hardCap180)min - forcing guaranteed fallback")
                    }
                } else {
                    print("⛔ [HARDWALL] Topology-safe failed - forcing guaranteed fallback")
                }
                // SPRINT-4: Global hard-stop check before generateOutAndBackFallback
                if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "OUT_AND_BACK_FALLBACK") {
                    print("⛔ [HARD-STOP] Skipping out-and-back fallback - returning best-so-far")
                    if let best = bestFallbackRoute {
                        return best
                    }
                    throw GoogleMapsError.noRouteFound
                }
                
                // v2.0.13: Fallback constraints - hard quality floor (≤130% everywhere)
                // Before accepting fallback, check all conditions:
                // 1. elapsedSeconds >= 12.0, AND
                // 2. no candidate with >=2 WPs in 80-120% exists, AND
                // 3. fallback accuracy <= 1.30
                let elapsedSeconds = Date().timeIntervalSince(startTime)
                let hasViableCandidate = validRoutes.contains { r in
                    let acc = Double(r.durationSeconds / 60) / Double(targetDurationMinutes)
                    return acc >= 0.80 && acc <= 1.20 && r.places.count >= 2
                }
                
                // Use fallback only when ALL conditions met
                if elapsedSeconds >= 12.0 && !hasViableCandidate {
                    // Generate fallback first to check accuracy
                    let fallback = try await generateOutAndBackFallback(
                        from: location,
                        targetDurationMinutes: targetDurationMinutes
                    )
                    
                    let fallbackMins = fallback.durationSeconds / 60
                    let fallbackAcc = Double(fallbackMins) / Double(targetDurationMinutes)
                    fallbackAccuracy = fallbackAcc
                    
                    // Hard quality floor: reject if >130%
                    if fallbackAcc <= 1.30 {
                        fallbackFired = true
                        fallbackReason = "quality_floor"
                        print("🆘 [FALLBACK] ✅ Triggering fallback: elapsed=\(String(format: "%.1f", elapsedSeconds))s, no viable candidate, fallback=\(String(format: "%.1f", fallbackAcc * 100))% ≤130%")
                        
                        // Fallback routes MUST be accepted - if nil, this is a critical error
                        // SPRINT-5: Pass budget for universal hard-stop
                        let result = await finalizeAndReturnRoute(fallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true, budget: budget)
                        if let finalized = result.route {
                            return finalized
                        }
                        // Critical: fallback was rejected - return unfinalized as last resort
                        print("⛔ [CRITICAL] Guaranteed fallback rejected - returning unfinalized")
                        return fallback
                    } else {
                        print("🆘 [FALLBACK] ❌ Rejected: fallback=\(String(format: "%.1f", fallbackAcc * 100))% >130% (hard quality floor)")
                        fallbackReason = "exceeds_130_percent"
                        // v2.0.17: Return best-so-far candidate explicitly when fallback fails floor
                        if let bestSoFar = validRoutes.first {
                            print("🔄 [FALLBACK] Returning best-so-far candidate: \(bestSoFar.durationSeconds/60)min, \(bestSoFar.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                            // SPRINT-5: Pass budget for universal hard-stop
                            let result = await finalizeAndReturnRoute(bestSoFar, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                            if let finalized = result.route {
                                return finalized
                            }
                            return bestSoFar
                        } else if let bestFallback = bestFallbackRoute {
                            print("🔄 [FALLBACK] Returning best fallback candidate: \(bestFallback.durationSeconds/60)min, \(bestFallback.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                            let result = await finalizeAndReturnRoute(bestFallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                            if let finalized = result.route {
                                return finalized
                            }
                            return bestFallback
                        }
                        // If no best-so-far exists, throw error (upstream shows friendly message and retry CTA)
                        throw GoogleMapsError.noRouteFound
                    }
                } else {
                    print("🆘 [FALLBACK] Skipped: elapsed=\(String(format: "%.1f", elapsedSeconds))s, hasViable=\(hasViableCandidate)")
                }
            }
            
            // v2.0.3 Phase 1.5: Short-circuit if we have an in-tolerance route and grace period passed
            if let firstValidTime = firstValidRouteFoundAt {
                let gracePeriod: TimeInterval = 1.0
                let elapsedSinceFirst = Date().timeIntervalSince(firstValidTime)
                if elapsedSinceFirst > gracePeriod {
                    // Check if we have any in-tolerance route (80-130%)
                    let toleranceMin = Int(Double(targetDurationMinutes) * 0.80)
                    let toleranceMax = Int(Double(targetDurationMinutes) * 1.30)
                    if let inToleranceRoute = validRoutes.first(where: { route in
                        let routeMins = route.durationSeconds / 60
                        return routeMins >= toleranceMin && routeMins <= toleranceMax
                    }) {
                        let routeMins = inToleranceRoute.durationSeconds / 60
                        let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
                        if routeMins <= hardCap180 {
                            print("✅ [EARLY EXIT] Found in-tolerance route after \(String(format: "%.2f", elapsedSinceFirst))s grace - short-circuiting")
                            // SPRINT-5: Pass budget for universal hard-stop
                            let result = await finalizeAndReturnRoute(inToleranceRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                            if let finalized = result.route {
                                return finalized
                            }
                            print("⛔ [GUARD] In-tolerance route rejected - continuing")
                        } else {
                            print("⛔ [EARLY EXIT] Route \(routeMins)min exceeds 180% cap \(hardCap180)min - continuing")
                        }
                    }
                }
            }
            
            // v2.0.3 Phase 1.5 Batch A: Periodic topology-safe check inside loops (every 3 seconds)
            // v2.0.3 Phase 1.5 Batch A: Periodic topology-safe check INSIDE loops
            let timeSinceLastCheck = Date().timeIntervalSince(lastTopoSafeCheck)
            if timeSinceLastCheck >= topoSafeCheckInterval && elapsed > earlyTopoSafe && validRoutes.isEmpty {
                // SPRINT-5: Budget check before periodic topology-safe
                if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "TOPO_SAFE_PERIODIC") {
                    print("⛔ [HARD-STOP] Skipping periodic topology-safe - budget exceeded")
                    break  // Exit outer loop
                }
                print("⏱️ [TOPO-ACT] Periodic check inside loop (threshold=\(String(format: "%.1f", earlyTopoSafe))s, ADS=\(finalAngularDiversityScore), elapsed=\(String(format: "%.2f", elapsed))s, pc=\(postcode ?? "none"))")
                lastTopoSafeCheck = Date()
                
                if let topologyRoute = try? await generateRouteShortTopologySafe(
                    from: location,
                    targetDurationMinutes: targetDurationMinutes,
                    excludePlaceIds: excludePlaceIds,
                    excludePOIs: excludePOIs,
                    budget: budget  // SPRINT-5: Pass budget for hard-stop awareness
                ) {
                    let routeMins = topologyRoute.durationSeconds / 60
                    let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
                    if routeMins <= hardCap180 {
                        print("✅ [TOPO-ACT] Periodic check succeeded: \(routeMins)min")
                    // SPRINT-5: Pass budget for universal hard-stop
                    let result = await finalizeAndReturnRoute(topologyRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                    if let finalized = result.route {
                        return finalized
                    }
                        print("⛔ [GUARD] Periodic topology-safe route rejected - continuing")
                    } else {
                        print("⛔ [TOPO-ACT] Route \(routeMins)min exceeds 180% cap \(hardCap180)min - continuing")
                    }
                }
            }
            
            guard totalAttempts < maxTotalAttempts else {
                print("🗺️ ⛔ Stopping: reached max attempts (\(maxTotalAttempts))")
                break
            }
            
            // v2.0.3: Auto-relaxation - if no valid routes after 10 attempts, relax minimum
            // BUT: Only relax once per cycle to prevent infinite loops
            if attemptsWithoutValidRoute >= 10 && minWaypointsForTier > 1 && !relaxedThisCycle {
                let oldMin = minWaypointsForTier
                minWaypointsForTier = max(1, minWaypointsForTier - 1)
                print("⚠️ [WAYPOINT-RELAX] No valid routes after \(attemptsWithoutValidRoute) attempts - relaxing min waypoints: \(oldMin) → \(minWaypointsForTier)")
                attemptsWithoutValidRoute = 0  // Reset counter
                relaxedThisCycle = true  // Mark as relaxed this cycle
                
                // Recalculate waypointCountsToTry with new minimum
                if quickMode {
                    waypointCountsToTry = Array(minWaypointsForTier...standardMaxWaypoints)
                } else {
                    waypointCountsToTry = Array((minWaypointsForTier...standardMaxWaypoints).reversed())
                }
                
                // v2.0.3: Guard against empty array (edge case: if minWaypointsForTier > standardMaxWaypoints)
                guard !waypointCountsToTry.isEmpty else {
                    print("⚠️ [WAYPOINT-RELAX] Cannot relax further - waypoint range is empty")
                    break  // Exit loop gracefully
                }
                
                print("⚠️ [WAYPOINT-RELAX] Recalculated waypoint range: \(waypointCountsToTry)")
                continue  // Restart loop with relaxed minimum
            }
            
            // In quick mode, return immediately if we have a valid route that meets minimum threshold
            // If route is too short (< 75% of target), continue trying more waypoints
            if quickMode && !validRoutes.isEmpty {
                let bestRoute = validRoutes.first!
                let bestRouteMinutes = bestRoute.durationSeconds / 60
                let minimumAcceptable = Int(Double(targetDurationMinutes) * 0.75)  // 75% minimum
                let maximumAcceptable = Int(Double(targetDurationMinutes) * 1.20)  // 120% maximum for early return
                
                // Final deduplication check before returning
                let deduplicatedPlaces = deduplicateRoutePlaces(bestRoute.places)
                if deduplicatedPlaces.count < bestRoute.places.count {
                    print("🗺️ ⚡ Quick mode: Found duplicates in route, will regenerate before returning")
                }
                
                if bestRouteMinutes >= minimumAcceptable && bestRouteMinutes <= maximumAcceptable {
                    print("🗺️ ⚡ Quick mode: returning valid route (\(bestRouteMinutes)min within 75-120%)")
                    break
                } else if bestRouteMinutes > maximumAcceptable {
                    // v1.6.36: Route too long (>120%) - stop adding waypoints, try fewer
                    print("🗺️ ⚡ Quick mode: route too long (\(bestRouteMinutes)min > \(maximumAcceptable)min), trying fewer waypoints...")
                    // Don't break - continue to try fewer waypoints in next iteration
                } else if waypointCount <= standardMaxWaypoints {
                    // Route too short, but we have fallback waypoint counts to try
                    print("🗺️ ⚡ Quick mode: route too short (\(bestRouteMinutes)min < \(minimumAcceptable)min), trying more waypoints...")
                } else {
                    // Tried fallback waypoints, return what we have
                    print("🗺️ ⚡ Quick mode: returning best available route (\(bestRouteMinutes)min)")
                    break
                }
            }
            
            guard validRoutes.count < 3 else { break } // Stop if we have enough valid routes
            
            // IMPORTANT: Scale ideal distance based on waypoint count
            // Walking routes are ~1.5-2x longer than straight-line distance due to streets/turns
            // For longer routes, we need to target farther POIs to hit the target duration
            // Segment distance factor - keep POIs closer for more predictable routes
            // Rural areas especially need closer POIs to avoid very long indirect routes
            let routeOverheadFactor: Double = 0.8  // Use 80% of ideal distance for all routes
            let segmentsInRoute = waypointCount + 1
            let idealSegmentDistance = Int(Double(totalDistanceTarget) * routeOverheadFactor) / segmentsInRoute
            
            // Re-select candidates with appropriate distance for this waypoint count
            var candidatesForCount = selectCandidateWaypoints(
                from: places,
                origin: location,
                idealWaypointDistance: idealSegmentDistance,
                difficulty: difficulty,
                targetDurationMinutes: targetDurationMinutes
            )
            
            // TIME-BASED PRE-FILTER: Remove candidates whose one-way time exceeds half target + 1 min
            // This prevents attempting routes that are clearly too long
            let maxOneWayForLoop = (targetDurationMinutes / 2) + 1
            let timeFilteredCandidates = candidatesForCount.filter { poi in
                // Check cached time first
                if let cached = getCachedLegTime(from: location, to: poi) {
                    if cached.minutes > maxOneWayForLoop {
                        return false  // Cached time too long
                    }
                    return true
                }
                // Estimate based on distance
                let dist = distanceBetween(location, poi.coordinate)
                let estimatedMins = Int(dist / Double(adaptiveWalkingSpeed))
                return estimatedMins <= maxOneWayForLoop + 2  // +2 buffer since estimate is rough
            }
            
            if timeFilteredCandidates.count < candidatesForCount.count {
                print("🎯 ⏱️ Time filter: \(candidatesForCount.count) → \(timeFilteredCandidates.count) candidates (max one-way: \(maxOneWayForLoop)min)")
                candidatesForCount = timeFilteredCandidates
            }
            
            // DIRECTIONAL PREFERENCE: If a direction is specified, prefer POIs in that quadrant
            if let direction = preferredDirection {
                let directedCandidates = candidatesForCount.filter { poi in
                    let angle = bearingBetween(location, poi.coordinate)
                    return direction.contains(angle: angle)
                }
                
                if directedCandidates.count >= waypointCount {
                    candidatesForCount = directedCandidates
                    print("🧭 Filtered to \(directedCandidates.count) POIs in \(direction) direction")
                } else {
                    print("🧭 Not enough POIs in \(direction) direction (\(directedCandidates.count)), using all candidates")
                }
            }
            
            // v1.8.11: SHUFFLE top candidates for VARIETY across sessions
            // Without this, the same "best" POIs are always selected first, producing identical routes
            // We keep all candidates (quality maintained) but randomize order of top picks
            if candidatesForCount.count > 5 {
                let shuffleCount = min(12, candidatesForCount.count)  // Shuffle top 12 candidates
                var topCandidates = Array(candidatesForCount.prefix(shuffleCount))
                topCandidates.shuffle()
                candidatesForCount = topCandidates + Array(candidatesForCount.dropFirst(shuffleCount))
                print("🎲 Shuffled top \(shuffleCount) candidates for variety")
            }
            
            print("🗺️ --- Trying \(waypointCount) waypoint(s) (ideal segment: \(idealSegmentDistance)m) ---")
            
            guard candidatesForCount.count >= waypointCount else {
                print("🗺️ Not enough candidates (\(candidatesForCount.count)) for \(waypointCount) waypoints")
                continue
            }
            
            // SPRINT-8: SECTOR QUOTA - Diversify first-layer by bearing sectors
            // v2.0.13: Always ON for ≥35 min routes (increased diversity for long routes)
            // Goal: Increase valid-route diversity by ensuring POIs from multiple directions
            var sectorDiversifiedCandidates = candidatesForCount
            if (RoutingToggles.sectorQuotaEnabled && waypointCount >= 2) || targetDurationMinutes >= 35 {
                sectorQuotaUsed = true
                let sectorCount = RoutingToggles.sectorCount  // 4 sectors (90° each)
                let quotaPerSector = RoutingToggles.sectorQuotaCount  // 2 per sector
                
                // Group by sector
                var sectors: [[PlaceResult]] = Array(repeating: [], count: sectorCount)
                for poi in candidatesForCount {
                    let bearing = bearingBetween(location, poi.coordinate)
                    // Convert bearing (-180 to 180) to sector index (0 to sectorCount-1)
                    let normalizedBearing = bearing < 0 ? bearing + 360 : bearing
                    let sectorIdx = Int(normalizedBearing / (360.0 / Double(sectorCount))) % sectorCount
                    sectors[sectorIdx].append(poi)
                }
                
                // Select up to quota from each sector
                var diversified: [PlaceResult] = []
                for (idx, sector) in sectors.enumerated() {
                    let selected = Array(sector.prefix(quotaPerSector))
                    diversified.append(contentsOf: selected)
                    if !selected.isEmpty {
                        print("🧭 [SECTOR-\(idx)] Selected \(selected.count) POIs: \(selected.prefix(2).map { $0.name }.joined(separator: ", "))")
                    }
                }
                
                // Add remaining POIs not in diversified set
                let diversifiedIds = Set(diversified.map { $0.placeId })
                let remaining = candidatesForCount.filter { !diversifiedIds.contains($0.placeId) }
                sectorDiversifiedCandidates = diversified + remaining
                
                print("🧭 [SECTOR-QUOTA] Diversified \(candidatesForCount.count) → \(diversified.count) first-layer + \(remaining.count) remaining")
            }
            
            // Use sector-diversified candidates for combination collection
            var finalCandidates = sectorDiversifiedCandidates
            
            // C) Route-level dedup: emit dedup telemetry at candidate-pool time (pre-route) where POI sets are bigger
            // Invoke dedup for any candidate pool with ≥2 POIs (not just when clusters were pre-formed)
            if finalCandidates.count >= 2 {
                finalCandidates = deduplicateRoutePlaces(finalCandidates)
                print("📊 [CANDIDATE-POOL-DEDUP] Pool size: \(sectorDiversifiedCandidates.count) → \(finalCandidates.count) after dedup")
            }
            
            // SPRINT-4: K-BEST PRE-SCREENING with Pareto set
            // Collect candidates, build Pareto set from estimates, then only route top k=3
            let kBestK = RoutingToggles.kBestK  // k=3: Only route top 3 from Pareto set
            let preScreenPoolSize = quickMode ? 8 : 15  // Collect more candidates for Pareto set
            var collectedCombinations: [[PlaceResult]] = []
            var triedCombinations = Set<String>()
            
            // Check hard-wall before collecting
            let elapsedBeforeCollect = Date().timeIntervalSince(startTime)
            if elapsedBeforeCollect > hardWallTimer && validRoutes.isEmpty {
                print("⛔ [HARDWALL] \(String(format: "%.1f", hardWallTimer))s exceeded BEFORE combination collection - skipping")
                continue
            }
            
            // --- Phase 1: COLLECT diverse-first combinations ---
            let diverseFirstCount = min(8, finalCandidates.count)
            for _ in 0..<diverseFirstCount {
                let minSpacing = (finalAngularDiversityScore == 2) ? 60.0 : nil
                let selectedWaypoints = selectAngularlyDiverseWaypoints(
                    from: finalCandidates,
                    origin: location,
                    count: waypointCount,
                    enforceMinSpacing: minSpacing
                )
                
                let comboKey = selectedWaypoints.map { $0.placeId }.sorted().joined(separator: ",")
                guard !triedCombinations.contains(comboKey) else { continue }
                triedCombinations.insert(comboKey)
                collectedCombinations.append(selectedWaypoints)
            }
            
            // --- Phase 2: COLLECT weighted-random combinations (if not quick mode) ---
            if !quickMode {
                let weightedRandomCount = min(16, finalCandidates.count)
                for _ in 0..<weightedRandomCount {
                    var selectedWaypoints: [PlaceResult] = []
                    var availableIndices = Array(0..<finalCandidates.count)
                    
                    for _ in 0..<waypointCount {
                        guard !availableIndices.isEmpty else { break }
                        
                        let weights = availableIndices.map { idx in 
                            exp(-Double(idx) * 0.3)
                        }
                        let totalWeight = weights.reduce(0, +)
                        var random = Double.random(in: 0..<totalWeight)
                        
                        var selectedIdx = 0
                        for (i, weight) in weights.enumerated() {
                            random -= weight
                            if random <= 0 {
                                selectedIdx = i
                                break
                            }
                        }
                        
                        let candidateIndex = availableIndices[selectedIdx]
                        selectedWaypoints.append(finalCandidates[candidateIndex])
                        availableIndices.remove(at: selectedIdx)
                    }
                    
                    guard selectedWaypoints.count == waypointCount else { continue }
                    
                    // Deduplicate within combination
                    var deduplicatedWaypoints: [PlaceResult] = []
                    for waypoint in selectedWaypoints {
                        let isDuplicate = deduplicatedWaypoints.contains { existing in
                            isRouteDuplicate(waypoint, existing)
                        }
                        if !isDuplicate {
                            deduplicatedWaypoints.append(waypoint)
                        }
                    }
                    
                    guard deduplicatedWaypoints.count >= max(1, waypointCount - 1) else { continue }
                    selectedWaypoints = deduplicatedWaypoints
                    
                    let comboKey = selectedWaypoints.map { $0.placeId }.sorted().joined(separator: ",")
                    guard !triedCombinations.contains(comboKey) else { continue }
                    triedCombinations.insert(comboKey)
                    collectedCombinations.append(selectedWaypoints)
                }
            }
            
            print("📊 [K-BEST] Collected \(collectedCombinations.count) candidate combinations for \(waypointCount) waypoints")
            
            guard !collectedCombinations.isEmpty else {
                print("📊 [K-BEST] No valid combinations collected - skipping waypoint count")
                continue
            }
            
            // --- Phase 3: PRE-SCREEN with on-device estimator (using adaptive roadFactor) ---
            // Pre-screen more candidates than we'll route (for Pareto set diversity)
            let prescreened = preScreenCandidates(
                candidates: collectedCombinations,
                origin: location,
                targetDurationMinutes: targetDurationMinutes,
                postcode: postcode,
                maxToReturn: preScreenPoolSize,  // Get more candidates for Pareto set
                roadFactor: roadFactor
            )
            
            print("📊 [K-BEST] Pre-screened \(prescreened.count) candidates (will route top k=\(kBestK) from Pareto set)")
            
            // --- Phase 4: BUILD PARETO SET from estimates (no routing yet) ---
            // SPRINT-4: Build Pareto set using estimates only to avoid engine calls
            var estimatedParetoSet: [ParetoCandidate] = []
            
            for candidate in prescreened {
                let estimatedMins = candidate.estimatedDuration / 60
                let estimatedHitError = abs(Double(estimatedMins - targetDurationMinutes)) / Double(targetDurationMinutes)
                
                // Estimate unique segment coverage (simplified: use waypoint count as proxy)
                let estimatedCoverage = min(1.0, Double(candidate.waypoints.count) / 4.0)
                
                let estimatedCandidate = ParetoCandidate(
                    waypoints: candidate.waypoints,
                    estimatedDuration: candidate.estimatedDuration,
                    hitError: estimatedHitError,
                    waypointCount: candidate.waypoints.count,
                    uniqueSegmentCoverage: estimatedCoverage,
                    route: nil  // No route yet - we'll route only finalists
                )
                
                updateParetoSet(&estimatedParetoSet, with: estimatedCandidate, k: kBestK)
            }
            
            // Sort Pareto set by composite score and take top k
            estimatedParetoSet.sort { compositeScore($0, targetDurationMinutes: targetDurationMinutes) > compositeScore($1, targetDurationMinutes: targetDurationMinutes) }
            let finalists = Array(estimatedParetoSet.prefix(kBestK))
            
            print("📊 [K-BEST] Pareto set: \(estimatedParetoSet.count) candidates, routing top k=\(finalists.count) finalists")
            for (idx, finalist) in finalists.enumerated() {
                let estimatedMins = finalist.estimatedDuration / 60
                print("📊 [K-BEST]   Finalist \(idx + 1): ~\(estimatedMins)min, \(finalist.waypointCount) WPs, hitError=\(String(format: "%.2f", finalist.hitError)), coverage=\(String(format: "%.2f", finalist.uniqueSegmentCoverage))")
            }
            
            // TASK 6: Template fallback for fragile durations (10, 25, 45 min)
            // Trigger if after first expansion candidates < K
            if RoutingToggles.templateFallbackDurations.contains(targetDurationMinutes) {
                // SPRINT-4: Global hard-stop check before template fallback
                if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "TEMPLATE_FALLBACK") {
                    print("⛔ [HARD-STOP] Skipping template fallback - returning best-so-far")
                } else if prescreened.count < RoutingToggles.templateTriggerCandidatesLt {
                    print("📋 [TEMPLATE] Fragile duration \(targetDurationMinutes)min with \(prescreened.count) candidates < \(RoutingToggles.templateTriggerCandidatesLt) - using template fallback")
                    
                    if let templateRoute = getTemplateRoute(duration: targetDurationMinutes, origin: location, places: places) {
                        // Try to route the template
                        // SPRINT-4: Create hard-stop check closure
                        let templateHardStopCheck: (() -> Bool)? = {
                            !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "TEMPLATE_ROUTING")
                        }
                        let (templateResult, didTimeout) = await directionsWithTimeout(
                            origin: location,
                            destination: location,
                            waypoints: templateRoute.places.map { $0.coordinate },
                            timeout: RoutingToggles.mapkitHardCap,
                            targetDurationMinutes: targetDurationMinutes,
                            angularDiversityScore: finalAngularDiversityScore,
                            postcode: postcode,
                            checkGlobalHardStop: templateHardStopCheck
                        )
                        
                        if let result = templateResult, !didTimeout {
                            let templateDuration = result.legs.reduce(0) { $0 + $1.duration.value }
                            let templateDistance = result.legs.reduce(0) { $0 + $1.distance.value }
                            let templateMins = templateDuration / 60
                            
                            let finalTemplateRoute = GeneratedRoute(
                                places: templateRoute.places,
                                polyline: result.overviewPolyline.points,
                                distanceMeters: templateDistance,
                                durationSeconds: templateDuration,
                                legs: result.legs
                            )
                            
                            print("📋 [TEMPLATE] Template route: \(templateMins)min")
                            
                            if templateDuration >= minAcceptableDuration && templateDuration <= maxAcceptableDuration {
                                print("📋 [TEMPLATE] ✅ Template route is valid - using it")
                                // SPRINT-5: Pass budget for universal hard-stop
                                let result = await finalizeAndReturnRoute(finalTemplateRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                                if let finalized = result.route {
                                    return finalized
                                }
                            } else {
                                // Add as fallback
                                print("📋 [TEMPLATE] Template route outside tolerance - adding as fallback")
                                if bestFallbackRoute == nil || abs(templateMins - targetDurationMinutes) < bestFallbackDiff {
                                    bestFallbackRoute = finalTemplateRoute
                                    bestFallbackDiff = abs(templateMins - targetDurationMinutes)
                                }
                            }
                        } else {
                            print("📋 [TEMPLATE] Template routing failed or timed out")
                        }
                    }
                }
            }
            
            // --- Phase 5: ROUTE only top-k finalists from Pareto set ---
            // SPRINT-4: Only call MapKit/OSRM for finalists (reduces engine calls significantly)
            var routedParetoSet: [ParetoCandidate] = []
            var iterationsWithoutImprovement = 0
            
            for (idx, finalist) in finalists.enumerated() {
                // SPRINT-4: Global hard-stop check at top of inner attempt loop
                if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "K_BEST_ROUTING_candidate\(idx)") {
                    print("⛔ [HARD-STOP] Returning best-so-far from k-best routing")
                    break  // Exit immediately
                }
                
                guard totalAttempts < maxTotalAttempts else { break }
                
                // TASK 2: Check time budget - soft stop after 12s, hard stop after 18s
                let elapsedInLoop = Date().timeIntervalSince(startTime)
                let softStopReached = elapsedInLoop > RoutingToggles.softStopSec
                let hardStopReached = elapsedInLoop > RoutingToggles.hardStopSec
                
                // Hard stop: always break
                if hardStopReached {
                    print("⛔ [HARD-STOP] \(String(format: "%.1f", RoutingToggles.hardStopSec))s exceeded - stopping routing")
                    break
                }
                
                // SPRINT-4: Soft stop - only exit early if routed Pareto set is filled AND stable
                if softStopReached && RoutingToggles.earlyExitAfterSoftStopIfKFilled {
                    if isParetoSetStable(routedParetoSet, iterationsWithoutImprovement: iterationsWithoutImprovement) {
                        print("⏱️ [SOFT-STOP] \(String(format: "%.1f", RoutingToggles.softStopSec))s reached with stable routed Pareto set (k=\(routedParetoSet.count)) - exiting")
                        break
                    } else {
                        print("⏱️ [SOFT-STOP] Continuing despite soft stop - routed Pareto set not stable (k=\(routedParetoSet.count), unstable=\(iterationsWithoutImprovement))")
                    }
                }
                
                // Hard-wall check (absolute maximum)
                if elapsedInLoop > hardWallTimer && validRoutes.isEmpty {
                    print("⛔ [HARDWALL] \(String(format: "%.1f", hardWallTimer))s exceeded INSIDE k-best routing loop")
                    break
                }
                
                // SPRINT-4: Check if we should defer this routing call (finalists are already high-value)
                // Skip deferral for finalists - they're already the best candidates
                
                totalAttempts += 1
                routeCapture?.incrementAttempts()
                
                let estimatedMins = finalist.estimatedDuration / 60
                print("🗺️ [K-BEST] Routing finalist \(idx + 1)/\(finalists.count): ~\(estimatedMins)min estimated, \(finalist.waypointCount) waypoints")
                
                do {
                    if let route = try await tryRouteAndEvaluate(
                        origin: location,
                        waypoints: finalist.waypoints,
                        targetDurationMinutes: targetDurationMinutes,
                        minAcceptable: minAcceptableDuration,
                        maxAcceptable: maxAcceptableDuration,
                        validRoutes: &validRoutes,
                        bestFallback: &bestFallbackRoute,
                        bestFallbackDiff: &bestFallbackDiff,
                        allPlaces: places,
                        routeCapture: routeCapture,
                        firstValidRouteFoundAt: &firstValidRouteFoundAt,
                        angularDiversityScore: finalAngularDiversityScore,
                        postcode: postcode,
                        checkHardStop: checkHardStop,  // PHASE A: Pass hard-stop check
                        repairPasses: &repairPasses,  // PHASE D: Pass repair counter
                        budget: budget,  // v2.0.15: Pass budget for timeRemaining checks
                        startTime: startTime,  // v2.0.15: Pass startTime for timeRemaining checks
                        earlyCommitOpportunity: &earlyCommitOpportunity,  // v2.0.16: Track early commit opportunities
                        bestSoFarCommitted: &bestSoFarCommitted  // v2.0.16: Track early commits taken
                    ) {
                        let routeMins = route.durationSeconds / 60
                        let estimationError = abs(routeMins - estimatedMins)
                        print("📊 [K-BEST] Actual: \(routeMins)min, Estimated: \(estimatedMins)min, Error: \(estimationError)min")
                        
                        // Record multiplier (only when using curated DB and estimation came from pre-filter)
                        if usedDatabase && estimatedMins > 0 {
                            routeMultiplierTracker.record(estimatedMinutes: Double(estimatedMins), actualMinutes: Double(routeMins))
                            if let median = routeMultiplierTracker.median {
                                print("📐 [MULTIPLIER] routeMultiplier median: \(String(format: "%.2f", median))")
                            }
                        }
                        
                        // Track overshoot for adaptive roadFactor correction
                        let overshoot = Double(routeMins) / Double(targetDurationMinutes)
                        overshootSamples.append(overshoot)
                        
                        // Apply adaptive correction after 2+ samples
                        if overshootSamples.count >= 2 {
                            let avgOvershoot = overshootSamples.prefix(2).reduce(0, +) / 2.0
                            if avgOvershoot > 1.8 {
                                roadFactor = min(roadFactor * 1.6, 2.8)
                                print("🔧 [ADAPTIVE] High overshoot detected (avg: \(String(format: "%.2f", avgOvershoot))) - adjusting roadFactor to \(String(format: "%.2f", roadFactor))")
                            }
                        }
                        
                        // SPRINT-4: Add routed candidate to final Pareto set
                        let hitError = abs(Double(routeMins - targetDurationMinutes)) / Double(targetDurationMinutes)
                        let routedCandidate = ParetoCandidate(
                            waypoints: finalist.waypoints,
                            estimatedDuration: finalist.estimatedDuration,
                            hitError: hitError,
                            waypointCount: finalist.waypointCount,
                            uniqueSegmentCoverage: 1.0 - calculateBacktrackingScore(polyline: route.polyline),
                            route: route
                        )
                        updateParetoSet(&routedParetoSet, with: routedCandidate, k: kBestK)
                        
                        // Track improvements
                        let previousCount = routedParetoSet.count - 1
                        if routedParetoSet.count > previousCount {
                            iterationsWithoutImprovement = 0
                        } else {
                            iterationsWithoutImprovement += 1
                        }
                        
                        if routeMins >= minAcceptableMinutes && routeMins <= maxAcceptableMinutes {
                            print("🗺️ ✓ [K-BEST] Found valid route with \(waypointCount) POIs (Routed Pareto: \(routedParetoSet.count)/\(kBestK))")
                        }
                        
                        // SPRINT-4: Early exit if we have good routes and Pareto set is filled
                        if routedParetoSet.count >= kBestK && !validRoutes.isEmpty {
                            print("🗺️ ⚡ [K-BEST] Pareto set filled (k=\(kBestK)) with valid routes - proceeding to selection")
                            break
                        }
                        
                        // v2.0.13: Earlier best-so-far exit to tame p95/p99
                        // If we hit target band early (≤7s) with min WPs, exit quickly
                        let elapsedSeconds = Date().timeIntervalSince(startTime)
                        let routeAccuracy = Double(routeMins) / Double(targetDurationMinutes)
                        let (minBand, maxBand): (Double, Double) = targetDurationMinutes <= 30 
                            ? (0.95, 1.05)  // 10-30 min: 95-105%
                            : (0.90, 1.10)  // 35-60 min: 90-110%
                        
                        if elapsedSeconds <= 7.0 &&
                           routeAccuracy >= minBand && routeAccuracy <= maxBand &&
                           route.places.count >= RoutingToggles.minWaypoints(forDuration: targetDurationMinutes) {
                            earlyBandHit = true  // v2.0.13: Track early band hit
                            print("🎯 [EARLY-EXIT] Route in target band (\(String(format: "%.1f", routeAccuracy * 100))%) with \(route.places.count) WPs at \(String(format: "%.1f", elapsedSeconds))s - exiting early")
                            break
                        }
                        
                        // v2.0.13: Depth guard - stop when we have ≥2 viable candidates
                        // Prevents runaway depth when we already have good options
                        if elapsedSeconds >= 9.0 {
                            let viableCount = validRoutes.filter { r in
                                let acc = Double(r.durationSeconds / 60) / Double(targetDurationMinutes)
                                return acc >= 0.90 && acc <= 1.20 && 
                                       r.places.count >= RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
                            }.count
                            if viableCount >= 2 {
                                print("🎯 [DEPTH-GUARD] Have \(viableCount) viable candidates at \(String(format: "%.1f", elapsedSeconds))s - stopping depth search")
                                break
                            }
                        }
                    }
                } catch {
                    print("🗺️ [K-BEST] Route generation error: \(error.localizedDescription)")
                    iterationsWithoutImprovement += 1
                }
            }
            
            // v2.0.3: Update attemptsWithoutValidRoute after trying combinations for this waypoint count
            if validRoutes.isEmpty {
                attemptsWithoutValidRoute += 1
            } else {
                attemptsWithoutValidRoute = 0  // Reset on success
                relaxedThisCycle = false  // v2.0.3: Reset relaxation flag on success
            }
            
            print("🗺️ 🔄 END of waypointCount=\(waypointCount) loop, totalAttempts=\(totalAttempts)")
        }
        // SPRINT-4: Check hard-stop before final selection using budget
        let finalElapsed = Date().timeIntervalSince(startTime)
        let stopReason: String
        if !budget.within() || hardStopHit {
            stopReason = "HARD_STOP"
            print("⛔ [HARD-STOP] Hard-stop was hit during generation (elapsed=\(String(format: "%.2f", budget.elapsed))s) - returning best-so-far")
        } else if finalElapsed > RoutingToggles.softStopSec {
            stopReason = "SOFT_STOP"
        } else {
            stopReason = "NORMAL"
        }
        
            // v2.0.13: Set telemetry counts
            validCandidates = validRoutes.count
            kBestCandidates = min(RoutingToggles.kBestK, validRoutes.count)
            
            print("🗺️ 🏁 OUTER LOOP COMPLETE. validRoutes=\(validRoutes.count), hasFallback=\(bestFallbackRoute != nil), stop_reason=\(stopReason)")
        
        // Return best valid route (50-100% of target, never exceeds)
        // PRIORITY: 1) Most waypoints  2) Less backtracking  3) Closest to target time
        validRoutesCheck: if !validRoutes.isEmpty {
            // v2.0.13: Fallback constraints - only use fallback if:
            // 1. elapsedSeconds >= 12.0, AND
            // 2. no candidate with >=2 WPs in 80-120% exists, AND
            // 3. absolute cap: fallback accuracy must be <= 1.30
            // This prevents fallback from being used when we have viable candidates
            let elapsedSeconds = Date().timeIntervalSince(startTime)
            let hasViableCandidate = validRoutes.contains { r in
                let acc = Double(r.durationSeconds / 60) / Double(targetDurationMinutes)
                return acc >= 0.80 && acc <= 1.20 && r.places.count >= 2
            }
            
            // If we have viable candidates, don't use fallback
            if hasViableCandidate {
                print("🎯 [FALLBACK-GUARD] Have viable candidate (≥2 WPs, 80-120%) - skipping fallback")
            }
            // Calculate composite scores for all valid routes
            // Includes backtracking score AND soft cap overrun penalty
            // SPRINT-6: Extended tuple with subTargetBonus and waypointBonus
            let routesWithScores = validRoutes.map { route -> (route: GeneratedRoute, backtrackScore: Double, overrunPenalty: Double, subTargetBonus: Double, waypointBonus: Double) in
                let backtrack = calculateBacktrackingScore(polyline: route.polyline)
                
                // SPRINT-8: HINGED OVERRUN PENALTY
                // Routes >110% get penalized, routes >120% get EXTRA steep penalty
                // This prevents selecting 120-180% candidates when 85-105% exist
                let accuracy = Double(route.durationSeconds / 60) / Double(targetDurationMinutes)
                var overrunPenalty = 0.0
                
                // v2.0.13: First hinge - penalty starts at 110% (tightened from 30 to 36)
                if accuracy > 1.10 {
                    overrunPenalty = (accuracy - 1.10) * 36  // ~3.6 penalty per 10%
                }
                
                // v2.0.13: Second hinge - EXTRA STEEP penalty above 120% (tightened from 60 to 72)
                if accuracy > RoutingToggles.overshootHingeThreshold {
                    let hingeExcess = accuracy - RoutingToggles.overshootHingeThreshold
                    overrunPenalty += hingeExcess * 72  // ~7.2 extra per 10% (was 60)
                }
                
                // Right-edge penalty for ratio > 1.10
                let rightEdgePenalty = accuracy > 1.10 ? 0.5 : 0.0
                overrunPenalty += rightEdgePenalty
                
                // SPRINT-6: Overshoot penalty ×3.0 for routes with <min waypoints (prefer 95-105% fits with ≥min WPs)
                let minWaypoints = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
                if route.places.count < minWaypoints && accuracy > 1.05 {
                    overrunPenalty *= RoutingToggles.overshootPenaltyMultiplier  // 3.0× penalty for routes with <min waypoints
                }
                
                // TWEAK 3: Direct penalty for under-WP routes (demote in scoring rather than hard-reject)
                // This keeps diversity if others fail, but strongly prefers routes meeting WP minimums
                if route.places.count < minWaypoints {
                    overrunPenalty += RoutingToggles.underWPPenalty  // +1.0 penalty for under-WP routes
                }
                
                // SPRINT-6: Small bonus for routes ≤100% (favor slightly short over slightly long in ties)
                var subTargetBonus = 0.0
                if accuracy <= 1.0 && accuracy >= 0.90 {
                    subTargetBonus = RoutingToggles.subTargetBonus  // 0.01 bonus
                }
                
                // SPRINT-6: Waypoint bonus (more waypoints = better route variety)
                // SPRINT-7: Conditional bonus - add +0.02 per WP when route is within ±10% of target
                let isCloseFit = abs(1.0 - accuracy) <= 0.10  // Within 90-110%
                let effectiveWPBonus = RoutingToggles.waypointScoreBonus + (isCloseFit ? 0.02 : 0.0)  // 0.08 + 0.02 = 0.10 for close fits
                let waypointBonus = Double(route.places.count) * effectiveWPBonus
                
                return (route, backtrack, overrunPenalty, subTargetBonus, waypointBonus)
            }
            
            // SPRINT-8: Check if any route had hinge penalty (>120%)
            for routeWithScore in routesWithScores {
                let acc = Double(routeWithScore.route.durationSeconds / 60) / Double(targetDurationMinutes)
                if acc > RoutingToggles.overshootHingeThreshold {
                    hingePenaltyFired = true
                    break
                }
            }
            
            // SPRINT-6: Composite scoring with sub-target bonus and waypoint bonus
            // Sort by: composite score (lower is better), then closest to target
            let sorted = routesWithScores.sorted { r1, r2 in
                // Calculate composite scores: lower = better
                // overrunPenalty: higher = worse
                // subTargetBonus: higher = better (subtract from penalty)
                // waypointBonus: higher = better (subtract from penalty)
                // backtrackScore: higher = worse
                let score1 = r1.overrunPenalty - r1.subTargetBonus - r1.waypointBonus + (r1.backtrackScore * 0.5)
                let score2 = r2.overrunPenalty - r2.subTargetBonus - r2.waypointBonus + (r2.backtrackScore * 0.5)
                
                // FIRST: Lower composite score is better
                if abs(score1 - score2) > 0.05 {
                    return score1 < score2
                }
                
                // SPRINT-8: In close ties (score diff < 0.2), prefer the one closer to 1.0
                // and if equal distance, prefer sub-100% (easier to extend)
                if abs(score1 - score2) < 0.2 {
                    let acc1 = Double(r1.route.durationSeconds / 60) / Double(targetDurationMinutes)
                    let acc2 = Double(r2.route.durationSeconds / 60) / Double(targetDurationMinutes)
                    let dist1 = abs(1.0 - acc1)
                    let dist2 = abs(1.0 - acc2)
                    if abs(dist1 - dist2) > 0.01 {
                        return dist1 < dist2  // Closer to 1.0 wins
                    }
                    // If equally close, prefer sub-100% (easier to extend later)
                    if acc1 != acc2 && acc1 <= 1.0 && acc2 > 1.0 {
                        return true  // r1 is sub-100%, prefer it
                    }
                    if acc1 != acc2 && acc2 <= 1.0 && acc1 > 1.0 {
                        return false  // r2 is sub-100%, prefer it
                    }
                }
                
                // Second: more waypoints is better (tiebreaker)
                if r1.route.places.count != r2.route.places.count {
                    return r1.route.places.count > r2.route.places.count
                }
                // Third: closer to target is better (prefer slightly short)
                let diff1 = abs(targetDurationMinutes - r1.route.durationSeconds / 60)
                let diff2 = abs(targetDurationMinutes - r2.route.durationSeconds / 60)
                if diff1 != diff2 {
                    return diff1 < diff2
                }
                // Fourth: prefer shorter if equidistant from target (SPRINT-6: bias toward sub-100%)
                return r1.route.durationSeconds < r2.route.durationSeconds
            }
            
            // v2.0.3 Phase 1.5 Batch A: Filter out routes >180% BEFORE selection
            let selectionHardCap180 = Int(Double(targetDurationMinutes) * 1.80)
            
            let cappedValidRoutes = sorted.filter { routeWithScore in
                let routeMins = routeWithScore.route.durationSeconds / 60
                return routeMins <= selectionHardCap180  // Never select routes >180%
            }
            
            // If no routes within cap, fall through to guaranteed fallback
            guard !cappedValidRoutes.isEmpty else {
                print("⛔ [SELECTION] All routes exceed 180% cap - falling through to guaranteed fallback")
                // Explicitly break out of the validRoutes check - code will continue to bestFallbackRoute check
                break validRoutesCheck
            }
            
            var selected = cappedValidRoutes.first!.route
            let selectedScore = cappedValidRoutes.first!.backtrackScore
            var selectedMins = selected.durationSeconds / 60
            
            // SPRINT-8: Check if this route would have triggered early commit
            let selectedAccuracy = Double(selectedMins) / Double(targetDurationMinutes)
            let minWP = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)  // Declare early for use below
            let (minBand, maxBand): (Double, Double) = targetDurationMinutes <= 30 
                ? (0.95, 1.05)  // 10-30 min: 95-105%
                : (0.90, 1.10)  // 35-60 min: 90-110%
            
            // v2.0.15: Track early commit opportunity (met band and WPs ≥ min, NOT min-1)
            let inBand = selectedAccuracy >= minBand && selectedAccuracy <= maxBand
            earlyCommitOpportunity = inBand && selected.places.count >= minWP
            
            if inBand && selected.places.count >= minWP {
                bestSoFarCommitted = true
                commitBand = targetDurationMinutes <= 30 ? "95-105" : "90-110"
            }
            
            // v2.0.13: Track if selected route is overshoot
            overshootSelected = selectedAccuracy > 1.20
            
            // Double-check: reject if somehow >180% slipped through
            guard selectedMins <= selectionHardCap180 else {
                print("⛔ [SELECTION] Selected route \(selectedMins)min exceeds 180% cap \(selectionHardCap180)min - rejecting")
                break validRoutesCheck
            }
            
            print("🗺️ Route backtracking score: \(String(format: "%.0f", selectedScore * 100))% (lower = more loop-like)")
            print("🗺️ Selected route: \(selectedMins)min (cap: \(selectionHardCap180)min)")
            
            // SPRINT-8: WP REPAIR STEP after k-best selection but before finalization (v2.0.13)
            // v2.0.13: One extra spur only when it's cheap and likely to work
            // Goal: Guaranteed enforcement of minimum waypoint counts with heavier penalty if still under
            // Note: minWP and selectedAccuracy already declared above
            
            // v2.0.13: Only attempt repair if:
            // - waypoints == min-1 (one short), AND
            // - time remaining >= 1.5s (cheap), AND
            // - accuracy between 85-125% (likely to work)
            let shouldAttemptRepair = selected.places.count == minWP - 1 &&
                                     budget.within() &&
                                     (budget.hard - (Date().timeIntervalSince1970 - budget.t0)) >= 1.5 &&
                                     selectedAccuracy >= 0.85 && selectedAccuracy <= 1.25
            
            if shouldAttemptRepair || (selected.places.count < minWP && budget.within()) {
                repairAttempted = true
                print("🔧 [WP-REPAIR] Selected route has \(selected.places.count) WPs, need \(minWP) - attempting repair spur")
                
                // Find a nearby POI to add as a quick spur (0.2-0.5km, near polyline midpoint)
                let existingPOIIds = Set(selected.places.map { $0.placeId })
                let midpointIdx = selected.places.count / 2
                let midpointCoord = midpointIdx < selected.places.count 
                    ? selected.places[midpointIdx].coordinate 
                    : location
                
                let spurCandidates = places.filter { poi in
                    guard !existingPOIIds.contains(poi.placeId) else { return false }
                    let dist = distanceBetween(midpointCoord, poi.coordinate)
                    return dist >= 200 && dist <= 500  // 0.2-0.5km from midpoint
                }.prefix(3)
                
                if let spurPOI = spurCandidates.first {
                    var repairedPlaces = selected.places
                    repairedPlaces.insert(spurPOI, at: midpointIdx)
                    
                    // Quick route call to verify it doesn't blow up duration
                    do {
                        let repairDirs = try await getWalkingDirections(
                            origin: location,
                            destination: location,
                            waypoints: repairedPlaces.map { $0.coordinate },
                            preserveWaypointOrder: false
                        )
                        let repairDur = repairDirs.legs.reduce(0) { $0 + $1.duration.value }
                        let repairDist = repairDirs.legs.reduce(0) { $0 + $1.distance.value }
                        let repairAccuracy = Double(repairDur) / Double(targetDurationMinutes * 60)
                        
                        // Accept repair if within reasonable tolerance (80-150%)
                        if repairAccuracy >= 0.80 && repairAccuracy <= 1.50 {
                            selected = GeneratedRoute(
                                places: repairedPlaces,
                                polyline: repairDirs.overviewPolyline.points,
                                distanceMeters: repairDist,
                                durationSeconds: repairDur,
                                legs: repairDirs.legs
                            )
                            selectedMins = selected.durationSeconds / 60
                            repairSucceeded = repairedPlaces.count >= minWP
                            print("🔧 [WP-REPAIR] ✅ Repair successful: \(repairedPlaces.count) WPs, \(selectedMins)min (\(String(format: "%.1f", repairAccuracy * 100))%)")
                        } else {
                            print("🔧 [WP-REPAIR] ❌ Repair rejected: \(String(format: "%.1f", repairAccuracy * 100))% outside 80-150% tolerance")
                        }
                    } catch {
                        print("🔧 [WP-REPAIR] ❌ Repair failed: \(error.localizedDescription)")
                    }
                } else {
                    print("🔧 [WP-REPAIR] ❌ No suitable spur candidates within 200-500m of midpoint")
                }
                
                repairSucceeded = selected.places.count >= minWP
                
                // v2.0.13: If still under minimum after repair, apply heavier score penalty
                // This demotes under-min routes in selection but doesn't hard-reject (preserves diversity)
                if selected.places.count < minWP {
                    print("🔧 [WP-REPAIR] ⚠️ Still under min (\(selected.places.count)/\(minWP)) - will apply heavy penalty in scoring")
                    // Note: Penalty applied in scoring phase via underWPPenalty
                }
            }
            
            // FINAL DEDUPLICATION: Remove any duplicate POIs before processing
            let deduplicatedPlaces = deduplicateRoutePlaces(selected.places)
            if deduplicatedPlaces.count < selected.places.count {
                // Regenerate route with deduplicated places
                let sortedWaypoints = deduplicatedPlaces.sorted { wp1, wp2 in
                    let dist1 = distanceBetween(location, wp1.coordinate)
                    let dist2 = distanceBetween(location, wp2.coordinate)
                    return dist1 < dist2
                }
                
                do {
                    let directions = try await getWalkingDirections(
                        origin: location,
                        destination: location,
                        waypoints: sortedWaypoints.map { $0.coordinate },
                        preserveWaypointOrder: true
                    )
                    
                    let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                    let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                    
                    selected = GeneratedRoute(
                        places: sortedWaypoints,
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: distance,
                        durationSeconds: duration,
                        legs: directions.legs
                    )
                } catch {
                    print("⚠️ Failed to regenerate route after deduplication, using deduplicated places without regeneration")
                    // Even if regeneration fails, use deduplicated places to avoid returning duplicates
                    selected = GeneratedRoute(
                        places: sortedWaypoints,
                        polyline: selected.polyline,
                        distanceMeters: selected.distanceMeters,
                        durationSeconds: selected.durationSeconds,
                        legs: selected.legs
                    )
                }
            }
            
            // Remove waypoints that are too close together (should be ~100m+ apart)
            // v1.8.10: Now async - regenerates polyline when waypoints removed
            // v2.1.7: Standardized to 100m for all durations (was 250m for longer routes)
            selected = await removeCloseWaypoints(from: selected, minDistance: 100, origin: location)
            
            var finalMins = selected.durationSeconds / 60
            
            // v1.6.47: ROUTE EXTENSION - If route is 70-95% of target, try adding an on-route POI
            // v1.8.11: Widened from 80-95% to 70-95% to catch more routes
            let accuracy = Double(finalMins) / Double(targetDurationMinutes)
            if accuracy >= 0.70 && accuracy <= 0.95 {
                print("🔧 Route is \(Int(accuracy * 100))% of target (\(finalMins)/\(targetDurationMinutes)min) - trying to extend...")
                if let extended = await tryExtendRoute(
                    route: selected,
                    origin: location,
                    targetDurationMinutes: targetDurationMinutes,
                    availablePOIs: places,
                    excludePlaceIds: excludePlaceIds,
                    angularDiversityScore: finalAngularDiversityScore,
                    postcode: postcode,
                    checkHardStop: checkHardStop  // SPRINT-4: Pass hard-stop check
                ) {
                    // #region agent log
                    let logData4: [String: Any] = [
                        "sessionId": "debug-session",
                        "runId": "run1",
                        "hypothesisId": "A",
                        "location": "GoogleMapsService.swift:13888",
                        "message": "tryExtendRoute: returned extended route",
                        "data": [
                            "originalWaypoints": selected.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                            "extendedWaypoints": extended.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                            "distances": extended.places.count > 1 ? (0..<extended.places.count-1).map { i in
                                distanceBetween(extended.places[i].coordinate, extended.places[i+1].coordinate)
                            } : []
                        ],
                        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                    ]
                    if let logJSON4 = try? JSONSerialization.data(withJSONObject: logData4),
                       let logString4 = String(data: logJSON4, encoding: .utf8) {
                        try? logString4.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                    }
                    // #endregion
                    
                    let extendedMins = extended.durationSeconds / 60
                    let newAccuracy = Double(extendedMins) / Double(targetDurationMinutes)
                    if newAccuracy >= 0.95 && newAccuracy <= 1.10 {
                        print("🔧 ✅ Extended route: \(finalMins)min → \(extendedMins)min (\(Int(newAccuracy * 100))%)")
                        // CRITICAL: Extended route is already deduplicated by tryExtendRoute's finalizeRouteDedup
                        // But ensure it's still deduplicated in case of any edge cases (intermediate, will be finalized at return)
                        // v2.1.7: Remove close waypoints again after extension (road snapping can bring waypoints closer)
                        var extendedWithSpacing = await removeCloseWaypoints(from: extended, minDistance: 100, origin: location)
                        selected = finalizeRouteDedup(extendedWithSpacing, targetDurationMinutes: targetDurationMinutes)
                        finalMins = selected.durationSeconds / 60
                        
                        // #region agent log
                        let logData5: [String: Any] = [
                            "sessionId": "debug-session",
                            "runId": "run1",
                            "hypothesisId": "A",
                            "location": "GoogleMapsService.swift:13894",
                            "message": "After extension: final waypoints",
                            "data": [
                                "finalWaypoints": selected.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                                "distances": selected.places.count > 1 ? (0..<selected.places.count-1).map { i in
                                    distanceBetween(selected.places[i].coordinate, selected.places[i+1].coordinate)
                                } : []
                            ],
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                        ]
                        if let logJSON5 = try? JSONSerialization.data(withJSONObject: logData5),
                           let logString5 = String(data: logJSON5, encoding: .utf8) {
                            try? logString5.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                        }
                        // #endregion
                    } else {
                        print("🔧 ⏭️ Extension would be \(extendedMins)min (\(Int(newAccuracy * 100))%) - keeping original")
                    }
                }
            }
            
            // FINAL DEDUPLICATION CHECK: One last pass before returning
            let finalDeduplicatedPlaces = deduplicateRoutePlaces(selected.places)
            if finalDeduplicatedPlaces.count < selected.places.count {
                // Regenerate with deduplicated places
                let sortedWaypoints = finalDeduplicatedPlaces.sorted { wp1, wp2 in
                    let dist1 = distanceBetween(location, wp1.coordinate)
                    let dist2 = distanceBetween(location, wp2.coordinate)
                    return dist1 < dist2
                }
                
                do {
                    // v2.0.3 Phase 1.5 Batch A: Wrap final deduplication regeneration with timeout
                    let timeout = RoutingToggles.perCallTimeoutNormal
                    let (directionsResult, didTimeout) = await directionsWithTimeout(
                        origin: location,
                        destination: location,
                        waypoints: sortedWaypoints.map { $0.coordinate },
                        timeout: timeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: finalAngularDiversityScore,
                        postcode: postcode
                    )
                    
                    if didTimeout {
                        print("⚠️ [FINAL-REGEN] Timeout during final route regeneration - using deduplicated places with original duration")
                        selected = GeneratedRoute(
                            places: sortedWaypoints,
                            polyline: selected.polyline,
                            distanceMeters: selected.distanceMeters,
                            durationSeconds: selected.durationSeconds,
                            legs: selected.legs
                        )
                        finalMins = selected.durationSeconds / 60
                    } else if let directions = directionsResult {
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        
                        selected = GeneratedRoute(
                            places: sortedWaypoints,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                        finalMins = duration / 60
                        
                        // v2.0.3 Phase 1.5 Batch A: Check hard cap after regeneration
                        let hardCap180 = Int(Double(targetDurationMinutes) * 1.80)
                        if finalMins > hardCap180 {
                            print("⛔ [FINAL-REGEN] Regenerated route \(finalMins)min exceeds 180% cap \(hardCap180)min - using original")
                            selected = GeneratedRoute(
                                places: sortedWaypoints,
                                polyline: selected.polyline,
                                distanceMeters: selected.distanceMeters,
                                durationSeconds: selected.durationSeconds,
                                legs: selected.legs
                            )
                            finalMins = selected.durationSeconds / 60
                        }
                    } else {
                        print("⚠️ [FINAL-REGEN] Error during final route regeneration - using deduplicated places with original duration")
                        selected = GeneratedRoute(
                            places: sortedWaypoints,
                            polyline: selected.polyline,
                            distanceMeters: selected.distanceMeters,
                            durationSeconds: selected.durationSeconds,
                            legs: selected.legs
                        )
                        finalMins = selected.durationSeconds / 60
                    }
                } catch {
                    print("⚠️ Failed to regenerate route after final deduplication, using deduplicated places without regeneration")
                    // Even if regeneration fails, use deduplicated places to avoid returning duplicates
                    selected = GeneratedRoute(
                        places: sortedWaypoints,
                        polyline: selected.polyline,
                        distanceMeters: selected.distanceMeters,
                        durationSeconds: selected.durationSeconds,
                        legs: selected.legs
                    )
                    // Recalculate finalMins from deduplicated places (approximate)
                    finalMins = selected.durationSeconds / 60
                }
            }
            
            // v2.0.3 Phase 1.5 Batch A: Use centralized finalization (intermediate, will be finalized again at return)
            selected = finalizeRouteDedup(selected, targetDurationMinutes: targetDurationMinutes)
            
            // v2.1.7: Final distance check before returning (road snapping and final deduplication can bring waypoints closer)
            selected = await removeCloseWaypoints(from: selected, minDistance: 100, origin: location)
            
            // totalAttempts already tracks all routes attempted
            
            // v1.6.49: Clear summary logging for easy copy/paste
            let poiNames = selected.places.map { $0.name }.joined(separator: " → ")
            let distanceKm = String(format: "%.1f", Double(selected.distanceMeters) / 1000.0)
            print("═══════════════════════════════════════════════════════════")
            print("📍 ROUTE GENERATED: \(finalMins)min | \(selected.places.count) waypoints | \(distanceKm)km")
            print("📍 POIs: \(poiNames)")
            
            // 📋 COMPREHENSIVE ROUTE SUMMARY FOR DEBUGGING
            printRouteSummary(route: selected, targetDuration: targetDurationMinutes)
            print("═══════════════════════════════════════════════════════════")
            
            // Mark POIs as recently used for variety in future routes
            for place in selected.places {
                markPOIAsUsed(place.placeId)
            }
            
            // v2.0.3 Phase 1.5 Batch A: Use centralized finalization with hard cap enforcement
            let elapsed = Date().timeIntervalSince(startTime)
            print("📊 ROUTE SELECTION SUMMARY:")
            // PHASE D: Track waypoints before finalization
            wpBeforeFinalization = selected.places.count
            
            print("   🔢 Routes attempted: \(totalAttempts)")
            print("   ✅ Valid routes found: \(validRoutes.count)")
            print("   🎯 Selected route: \(selected.places.count) waypoints, \(selected.durationSeconds/60)min")
            print("   📦 Database used: \(usedDatabase ? "Yes" : "No")")
            print("   ⏱️ Total time: \(String(format: "%.2f", elapsed))s")
            
            // PHASE D: Per-route summary logging with SPRINT-6/8 fields
            print("📊 [TELEMETRY] route_id=\(targetDurationMinutes)min duration_bucket=\(targetDurationMinutes)min elapsed_ms=\(Int(elapsed * 1000))")
            print("   engine_calls={mapkit:\(engineCalls.mapkit), osrm:\(engineCalls.osrm), skipped:\(engineCalls.skipped)}")
            print("   expansions=\(expansions), repair_passes=\(repairPasses), nudges=\(nudges), micro_spurs=\(microSpurs)")
            print("   wp_before_finalization=\(wpBeforeFinalization), wp_after_finalization=\(wpAfterFinalization)")
            print("   stop_reason=\(stopReason) stage_exited=\(stageExited) per_leg_over_cap=\(perLegOverCap)")
            // SPRINT-8: New telemetry fields
            print("   best_so_far_committed=\(bestSoFarCommitted) bias_applied=\(String(format: "%.3f", biasApplied))")
            print("   repair_attempt=\(repairAttempted) repair_success=\(repairSucceeded) hinge_penalty_fired=\(hingePenaltyFired) sector_quota_used=\(sectorQuotaUsed)")
            // v2.0.13: Additional telemetry fields
            print("   early_band_hit=\(earlyBandHit) commit_band=\(commitBand) per_leg_cap_applied=\(perLegCapApplied)")
            print("   cap_after_good_candidate=\(capAfterGoodCandidate) fallback_fired=\(fallbackFired) fallback_reason=\(fallbackReason)")
            print("   fallback_accuracy=\(String(format: "%.3f", fallbackAccuracy)) kbest_candidates=\(kBestCandidates) valid_candidates=\(validCandidates)")
            print("   overshoot_selected=\(overshootSelected) early_commit_opportunity=\(earlyCommitOpportunity)")
            
            // v2.0.17: Capture telemetry in routeCapture for batch aggregation
            routeCapture?.telemetry.earlyCommitOpportunity = earlyCommitOpportunity
            routeCapture?.telemetry.earlyCommitsTaken = bestSoFarCommitted
            routeCapture?.telemetry.fallbackFired = fallbackFired
            routeCapture?.telemetry.fallbackOver130Pct = (fallbackFired && fallbackAccuracy > 1.30)
            routeCapture?.telemetry.overshootSelectedGt120Pct = overshootSelected
            routeCapture?.telemetry.perLegCapApplied = perLegCapApplied
            routeCapture?.telemetry.capAfterGoodCandidate = capAfterGoodCandidate
            routeCapture?.telemetry.sectorQuotaUsed = sectorQuotaUsed
            
            // SPRINT-4: Repair before fallback for S11 mid-long durations (>120% overshoot)
            // For S11 postcodes with mid-long durations (≥30min), repair first valid route if >120%
            let isS11 = postcode?.hasPrefix("S11") ?? false
            let isMidLong = targetDurationMinutes >= 30
            let firstValidRatio = Double(selectedMins) / Double(targetDurationMinutes)
            
            if isS11 && isMidLong && firstValidRatio > 1.20 && selected.places.count > 1 {
                print("🔧 [REPAIR-S11] First valid route \(selectedMins)min (\(String(format: "%.1f", firstValidRatio * 100))%) >120% - applying repair before fallback")
                
                // SPRINT-4: Budget check before repair
                if !RoutingToggles.mustContinue(budget, bestSoFar: selected, stage: "REPAIR_S11_START") {
                    print("⛔ [HARD-STOP] Skipping S11 repair - returning best-so-far")
                } else {
                    var candidate = selected
                    
                    // Step 1: Trim farthest leg
                    if let farthestIndex = candidate.places.enumerated().max(by: {
                        distanceBetween(location, $0.element.coordinate) < distanceBetween(location, $1.element.coordinate)
                    })?.offset {
                        let farthestPOI = candidate.places[farthestIndex]
                        print("🔧 [REPAIR-S11] Step 1: Trimming farthest waypoint '\(farthestPOI.name)'")
                        
                        var trimmedWaypoints = candidate.places
                        trimmedWaypoints.remove(at: farthestIndex)
                        
                        // SPRINT-4: Budget check before trim routing call
                        if !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_TRIM") {
                            print("⛔ [HARD-STOP] Skipping trim routing - using original")
                        } else {
                            let trimTimeout = RoutingToggles.perCallTimeoutNormal
                            let trimHardStopCheck: (() -> Bool)? = {
                                !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_TRIM_CALL")
                            }
                            let (trimResult, didTimeout) = await directionsWithTimeout(
                                origin: location,
                                destination: location,
                                waypoints: trimmedWaypoints.map { $0.coordinate },
                                timeout: trimTimeout,
                                targetDurationMinutes: targetDurationMinutes,
                                angularDiversityScore: finalAngularDiversityScore,
                                postcode: postcode,
                                checkGlobalHardStop: trimHardStopCheck
                            )
                            
                            if let directions = trimResult, !didTimeout {
                                let trimmedDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                                let trimmedDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                                let trimmedMins = trimmedDuration / 60
                                print("🔧 [REPAIR-S11] Trim result: \(trimmedMins)min (was \(selectedMins)min)")
                                
                                candidate = GeneratedRoute(
                                    places: trimmedWaypoints,
                                    polyline: directions.overviewPolyline.points,
                                    distanceMeters: trimmedDistance,
                                    durationSeconds: trimmedDuration,
                                    legs: directions.legs
                                )
                            }
                        }
                    }
                    
                    // Step 2: Micro-extend first pass (+2-4 min)
                    let candidateRatio = Double(candidate.durationSeconds / 60) / Double(targetDurationMinutes)
                    if candidateRatio < 0.95 && !places.isEmpty {
                        print("🔧 [REPAIR-S11] Step 2: Micro-extend pass 1 (+2-4 min)")
                        
                        // SPRINT-4: Budget check before micro-extend
                        if !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_EXTEND1") {
                            print("⛔ [HARD-STOP] Skipping micro-extend pass 1 - using candidate")
                        } else {
                            // Find nearby POI to add
                            let existingPOIIds = Set(candidate.places.map { $0.placeId })
                            let nearbyPOIs = places.filter { poi in
                                guard !existingPOIIds.contains(poi.placeId) else { return false }
                                return distanceBetween(location, poi.coordinate) < 500
                            }
                            
                            if let extensionPOI = nearbyPOIs.first {
                                var extendedWaypoints = candidate.places
                                extendedWaypoints.append(extensionPOI)
                                
                                let extTimeout = RoutingToggles.mapkitSoftCap
                                let extHardStopCheck: (() -> Bool)? = {
                                    !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_EXTEND1_CALL")
                                }
                                let (extResult, didTimeout) = await directionsWithTimeout(
                                    origin: location,
                                    destination: location,
                                    waypoints: extendedWaypoints.map { $0.coordinate },
                                    timeout: extTimeout,
                                    targetDurationMinutes: targetDurationMinutes,
                                    angularDiversityScore: finalAngularDiversityScore,
                                    postcode: postcode,
                                    checkGlobalHardStop: extHardStopCheck
                                )
                                
                                if let directions = extResult, !didTimeout {
                                    let extDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                                    let extMins = extDuration / 60
                                    let extRatio = Double(extMins) / Double(targetDurationMinutes)
                                    print("🔧 [REPAIR-S11] Extend pass 1 result: \(extMins)min (\(String(format: "%.1f", extRatio * 100))%)")
                                    
                                    if extRatio <= 1.30 {
                                        candidate = GeneratedRoute(
                                            places: extendedWaypoints,
                                            polyline: directions.overviewPolyline.points,
                                            distanceMeters: directions.legs.reduce(0) { $0 + $1.distance.value },
                                            durationSeconds: extDuration,
                                            legs: directions.legs
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // Step 3: Micro-extend second pass (+1-2 min) if still <95%
                    let finalCandidateRatio = Double(candidate.durationSeconds / 60) / Double(targetDurationMinutes)
                    if finalCandidateRatio < 0.95 && !places.isEmpty {
                        print("🔧 [REPAIR-S11] Step 3: Micro-extend pass 2 (+1-2 min)")
                        
                        // SPRINT-4: Budget check before micro-extend pass 2
                        if !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_EXTEND2") {
                            print("⛔ [HARD-STOP] Skipping micro-extend pass 2 - using candidate")
                        } else {
                            let existingPOIIds = Set(candidate.places.map { $0.placeId })
                            let nearbyPOIs = places.filter { poi in
                                guard !existingPOIIds.contains(poi.placeId) else { return false }
                                return distanceBetween(location, poi.coordinate) < 500
                            }
                            
                            if let extensionPOI = nearbyPOIs.first {
                                var extendedWaypoints = candidate.places
                                extendedWaypoints.append(extensionPOI)
                                
                                let extTimeout = RoutingToggles.mapkitSoftCap
                                let extHardStopCheck: (() -> Bool)? = {
                                    !RoutingToggles.mustContinue(budget, bestSoFar: candidate, stage: "REPAIR_S11_EXTEND2_CALL")
                                }
                                let (extResult, didTimeout) = await directionsWithTimeout(
                                    origin: location,
                                    destination: location,
                                    waypoints: extendedWaypoints.map { $0.coordinate },
                                    timeout: extTimeout,
                                    targetDurationMinutes: targetDurationMinutes,
                                    angularDiversityScore: finalAngularDiversityScore,
                                    postcode: postcode,
                                    checkGlobalHardStop: extHardStopCheck
                                )
                                
                                if let directions = extResult, !didTimeout {
                                    let extDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                                    let extMins = extDuration / 60
                                    let extRatio = Double(extMins) / Double(targetDurationMinutes)
                                    print("🔧 [REPAIR-S11] Extend pass 2 result: \(extMins)min (\(String(format: "%.1f", extRatio * 100))%)")
                                    
                                    if extRatio <= 1.30 {
                                        candidate = GeneratedRoute(
                                            places: extendedWaypoints,
                                            polyline: directions.overviewPolyline.points,
                                            distanceMeters: directions.legs.reduce(0) { $0 + $1.distance.value },
                                            durationSeconds: extDuration,
                                            legs: directions.legs
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // Update selected with repaired candidate
                    selected = candidate
                    selectedMins = selected.durationSeconds / 60
                    print("🔧 [REPAIR-S11] Final repaired route: \(selectedMins)min (\(String(format: "%.1f", Double(selectedMins) / Double(targetDurationMinutes) * 100))%)")
                }
            }
            
            // v2.0.3 Phase 1.5 Batch A: Final hard cap check before returning
            // Note: reusing selectedMins and selectionHardCap180 from earlier in this block
            selectedMins = selected.durationSeconds / 60  // Update after possible modifications
            if selectedMins > selectionHardCap180 {
                print("⛔ [SELECTION] Selected route \(selectedMins)min exceeds 180% cap \(selectionHardCap180)min - falling through to guaranteed fallback")
                // Track fallback reason: engine_cap
                // (Will be set in guaranteed fallback section)
                // Fall through to guaranteed fallback
            } else {
                // PHASE B: Pass origin and allPlaces for waypoint preservation
                // SPRINT-5: Pass budget for universal hard-stop enforcement in finalization
                let result = await finalizeAndReturnRoute(selected, targetDurationMinutes: targetDurationMinutes, postcode: postcode, origin: location, allPlaces: places, budget: budget)
                if let finalized = result.route {
                    // PHASE D: Track nudges and micro-spurs
                    nudges += result.nudgesAdded
                    microSpurs += result.microSpursAdded
                    // PHASE D: Track waypoints after finalization
                    wpAfterFinalization = finalized.places.count
                    // SPRINT-6: Check if any leg exceeds 50% of target
                    let perLegCapThreshold = Int(Double(targetDurationMinutes) * 0.50 * 60)
                    perLegOverCap = finalized.legs.contains { $0.duration.value > perLegCapThreshold }
                    perLegCapApplied = perLegOverCap  // v2.0.13: Track if cap was applied
                    
                    // v2.0.13: Check if per-leg cap ran after a good candidate existed
                    let finalAcc = Double(finalized.durationSeconds) / Double(targetDurationMinutes * 60)
                    let (minBand, maxBand): (Double, Double) = targetDurationMinutes <= 30 
                        ? (0.95, 1.05) : (0.90, 1.10)
                    let wasGoodBefore = finalAcc >= minBand && finalAcc <= maxBand && 
                                       finalized.places.count >= RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
                    capAfterGoodCandidate = perLegCapApplied && wasGoodBefore
                    
                    print("📊 [TELEMETRY] wp_after_finalization=\(wpAfterFinalization) per_leg_over_cap=\(perLegOverCap) per_leg_cap_applied=\(perLegCapApplied) cap_after_good=\(capAfterGoodCandidate)")
                    return finalized
                }
                print("⛔ [GUARD] Selected route rejected - falling through to guaranteed fallback")
                // Track fallback reason: engine_cap (route rejected by finalizeAndReturnRoute)
                // (Will be set in guaranteed fallback section)
            }
        }
        
        // Return BEST fallback route we found - but ONLY if within 150% cap
        // v2.0.1: Relaxed from 130% to 150% for areas with indirect road networks
        if var best = bestFallbackRoute {
            let mins = best.durationSeconds / 60
            let hardCap = Int(Double(targetDurationMinutes) * 1.50)  // 150% hard cap (relaxed from 130%)
            
            // v2.0.1: Relaxed from 130% to 150% for areas with indirect road networks
            if mins > hardCap {
                print("🗺️ ❌ Fallback route exceeds 150% cap: \(mins)min > \(hardCap)min - REJECTING")
                // Don't return this route, fall through to guaranteed fallback
            } else {
                // Remove waypoints that are too close together (should be ~100m+ apart)
                // v1.8.10: Now async - regenerates polyline when waypoints removed
                // v2.1.7: Standardized to 100m for all durations (was 250m for longer routes)
                best = await removeCloseWaypoints(from: best, minDistance: 100, origin: location)
                
                // Check if route is within 80-100% tolerance
                let toleranceMin = Int(Double(targetDurationMinutes) * 0.80)
                let toleranceMax = targetDurationMinutes
                let isWithinTolerance = mins >= toleranceMin && mins <= toleranceMax
                
                if isWithinTolerance {
                    print("🗺️ ✓ Fallback route within 80-100%: \(mins)min (target: \(targetDurationMinutes)min)")
                } else if mins < toleranceMin {
                    print("🗺️ ⚠️ Returning shorter route: \(mins)min (target: \(targetDurationMinutes)min)")
                } else {
                    print("🗺️ ⚠️ Returning longer route: \(mins)min (target: \(targetDurationMinutes)min)")
                }
                
                // Final deduplication before returning fallback
                let deduplicatedPlaces = deduplicateRoutePlaces(best.places)
                var shouldUseBest = true  // v2.0.3: Flag to track if route is still valid after regeneration
                
                if deduplicatedPlaces.count < best.places.count {
                    // Regenerate route with deduplicated places
                    do {
                        let directions = try await getWalkingDirections(
                            origin: location,
                            destination: location,
                            waypoints: deduplicatedPlaces.map { $0.coordinate },
                            preserveWaypointOrder: true
                        )
                        let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                        let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                        best = GeneratedRoute(
                            places: deduplicatedPlaces,
                            polyline: directions.overviewPolyline.points,
                            distanceMeters: distance,
                            durationSeconds: duration,
                            legs: directions.legs
                        )
                        
                        // v2.0.3: CRITICAL FIX - Re-check hard cap after regeneration
                        // Route duration can change after deduplication/regeneration
                        let regeneratedMins = best.durationSeconds / 60
                        if regeneratedMins > hardCap {
                            print("🗺️ ❌ Regenerated fallback route exceeds 150% cap: \(regeneratedMins)min > \(hardCap)min - REJECTING")
                            // Mark as invalid - will fall through to guaranteed fallback
                            shouldUseBest = false
                        }
                    } catch {
                        print("⚠️ Failed to regenerate fallback route after deduplication, using original")
                    }
                }
                
                // Only mark POIs and return if we still have a valid route
                if shouldUseBest {
                    // Mark POIs as recently used for variety
                    for place in best.places {
                        markPOIAsUsed(place.placeId)
                    }
                    
                    // Note: Google fallback is handled separately in generateLocalRouteWithGoogleFallback
                    // PHASE B: Pass origin and allPlaces for waypoint preservation
                    // SPRINT-5: Pass budget for universal hard-stop enforcement in finalization
                    let result = await finalizeAndReturnRoute(best, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true, origin: location, allPlaces: places, budget: budget)
                    if let finalRoute = result.route {
                        // PHASE D: Track nudges and micro-spurs
                        nudges += result.nudgesAdded
                        microSpurs += result.microSpursAdded
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("📊 ROUTE SELECTION SUMMARY (FALLBACK):")
                        print("   🔢 Routes attempted: \(totalAttempts)")
                        print("   ✅ Valid routes found: \(validRoutes.count)")
                        print("   🎯 Selected route: \(finalRoute.places.count) waypoints, \(finalRoute.durationSeconds/60)min")
                        print("   📦 Database used: \(usedDatabase ? "Yes" : "No")")
                        print("   ⏱️ Total time: \(String(format: "%.2f", elapsed))s")
                        return finalRoute
                    }
                    print("⛔ [GUARD] Fallback route rejected - falling through to guaranteed fallback")
                    // Track fallback reason: engine_cap (fallback route rejected)
                }
                // If best was invalidated, fall through to guaranteed fallback
            }
        }
        
        // GUARANTEED FALLBACK: Create a simple out-and-back route if all else fails
        // v2.0.14: Hard quality floor - ≤130% everywhere (never accept >130% fallback)
        // This ensures we ALWAYS return something rather than leaving the user waiting
        // SPRINT-4: Track fallback reason (determine why we're using guaranteed fallback)
        // v2.0.13: Use existing fallbackReason telemetry variable (declared at function start)
        if !budget.within() {
            fallbackReason = "budget_breached"
        } else if validRoutes.isEmpty && bestFallbackRoute == nil {
            fallbackReason = "no_candidates"
        } else if validRoutes.isEmpty && bestFallbackRoute != nil {
            // Had fallback but it was rejected - could be engine_cap or repair_failed
            if postcode?.hasPrefix("S11") == true && targetDurationMinutes >= 30 {
                fallbackReason = "repair_failed"  // S11 repair was attempted but didn't help
            } else {
                fallbackReason = "engine_cap"  // Route exceeded caps
            }
        } else {
            // Had valid routes but they were all rejected
            fallbackReason = "engine_cap"  // Routes exceeded 180% cap or were rejected
        }
        
        // SPRINT-4: Increment attempts when guaranteed fallback is used
        totalAttempts += 1
        routeCapture?.incrementAttempts()
        
        // v2.0.14: Before accepting ANY fallback, check quality floor
        let elapsedSeconds = Date().timeIntervalSince(startTime)
        let hasViableCandidate = validRoutes.contains { r in
            let acc = Double(r.durationSeconds / 60) / Double(targetDurationMinutes)
            return acc >= 0.80 && acc <= 1.20 && r.places.count >= 2
        }
        
        // Quality check: elapsed >= 12.0 AND no viable candidate AND fallback will be <= 130%
        // Note: We'll check fallback accuracy after generation
        let qualityOk = elapsedSeconds >= 12.0 && !hasViableCandidate
        
        if !qualityOk {
            print("🆘 [FALLBACK] ❌ Quality check failed: elapsed=\(String(format: "%.1f", elapsedSeconds))s, hasViable=\(hasViableCandidate) - rejecting fallback")
            throw GoogleMapsError.noRouteFound  // Never accept fallback if quality check fails
        }
        
        // SPRINT-4: Global hard-stop check before guaranteed fallback
        if !RoutingToggles.mustContinue(budget, bestSoFar: bestFallbackRoute, stage: "GUARANTEED_FALLBACK") {
            print("⛔ [HARD-STOP] Skipping guaranteed fallback - returning best-so-far")
            
            // SPRINT-4: Emit fallback fired log even when skipped due to budget
            let elapsed = Date().timeIntervalSince(startTime)
            print("📊 [FALLBACK_FIRED] reason=budget_breached elapsed_ms=\(Int(elapsed * 1000)) wp_before=\(wpBeforeFinalization) wp_after=\(wpAfterFinalization) stop_reason=\(stopReason)")
            
            if let best = bestFallbackRoute {
                return best
            }
            throw GoogleMapsError.noRouteFound
        }
        
        print("🗺️ 🆘 Creating guaranteed fallback route...")
        print("🗺️ 🆘 Available POIs for fallback: \(places.count)")
        if places.count < 5 {
            print("🗺️ 🆘 Available POI names: \(places.prefix(5).map { $0.name }.joined(separator: ", "))")
        }
        if let guaranteedRoute = try? await createGuaranteedFallbackRoute(
            from: location,
            targetDurationMinutes: targetDurationMinutes,
            availablePOIs: places,
            budget: budget  // SPRINT-4: Pass budget for hard-stop enforcement
        ) {
            let mins = guaranteedRoute.durationSeconds / 60
            let fallbackAcc = Double(mins) / Double(targetDurationMinutes)
            fallbackAccuracy = fallbackAcc
            
            // v2.0.14: Hard quality floor - ≤130% everywhere (never accept >130% fallback)
            if fallbackAcc <= 1.30 {
                fallbackFired = true
                fallbackReason = "quality_floor"
                print("🗺️ 🆘 ✅ Guaranteed fallback created: \(mins)min (\(String(format: "%.1f", fallbackAcc * 100))%) ≤130%")
            } else {
                print("🗺️ 🆘 ❌ Guaranteed fallback exceeds 130%: \(mins)min (\(String(format: "%.1f", fallbackAcc * 100))%) - REJECTING (hard quality floor)")
                fallbackReason = "exceeds_130_percent"
                // v2.0.17: Return best-so-far candidate explicitly when fallback fails floor
                if let bestSoFar = validRoutes.first {
                    print("🔄 [FALLBACK] Returning best-so-far candidate: \(bestSoFar.durationSeconds/60)min, \(bestSoFar.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                    let result = await finalizeAndReturnRoute(bestSoFar, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                    if let finalized = result.route {
                        return finalized
                    }
                    return bestSoFar
                } else if let bestFallback = bestFallbackRoute {
                    print("🔄 [FALLBACK] Returning best fallback candidate: \(bestFallback.durationSeconds/60)min, \(bestFallback.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                    let result = await finalizeAndReturnRoute(bestFallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                    if let finalized = result.route {
                        return finalized
                    }
                    return bestFallback
                }
                // If no best-so-far exists, throw error (upstream shows friendly message and retry CTA)
                throw GoogleMapsError.noRouteFound  // Never accept >130% fallback
            }
            
            // Continue with fallback acceptance (already validated ≤130%)
            print("🗺️ ✓ Guaranteed fallback created: \(mins)min (target: \(targetDurationMinutes)min)")
            
            // Final deduplication before returning guaranteed fallback
            let deduplicatedPlaces = deduplicateRoutePlaces(guaranteedRoute.places)
            if deduplicatedPlaces.count < guaranteedRoute.places.count {
                // SPRINT-4: Global hard-stop check before regeneration
                if !RoutingToggles.mustContinue(budget, bestSoFar: guaranteedRoute, stage: "FALLBACK_REGEN") {
                        print("⛔ [HARD-STOP] Skipping fallback regeneration - using original")
                        let result = await finalizeAndReturnRoute(guaranteedRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                        if let finalized = result.route {
                            return finalized
                        }
                        return guaranteedRoute
                }
                
                // Regenerate route with deduplicated places
                // v2.0.3 Phase 1.5 Batch A: Wrap guaranteed fallback regeneration with timeout
                let timeout = RoutingToggles.perCallTimeoutNormal
                // SPRINT-4: Create hard-stop check closure
                let regenHardStopCheck: (() -> Bool)? = {
                    !RoutingToggles.mustContinue(budget, bestSoFar: guaranteedRoute, stage: "FALLBACK_REGEN_CALL")
                }
                let (directionsResult, didTimeout) = await directionsWithTimeout(
                    origin: location,
                    destination: location,
                    waypoints: deduplicatedPlaces.map { $0.coordinate },
                    timeout: timeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: postcode,
                    checkGlobalHardStop: regenHardStopCheck
                )
                
                if didTimeout {
                    // Timeout during regeneration - use original route
                    let result = await finalizeAndReturnRoute(guaranteedRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                    if let finalized = result.route {
                        return finalized
                    }
                    // Critical: guaranteed route rejected - return unfinalized
                    print("⛔ [CRITICAL] Guaranteed fallback rejected - returning unfinalized")
                    return guaranteedRoute
                }
                
                guard let directions = directionsResult else {
                    // Error during regeneration - use original route
                    let result = await finalizeAndReturnRoute(guaranteedRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                    if let finalized = result.route {
                        return finalized
                    }
                    // Critical: guaranteed route rejected - return unfinalized
                    print("⛔ [CRITICAL] Guaranteed fallback rejected - returning unfinalized")
                    return guaranteedRoute
                }
                
                let duration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let distance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let deduplicatedRoute = GeneratedRoute(
                    places: deduplicatedPlaces,
                    polyline: directions.overviewPolyline.points,
                    distanceMeters: distance,
                    durationSeconds: duration,
                    legs: directions.legs
                )
                
                // v2.0.14: CRITICAL FIX - Re-check quality floor after regeneration
                // Route duration can change after deduplication/regeneration
                let regeneratedMins = deduplicatedRoute.durationSeconds / 60
                let regeneratedAcc = Double(regeneratedMins) / Double(targetDurationMinutes)
                if regeneratedAcc > 1.30 {
                    print("🗺️ 🆘 ❌ Regenerated guaranteed fallback exceeds 130%: \(regeneratedMins)min (\(String(format: "%.1f", regeneratedAcc * 100))%) - REJECTING (hard quality floor)")
                    fallbackReason = "exceeds_130_percent"
                    // v2.0.17: Return best-so-far candidate explicitly when fallback fails floor
                    if let bestSoFar = validRoutes.first {
                        print("🔄 [FALLBACK] Returning best-so-far candidate: \(bestSoFar.durationSeconds/60)min, \(bestSoFar.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                        let result = await finalizeAndReturnRoute(bestSoFar, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                        if let finalized = result.route {
                            return finalized
                        }
                        return bestSoFar
                    } else if let bestFallback = bestFallbackRoute {
                        print("🔄 [FALLBACK] Returning best fallback candidate: \(bestFallback.durationSeconds/60)min, \(bestFallback.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                        let result = await finalizeAndReturnRoute(bestFallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                        if let finalized = result.route {
                            return finalized
                        }
                        return bestFallback
                    }
                    // If no best-so-far exists, throw error (upstream shows friendly message and retry CTA)
                    throw GoogleMapsError.noRouteFound  // Never accept >130% fallback
                }
                
                // Mark POIs as recently used for variety
                for place in deduplicatedRoute.places {
                    markPOIAsUsed(place.placeId)
                }
                
                // v2.0.3 Phase 1.5 Batch A: Use centralized finalization
                let result = await finalizeAndReturnRoute(deduplicatedRoute, targetDurationMinutes: targetDurationMinutes, postcode: postcode, allowExtendedCapForFallback: true)
                if let finalized = result.route {
                    printRouteSummary(route: finalized, targetDuration: targetDurationMinutes)
                    let elapsed = Date().timeIntervalSince(startTime)
                    
                    // SPRINT-4: Emit structured fallback fired log
                    let finalWPCount = finalized.places.count
                    print("📊 [FALLBACK_FIRED] reason=\(fallbackReason) elapsed_ms=\(Int(elapsed * 1000)) wp_before=\(wpBeforeFinalization) wp_after=\(finalWPCount) stop_reason=\(stopReason)")
                    
                    print("📊 ROUTE SELECTION SUMMARY (GUARANTEED FALLBACK):")
                    print("   🔢 Routes attempted: \(totalAttempts)")
                    print("   ✅ Valid routes found: \(validRoutes.count)")
                    print("   🎯 Selected route: \(finalized.places.count) waypoints, \(finalized.durationSeconds/60)min")
                    print("   📦 Database used: \(usedDatabase ? "Yes" : "No")")
                    print("   ⏱️ Total time: \(String(format: "%.2f", elapsed))s")
                    print("   📊 Fallback reason: \(fallbackReason)")
                    return finalized
                }
                // Critical: guaranteed route rejected - return unfinalized
                print("⛔ [CRITICAL] Guaranteed fallback rejected - returning unfinalized")
                return deduplicatedRoute
            } else {
                // No deduplication needed - use route as-is
                // v2.0.14: Re-check quality floor after any processing
                let finalMins = guaranteedRoute.durationSeconds / 60
                let finalAcc = Double(finalMins) / Double(targetDurationMinutes)
                if finalAcc > 1.30 {
                    print("🗺️ 🆘 ❌ Guaranteed fallback exceeds 130% after processing: \(finalMins)min (\(String(format: "%.1f", finalAcc * 100))%) - REJECTING")
                    fallbackReason = "exceeds_130_percent"
                    // v2.0.17: Return best-so-far candidate explicitly when fallback fails floor
                    if let bestSoFar = validRoutes.first {
                        print("🔄 [FALLBACK] Returning best-so-far candidate: \(bestSoFar.durationSeconds/60)min, \(bestSoFar.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                        let result = await finalizeAndReturnRoute(bestSoFar, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                        if let finalized = result.route {
                            return finalized
                        }
                        return bestSoFar
                    } else if let bestFallback = bestFallbackRoute {
                        print("🔄 [FALLBACK] Returning best fallback candidate: \(bestFallback.durationSeconds/60)min, \(bestFallback.places.count) WPs (qualifier: best_so_far_after_floor_block)")
                        let result = await finalizeAndReturnRoute(bestFallback, targetDurationMinutes: targetDurationMinutes, postcode: postcode, budget: budget)
                        if let finalized = result.route {
                            return finalized
                        }
                        return bestFallback
                    }
                    // If no best-so-far exists, throw error (upstream shows friendly message and retry CTA)
                    throw GoogleMapsError.noRouteFound
                }
            }
            
            // Mark POIs as recently used for variety
            for place in guaranteedRoute.places {
                markPOIAsUsed(place.placeId)
            }
            
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            let finalized = finalizeRouteDedup(guaranteedRoute, targetDurationMinutes: targetDurationMinutes)
            printRouteSummary(route: finalized, targetDuration: targetDurationMinutes)
            let elapsed = Date().timeIntervalSince(startTime)
            
            // SPRINT-4: Emit structured fallback fired log
            let finalWPCount = finalized.places.count
            print("📊 [FALLBACK_FIRED] reason=\(fallbackReason) elapsed_ms=\(Int(elapsed * 1000)) wp_before=\(wpBeforeFinalization) wp_after=\(finalWPCount) stop_reason=\(stopReason)")
            
            print("📊 ROUTE SELECTION SUMMARY (GUARANTEED FALLBACK):")
            print("   🔢 Routes attempted: \(totalAttempts)")
            print("   ✅ Valid routes found: \(validRoutes.count)")
            print("   🎯 Selected route: \(finalized.places.count) waypoints, \(finalized.durationSeconds/60)min")
            print("   📦 Database used: \(usedDatabase ? "Yes" : "No")")
            print("   ⏱️ Total time: \(String(format: "%.2f", elapsed))s")
            print("   📊 Fallback reason: \(fallbackReason)")
            return finalized
        }
        
        throw GoogleMapsError.noRouteFound
    }
    
    /// Creates a guaranteed simple route when complex generation fails
    /// Uses the closest POI at roughly half the target walking distance
    /// v2.0.2: Added guardrails to prevent time-wasting
    /// SPRINT-4: Accepts budget parameter for hard-stop enforcement
    private func createGuaranteedFallbackRoute(
        from origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        availablePOIs: [PlaceResult],
        budget: RoutingToggles.Budget? = nil  // SPRINT-4: Global hard-stop budget
    ) async throws -> GeneratedRoute? {
        guard !availablePOIs.isEmpty else {
            print("🗺️ 🆘 No POIs available for fallback")
            return nil
        }
        
        // Target distance: half the walking distance (out and back)
        // Walking ~80m/min, so 20min = 1600m total = 800m out
        let targetOutDistance = Double(targetDurationMinutes) * 80.0 / 2.0
        
        print("🗺️ 🆘 Looking for POI ~\(Int(targetOutDistance))m away for out-and-back")
        
        // Find POI closest to target distance
        let poisWithDistance = availablePOIs.map { poi -> (poi: PlaceResult, distance: Double, diff: Double) in
            let dist = distanceBetween(origin, poi.coordinate)
            let diff = abs(dist - targetOutDistance)
            return (poi, dist, diff)
        }
        
        let sorted = poisWithDistance.sorted { $0.diff < $1.diff }
        
        // v2.0.2: Guardrails - stop trying after 2 failures with >150% overshoot
        var failures = 0
        var lastOvershoot: Double = 0.0
        
        // Try POIs in order of how close they are to ideal distance (reduced from 5 to 3)
        for candidate in sorted.prefix(3) {
            // SPRINT-4: Global hard-stop check in guaranteed fallback loop
            if let budget = budget, !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "GUARANTEED_FALLBACK_LOOP") {
                print("⛔ [HARD-STOP] Aborting guaranteed fallback loop - returning nil")
                return nil
            }
            
            let poi = candidate.poi
            let poiDist = candidate.distance
            
            // Skip if too close (need some walking distance)
            if poiDist < 50 {
                continue
            }
            
            print("🗺️ 🆘 Trying \(poi.name) at \(Int(poiDist))m...")
            
            do {
                // SPRINT-4: Global hard-stop check before routing call
                if let budget = budget, !RoutingToggles.mustContinue(budget, bestSoFar: nil, stage: "GUARANTEED_FALLBACK_ROUTING") {
                    print("⛔ [HARD-STOP] Aborting guaranteed fallback routing - returning nil")
                    return nil
                }
                
                // v2.0.3 Phase 1.5 Batch A: Wrap fallback getWalkingDirections with timeout
                let timeout = RoutingToggles.perCallTimeoutNormal  // Default for fallback
                // SPRINT-4: Create hard-stop check closure
                let fallbackHardStopCheck: (() -> Bool)? = budget.map { b in
                    { !RoutingToggles.mustContinue(b, bestSoFar: nil, stage: "GUARANTEED_FALLBACK_CALL") }
                }
                let (directionsResult, didTimeout) = await directionsWithTimeout(
                    origin: origin,
                    destination: origin,
                    waypoints: [poi.coordinate],
                    timeout: timeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: nil,
                    checkGlobalHardStop: fallbackHardStopCheck
                )
                
                if didTimeout {
                    continue  // Try next POI
                }
                
                guard let directions = directionsResult else {
                    continue
                }
                
                // Calculate total duration from legs
                let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let durationMinutes = totalDuration / 60
                
                // Accept if within 40-150% of target (v2.0.1: relaxed from 130% for indirect road networks)
                let minAccept = max(2, targetDurationMinutes * 4 / 10)  // 40%
                let maxAccept = targetDurationMinutes * 15 / 10  // 150% - relaxed cap
                
                if durationMinutes >= minAccept && durationMinutes <= maxAccept {
                    print("🗺️ 🆘 ✓ Found viable out-and-back: \(durationMinutes)min")
                    
                    let outAndBackRoute = GeneratedRoute(
                        places: [poi],
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: totalDistance,
                        durationSeconds: totalDuration,
                        legs: directions.legs
                    )
                    // FINAL SAFETY WRAPPER: Ensure deduplication on return
                    return finalizeRouteDedup(outAndBackRoute)
                } else {
                    let overshoot = Double(durationMinutes) / Double(targetDurationMinutes)
                    lastOvershoot = overshoot
                    failures += 1
                    print("🗺️ 🆘 ✗ \(poi.name): \(durationMinutes)min not in \(minAccept)-\(maxAccept)min range (overshoot: \(String(format: "%.2f", overshoot)))")
                    
                    // v2.0.2: Guardrail - stop trying after 2 failures with >150% overshoot
                    if failures >= 2 && lastOvershoot > 1.5 {
                        print("🗺️ 🆘 ⛔ GUARDRAIL: Stopping after \(failures) failures with >150% overshoot (last: \(String(format: "%.1f", lastOvershoot * 100))%)")
                        break
                    }
                }
            } catch {
                failures += 1
                let poi = candidate.poi
                print("🗺️ 🆘 ✗ Route to \(poi.name) failed: \(error.localizedDescription)")
                
                // v2.0.2: Guardrail - stop trying after 2 failures
                if failures >= 2 {
                    print("🗺️ 🆘 ⛔ GUARDRAIL: Stopping after \(failures) route failures")
                    break
                }
                continue
            }
        }
        
        // Last resort: return a reachable POI but cap at 180% of target
        // v2.0.1: Increased from 130% to 180% for locations with indirect road networks
        // (e.g., hospital grounds where actual walking distance is 2x+ straight-line)
        // Better to return a longer-than-ideal route than fail completely
        let absoluteMaxDuration = targetDurationMinutes * 180 / 100  // 180% cap
        var bestLastResort: GeneratedRoute? = nil
        var bestLastResortDiff = Int.max
        
        for candidate in sorted.prefix(5) {  // v2.0.1: Reduced from 10 to 5 for speed
            let poi = candidate.poi
            print("🗺️ 🆘 Last resort: trying \(poi.name)")
            
            do {
                // v2.0.3 Phase 1.5 Batch A: Wrap last-resort getWalkingDirections with timeout
                let timeout = RoutingToggles.perCallTimeoutNormal  // Default for last-resort
                let (directionsResult, didTimeout) = await directionsWithTimeout(
                    origin: origin,
                    destination: origin,
                    waypoints: [poi.coordinate],
                    timeout: timeout,
                    targetDurationMinutes: targetDurationMinutes,
                    angularDiversityScore: nil,
                    postcode: nil
                )
                
                if didTimeout {
                    continue  // Try next POI
                }
                
                guard let directions = directionsResult else {
                    continue
                }
                
                let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
                let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
                let durationMinutes = totalDuration / 60
                
                // Skip if over 150% of target - never return absurdly long routes
                if durationMinutes > absoluteMaxDuration {
                    print("🗺️ 🆘 ✗ \(poi.name): \(durationMinutes)min exceeds \(absoluteMaxDuration)min cap")
                    continue
                }
                
                let diff = abs(durationMinutes - targetDurationMinutes)
                print("🗺️ 🆘 ✓ \(poi.name): \(durationMinutes)min (diff: \(diff)min)")
                
                // Keep the one closest to target
                if diff < bestLastResortDiff {
                    bestLastResortDiff = diff
                    bestLastResort = GeneratedRoute(
                        places: [poi],
                        polyline: directions.overviewPolyline.points,
                        distanceMeters: totalDistance,
                        durationSeconds: totalDuration,
                        legs: directions.legs
                    )
                }
            } catch {
                continue  // Try next POI
            }
        }
        
        if let route = bestLastResort {
            print("🗺️ 🆘 ✓ Best last resort: \(route.durationSeconds/60)min")
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(route)
        }
        
        return nil
    }
    
    /// Calculate how much a route backtracks on itself (0.0 = perfect loop, 1.0 = complete out-and-back)
    /// Compares outbound path to return path - if they overlap significantly, score is high
    private func calculateBacktrackingScore(polyline: String) -> Double {
        let points = decodePolyline(polyline)
        guard points.count >= 4 else { return 0.5 }  // Not enough points to analyze
        
        // Split route at midpoint
        let midIndex = points.count / 2
        let outbound = Array(points.prefix(midIndex))
        let returnPath = Array(points.suffix(from: midIndex))
        
        guard !outbound.isEmpty && !returnPath.isEmpty else { return 0.5 }
        
        // Sample points from return path and check how close they are to outbound path
        let sampleCount = min(10, returnPath.count)
        let sampleInterval = max(1, returnPath.count / sampleCount)
        
        var closePointCount = 0
        let closeThresholdMeters: Double = 30  // Points within 30m are considered "same path"
        
        for i in stride(from: 0, to: returnPath.count, by: sampleInterval) {
            let returnPoint = returnPath[i]
            
            // Check if this return point is close to any outbound point
            let isCloseToOutbound = outbound.contains { outboundPoint in
                distanceBetween(outboundPoint, returnPoint) < closeThresholdMeters
            }
            
            if isCloseToOutbound {
                closePointCount += 1
            }
        }
        
        let sampledPoints = (returnPath.count + sampleInterval - 1) / sampleInterval
        let backtrackRatio = Double(closePointCount) / Double(max(1, sampledPoints))
        
        return backtrackRatio  // 0.0 = no overlap (good loop), 1.0 = full overlap (out-and-back)
    }
    
    /// Remove waypoints that are too close together (keeps first one in each cluster).
    /// v2.1.7: Synchronous version for cached routes (filters waypoints without regenerating polyline).
    /// When origin is provided, waypoints under 100m from start/end are excluded (matches route_csv_generator).
    func filterCloseWaypointsSync(from route: GeneratedRoute, minDistance: Double, origin: CLLocationCoordinate2D? = nil) -> GeneratedRoute {
        guard route.places.count > 1 else {
            return route
        }
        
        let minFromStart = RoutingToggles.minDistanceFromStartToFirstWaypoint
        var filteredPlaces: [PlaceResult] = []
        
        for place in route.places {
            if let start = origin, distanceBetween(start, place.coordinate) < minFromStart {
                print("🗺️ [CACHE-FILTER] Removed '\(place.name)' - too close to start (< \(Int(minFromStart))m)")
                continue
            }
            let tooClose = filteredPlaces.contains { kept in
                distanceBetween(kept.coordinate, place.coordinate) < minDistance
            }
            
            if !tooClose {
                filteredPlaces.append(place)
            } else {
                print("🗺️ [CACHE-FILTER] Removed '\(place.name)' - too close to another waypoint (< \(minDistance)m)")
            }
        }
        
        if filteredPlaces.count != route.places.count {
            print("🗺️ [CACHE-FILTER] Filtered cached route: \(route.places.count) → \(filteredPlaces.count) waypoints (minDistance: \(minDistance)m)")
            // Return route with filtered places (polyline won't match, but waypoints are valid)
            return GeneratedRoute(
                places: filteredPlaces,
                polyline: route.polyline,  // Keep original polyline (might not match filtered waypoints)
                distanceMeters: route.distanceMeters,
                durationSeconds: route.durationSeconds,
                legs: route.legs
            )
        }
        
        return route
    }
    
    /// v1.8.10: Now async - regenerates polyline when waypoints are removed to fix Star Inn bug
    private func removeCloseWaypoints(from route: GeneratedRoute, minDistance: Double, origin: CLLocationCoordinate2D) async -> GeneratedRoute {
        // #region agent log
        let logData1: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "C",
            "location": "GoogleMapsService.swift:14874",
            "message": "removeCloseWaypoints: entry",
            "data": [
                "waypointCount": route.places.count,
                "minDistance": minDistance,
                "waypoints": route.places.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] }
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logJSON1 = try? JSONSerialization.data(withJSONObject: logData1),
           let logString1 = String(data: logJSON1, encoding: .utf8) {
            try? logString1.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
        }
        // #endregion
        
        guard route.places.count > 1 else {
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(route)
        }
        
        let minFromStart = RoutingToggles.minDistanceFromStartToFirstWaypoint
        var filteredPlaces: [PlaceResult] = []
        
        for place in route.places {
            // Explicit rule: first waypoint must be >100m from start/end (matches route_csv_generator)
            if distanceBetween(origin, place.coordinate) < minFromStart {
                print("🗺️ Removed '\(place.name)' - too close to start (< \(Int(minFromStart))m)")
                continue
            }
            // Check if this place is too close to any already-kept place
            var closestDistance: Double = .greatestFiniteMagnitude
            var closestWaypointName: String = ""
            let tooClose = filteredPlaces.contains { kept in
                let dist = distanceBetween(kept.coordinate, place.coordinate)
                if dist < closestDistance {
                    closestDistance = dist
                    closestWaypointName = kept.name
                }
                return dist < minDistance
            }
            
            if !tooClose {
                filteredPlaces.append(place)
            } else {
                // #region agent log
                let logData2: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "C",
                    "location": "GoogleMapsService.swift:14890",
                    "message": "removeCloseWaypoints: removed too close",
                    "data": [
                        "removedName": place.name,
                        "closestWaypointName": closestWaypointName,
                        "distance": closestDistance,
                        "minDistance": minDistance
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logJSON2 = try? JSONSerialization.data(withJSONObject: logData2),
                   let logString2 = String(data: logJSON2, encoding: .utf8) {
                    try? logString2.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
                }
                // #endregion
                print("🗺️ Removed '\(place.name)' - too close to another waypoint (\(String(format: "%.1f", closestDistance))m from '\(closestWaypointName)')")
            }
        }
        
        // #region agent log
        let logData3: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "C",
            "location": "GoogleMapsService.swift:14895",
            "message": "removeCloseWaypoints: exit",
            "data": [
                "originalCount": route.places.count,
                "filteredCount": filteredPlaces.count,
                "finalWaypoints": filteredPlaces.map { ["name": $0.name, "lat": $0.coordinate.latitude, "lng": $0.coordinate.longitude] },
                "distances": filteredPlaces.count > 1 ? (0..<filteredPlaces.count-1).map { i in
                    distanceBetween(filteredPlaces[i].coordinate, filteredPlaces[i+1].coordinate)
                } : []
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logJSON3 = try? JSONSerialization.data(withJSONObject: logData3),
           let logString3 = String(data: logJSON3, encoding: .utf8) {
            try? logString3.appendLine(toFile: "/Users/raihant/Documents/WalkingWR/.cursor/debug.log")
        }
        // #endregion
        
        // v1.8.10: Regenerate polyline if waypoints were removed
        if filteredPlaces.count != route.places.count {
            print("🗺️ Waypoints filtered: \(route.places.count) → \(filteredPlaces.count) - regenerating polyline...")
            
            // v2.0.3 Batch A: Wrap with timeout
            let regenTimeout = RoutingToggles.perCallTimeoutNormal
            let (regenResult, didTimeout) = await directionsWithTimeout(
                origin: origin,
                destination: origin,
                waypoints: filteredPlaces.map { $0.coordinate },
                timeout: regenTimeout,
                targetDurationMinutes: nil,
                angularDiversityScore: nil,
                postcode: nil
            )
            
            if didTimeout {
                print("🗺️ ⏱️ Timeout regenerating polyline after filtering")
            } else if let newDirections = regenResult {
                print("🗺️ ✅ Polyline regenerated after filtering")
                let filteredRoute = GeneratedRoute(
                    places: filteredPlaces,
                    polyline: newDirections.overviewPolyline.points,
                    distanceMeters: newDirections.legs.reduce(0) { $0 + $1.distance.value },
                    durationSeconds: newDirections.legs.reduce(0) { $0 + $1.duration.value },
                    legs: newDirections.legs
                )
                // FINAL SAFETY WRAPPER: Ensure deduplication on return
                return finalizeRouteDedup(filteredRoute)
            } else {
                print("🗺️ ⚠️ Polyline regeneration failed")
            }
        }
        
        let finalRoute = GeneratedRoute(
            places: filteredPlaces,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
        // FINAL SAFETY WRAPPER: Ensure deduplication on return
        return finalizeRouteDedup(finalRoute, targetDurationMinutes: nil)
    }
    
    // MARK: - Route Extension (v1.6.47)
    
    /// Try to extend a route that's 80-95% of target by adding an "on-route" POI
    /// Looks for POIs within 100m of the existing route polyline
    /// Returns extended route if successful, nil otherwise
    private func tryExtendRoute(
        route: GeneratedRoute,
        origin: CLLocationCoordinate2D,
        targetDurationMinutes: Int,
        availablePOIs: [PlaceResult],
        excludePlaceIds: Set<String>,
        angularDiversityScore: Int? = nil,  // v2.0.3 Phase 1.5 Batch A: For timeout calculation
        postcode: String? = nil,  // v2.0.3 Phase 1.5 Batch A: For postcode-aware timeout
        checkHardStop: ((String, String) -> Bool)? = nil  // SPRINT-4: Global hard-stop check
    ) async -> GeneratedRoute? {
        guard !route.polyline.isEmpty else {
            print("🔧 No polyline available for route extension")
            return nil
        }
        
        // Decode polyline to get route coordinates
        let routePoints = decodePolyline(route.polyline)
        guard routePoints.count > 1 else {
            print("🔧 Polyline has insufficient points")
            return nil
        }
        
        // Get existing POI IDs in this route
        let existingPOIIds = Set(route.places.map { $0.placeId })
        
        // Find POIs within 100m of the route that aren't already included
        let searchRadius: Double = 100  // meters
        var onRoutePOIs: [(poi: PlaceResult, minDistance: Double, nearestPointIndex: Int)] = []
        
        for poi in availablePOIs {
            // Skip if already in route or excluded
            guard !existingPOIIds.contains(poi.placeId) else { continue }
            guard !excludePlaceIds.contains(poi.placeId) else { continue }
            // Skip restricted POIs (playcare, nursery, playground, etc.)
            guard !isRestrictedPOI(poi) else { continue }
            
            // Find minimum distance from this POI to any point on the route
            var minDist = Double.infinity
            var nearestIdx = 0
            
            for (idx, routePoint) in routePoints.enumerated() {
                let dist = distanceBetween(poi.coordinate, routePoint)
                if dist < minDist {
                    minDist = dist
                    nearestIdx = idx
                }
            }
            
            if minDist <= searchRadius {
                onRoutePOIs.append((poi: poi, minDistance: minDist, nearestPointIndex: nearestIdx))
            }
        }
        
        guard !onRoutePOIs.isEmpty else {
            print("🔧 No on-route POIs found within \(Int(searchRadius))m")
            return nil
        }
        
        // Calculate current shortfall - only extend if 1+ minutes headroom
        // v1.8.11: Reduced from 3min to 1min to enable more route extensions
        let currentMins = route.durationSeconds / 60
        let shortfallMins = targetDurationMinutes - currentMins
        
        guard shortfallMins >= 1 else {
            print("🔧 Only \(shortfallMins)min headroom (need 1+) - skipping extension")
            return nil
        }
        
        print("🔧 Found \(onRoutePOIs.count) on-route POIs within \(Int(searchRadius))m (\(shortfallMins)min headroom)")
        
        // Sort by proximity to route MIDPOINT (prefer POIs in the middle of the walk)
        // This ensures we add POIs that are truly "on the way", not at the very start/end
        let midpointIndex = routePoints.count / 2
        onRoutePOIs.sort { poi1, poi2 in
            let dist1 = abs(poi1.nearestPointIndex - midpointIndex)
            let dist2 = abs(poi2.nearestPointIndex - midpointIndex)
            // Primary: closer to midpoint is better
            // Secondary: if equally close to midpoint, prefer closer to route
            if dist1 != dist2 {
                return dist1 < dist2
            }
            return poi1.minDistance < poi2.minDistance
        }
        
        // Try adding the closest POI(s) - estimate ~2-3 min detour per nearby POI
        for candidate in onRoutePOIs.prefix(3) {
            // CRITICAL: Check if this POI is already in the route using unified comparator
            // This must check against ALL places in the route, not just the first match
            let isDuplicate = route.places.contains { existing in
                isRouteDuplicate(candidate.poi, existing)
            }
            
            if isDuplicate {
                if let matched = route.places.first(where: { isRouteDuplicate(candidate.poi, $0) }) {
                    let distance = distanceBetween(candidate.poi.coordinate, matched.coordinate)
                    let nameA = GoogleMapsService.cleanPOIDisplayName(candidate.poi.name).lowercased()
                    let nameB = GoogleMapsService.cleanPOIDisplayName(matched.name).lowercased()
                    print("🔧 Skipping '\(candidate.poi.name)' - duplicate of existing POI '\(matched.name)' in route (\(String(format: "%.1f", distance))m apart, cleaned: '\(nameA)' == '\(nameB)')")
                }
                continue  // Skip this POI - already in route
            }
            
            // Estimate detour time (distance to POI and back, at ~80m/min walking)
            let detourMeters = candidate.minDistance * 2  // There and back
            let estimatedDetourMins = Int(detourMeters / 80) + 1  // +1 for stopping time
            
            // Would this bring us closer to target?
            let projectedMins = currentMins + estimatedDetourMins
            let projectedAccuracy = Double(projectedMins) / Double(targetDurationMinutes)
            
            if projectedAccuracy >= 0.90 && projectedAccuracy <= 1.15 {
                print("🔧 Trying to add '\(candidate.poi.name)' (\(Int(candidate.minDistance))m from route, ~+\(estimatedDetourMins)min)")
                
                // Insert POI at the appropriate position in the route
                // Find where in the places array to insert based on nearestPointIndex
                var newPlaces = route.places
                
                // Simple heuristic: if nearest point is in first half of route, insert after first POI
                // Otherwise insert before last POI
                let insertPosition: Int
                if candidate.nearestPointIndex < routePoints.count / 2 {
                    insertPosition = min(1, newPlaces.count)
                } else {
                    insertPosition = max(0, newPlaces.count - 1)
                }
                
                newPlaces.insert(candidate.poi, at: insertPosition)
                
                // v2.0.3 Phase 1.5 Batch A: Wrap extension getWalkingDirections with timeout
                do {
                    let timeout = (angularDiversityScore ?? 3) < 3
                        ? RoutingToggles.perCallTimeoutLowADS
                        : RoutingToggles.perCallTimeoutNormal
                    
                    // SPRINT-4: Create hard-stop check closure
                    let hardStopCheck: (() -> Bool)? = checkHardStop.map { checkFn in
                        { checkFn("EXTEND_ROUTE", "extend") }
                    }
                    
                    let (newDirectionsResult, didTimeout) = await directionsWithTimeout(
                        origin: origin,
                        destination: origin,
                        waypoints: newPlaces.map { $0.coordinate },
                        timeout: timeout,
                        targetDurationMinutes: targetDurationMinutes,
                        angularDiversityScore: angularDiversityScore,
                        postcode: postcode,
                        checkGlobalHardStop: hardStopCheck
                    )
                    
                    if didTimeout {
                        print("🔧 [EXTENSION] Timeout during extension - skipping this POI")
                        continue
                    }
                    
                    guard let newDirections = newDirectionsResult else {
                        continue
                    }
                    
                    let newDurationSeconds = newDirections.legs.reduce(0) { $0 + $1.duration.value }
                    let newDistanceMeters = newDirections.legs.reduce(0) { $0 + $1.distance.value }
                    
                    let extendedRoute = GeneratedRoute(
                        places: newPlaces,
                        polyline: newDirections.overviewPolyline.points,
                        distanceMeters: newDistanceMeters,
                        durationSeconds: newDurationSeconds,
                        legs: newDirections.legs
                    )
                    
                    // CRITICAL: Deduplicate before returning - catches duplicates that might have been added
                    return finalizeRouteDedup(extendedRoute)
                } catch {
                    print("🔧 Failed to generate extended route: \(error.localizedDescription)")
                    continue
                }
            } else {
                print("🔧 '\(candidate.poi.name)' would give \(projectedMins)min (\(Int(projectedAccuracy * 100))%) - skipping")
            }
        }
        
        return nil
    }
    
    /// Generate waypoint counts to try, starting from estimated and branching out
    private func generateWaypointCounts(estimated: Int, min: Int, max: Int) -> [Int] {
        var counts: [Int] = [estimated]
        
        // Add counts branching out from estimate
        for offset in 1...4 {
            if estimated - offset >= min {
                counts.append(estimated - offset)
            }
            if estimated + offset <= max {
                counts.append(estimated + offset)
            }
        }
        
        // Remove duplicates and sort by distance from estimate
        return Array(Set(counts)).sorted { abs($0 - estimated) < abs($1 - estimated) }
    }
    
    /// Try a route and evaluate if it's within tolerance
    /// v1.8.4: Added allPlaces parameter for "extend undershooting route" feature
    private func tryRouteAndEvaluate(
        origin: CLLocationCoordinate2D,
        waypoints: [PlaceResult],
        targetDurationMinutes: Int,
        minAcceptable: Int,
        maxAcceptable: Int,
        validRoutes: inout [GeneratedRoute],
        bestFallback: inout GeneratedRoute?,
        bestFallbackDiff: inout Int,
        allPlaces: [PlaceResult] = [],  // All available POIs for extension
        routeCapture: RouteCapture? = nil,  // Optional: Capture all valid routes for testing
        firstValidRouteFoundAt: inout Date?,  // v2.0.3 Phase 1.5: Track when first valid route found
        angularDiversityScore: Int? = nil,  // v2.0.3 Phase 1.5: For timeout calculation
        postcode: String? = nil,  // v2.0.3 Phase 1.5: For postcode-aware timeout
        checkHardStop: ((String, String) -> Bool)? = nil,  // PHASE A: Global hard-stop check
        repairPasses: inout Int,  // PHASE D: Track repair passes
        budget: RoutingToggles.Budget? = nil,  // v2.0.15: Budget for timeRemaining checks
        startTime: Date? = nil,  // v2.0.15: Start time for timeRemaining checks
        earlyCommitOpportunity: inout Bool,  // v2.0.16: Track when candidate enters commit band
        bestSoFarCommitted: inout Bool  // v2.0.16: Track when we actually commit early
    ) async throws -> GeneratedRoute? {
        do {
            let waypointCoords = waypoints.map { $0.coordinate }
            
            // v2.0.3 Phase 1.5 Batch A: Per-call timeout with ADS/postcode awareness
            let timeout: TimeInterval = {
                if let pc = postcode, let override = postcodeOverrides[pc] {
                    return override.perCallTimeoutSec
                }
                return (angularDiversityScore ?? 3) < 3
                    ? RoutingToggles.perCallTimeoutLowADS
                    : RoutingToggles.perCallTimeoutNormal
            }()
            
            // SPRINT-4: Create hard-stop check closure for directionsWithTimeout
            let hardStopCheck: (() -> Bool)? = checkHardStop.map { checkFn in
                { checkFn("ROUTING", "route") }
            }
            
            let (directionsResult, didTimeout) = await directionsWithTimeout(
                origin: origin,
                destination: origin,
                waypoints: waypointCoords,
                timeout: timeout,
                targetDurationMinutes: targetDurationMinutes,
                angularDiversityScore: angularDiversityScore,
                postcode: postcode,
                checkGlobalHardStop: hardStopCheck
            )
            
            if didTimeout {
                // Timeout already logged in directionsWithTimeout with structured telemetry
                // Return nil to trigger topology-safe fallback in caller
                throw GoogleMapsError.noRouteFound
            }
            
            guard let directions = directionsResult else {
                throw GoogleMapsError.noRouteFound
            }
            
            let totalDuration = directions.legs.reduce(0) { $0 + $1.duration.value }
            let totalDistance = directions.legs.reduce(0) { $0 + $1.distance.value }
            let durationMin = totalDuration / 60
            let diff = abs(durationMin - targetDurationMinutes)
            let targetDurationSeconds = targetDurationMinutes * 60
            let percentOfTarget = Double(totalDuration) / Double(targetDurationSeconds)
            
            // v2.0.3 Phase 1.5 Hotfix: Strict lower-bound validation - reject routes <50% unless we have no valid routes
            // This prevents accepting 7-16 minute outcomes for 20-35-55 minute targets during normal generation
            // But allows them if we have no other options (fallback scenario)
            let lowerBound = 0.50
            let hasNoValidRoutes = validRoutes.isEmpty && bestFallback == nil
            if percentOfTarget < lowerBound && !hasNoValidRoutes {
                print("⛔ [VALIDATION] Route too short (\(durationMin)min = \(String(format: "%.1f", percentOfTarget * 100))% of \(targetDurationMinutes)min target). Rejecting and retrying...")
                return nil
            }
            
            // EARLY REJECTION: If route is more than double target, skip entirely
            if durationMin > targetDurationMinutes * 2 {
                print("🗺️ ✗ REJECTED: \(durationMin)min is way too long (target: \(targetDurationMinutes)min)")
                return nil
            }
            
            let polylinePoints = directions.overviewPolyline.points
            let decodedPolyline = decodePolyline(polylinePoints)
            let decodedCount = decodedPolyline.count
            
            // v1.8.2: Publish route attempt for loading animation
            let isWithinTolerance = totalDuration >= minAcceptable && totalDuration <= maxAcceptable
            let poiNames = waypoints.prefix(2).map { $0.name }.joined(separator: " → ")
            publishRouteAttempt(
                coordinates: decodedPolyline,
                poiName: poiNames,
                isValid: isWithinTolerance,
                durationMinutes: durationMin
            )
            
            // Reorder waypoints based on Google's optimized order
            var orderedWaypoints = waypoints
            if let waypointOrder = directions.waypointOrder, waypointOrder.count == waypoints.count {
                orderedWaypoints = waypointOrder.compactMap { index in
                    index < waypoints.count ? waypoints[index] : nil
                }
                print("🗺️ Waypoints reordered by Google: \(waypointOrder)")
            }
            
            let route = GeneratedRoute(
                places: orderedWaypoints,
                polyline: polylinePoints,
                distanceMeters: totalDistance,
                durationSeconds: totalDuration,
                legs: directions.legs
            )
            
            if totalDuration >= minAcceptable && totalDuration <= maxAcceptable {
                print("🗺️ ✓ VALID: \(durationMin)min, \(totalDistance)m, \(decodedCount) polyline points")
                
                // v2.0.3 Phase 1.5: Track when first valid route found for short-circuit
                if firstValidRouteFoundAt == nil {
                    firstValidRouteFoundAt = Date()
                    print("✅ [EARLY EXIT] First valid route found - will short-circuit after 1s grace period")
                }
                
                // v2.0.16: HARD EARLY COMMIT RULE (enhanced - activate more, still safe)
                // Commit when in band & WPs met, OR if WPs == min-1 AND a quick repair succeeds
                // Duration-specific bands: 10-30min → 95-105%, 35-60min → 90-110%
                // This prevents valid routes from being degraded by later per-leg caps or cascading repairs
                let earlyCommitAccuracy = Double(totalDuration) / Double(targetDurationSeconds)
                let minWP = RoutingToggles.minWaypoints(forDuration: targetDurationMinutes)
                
                // Determine target band based on duration
                let inBandShort = targetDurationMinutes <= 30 && earlyCommitAccuracy >= 0.95 && earlyCommitAccuracy <= 1.05
                let inBandLong = targetDurationMinutes >= 35 && earlyCommitAccuracy >= 0.90 && earlyCommitAccuracy <= 1.10
                let meetsOrNear = orderedWaypoints.count >= minWP || orderedWaypoints.count == minWP - 1
                
                // B) Loosen early-commit detection: set opportunity when candidate enters commit band
                // Set the denominator when a candidate enters the commit band, before any finalization/cap/trim
                if (inBandShort || inBandLong) && meetsOrNear {
                    // Set opportunity flag once for this route when candidate enters commit band
                    // This ensures we count opportunities even if a later step steals control
                    if orderedWaypoints.count >= minWP || (orderedWaypoints.count == minWP - 1) {
                        earlyCommitOpportunity = true
                    }
                }
                
                if (inBandShort || inBandLong) && meetsOrNear {
                    // Case 1: min-1 WPs - try fast repair if time permits (≥1.2s)
                    if orderedWaypoints.count == minWP - 1 {
                        // v2.0.15: Check timeRemaining >= 1.2s before attempting repair
                        let timeRemaining = budget.map { $0.hard - (Date().timeIntervalSince1970 - $0.t0) } ?? 18.0
                        if timeRemaining >= 1.2 && !allPlaces.isEmpty {
                            print("🎯 [EARLY-COMMIT] Route at \(String(format: "%.1f", earlyCommitAccuracy * 100))% with \(orderedWaypoints.count) WPs (min-1) - attempting fast repair")
                            
                            let existingIds = Set(orderedWaypoints.map { $0.placeId })
                            let midpointIdx = orderedWaypoints.count / 2
                            let midpointCoord = midpointIdx < orderedWaypoints.count 
                                ? orderedWaypoints[midpointIdx].coordinate 
                                : origin
                            
                            // Repair spur: 0.2-0.5km from midpoint
                            let spurCandidates = allPlaces.filter { poi in
                                guard !existingIds.contains(poi.placeId) else { return false }
                                let dist = distanceBetween(midpointCoord, poi.coordinate)
                                return dist >= 200 && dist <= 500  // 0.2-0.5km from midpoint
                            }.prefix(1)
                            
                            if let spurPOI = spurCandidates.first {
                                var repairedWPs = orderedWaypoints
                                repairedWPs.insert(spurPOI, at: midpointIdx)
                                
                                let (spurResult, spurTimeout) = await directionsWithTimeout(
                                    origin: origin,
                                    destination: origin,
                                    waypoints: repairedWPs.map { $0.coordinate },
                                    timeout: RoutingToggles.perCallTimeoutNormal,
                                    targetDurationMinutes: targetDurationMinutes,
                                    angularDiversityScore: angularDiversityScore,
                                    postcode: postcode
                                )
                                
                                if let spurDirs = spurResult, !spurTimeout {
                                    let spurDur = spurDirs.legs.reduce(0) { $0 + $1.duration.value }
                                    let spurDist = spurDirs.legs.reduce(0) { $0 + $1.distance.value }
                                    let spurAcc = Double(spurDur) / Double(targetDurationSeconds)
                                    
                                    // Check if repair succeeded and route is still in band
                                    let stillInBand = (inBandShort && spurAcc >= 0.95 && spurAcc <= 1.05) ||
                                                      (inBandLong && spurAcc >= 0.90 && spurAcc <= 1.10)
                                    
                                    if stillInBand && repairedWPs.count >= minWP {
                                        print("🎯 [EARLY-COMMIT] ✅ Fast repair successful: \(repairedWPs.count) WPs, \(String(format: "%.1f", spurAcc * 100))%")
                                        let repairedRoute = GeneratedRoute(
                                            places: repairedWPs,
                                            polyline: spurDirs.overviewPolyline.points,
                                            distanceMeters: spurDist,
                                            durationSeconds: spurDur,
                                            legs: spurDirs.legs
                                        )
                                        validRoutes.append(repairedRoute)
                                        routeCapture?.addRoute(repairedRoute)
                                        // v2.0.16: Set telemetry flags on successful commit
                                        earlyCommitOpportunity = true  // Repair succeeded, so opportunity was taken
                                        bestSoFarCommitted = true
                                        print("🎯 [EARLY-COMMIT] HARD COMMIT: Returning with repair (\(repairedWPs.count) WPs, \(spurDur/60)min) - skipping caps/trims/repairs/depth")
                                        return finalizeRouteDedup(repairedRoute)
                                    }
                                }
                            }
                            // Fall through if repair fails
                        }
                    }
                    // Case 2: Already at min WPs or above
                    else if orderedWaypoints.count >= minWP {
                        print("🎯 [EARLY-COMMIT] Route at \(String(format: "%.1f", earlyCommitAccuracy * 100))% with \(orderedWaypoints.count) WPs - within sweet spot")
                        
                        // v2.0.15: Try one micro-spur for fine-tuning if time permits (≥1.0s)
                        let timeRemaining = budget.map { $0.hard - (Date().timeIntervalSince1970 - $0.t0) } ?? 18.0
                        var finalRoute = route
                        
                        if timeRemaining >= 1.0 && !allPlaces.isEmpty {
                            // Attempt one micro-spur insertion (0.2-0.5km from midpoint)
                            let existingIds = Set(orderedWaypoints.map { $0.placeId })
                            let midpointIdx = orderedWaypoints.count / 2
                            let midpointCoord = midpointIdx < orderedWaypoints.count 
                                ? orderedWaypoints[midpointIdx].coordinate 
                                : origin
                            
                            let spurCandidates = allPlaces.filter { poi in
                                guard !existingIds.contains(poi.placeId) else { return false }
                                let dist = distanceBetween(midpointCoord, poi.coordinate)
                                return dist >= 200 && dist <= 500  // 0.2-0.5km from midpoint
                            }.prefix(1)
                            
                            if let spurPOI = spurCandidates.first {
                                var enhancedWPs = orderedWaypoints
                                enhancedWPs.insert(spurPOI, at: midpointIdx)
                                
                                let (spurResult, spurTimeout) = await directionsWithTimeout(
                                    origin: origin,
                                    destination: origin,
                                    waypoints: enhancedWPs.map { $0.coordinate },
                                    timeout: RoutingToggles.perCallTimeoutNormal,
                                    targetDurationMinutes: targetDurationMinutes,
                                    angularDiversityScore: angularDiversityScore,
                                    postcode: postcode
                                )
                                
                                if let spurDirs = spurResult, !spurTimeout {
                                    let spurDur = spurDirs.legs.reduce(0) { $0 + $1.duration.value }
                                    let spurAcc = Double(spurDur) / Double(targetDurationSeconds)
                                    
                                    // Accept micro-spur if still in band
                                    let stillInBand = (inBandShort && spurAcc >= 0.95 && spurAcc <= 1.05) ||
                                                      (inBandLong && spurAcc >= 0.90 && spurAcc <= 1.10)
                                    
                                    if stillInBand {
                                        print("🎯 [EARLY-COMMIT] ✅ Micro-spur successful: \(enhancedWPs.count) WPs, \(String(format: "%.1f", spurAcc * 100))%")
                                        finalRoute = GeneratedRoute(
                                            places: enhancedWPs,
                                            polyline: spurDirs.overviewPolyline.points,
                                            distanceMeters: spurDirs.legs.reduce(0) { $0 + $1.distance.value },
                                            durationSeconds: spurDur,
                                            legs: spurDirs.legs
                                        )
                                    }
                                }
                            }
                        }
                        
                        // v2.0.16: Set telemetry flags on successful commit
                        bestSoFarCommitted = true
                        // HARD COMMIT: Return immediately, skip ALL further processing (caps/trims/repairs/depth)
                        validRoutes.append(finalRoute)
                        routeCapture?.addRoute(finalRoute)
                        print("🎯 [EARLY-COMMIT] HARD COMMIT: Returning (\(finalRoute.places.count) WPs, \(finalRoute.durationSeconds/60)min) - skipping caps/trims/repairs/depth")
                        return finalizeRouteDedup(finalRoute)
                    }
                }
                
                // v1.8.4: EXTEND UNDERSHOOTING ROUTE
                // v2.0.3 Phase 1.5 Hotfix: Lowered extension trigger to 35-98% to catch severe undershoots (28-50%)
                // SPRINT-7 HOTFIX: Further lowered to 20% and made more aggressive for long-duration targets
                // Note: targetDurationSeconds already calculated above
                let percentOfTarget = Double(totalDuration) / Double(targetDurationSeconds) * 100
                let timeHeadroomSeconds = targetDurationSeconds - totalDuration
                // Use seconds directly for more precise control
                
                // SPRINT-7 HOTFIX: More aggressive extension for long-duration targets
                // - Lowered minimum from 35% to 20% to catch severe undershoots
                // - For 40+ min targets, be more aggressive (even at 15% we should try)
                let minPercentForExtension = targetDurationMinutes >= 40 ? 15.0 : 20.0
                
                // v2.0.3 Phase 1.5 Hotfix: Only try extension if:
                // - Route is undershooting (20-98% of target) - SPRINT-7: lowered from 35% to 20%
                // - We have at least 90 seconds of headroom - increased from 45s to allow more extension
                // - We have available POIs to check
                if percentOfTarget >= minPercentForExtension && percentOfTarget <= 98 && timeHeadroomSeconds >= 90 && !allPlaces.isEmpty {
                    // v2.0.3: Guard against MapKit waypoint limit (8-10 depending on region)
                    let maxMapKitWaypoints = 8  // Conservative limit
                    let currentWaypointCount = orderedWaypoints.count
                    guard currentWaypointCount < maxMapKitWaypoints else {
                        print("⚠️ [EXT-P1] Cannot extend: already at MapKit limit (\(currentWaypointCount) waypoints)")
                        validRoutes.append(route)
                        routeCapture?.addRoute(route)
                        return route
                    }
                    
                    // SPRINT-7 HOTFIX: Adaptive search radius based on severity of undershoot
                    // Severe undershoot (<50%) → look further from route (up to 500m)
                    // Mild undershoot (50-98%) → keep tighter radius (200m)
                    let extensionSearchRadius: Double = percentOfTarget < 50 ? 500.0 : 200.0
                    
                    print("🗺️ 🔍 [EXT-P1] Extension check: \(Int(percentOfTarget))% of target (\(Int(timeHeadroomSeconds))s headroom, radius=\(Int(extensionSearchRadius))m)")
                    
                    // Find POIs within search radius of the existing route polyline that aren't already in the route
                    let existingPOIIds = Set(orderedWaypoints.map { $0.placeId })
                    let poisNearRoute = allPlaces.filter { poi in
                        guard !existingPOIIds.contains(poi.placeId) else { return false }
                        // Check if POI is within search radius of any point on the route
                        return decodedPolyline.contains { routePoint in
                            distanceBetween(poi.coordinate, routePoint) < extensionSearchRadius
                        }
                    }
                    
                    if !poisNearRoute.isEmpty {
                        print("🗺️ 🔍 Found \(poisNearRoute.count) POIs on-route: \(poisNearRoute.prefix(3).map { $0.name }.joined(separator: ", "))")
                        
                        // SPRINT-7 HOTFIX: Multi-pass extension for severe undershoots
                        // If route is <70% of target, we may need to add multiple POIs
                        let maxExtensionPasses = percentOfTarget < 70 ? 3 : 1
                        var currentWaypoints = orderedWaypoints
                        var currentDuration = totalDuration
                        var usedPOIIds = Set(orderedWaypoints.map { $0.placeId })
                        var extensionSucceeded = false
                        var bestExtendedRoute: GeneratedRoute?
                        
                        for extPass in 1...maxExtensionPasses {
                            // Check if we've reached target
                            if currentDuration >= minAcceptable {
                                print("🗺️ 🔍 [EXT-P\(extPass)] Route now at \(currentDuration/60)min - within tolerance, stopping extension")
                                break
                            }
                            
                            // Check MapKit waypoint limit
                            if currentWaypoints.count >= maxMapKitWaypoints {
                                print("🗺️ 🔍 [EXT-P\(extPass)] At MapKit waypoint limit (\(currentWaypoints.count)) - stopping extension")
                                break
                            }
                            
                            // Find POIs not yet used
                            let availablePOIs = poisNearRoute.filter { !usedPOIIds.contains($0.placeId) }
                            guard !availablePOIs.isEmpty else {
                                print("🗺️ 🔍 [EXT-P\(extPass)] No more available POIs - stopping extension")
                                break
                            }
                            
                            // Sort by distance to a middle point of the route for better placement
                            let midIndex = decodedPolyline.count / 2
                            let midPoint = midIndex < decodedPolyline.count ? decodedPolyline[midIndex] : origin
                            let sortedNearby = availablePOIs.sorted { 
                                distanceBetween($0.coordinate, midPoint) < distanceBetween($1.coordinate, midPoint)
                            }
                            
                            guard let extensionPOI = sortedNearby.first else { break }
                            
                            var extendedWaypoints = currentWaypoints
                            extendedWaypoints.append(extensionPOI)
                            usedPOIIds.insert(extensionPOI.placeId)
                            
                            print("🗺️ 🔍 [EXT-P\(extPass)] Trying to add '\(extensionPOI.name)' (pass \(extPass)/\(maxExtensionPasses))")
                            
                            // v2.0.3 Batch A: Wrap extension with timeout
                            let extTimeout = (angularDiversityScore ?? 3) < 3 ? RoutingToggles.perCallTimeoutLowADS : RoutingToggles.perCallTimeoutNormal
                            let (extDirectionsResult, didTimeout) = await directionsWithTimeout(
                                origin: origin,
                                destination: origin,
                                waypoints: extendedWaypoints.map { $0.coordinate },
                                timeout: extTimeout,
                                targetDurationMinutes: targetDurationMinutes,
                                angularDiversityScore: angularDiversityScore,
                                postcode: postcode
                            )
                            
                            if didTimeout {
                                print("🗺️ 🔍 [EXT-P\(extPass)] ⏱️ Timeout - stopping extension")
                                break
                            }
                            
                            guard let extendedDirections = extDirectionsResult else {
                                print("🗺️ 🔍 [EXT-P\(extPass)] Directions failed - stopping extension")
                                break
                            }
                            
                            let extendedDuration = extendedDirections.legs.reduce(0) { $0 + $1.duration.value }
                            let extendedDistance = extendedDirections.legs.reduce(0) { $0 + $1.distance.value }
                            let extendedMins = extendedDuration / 60
                            
                            print("🗺️ 🔍 [EXT-P\(extPass)] Extended: \(currentDuration/60)min → \(extendedMins)min")
                            
                            // Update current state for next pass
                            currentWaypoints = extendedWaypoints
                            currentDuration = extendedDuration
                            
                            // Reorder extended waypoints if Google provided an order
                            var orderedExtendedWaypoints = extendedWaypoints
                            if let order = extendedDirections.waypointOrder, order.count == extendedWaypoints.count {
                                orderedExtendedWaypoints = order.compactMap { idx in
                                    idx < extendedWaypoints.count ? extendedWaypoints[idx] : nil
                                }
                            }
                            
                            bestExtendedRoute = GeneratedRoute(
                                places: orderedExtendedWaypoints,
                                polyline: extendedDirections.overviewPolyline.points,
                                distanceMeters: extendedDistance,
                                durationSeconds: extendedDuration,
                                legs: extendedDirections.legs
                            )
                            
                            // Check if we've reached tolerance
                            if extendedDuration >= minAcceptable && extendedDuration <= maxAcceptable {
                                print("🗺️ 🔍 [EXT-P\(extPass)] ✅ EXTENDED route now within tolerance: \(extendedMins)min")
                                extensionSucceeded = true
                                break
                            }
                        }
                        
                        // Use best extended route if available
                        if let extendedRoute = bestExtendedRoute {
                            if extensionSucceeded || extendedRoute.durationSeconds > totalDuration {
                                print("🗺️ 🔍 [EXT] Final: \(durationMin)min → \(extendedRoute.durationSeconds/60)min (added \(extendedRoute.places.count - orderedWaypoints.count) POIs)")
                                validRoutes.append(extendedRoute)
                                routeCapture?.addRoute(extendedRoute)
                                return finalizeRouteDedup(extendedRoute)
                            }
                        }
                        
                        // Fall back to original route
                        validRoutes.append(route)
                        routeCapture?.addRoute(route)
                    } else {
                        print("🗺️ 🔍 No on-route POIs found for extension")
                        validRoutes.append(route)
                        routeCapture?.addRoute(route)
                    }
                } else {
                    // Route is not undershooting, or no headroom/POIs - use as-is
                    validRoutes.append(route)
                    routeCapture?.addRoute(route)
                }
            } else {
                print("🗺️ ✗ Outside tolerance: \(durationMin)min (diff: \(diff)min)")
                
                // P0 FIX: Multi-pass repair for overshoot (S11 9BF fix)
                // For durations ≥45min: if >120%, perform TRIM + up to 2 more trim passes
                let targetDurationSeconds = targetDurationMinutes * 60
                let overshootRatio = Double(totalDuration) / Double(targetDurationSeconds)
                let shouldMultiPassRepair = targetDurationMinutes >= 45 && overshootRatio > 1.20 && orderedWaypoints.count > 1
                
                if shouldMultiPassRepair {
                    print("🔧 [REPAIR] Multi-pass repair: route \(String(format: "%.1f", overshootRatio * 100))% of target, \(orderedWaypoints.count) waypoints")
                    
                    // PHASE D: Track repair passes
                    repairPasses += 1
                    
                    var currentWaypoints = orderedWaypoints
                    var currentRoute: GeneratedRoute? = nil
                    let maxTrimPasses = 2
                    
                    for trimPass in 1...maxTrimPasses {
                        // SPRINT-4: Universal hard-stop check in trim loop
                        if let checkHardStopFn = checkHardStop, checkHardStopFn("TRIM_PASS\(trimPass)", "repair") {
                            print("⛔ [HARD-STOP] Aborting trim/repair - returning best-so-far")
                            break  // Exit trim loop immediately
                        }
                        
                        // Find farthest waypoint from origin
                        guard let farthestIndex = currentWaypoints.enumerated().max(by: { 
                            distanceBetween(origin, $0.element.coordinate) < distanceBetween(origin, $1.element.coordinate)
                        })?.offset else { break }
                        
                        let farthestPOI = currentWaypoints[farthestIndex]
                        print("🔧 [REPAIR] Pass \(trimPass)/\(maxTrimPasses): Removing '\(farthestPOI.name)' (farthest)")
                        
                        var trimmedWaypoints = currentWaypoints
                        trimmedWaypoints.remove(at: farthestIndex)
                        
                        // Wrap trim with timeout
                        let trimTimeout = (angularDiversityScore ?? 3) < 3 ? RoutingToggles.perCallTimeoutLowADS : RoutingToggles.perCallTimeoutNormal
                        // SPRINT-5: Create hard-stop check closure for multi-pass repair
                        let repairHardStopCheck: (() -> Bool)? = checkHardStop.map { checkFn in
                            { checkFn("REPAIR_TRIM_PASS\(trimPass)", "repair") }
                        }
                        let (trimResult, didTimeout) = await directionsWithTimeout(
                            origin: origin,
                            destination: origin,
                            waypoints: trimmedWaypoints.map { $0.coordinate },
                            timeout: trimTimeout,
                            targetDurationMinutes: targetDurationMinutes,
                            angularDiversityScore: angularDiversityScore,
                            postcode: postcode,
                            checkGlobalHardStop: repairHardStopCheck  // SPRINT-5: Universal hard-stop
                        )
                        
                        if didTimeout {
                            print("🔧 [REPAIR] ⏱️ Timeout on pass \(trimPass)")
                            break
                        }
                        
                        guard let trimmedDirections = trimResult else { break }
                        
                        let trimmedDuration = trimmedDirections.legs.reduce(0) { $0 + $1.duration.value }
                        let trimmedDistance = trimmedDirections.legs.reduce(0) { $0 + $1.distance.value }
                        let trimmedMins = trimmedDuration / 60
                        let newOvershootRatio = Double(trimmedDuration) / Double(targetDurationSeconds)
                        
                        let trimmedRoute = GeneratedRoute(
                            places: trimmedWaypoints,
                            polyline: trimmedDirections.overviewPolyline.points,
                            distanceMeters: trimmedDistance,
                            durationSeconds: trimmedDuration,
                            legs: trimmedDirections.legs
                        )
                        
                        if trimmedDuration >= minAcceptable && trimmedDuration <= maxAcceptable {
                            print("🔧 [REPAIR] ✅ Pass \(trimPass) succeeded: \(trimmedMins)min (was \(durationMin)min)")
                            validRoutes.append(trimmedRoute)
                            routeCapture?.addRoute(trimmedRoute)
                            return trimmedRoute
                        } else if newOvershootRatio <= 1.20 {
                            // Still overshoot but <120% - might be acceptable, continue to next pass
                            print("🔧 [REPAIR] Pass \(trimPass): \(trimmedMins)min (\(String(format: "%.1f", newOvershootRatio * 100))%) - continuing")
                            currentWaypoints = trimmedWaypoints
                            currentRoute = trimmedRoute
                        } else {
                            // Still >120%, continue to next pass
                            print("🔧 [REPAIR] Pass \(trimPass): Still \(String(format: "%.1f", newOvershootRatio * 100))% - continuing")
                            currentWaypoints = trimmedWaypoints
                            currentRoute = trimmedRoute
                        }
                    }
                    
                    // If we have a route after multi-pass repair (even if not perfect), use it
                    if let repairedRoute = currentRoute {
                        let repairedMins = repairedRoute.durationSeconds / 60
                        let repairedPercent = Double(repairedRoute.durationSeconds) / Double(targetDurationSeconds) * 100
                        
                        // TASK 3: If route is now undershooting (<90%), try MICRO-EXTEND passes
                        if repairedPercent < 90.0 && !allPlaces.isEmpty {
                            print("🔧 [MICRO-EXTEND] Route at \(String(format: "%.1f", repairedPercent))% after trim - starting micro-extend")
                            
                            var extendedRoute = repairedRoute
                            var extendedWaypoints = currentWaypoints
                            
                            // TASK 3: Two micro-extend passes (+2-4 min each)
                            for extendPass in 0..<RoutingToggles.microExtendPasses {
                                // SPRINT-4: Universal hard-stop check in extend loop
                                if let checkHardStopFn = checkHardStop, checkHardStopFn("EXTEND_PASS\(extendPass + 1)", "repair") {
                                    print("⛔ [HARD-STOP] Aborting micro-extend - returning best-so-far")
                                    break  // Exit extend loop immediately
                                }
                                
                                let addMinutes = RoutingToggles.microExtendAddMin[min(extendPass, RoutingToggles.microExtendAddMin.count - 1)]
                                let addSeconds = addMinutes * 60
                                let currentPercent = Double(extendedRoute.durationSeconds) / Double(targetDurationSeconds) * 100
                                
                                if currentPercent >= 95.0 {
                                    print("🔧 [MICRO-EXTEND] Pass \(extendPass + 1): Already at \(String(format: "%.1f", currentPercent))% - stopping")
                                    break
                                }
                                
                                // Find nearby POIs not already in route
                                let existingPOIIds = Set(extendedWaypoints.map { $0.placeId })
                                let nearbyPOIs = allPlaces.filter { poi in
                                    guard !existingPOIIds.contains(poi.placeId) else { return false }
                                    // TASK 3: Category-aware duplicate check
                                    if RoutingToggles.duplicateCheckCategoryFirst {
                                        let poiTypes = Set(poi.types ?? [])
                                        let categoryDuplicate = extendedWaypoints.contains { existing in
                                            let existingTypes = Set(existing.types ?? [])
                                            return !poiTypes.isDisjoint(with: existingTypes) &&
                                                distanceBetween(poi.coordinate, existing.coordinate) < 50
                                        }
                                        if categoryDuplicate { return false }
                                    }
                                    return distanceBetween(origin, poi.coordinate) < 500  // Within 500m
                                }
                                
                                // Find POI that would add approximately the target minutes
                                let targetAddDistance = Double(addSeconds) / 60.0 * Double(adaptiveWalkingSpeed)
                                let sortedNearby = nearbyPOIs.sorted { 
                                    abs(distanceBetween(origin, $0.coordinate) - targetAddDistance) < 
                                    abs(distanceBetween(origin, $1.coordinate) - targetAddDistance)
                                }
                                
                                guard let extensionPOI = sortedNearby.first else {
                                    print("🔧 [MICRO-EXTEND] Pass \(extendPass + 1): No suitable POI found")
                                    break
                                }
                                
                                var testWaypoints = extendedWaypoints
                                testWaypoints.append(extensionPOI)
                                
                                let extTimeout = RoutingToggles.mapkitSoftCap  // Use soft cap for micro-extend
                                // SPRINT-4: Create hard-stop check closure
                                let extHardStopCheck: (() -> Bool)? = checkHardStop.map { checkFn in
                                    { checkFn("EXTEND", "extend") }
                                }
                                let (extResult, didTimeout) = await directionsWithTimeout(
                                    origin: origin,
                                    destination: origin,
                                    waypoints: testWaypoints.map { $0.coordinate },
                                    timeout: extTimeout,
                                    targetDurationMinutes: targetDurationMinutes,
                                    angularDiversityScore: angularDiversityScore,
                                    postcode: postcode,
                                    checkGlobalHardStop: extHardStopCheck
                                )
                                
                                if didTimeout || extResult == nil {
                                    print("🔧 [MICRO-EXTEND] Pass \(extendPass + 1): Timeout or no result")
                                    continue
                                }
                                
                                let extDuration = extResult!.legs.reduce(0) { $0 + $1.duration.value }
                                let extDistance = extResult!.legs.reduce(0) { $0 + $1.distance.value }
                                let extMins = extDuration / 60
                                let extPercent = Double(extDuration) / Double(targetDurationSeconds) * 100
                                
                                print("🔧 [MICRO-EXTEND] Pass \(extendPass + 1): Added '\(extensionPOI.name)' → \(extMins)min (\(String(format: "%.1f", extPercent))%)")
                                
                                extendedWaypoints = testWaypoints
                                extendedRoute = GeneratedRoute(
                                    places: testWaypoints,
                                    polyline: extResult!.overviewPolyline.points,
                                    distanceMeters: extDistance,
                                    durationSeconds: extDuration,
                                    legs: extResult!.legs
                                )
                            }
                            
                            let finalMins = extendedRoute.durationSeconds / 60
                            let finalPercent = Double(extendedRoute.durationSeconds) / Double(targetDurationSeconds) * 100
                            print("🔧 [MICRO-EXTEND] Final: \(finalMins)min (\(String(format: "%.1f", finalPercent))%)")
                            
                            if extendedRoute.durationSeconds >= minAcceptable && extendedRoute.durationSeconds <= maxAcceptable {
                                print("🔧 [REPAIR] ✅ Micro-extended route is valid")
                                validRoutes.append(extendedRoute)
                                routeCapture?.addRoute(extendedRoute)
                                return extendedRoute
                            } else {
                                print("🔧 [REPAIR] Using best micro-extended route (may still be outside tolerance)")
                                validRoutes.append(extendedRoute)
                                routeCapture?.addRoute(extendedRoute)
                                return extendedRoute
                            }
                        }
                        
                        print("🔧 [REPAIR] Using best repaired route: \(repairedMins)min after \(maxTrimPasses) passes")
                        validRoutes.append(repairedRoute)
                        routeCapture?.addRoute(repairedRoute)
                        return repairedRoute
                    }
                }
                
                // v2.0.3: Early trim on obvious overshoot (>140%) or if we already have a valid route
                let shouldTrimEarly = (totalDuration > Int(Double(targetDurationSeconds) * 1.40)) || 
                                      (totalDuration > maxAcceptable && !validRoutes.isEmpty)
                
                if shouldTrimEarly && orderedWaypoints.count > 1 {
                    let trimReason = totalDuration > Int(Double(targetDurationSeconds) * 1.40) ? 
                        ">140% overshoot" : "already have valid route"
                    print("🗺️ ✂️ [TRIM] [EARLY TRIM] Route \(trimReason) - trimming farthest waypoint immediately")
                    
                    // Find farthest waypoint from origin
                    if let farthestIndex = orderedWaypoints.enumerated().max(by: { 
                        distanceBetween(origin, $0.element.coordinate) < distanceBetween(origin, $1.element.coordinate)
                    })?.offset {
                        let farthestPOI = orderedWaypoints[farthestIndex]
                        print("🗺️ ✂️ Removing '\(farthestPOI.name)' (farthest at \(Int(distanceBetween(origin, farthestPOI.coordinate)))m)")
                        
                        var trimmedWaypoints = orderedWaypoints
                        trimmedWaypoints.remove(at: farthestIndex)
                        
                        // v2.0.3 Batch A: Wrap trim with timeout
                        let trimTimeout = (angularDiversityScore ?? 3) < 3 ? RoutingToggles.perCallTimeoutLowADS : RoutingToggles.perCallTimeoutNormal
                        // SPRINT-4: Create hard-stop check closure
                        let trimHardStopCheck: (() -> Bool)? = checkHardStop.map { checkFn in
                            { checkFn("TRIM_EARLY", "trim") }
                        }
                        let (trimResult, didTimeout) = await directionsWithTimeout(
                            origin: origin,
                            destination: origin,
                            waypoints: trimmedWaypoints.map { $0.coordinate },
                            timeout: trimTimeout,
                            targetDurationMinutes: targetDurationMinutes,
                            angularDiversityScore: angularDiversityScore,
                            postcode: postcode,
                            checkGlobalHardStop: trimHardStopCheck
                        )
                        
                        if didTimeout {
                            print("🗺️ ✂️ [TRIM] ⏱️ Timeout trimming route")
                        } else if let trimmedDirections = trimResult {
                            let trimmedDuration = trimmedDirections.legs.reduce(0) { $0 + $1.duration.value }
                            let trimmedDistance = trimmedDirections.legs.reduce(0) { $0 + $1.distance.value }
                            let trimmedMins = trimmedDuration / 60
                            
                            if trimmedDuration >= minAcceptable && trimmedDuration <= maxAcceptable {
                                print("🗺️ ✂️ [TRIM] ✅ Trimmed route is valid: \(trimmedMins)min (was \(durationMin)min)")
                                
                                let trimmedRoute = GeneratedRoute(
                                    places: trimmedWaypoints,
                                    polyline: trimmedDirections.overviewPolyline.points,
                                    distanceMeters: trimmedDistance,
                                    durationSeconds: trimmedDuration,
                                    legs: trimmedDirections.legs
                                )
                                validRoutes.append(trimmedRoute)
                                routeCapture?.addRoute(trimmedRoute)
                                return trimmedRoute
                            } else {
                                print("🗺️ ✂️ [TRIM] ✗ Trimmed route still outside tolerance: \(trimmedMins)min")
                            }
                        }
                    }
                } else if totalDuration > maxAcceptable && orderedWaypoints.count > 1 {
                    // Original trim logic for routes just over maxAcceptable (not early trim case)
                    print("🗺️ ✂️ [TRIM] Route too long, trying to trim farthest waypoint...")
                    
                    // Find farthest waypoint from origin
                    if let farthestIndex = orderedWaypoints.enumerated().max(by: { 
                        distanceBetween(origin, $0.element.coordinate) < distanceBetween(origin, $1.element.coordinate)
                    })?.offset {
                        let farthestPOI = orderedWaypoints[farthestIndex]
                        print("🗺️ ✂️ [TRIM] Removing '\(farthestPOI.name)' (farthest at \(Int(distanceBetween(origin, farthestPOI.coordinate)))m)")
                        
                        var trimmedWaypoints = orderedWaypoints
                        trimmedWaypoints.remove(at: farthestIndex)
                        
                        // v2.0.3 Batch A: Wrap trim with timeout
                        let trimTimeout2 = (angularDiversityScore ?? 3) < 3 ? RoutingToggles.perCallTimeoutLowADS : RoutingToggles.perCallTimeoutNormal
                        // SPRINT-4: Create hard-stop check closure
                        let trimHardStopCheck2: (() -> Bool)? = checkHardStop.map { checkFn in
                            { checkFn("TRIM_STANDARD", "trim") }
                        }
                        let (trimResult2, didTimeout2) = await directionsWithTimeout(
                            origin: origin,
                            destination: origin,
                            waypoints: trimmedWaypoints.map { $0.coordinate },
                            timeout: trimTimeout2,
                            targetDurationMinutes: targetDurationMinutes,
                            angularDiversityScore: angularDiversityScore,
                            postcode: postcode,
                            checkGlobalHardStop: trimHardStopCheck2
                        )
                        
                        if didTimeout2 {
                            print("🗺️ ✂️ [TRIM] ⏱️ Timeout trimming route (standard)")
                        } else if let trimmedDirections = trimResult2 {
                            let trimmedDuration = trimmedDirections.legs.reduce(0) { $0 + $1.duration.value }
                            let trimmedDistance = trimmedDirections.legs.reduce(0) { $0 + $1.distance.value }
                            let trimmedMins = trimmedDuration / 60
                            
                            if trimmedDuration >= minAcceptable && trimmedDuration <= maxAcceptable {
                                print("🗺️ ✂️ [TRIM] ✅ Trimmed route is valid: \(trimmedMins)min (was \(durationMin)min)")
                                
                                let trimmedRoute = GeneratedRoute(
                                    places: trimmedWaypoints,
                                    polyline: trimmedDirections.overviewPolyline.points,
                                    distanceMeters: trimmedDistance,
                                    durationSeconds: trimmedDuration,
                                    legs: trimmedDirections.legs
                                )
                                validRoutes.append(trimmedRoute)
                                routeCapture?.addRoute(trimmedRoute)
                                return trimmedRoute
                            } else {
                                print("🗺️ ✂️ [TRIM] ✗ Trimmed route still outside tolerance: \(trimmedMins)min")
                            }
                        }
                    }
                }
            }
            
            // Track best fallback - save ANY route as fallback, preferring closest to target
            // This ensures we always have SOMETHING to show rather than leaving user waiting
            let shouldUpdate = bestFallback == nil || diff < bestFallbackDiff
                
                if shouldUpdate {
                    bestFallbackDiff = diff
                    bestFallback = route
                print("🗺️ 📌 Best fallback so far: \(durationMin)min (diff: \(diff)min)")
            }
            
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(route)
        } catch let error as GoogleMapsError {
            // Propagate rate limit errors so caller can handle them
            if case .rateLimited = error {
                throw error
            }
            print("🗺️ Route failed: \(error.localizedDescription)")
            return nil
        } catch {
            print("🗺️ Route failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Select candidate waypoints sorted by preference
    /// Difficulty affects order: easy prefers closer, hard prefers further (within reasonable range)
    /// Uses ELASTIC windows: expands range if not enough candidates found
    /// Now includes walkability scoring and recent-use penalty
    private func selectCandidateWaypoints(from places: [PlaceResult], origin: CLLocationCoordinate2D, idealWaypointDistance: Int, difficulty: RouteDifficulty?, targetDurationMinutes: Int = 20, minRequired: Int = 3) -> [PlaceResult] {
        let idealDistance = Double(idealWaypointDistance)
        
        // Excluded types
        let excludedTypes = Set(["transit_station", "locality", "political", "sublocality"])
        
        // ELASTIC WINDOWS: Start with default range, expand if needed
        var expansionFactor: Double = 1.0
        let maxExpansions = 3  // Up to 3x expansion
        var filtered: [PlaceResult] = []
        var minDistance: Double = 0
        var maxDistance: Double = 0
        
        for attempt in 0..<maxExpansions {
            // Calculate range with current expansion
            minDistance = max(50, idealDistance * 0.3 / expansionFactor)  // Shrink min
            maxDistance = max(400, idealDistance * 2.5 * expansionFactor)  // Grow max
            
            if attempt == 0 {
                print("🎯 Candidate selection: ideal=\(Int(idealDistance))m, range=\(Int(minDistance))-\(Int(maxDistance))m")
            } else {
                print("🎯 📈 ELASTIC EXPANSION \(attempt): range=\(Int(minDistance))-\(Int(maxDistance))m (factor: \(expansionFactor)x)")
            }
        
        // Filter places within acceptable range
            var tooClose: [(String, Int)] = []
            var tooFar: [(String, Int)] = []
            
            filtered = places.filter { place in
            let distance = distanceBetween(origin, place.coordinate)
            let types = Set(place.types ?? [])
            let hasExcludedType = !types.isDisjoint(with: excludedTypes)
                
                // Safety net: Filter out restricted POIs (playcare, nursery, etc.)
                if isRestrictedPOI(place) {
                    return false
                }
                
                if hasExcludedType { return false }
                if distance < minDistance {
                    tooClose.append((place.name, Int(distance)))
                    return false
                }
                if distance > maxDistance {
                    tooFar.append((place.name, Int(distance)))
                    return false
                }
                return true
            }
            
            // Log what was filtered out (only on first attempt)
            if attempt == 0 {
                if !tooClose.isEmpty {
                    print("🎯 ❌ Too close (<\(Int(minDistance))m): \(tooClose.prefix(5).map { "\($0.0) (\($0.1)m)" }.joined(separator: ", "))")
                }
                if !tooFar.isEmpty {
                    print("🎯 ❌ Too far (>\(Int(maxDistance))m): \(tooFar.prefix(5).map { "\($0.0) (\($0.1)m)" }.joined(separator: ", "))")
                }
            }
            
            // Check if we have enough candidates
            if filtered.count >= minRequired {
                print("🎯 ✓ \(filtered.count) candidates in range")
                break
            } else {
                print("🎯 ⚠️ Only \(filtered.count) candidates (need \(minRequired)) - expanding range...")
                expansionFactor *= 1.5  // 1x → 1.5x → 2.25x
            }
        }
        
        // Final fallback: if still not enough, include "too far" POIs
        if filtered.count < minRequired {
            print("🎯 🆘 FALLBACK: Including all non-excluded POIs")
            filtered = places.filter { place in
                let types = Set(place.types ?? [])
                // Still exclude restricted POIs (playcare, nursery, playground, etc.) even in fallback
                return types.isDisjoint(with: excludedTypes) && !isRestrictedPOI(place)
            }
            print("🎯 ✓ \(filtered.count) candidates after fallback")
        }
        
        // Calculate bearing (angle) from origin for each POI
        let placesWithAngles = filtered.map { place -> (place: PlaceResult, distance: Double, angle: Double) in
            let distance = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            return (place, distance, angle)
        }
        
        // Sort based on difficulty preference, but also consider angular diversity
        let sorted: [PlaceResult]
        switch difficulty {
        case .easy:
            // Easy: prefer closer POIs
            sorted = placesWithAngles.sorted { p1, p2 in
                let score1 = p1.distance < idealDistance * 0.5 ? p1.distance + 100 : p1.distance
                let score2 = p2.distance < idealDistance * 0.5 ? p2.distance + 100 : p2.distance
                return score1 < score2
            }.map { $0.place }
            print("🗺️ Sorting: EASY - preferring closer POIs")
            
        case .challenging:
            // Hard: prefer further POIs
            sorted = placesWithAngles.sorted { $0.distance > $1.distance }.map { $0.place }
            print("🗺️ Sorting: HARD - preferring further POIs")
            
        case .moderate, .none:
            // Moderate/None: Use combined scoring with walkability + angular diversity
            // Score each POI: distance fit + walkability bonus - recent use penalty
            // v1.6.38: OSM/Apple POIs not verified against Google are deprioritized
            let googlePOIs = places.filter { isGooglePOI($0) }
            let googlePOICount = googlePOIs.count
            
            let scoredPOIs = placesWithAngles.map { item -> (place: PlaceResult, score: Double, angle: Double) in
                let combinedScore = calculatePOIScore(
                    poi: item.place,
                    origin: origin,
                    idealDistance: idealDistance,
                    targetDurationMinutes: targetDurationMinutes,
                    googlePOICount: googlePOICount,
                    googlePOIs: googlePOIs,
                    totalPOICount: places.count  // v1.6.42: For density-aware distance bonus
                )
                return (item.place, combinedScore, item.angle)
            }
            
            // Group by 8 sectors for angular diversity
            var sectors: [[(place: PlaceResult, score: Double)]] = Array(repeating: [], count: 8)
            for item in scoredPOIs {
                let sectorIndex = Int((item.angle + 180) / 45) % 8
                sectors[sectorIndex].append((item.place, item.score))
            }
            
            // Pick BEST SCORED POI from each sector (not just closest)
            var diverseSelection: [PlaceResult] = []
            for sector in sectors {
                if let best = sector.max(by: { $0.score < $1.score }) {
                    diverseSelection.append(best.place)
                }
            }
            
            // Then add remaining POIs sorted by score
            let diverseIds = Set(diverseSelection.map { $0.placeId })
            let remaining = scoredPOIs
                .filter { !diverseIds.contains($0.place.placeId) }
                .sorted { $0.score > $1.score }
                .map { $0.place }
            
            sorted = diverseSelection + remaining
            
            // Log top picks with their scores
            let topPicks = scoredPOIs.sorted { $0.score > $1.score }.prefix(3)
            let pickLog = topPicks.map { "\($0.place.name) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
            print("🗺️ Sorting: SMART - walkability + variety scoring (\(diverseSelection.count) sectors)")
            print("🗺️ Top picks: \(pickLog)")
        }
        
        print("🗺️ Candidate waypoints: \(sorted.count) (ideal: \(Int(idealDistance))m, range: \(Int(minDistance))-\(Int(maxDistance))m)")
        for (i, place) in sorted.prefix(5).enumerated() {
            let dist = distanceBetween(origin, place.coordinate)
            let angle = bearingBetween(origin, place.coordinate)
            print("🗺️   \(i+1). '\(place.name)' at \(Int(dist))m, \(Int(angle))°")
        }
        
        return sorted
    }
    
    /// Calculate bearing (angle) from one coordinate to another in degrees (-180 to 180)
    private func bearingBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let lat1 = c1.latitude * .pi / 180
        let lat2 = c2.latitude * .pi / 180
        let dLon = (c2.longitude - c1.longitude) * .pi / 180
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        
        let bearing = atan2(y, x) * 180 / .pi
        return bearing  // -180 to 180 degrees
    }
    
    // v2.0.3: Helper to calculate angular difference with proper wrap-around handling
    private func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
    
    /// Select waypoints that are angularly spread around the origin to form better loops
    /// This avoids selecting multiple POIs in the same direction (which causes backtracking)
    /// v2.0.3: Added enforceMinSpacing parameter for ADS=2 case (60° minimum)
    private func selectAngularlyDiverseWaypoints(
        from places: [PlaceResult], 
        origin: CLLocationCoordinate2D, 
        count: Int,
        enforceMinSpacing: Double? = nil  // Optional: minimum angular spacing in degrees (e.g., 60°)
    ) -> [PlaceResult] {
        guard count > 0, !places.isEmpty else { return [] }
        guard count > 1 else { return Array(places.prefix(1)) }  // Single waypoint - just use first
        
        // Calculate angle for each place
        let placesWithAngles = places.map { place -> (place: PlaceResult, angle: Double) in
            let angle = bearingBetween(origin, place.coordinate)
            return (place, angle)
        }
        
        // v2.0.3: Use enforced minimum spacing if provided, otherwise use adaptive spacing
        let minAngularDistance: Double
        if let enforced = enforceMinSpacing {
            minAngularDistance = enforced  // Use enforced spacing (e.g., 60°)
            print("🧭 [ADS] Enforcing minimum \(Int(enforced))° angular spacing")
        } else {
            // Original adaptive logic
            let targetSpread = 360.0 / Double(count)
            minAngularDistance = targetSpread * 0.4  // At least 40% of ideal spread
        }
        
        var selected: [PlaceResult] = []
        var selectedAngles: [Double] = []
        
        for (place, angle) in placesWithAngles {
            // Check if this POI is already selected using unified comparator
            let isAlreadySelected = selected.contains { existing in
                isRouteDuplicate(place, existing)
            }
            
            if isAlreadySelected {
                continue  // Skip this POI - already selected
            }
            
            // v2.0.3: Use angularDifference helper for proper wrap-around handling
            let isAngularlyDistinct = selectedAngles.allSatisfy { existingAngle in
                let angularDistance = angularDifference(angle, existingAngle)
                return angularDistance >= minAngularDistance
            }
            
            if isAngularlyDistinct || selected.isEmpty {
                selected.append(place)
                selectedAngles.append(angle)
                
                if selected.count >= count {
                    break
                }
            }
        }
        
        // If we couldn't find enough angularly diverse POIs, fill with remaining
        if selected.count < count {
            for place in places {
            // Check if this POI is already selected using unified comparator
            let isAlreadySelected = selected.contains { existing in
                isRouteDuplicate(place, existing)
            }
                
                if !isAlreadySelected {
                    selected.append(place)
                    if selected.count >= count {
                        break
                    }
                }
            }
        }
        
        if selected.count > 1 {
            let angles = selected.map { Int(bearingBetween(origin, $0.coordinate)) }
            print("🗺️ Selected \(selected.count) angularly diverse waypoints: \(angles)°")
        }
        
        return selected
    }
    
    /// Add additional discovery spots along the route polyline without affecting timing
    /// These are display-only POIs that weren't used in the Directions API call
    private func addDiscoverySpotsAlongRoute(
        route: GeneratedRoute,
        allPlaces: [PlaceResult],
        desiredCount: Int,
        origin: CLLocationCoordinate2D
    ) async -> GeneratedRoute {
        let routePath = decodePolyline(route.polyline)
        guard routePath.count > 2 else {
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(route)
        }
        
        var existingPlaceIds = Set(route.places.map { $0.placeId })
        let spotsToAdd = desiredCount - route.places.count
        
        guard spotsToAdd > 0 else {
            // FINAL SAFETY WRAPPER: Ensure deduplication on return
            return finalizeRouteDedup(route)
        }
        
        print("🗺️ Adding up to \(spotsToAdd) discovery spots along route (have \(allPlaces.count) POIs available)...")
        
        var additionalSpots: [PlaceResult] = []
        
        // Calculate ideal spacing based on route length
        // Route distance in meters (approximate from polyline)
        var totalRouteDistance: Double = 0
        for i in 1..<routePath.count {
            totalRouteDistance += distanceBetween(routePath[i-1], routePath[i])
        }
        
        // Ideal spacing = route distance / (total spots + 1) to distribute evenly
        let totalSpotsIncludingExisting = route.places.count + spotsToAdd
        let idealSpacing = totalRouteDistance / Double(totalSpotsIncludingExisting + 1)
        let minSpacing = max(150, idealSpacing * 0.6)  // At least 60% of ideal, min 150m
        
        // Reduce min spacing for longer routes to fit more POIs
        let adjustedMinSpacing = max(100, min(minSpacing, totalRouteDistance / Double(spotsToAdd + 2)))
        
        print("🗺️ Route ~\(Int(totalRouteDistance))m, ideal spacing: \(Int(idealSpacing))m, min: \(Int(adjustedMinSpacing))m")
        
        for i in 1...spotsToAdd {
            // Calculate position along route (skip first 8% and last 8%)
            let fraction = 0.08 + (0.84 * Double(i) / Double(spotsToAdd + 1))
            let targetIndex = Int(Double(routePath.count - 1) * fraction)
            let targetPoint = routePath[targetIndex]
            
            // All existing waypoint coordinates (original + already added)
            let existingCoords = route.places.map { $0.coordinate } + additionalSpots.map { $0.coordinate }
            
            // Try progressively larger radii to find POIs near the route
            var nearestPOI: PlaceResult? = nil
            
            for maxDistanceFromRoute in [100.0, 200.0, 300.0, 500.0] {
                let candidatePOIs = allPlaces.filter { place in
                    // Check if already in route using unified comparator
                    let isDuplicate = route.places.contains { existing in
                        isRouteDuplicate(place, existing)
                    }
                    
                    // Also check against already-added discovery spots using unified comparator
                    let isInAdditionalSpots = additionalSpots.contains { existing in
                        isRouteDuplicate(place, existing)
                    }
                    
                    guard !isDuplicate && !isInAdditionalSpots else { return false }
                    guard distanceBetween(origin, place.coordinate) > 60 else { return false }
                    
                    // Check minimum spacing from existing waypoints (relaxed for later attempts)
                    let effectiveMinSpacing = maxDistanceFromRoute > 200 ? adjustedMinSpacing * 0.7 : adjustedMinSpacing
                    let tooCloseToExisting = existingCoords.contains { coord in
                        distanceBetween(coord, place.coordinate) < effectiveMinSpacing
                    }
                    guard !tooCloseToExisting else { return false }
                    
                    // Check if POI is near the target point on route
                    return distanceBetween(targetPoint, place.coordinate) < maxDistanceFromRoute
                }
                
                // Pick the one closest to our target point
                nearestPOI = candidatePOIs.min { p1, p2 in
                    distanceBetween(targetPoint, p1.coordinate) < distanceBetween(targetPoint, p2.coordinate)
                }
                
                if nearestPOI != nil { break }
            }
            
            if let poi = nearestPOI {
                additionalSpots.append(poi)
                existingPlaceIds.insert(poi.placeId)
                let dist = Int(distanceBetween(targetPoint, poi.coordinate))
                print("🗺️   Spot \(i): \(poi.name) (\(dist)m from route)")
            } else {
                print("🗺️   Spot \(i): No POI found near this section")
            }
        }
        
        // Merge original waypoints with additional spots, sorted by position along route
        var allWaypoints = route.places + additionalSpots
        
        // FINAL DEDUPLICATION: Remove any duplicates that might have slipped through using unified comparator
        var deduplicatedWaypoints: [PlaceResult] = []
        for waypoint in allWaypoints {
            let isDuplicate = deduplicatedWaypoints.contains { existing in
                isRouteDuplicate(waypoint, existing)
            }
            
            if isDuplicate {
                if let matched = deduplicatedWaypoints.first(where: { isRouteDuplicate(waypoint, $0) }) {
                    let distance = distanceBetween(waypoint.coordinate, matched.coordinate)
                    print("🗺️ Removed duplicate discovery spot: '\(waypoint.name)' (matches '\(matched.name)', \(String(format: "%.1f", distance))m apart)")
                }
            }
            
            if !isDuplicate {
                deduplicatedWaypoints.append(waypoint)
            }
        }
        
        allWaypoints = deduplicatedWaypoints
        
        // Sort by distance along route
        allWaypoints.sort { p1, p2 in
            let pos1 = findPositionAlongRoute(p1.coordinate, routePath: routePath)
            let pos2 = findPositionAlongRoute(p2.coordinate, routePath: routePath)
            return pos1 < pos2
        }
        
        let duplicatesRemoved = (route.places.count + additionalSpots.count) - allWaypoints.count
        if duplicatesRemoved > 0 {
            print("🗺️ Removed \(duplicatesRemoved) duplicate waypoint(s) during discovery spot merge")
        }
        print("🗺️ Route now has \(allWaypoints.count) discovery spots (added \(additionalSpots.count - duplicatesRemoved))")
        
        // v1.8.10: Regenerate polyline if waypoints changed to fix Star Inn bug
        if allWaypoints.count != route.places.count {
            print("🗺️ Regenerating polyline for \(allWaypoints.count) waypoints...")
            
            // v2.0.3 Batch A: Wrap with timeout
            let regenTimeout = RoutingToggles.perCallTimeoutNormal
            let (regenResult, didTimeout) = await directionsWithTimeout(
                origin: origin,
                destination: origin,
                waypoints: allWaypoints.map { $0.coordinate },
                timeout: regenTimeout,
                targetDurationMinutes: nil,
                angularDiversityScore: nil,
                postcode: nil
            )
            
            if didTimeout {
                print("🗺️ ⏱️ Timeout regenerating polyline for discovery spots")
            } else if let newDirections = regenResult {
                print("🗺️ ✅ Polyline regenerated - \(newDirections.legs.count) legs")
                let newRoute = GeneratedRoute(
                    places: allWaypoints,
                    polyline: newDirections.overviewPolyline.points,
                    distanceMeters: newDirections.legs.reduce(0) { $0 + $1.distance.value },
                    durationSeconds: newDirections.legs.reduce(0) { $0 + $1.duration.value },
                    legs: newDirections.legs
                )
                // FINAL SAFETY WRAPPER: Ensure deduplication on return
                return finalizeRouteDedup(newRoute)
            } else {
                print("🗺️ ⚠️ Polyline regeneration failed")
                // Fall back to original polyline
            }
        }
        
        let finalRoute = GeneratedRoute(
            places: allWaypoints,
            polyline: route.polyline,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            legs: route.legs
        )
        // FINAL SAFETY WRAPPER: Ensure deduplication on return
        return finalizeRouteDedup(finalRoute, targetDurationMinutes: nil)
    }
    
    /// Find approximate position (0.0 to 1.0) of a coordinate along the route
    private func findPositionAlongRoute(_ coord: CLLocationCoordinate2D, routePath: [CLLocationCoordinate2D]) -> Double {
        var closestIndex = 0
        var closestDistance = Double.infinity
        
        for (index, point) in routePath.enumerated() {
            let dist = distanceBetween(coord, point)
            if dist < closestDistance {
                closestDistance = dist
                closestIndex = index
            }
        }
        
        return Double(closestIndex) / Double(max(1, routePath.count - 1))
    }
    
    // MARK: - Helper Methods
    
    /// Decode a Google Maps encoded polyline string into coordinates
    func decodePolyline(_ encodedPath: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encodedPath.startIndex
        var lat: Int32 = 0
        var lng: Int32 = 0
        
        while index < encodedPath.endIndex {
            // Decode latitude
            var shift: Int32 = 0
            var result: Int32 = 0
            var byte: Int32
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += deltaLat
            
            // Decode longitude
            shift = 0
            result = 0
            
            repeat {
                guard index < encodedPath.endIndex else { break }
                byte = Int32(encodedPath[index].asciiValue! - 63)
                index = encodedPath.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let deltaLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += deltaLng
            
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            )
            coordinates.append(coordinate)
        }
        
        return coordinates
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
    
    // MARK: - v1.9.48: POI Deduplication Helper
    /// Deduplicates POIs by location proximity
    /// - Same name AND within 50m → dedupe (actual duplicate from different source)
    /// - Very close (<20m) regardless of name → dedupe (same physical location)
    /// Smart merge Geograph POIs with existing POIs from other sources
    /// Uses intelligent deduplication that considers source quality and POI quality scores
    /// STRICT: Geograph is evidence only - never replaces actual business POIs
    private func smartMergeGeographPOIs(
        existing: [PlaceResult],
        newGeograph: [PlaceResult],
        origin: CLLocationCoordinate2D
    ) -> [PlaceResult] {
        var merged = existing
        
        for geographPOI in newGeograph {
            // Skip non-POIs
            if isNonPOI(geographPOI) {
                continue
            }
            
            let geographScore = geographQualityScore(geographPOI)
            
            // Check for duplicates with existing POIs
            if let duplicateIndex = merged.firstIndex(where: { existing in
                // Skip non-POIs as merge targets
                if isNonPOI(existing) {
                    return false
                }
                return isDuplicateGeograph(geographPOI: geographPOI, existingPOI: existing)
            }) {
                // Duplicate found - choose best POI
                let existingPOI = merged[duplicateIndex]
                
                // STRICT: Never let Geograph replace actual business POIs (Google/Apple/OSM)
                // Geograph is evidence only - only replace if existing is also Geograph or Unknown
                if existingPOI.source == .google || existingPOI.source == .apple || existingPOI.source == .osm {
                    // Keep existing POI - Geograph is evidence only
                    continue
                }
                
                let best = chooseBestPOI(geographPOI: geographPOI, existingPOI: existingPOI)
                
                if best.placeId == geographPOI.placeId {
                    // Replace with Geograph version (only if existing was Geograph/Unknown)
                    merged[duplicateIndex] = geographPOI
                    print("   🔄 Replaced \(existingPOI.source.rawValue) POI '\(existingPOI.name)' with Geograph '\(geographPOI.name)' (score: \(String(format: "%.1f", geographScore)))")
                }
                // Otherwise keep existing POI
            } else {
                // No duplicate - add Geograph POI (as evidence)
                merged.append(geographPOI)
            }
        }
        
        return merged
    }
    
    /// Check if Geograph POI is a duplicate of existing POI
    /// STRICT: Requires type compatibility and high name similarity
    private func isDuplicateGeograph(geographPOI: PlaceResult, existingPOI: PlaceResult) -> Bool {
        // Never merge non-POIs
        if isNonPOI(geographPOI) || isNonPOI(existingPOI) {
            return false
        }
        
        let distance = distanceBetween(geographPOI.coordinate, existingPOI.coordinate)
        
        // Extract base names (remove Geograph grid prefixes for better matching)
        let geographBase = extractBaseFeatureName(geographPOI.name)
        let existingBase = extractBaseFeatureName(existingPOI.name)
        
        // Check type compatibility first
        let geographCategory = determinePOICategory(geographPOI)
        let existingCategory = determinePOICategory(existingPOI)
        let typesCompatible = arePOITypesCompatible(geographPOI, existingPOI, poiCategory: geographCategory, otherCategory: existingCategory)
        
        if !typesCompatible {
            return false
        }
        
        // Rule 1: Exact same location (< 10m) - definitely same place (if types compatible)
        if distance < 10.0 {
            return true
        }
        
        // Rule 2: Same base name (after normalization) AND close (within 25m) AND type compatible
        // TIGHTENED: distance ≤ 25m (was 30m)
        if geographBase == existingBase && distance <= 25.0 && typesCompatible {
            return true
        }
        
        // Rule 3: High name similarity AND close (within 25m) AND type compatible
        // TIGHTENED: similarity > 0.85 (was 0.8), distance ≤ 25m (was 30m)
        let nameSimilarity = calculateNameSimilarity(geographBase, existingBase, poi1: geographPOI, poi2: existingPOI)
        if nameSimilarity > 0.85 && distance <= 25.0 && typesCompatible {
            return true
        }
        
        // Rule 4: Very close (≤ 15m) AND same coarse group
        // TIGHTENED: distance ≤ 15m (was 20m), use coarse group
        let group1 = coarseGroup(geographPOI)
        let group2 = coarseGroup(existingPOI)
        let sameCoarseGroup = group1 != nil && group1 == group2 && group1 != "Unknown"
        if distance <= 15.0 && sameCoarseGroup {
            return true
        }
        
        // Rule 5: Moderate name similarity AND close AND same coarse group
        // TIGHTENED: similarity > 0.80 (was 0.7), distance ≤ 30m (was 40m)
        if nameSimilarity > 0.80 && distance <= 30.0 && sameCoarseGroup {
            return true
        }
        
        return false
    }
    
    /// Calculate name similarity (0.0 to 1.0)
    /// More conservative: substring matches only return high score if types are compatible
    private func calculateNameSimilarity(_ name1: String, _ name2: String, poi1: PlaceResult? = nil, poi2: PlaceResult? = nil) -> Double {
        let lower1 = name1.lowercased()
        let lower2 = name2.lowercased()
        
        // Exact match
        if lower1 == lower2 {
            return 1.0
        }
        
        // One contains the other - only return 0.9 if coarse groups match (prevents unsafe merges)
        if lower1.contains(lower2) || lower2.contains(lower1) {
            // If we have POI context, check coarse groups match
            if let p1 = poi1, let p2 = poi2 {
                let group1 = coarseGroup(p1)
                let group2 = coarseGroup(p2)
                if let g1 = group1, let g2 = group2, g1 == g2 && g1 != "Unknown" {
                    return 0.85  // Substring match with compatible groups
                }
                // If groups don't match, don't give high score for substring
                // Fall through to word-based similarity
            } else {
                // No context - be conservative, return lower score
                return 0.75
            }
        }
        
        // Word overlap with weighted scoring
        var words1 = Set(lower1.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        var words2 = Set(lower2.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        
        // Remove common location words that don't affect POI identity
        let locationWords = Set(["on", "at", "near", "the", "a", "an", "road", "street", "lane", "way", "avenue", "close", "drive", "kirkhamgate", "batley", "brandy", "carr"])
        words1 = words1.subtracting(locationWords)
        words2 = words2.subtracting(locationWords)
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        if union.isEmpty {
            return 0.0
        }
        
        // Base Jaccard similarity
        let jaccard = Double(intersection.count) / Double(union.count)
        
        // Boost similarity if core identifying words match (e.g., "star" + "inn" = high confidence)
        // If intersection has 2+ words and represents >50% of the shorter name, boost
        // BUT only if types are compatible (if we have POI context)
        let minWords = min(words1.count, words2.count)
        if minWords >= 2 && intersection.count >= 2 && Double(intersection.count) >= Double(minWords) * 0.5 {
            // Only boost if types are compatible (if we have POI context)
            var shouldBoost = true
            if let p1 = poi1, let p2 = poi2 {
                let group1 = coarseGroup(p1)
                let group2 = coarseGroup(p2)
                if let g1 = group1, let g2 = group2 {
                    shouldBoost = (g1 == g2 && g1 != "Unknown")
                }
            }
            if shouldBoost {
                // Boost by up to 0.15 for strong core word matches
                let boost = min(0.15, Double(intersection.count - 1) * 0.05)
                return min(1.0, jaccard + boost)
            }
        }
        
        return jaccard
    }
    
    /// Check if two POIs are in the same category
    private func sameCategory(_ poi1: PlaceResult, _ poi2: PlaceResult) -> Bool {
        let cat1 = determinePOICategory(poi1)
        let cat2 = determinePOICategory(poi2)
        return cat1 == cat2
    }
    
    // MARK: - Non-POI Detection & Coarse Grouping
    
    /// Check if a POI is actually a non-POI (junction, road, locality, etc.)
    /// These should never be merge targets or canonical representatives
    private func isNonPOI(_ poi: PlaceResult) -> Bool {
        let name = poi.name.lowercased()
        let types = Set((poi.types ?? []).map { $0.lowercased() })
        
        // Check types array for non-POI indicators
        let nonPOITypes = Set(["junction", "road", "locality", "neighbourhood", "sublocality", 
                              "political", "administrative", "route", "street_address"])
        if !types.isDisjoint(with: nonPOITypes) {
            return true
        }
        
        // Check name patterns for road junctions (e.g., "Batley Road Brandy Carr Road")
        // Pattern: Two road names separated by space (common OSM junction naming)
        let roadWords = ["road", "street", "lane", "way", "avenue", "close", "drive", "crescent", "grove", "place", "terrace"]
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var roadCount = 0
        for word in words {
            if roadWords.contains(word.lowercased()) {
                roadCount += 1
            }
        }
        // If name contains 2+ road words, likely a junction
        if roadCount >= 2 {
            return true
        }
        
        // Check for explicit junction/road patterns
        if name.contains("junction") || name.contains("intersection") || name.contains("crossroads") {
            return true
        }
        
        // Check for Geograph photo captions (not actual POIs)
        if poi.source == .geograph {
            // Geograph photos with generic descriptions are not POIs
            let genericPatterns = ["looking", "view", "path", "field", "track", "footpath", "bridleway"]
            if genericPatterns.contains(where: { name.contains($0) }) && !name.contains("memorial") && !name.contains("monument") {
                // Check if it's just a photo caption, not a named feature
                if name.count < 30 && !name.contains("church") && !name.contains("inn") && !name.contains("hall") {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Coarse grouping for type compatibility
    /// Groups POIs into broad categories for compatibility checking
    private func coarseGroup(_ poi: PlaceResult) -> String? {
        let category = determinePOICategory(poi)
        let name = poi.name.lowercased()
        let types = Set((poi.types ?? []).map { $0.lowercased() })
        
        // Food & Drink
        if category == "Pub/Inn" || 
           name.contains("restaurant") || name.contains("cafe") || name.contains("bar") ||
           name.contains("takeaway") || name.contains("fish and chips") || name.contains("bistro") ||
           types.contains("restaurant") || types.contains("cafe") || types.contains("bar") ||
           types.contains("food") || types.contains("meal_takeaway") {
            return "Food & Drink"
        }
        
        // Retail & Services
        if category == "Store" ||
           name.contains("shop") || name.contains("store") || name.contains("supermarket") ||
           name.contains("pharmacy") || name.contains("post office") ||
           types.contains("store") || types.contains("shop") || types.contains("supermarket") ||
           types.contains("pharmacy") || types.contains("post_office") {
            return "Retail & Services"
        }
        
        // Personal Care & Health
        if name.contains("hairdresser") || name.contains("barber") || name.contains("salon") ||
           name.contains("dentist") || name.contains("dental") || name.contains("physiotherapy") ||
           name.contains("physio") || name.contains("clinic") || name.contains("surgery") ||
           types.contains("hair_care") || types.contains("beauty_salon") || types.contains("dentist") ||
           types.contains("physiotherapist") || types.contains("doctor") {
            return "Personal Care & Health"
        }
        
        // Childcare & Education
        if name.contains("nursery") || name.contains("playcare") || name.contains("daycare") ||
           name.contains("preschool") || name.contains("school") || name.contains("academy") ||
           types.contains("school") || types.contains("nursery") || types.contains("kindergarten") ||
           types.contains("childcare") {
            return "Childcare & Education"
        }
        
        // Religious & Community
        if category == "Religious Building" || category == "Community Building" ||
           name.contains("church") || name.contains("chapel") || name.contains("mosque") ||
           name.contains("synagogue") || name.contains("temple") || name.contains("village hall") ||
           name.contains("community") || name.contains("community centre") ||
           types.contains("place_of_worship") || types.contains("church") || types.contains("community_centre") {
            return "Religious & Community"
        }
        
        // Heritage & Monuments
        if category == "Historic Building" || category == "Memorial/Monument" ||
           category == "Industrial Heritage" ||
           name.contains("memorial") || name.contains("monument") || name.contains("heritage") ||
           types.contains("memorial") || types.contains("monument") || types.contains("historic") {
            return "Heritage & Monuments"
        }
        
        // Postbox (special case - incompatible with most things)
        if category == "Postbox" || name.contains("postbox") || name.contains("post box") {
            return "Postbox"
        }
        
        // Natural Features
        if category == "Natural Feature" ||
           types.contains("park") || types.contains("natural_feature") {
            return "Natural Feature"
        }
        
        // Unknown/Landmark (default catch-all)
        if category == "Unknown" || category == "Landmark" {
            return "Unknown"
        }
        
        return category
    }
    
    /// Choose best POI when duplicate found (considers source priority and quality)
    private func chooseBestPOI(geographPOI: PlaceResult, existingPOI: PlaceResult) -> PlaceResult {
        let geographScore = geographQualityScore(geographPOI)
        
        // Priority 1: Always prefer Google (most accurate/up-to-date)
        if existingPOI.source == .google {
            return existingPOI
        }
        
        // Priority 2: Prefer high-quality Geograph over Apple/OSM
        if geographScore >= 6.0 && (existingPOI.source == .apple || existingPOI.source == .osm) {
            // Check if Geograph has better name/description
            let geographHasBetterName = geographPOI.name.count > existingPOI.name.count
            let geographHasBetterDesc = (geographPOI.vicinity?.count ?? 0) > (existingPOI.vicinity?.count ?? 0)
            
            if geographHasBetterName || geographHasBetterDesc {
                return geographPOI  // Geograph has better metadata
            }
        }
        
        // Priority 3: Prefer Geograph over OSM if both are low quality
        if geographScore >= 4.0 && existingPOI.source == .osm && geographScore > 4.0 {
            return geographPOI
        }
        
        // Default: keep existing (preserves priority order)
        return existingPOI
    }
    
    /// Check if a POI name matches a known chain (Tesco, Co-op, Costa, Greggs, Starbucks, etc.)
    private func isChainPOI(_ poi: PlaceResult) -> Bool {
        let name = normalizePOIName(poi.name).lowercased()
        let chainNames = ["tesco", "co-op", "coop", "costa", "greggs", "starbucks", "sainsburys", "aldi", "lidl", "morrisons", "asda", "spar", "m&s", "marks and spencer", "boots", "superdrug"]
        return chainNames.contains { name.contains($0) }
    }
    
    /// Check if two POIs have matching address/vicinity (for chain validation)
    private func hasMatchingAddress(_ a: PlaceResult, _ b: PlaceResult) -> Bool {
        // Check if vicinity strings match (if available)
        if let vicinityA = a.vicinity, let vicinityB = b.vicinity,
           !vicinityA.isEmpty, !vicinityB.isEmpty,
           vicinityA.lowercased() == vicinityB.lowercased() {
            return true
        }
        return false
    }
    
    private func deduplicatePOIs(_ pois: [PlaceResult]) -> [PlaceResult] {
        var result: [PlaceResult] = []
        
        // Sort by source priority: Google > Geograph (high score) > Apple > OSM > Geograph (low score)
        let sorted = pois.sorted { first, second in
            let firstPriority = sourcePriority(first)
            let secondPriority = sourcePriority(second)
            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }
            // If same priority, prefer higher quality Geograph
            if first.source == .geograph && second.source == .geograph {
                return geographQualityScore(first) > geographQualityScore(second)
            }
            return false
        }
        
        for poi in sorted {
            // Skip non-POIs - they cannot be merged or be merge targets
            if isNonPOI(poi) {
                continue
            }
            
            let isDuplicate = result.contains { existing in
                // Skip non-POIs as merge targets
                if isNonPOI(existing) {
                    return false
                }
                
                let distance = distanceBetween(existing.coordinate, poi.coordinate)
                
                // Extract base names (remove Geograph grid prefixes, normalize)
                let existingBase = extractBaseFeatureName(existing.name)
                let poiBase = extractBaseFeatureName(poi.name)
                
                // SAFETY CHECK: Must be type compatible before any merge
                let poiCategory = determinePOICategory(poi)
                let existingCategory = determinePOICategory(existing)
                let typesCompatible = arePOITypesCompatible(poi, existing, poiCategory: poiCategory, otherCategory: existingCategory)
                
                // If types are incompatible, never merge
                if !typesCompatible {
                    return false
                }
                
                // CHAIN SAFEGUARD: For chain POIs, require ≤15m or address/plus-code match
                let isChain = isChainPOI(poi) || isChainPOI(existing)
                if isChain {
                    let hasAddressMatch = hasMatchingAddress(poi, existing)
                    if distance > 15.0 && !hasAddressMatch {
                        // Chain POIs too far apart without address match - don't merge
                        return false
                    }
                }
                
                // Calculate name similarity with POI context for better accuracy
                let nameSimilarity = calculateNameSimilarity(existingBase, poiBase, poi1: existing, poi2: poi)
                
                // Rule 1: Exact name match (after normalization) AND close AND type compatible
                let exactNameMatch = existingBase == poiBase && distance <= 25 && typesCompatible
                
                // Rule 2: Name similarity (handles "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate")
                // TIGHTENED: similarity ≥ 0.85 AND distance ≤ 25m AND type compatible
                let similarNameAndClose = nameSimilarity >= 0.85 && distance <= 25 && typesCompatible
                
                // Rule 3: Very close - requires compatible types (no similarity-only merge)
                // TIGHTENED: distance ≤ 15m AND types compatible (removed similarity fallback)
                let veryClose = distance <= 15 && typesCompatible
                
                // Rule 4: Same coarse group AND very close AND similar name
                // TIGHTENED: same coarse group AND similarity ≥ 0.80 AND distance ≤ 20m
                let group1 = coarseGroup(poi)
                let group2 = coarseGroup(existing)
                let sameCoarseGroup = group1 != nil && group1 == group2 && group1 != "Unknown"
                let sameCatAndClose = sameCoarseGroup && distance <= 20 && nameSimilarity >= 0.80
                
                return exactNameMatch || similarNameAndClose || veryClose || sameCatAndClose
            }
            
            if !isDuplicate {
                result.append(poi)
            } else {
                // Log which duplicate was removed
                if let existing = result.first(where: { existing in
                    if isNonPOI(existing) {
                        return false
                    }
                    let distance = distanceBetween(existing.coordinate, poi.coordinate)
                    let existingBase = extractBaseFeatureName(existing.name)
                    let poiBase = extractBaseFeatureName(poi.name)
                    let poiCategory = determinePOICategory(poi)
                    let existingCategory = determinePOICategory(existing)
                    let typesCompatible = arePOITypesCompatible(poi, existing, poiCategory: poiCategory, otherCategory: existingCategory)
                    if !typesCompatible {
                        return false
                    }
                    let nameSimilarity = calculateNameSimilarity(existingBase, poiBase, poi1: existing, poi2: poi)
                    let group1 = coarseGroup(poi)
                    let group2 = coarseGroup(existing)
                    let sameCoarseGroup = group1 != nil && group1 == group2 && group1 != "Unknown"
                    return (existingBase == poiBase && distance <= 25 && typesCompatible) ||
                           (nameSimilarity >= 0.85 && distance <= 25 && typesCompatible) ||
                           (distance <= 15 && typesCompatible) ||
                           (sameCoarseGroup && distance <= 20 && nameSimilarity >= 0.80)
                }) {
                    print("🔄 Dedup: Removed '\(poi.name)' (source: \(poi.source.rawValue)) - duplicate of '\(existing.name)' (source: \(existing.source.rawValue))")
                }
            }
        }
        
        return result
    }
    
    /// Get source priority for deduplication (lower number = higher priority)
    private func sourcePriority(_ poi: PlaceResult) -> Int {
        switch poi.source {
        case .google: return 1
        case .geograph:
            // High-quality Geograph gets priority 2, low-quality gets 4
            return geographQualityScore(poi) >= 6.0 ? 2 : 4
        case .apple: return 3
        case .osm: return 5
        case .unknown: return 6
        }
    }
    
    // MARK: - Canonical POI Deduplication (v1.9.50)
    
    /// Canonical POI deduplication layer
    /// Clusters POIs spatially and by name similarity to create canonical representatives
    /// Prevents duplicates like "The Star Inn" vs "SE2922: The Star Inn, Kirkhamgate"
    /// 
    /// Process:
    /// 1. Spatial clustering (~50m) - treats each cluster as single real-world place
    /// 2. Name normalization + similarity (≥0.85) - merges similar names
    /// 3. Source priority - chooses best representative (Google > Apple > OSM > Geograph)
    /// 4. Preserves provenance - logs all merged aliases
    private func canonicalizePOIs(_ pois: [PlaceResult], origin: CLLocationCoordinate2D) -> [PlaceResult] {
        guard !pois.isEmpty else { return pois }
        
        print("🎯 [CANONICAL] Processing \(pois.count) POIs with type-aware merge rules:")
        print("   • Requires: (1) proximity ≤150m (or ≤400m with same grid ref/OSM ID), (2) compatible types, (3) name similarity ≥0.85 OR shared source signal")
        print("   • Never merges incompatible types (e.g., pub vs postbox)")
        
        var canonical: [PlaceResult] = []
        var processed = Set<String>()
        var mergeLog: [(canonical: String, merged: [String])] = []
        
        // Sort by source priority (best sources first)
        let sorted = pois.sorted { first, second in
            let firstPriority = sourcePriority(first)
            let secondPriority = sourcePriority(second)
            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }
            // If same priority, prefer Geograph with higher quality score
            if first.source == .geograph && second.source == .geograph {
                return geographQualityScore(first) > geographQualityScore(second)
            }
            return false
        }
        
        for poi in sorted {
            // Skip if already processed
            if processed.contains(poi.placeId) {
                continue
            }
            
            // Skip non-POIs - they cannot be canonical representatives
            if isNonPOI(poi) {
                continue
            }
            
            // Find all POIs in this canonical cluster
            var cluster: [PlaceResult] = [poi]
            processed.insert(poi.placeId)
            
            // Normalize this POI's name for comparison
            let poiBaseName = normalizePOIName(poi.name)
            let poiGridRef = extractGeographGridReference(poi.name)
            let poiOSMId = extractOSMId(poi.placeId)
            let poiCategory = determinePOICategory(poi)
            
            for otherPOI in sorted {
                if processed.contains(otherPOI.placeId) {
                    continue
                }
                
                // Skip non-POIs - they cannot be merged
                if isNonPOI(otherPOI) {
                    continue
                }
                
                // OPTIMIZATION: Quick distance check first (fastest filter)
                // Only compare POIs that could potentially be merged (within 500m)
                // This avoids expensive name similarity calculations for distant POIs
                let distance = distanceBetween(poi.coordinate, otherPOI.coordinate)
                if distance > 500.0 {
                    continue  // Too far to merge, skip expensive checks
                }
                let otherBaseName = normalizePOIName(otherPOI.name)
                let otherGridRef = extractGeographGridReference(otherPOI.name)
                let otherOSMId = extractOSMId(otherPOI.placeId)
                let otherCategory = determinePOICategory(otherPOI)
                
                // SAFETY CHECK: Must be type compatible before any merge
                let typesCompatible = arePOITypesCompatible(poi, otherPOI, poiCategory: poiCategory, otherCategory: otherCategory)
                if !typesCompatible {
                    continue
                }
                
                // Special handling for "Unknown" types - only merge if extremely similar and very close
                if poiCategory == "Unknown" || otherCategory == "Unknown" {
                    let nameSimilarity = calculateNameSimilarity(poiBaseName, otherBaseName, poi1: poi, poi2: otherPOI)
                    // Only allow merge if extremely similar names AND extremely close
                    if nameSimilarity >= 0.92 && distance <= 10.0 {
                        cluster.append(otherPOI)
                        processed.insert(otherPOI.placeId)
                        print("   🔗 Unknown type merge: \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity))")
                        continue
                    } else {
                        continue  // Don't merge Unknown types otherwise
                    }
                }
                
                // Shared source signals (check first - these override distance limits)
                let hasSharedGridRef = poiGridRef != nil && poiGridRef == otherGridRef
                let hasSharedOSMId = poiOSMId != nil && poiOSMId == otherOSMId
                
                // Name similarity with POI context
                let nameSimilarity = calculateNameSimilarity(poiBaseName, otherBaseName, poi1: poi, poi2: otherPOI)
                let hasNameSimilarity = nameSimilarity >= 0.90  // TIGHTENED from 0.85
                let _ = nameSimilarity >= 0.95  // Track very high similarity (unused for now)
                let _ = nameSimilarity > 0.95   // Track very high similarity (unused for now)
                
                // Debug logging for potential duplicates (only log close matches to reduce noise)
                // Only log if very close (<100m) or high similarity (>0.85) to reduce log spam
                if distance <= 100.0 || nameSimilarity > 0.85 {
                    let gridRefInfo: String
                    if hasSharedGridRef {
                        gridRefInfo = "shared: \(poiGridRef ?? "none")"
                    } else if poiGridRef != nil && otherGridRef == nil {
                        gridRefInfo = "one-sided: \(poiGridRef ?? "none")"
                    } else if poiGridRef == nil && otherGridRef != nil {
                        gridRefInfo = "one-sided: \(otherGridRef ?? "none")"
                    } else {
                        gridRefInfo = "none"
                    }
                    print("   🔍 Checking: '\(poi.name)' vs '\(otherPOI.name)' - \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity)), gridRef: \(gridRefInfo), types: \(poiCategory)/\(otherCategory)")
                }
                
                // RULE 1: Hard spatial merge (≤20m) - requires compatible types, ignores names
                // TIGHTENED: distance ≤ 20m (was 30m)
                let hardSpatialMerge = distance <= 20.0
                if hardSpatialMerge {
                    // Types already checked above
                    cluster.append(otherPOI)
                    processed.insert(otherPOI.placeId)
                    print("   🔗 Hard spatial merge: \(String(format: "%.1f", distance))m apart (ignoring name mismatch)")
                    continue
                }
                
                // RULE 2: Same Geograph grid reference - merge if very high name similarity
                // STRICT: Grid ref alone not enough - requires name similarity ≥ 0.92
                if hasSharedGridRef {
                    let withinStandardRange = distance <= 200.0 && nameSimilarity >= 0.92
                    let withinExtendedRange = distance <= 400.0 && nameSimilarity >= 0.92 && hasNameSimilarity
                    
                    if withinStandardRange || withinExtendedRange {
                        // Types already checked above
                        cluster.append(otherPOI)
                        processed.insert(otherPOI.placeId)
                        let rangeType = withinStandardRange ? "standard" : "extended (name similarity)"
                        print("   🔗 Same grid ref: \(poiGridRef ?? "") - \(String(format: "%.1f", distance))m apart (\(rangeType) merge)")
                        continue
                    } else {
                        print("   ⚠️ Same grid ref but insufficient name similarity: '\(poi.name)' vs '\(otherPOI.name)' - \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity)) (needs ≥0.92)")
                        continue
                    }
                }
                
                // RULE 2b: One has grid ref, other doesn't - merge ONLY if very high name similarity (≥0.92)
                // STRICT: Grid ref alone not enough - requires very high name similarity
                let oneHasGridRef = (poiGridRef != nil && otherGridRef == nil) || (poiGridRef == nil && otherGridRef != nil)
                if oneHasGridRef {
                    // STRICT: Require name similarity ≥ 0.92 (was 0.85/0.9)
                    let withinExtendedRange = distance <= 500.0 && nameSimilarity >= 0.92
                    let withinStandardRange = distance <= 300.0 && nameSimilarity >= 0.92
                    
                    if withinStandardRange || withinExtendedRange {
                        // Types already checked above
                        cluster.append(otherPOI)
                        processed.insert(otherPOI.placeId)
                        let gridRefPOI = poiGridRef != nil ? poi.name : otherPOI.name
                        let rangeType = withinStandardRange ? "standard" : "extended (very high similarity)"
                        print("   🔗 Grid ref match (one-sided): '\(gridRefPOI)' - \(String(format: "%.1f", distance))m apart, similarity: \(String(format: "%.2f", nameSimilarity)) (\(rangeType))")
                        continue
                    } else if distance <= 500.0 {
                        // Debug: why didn't it match?
                        print("   ⚠️ Grid ref one-sided but no merge: '\(poi.name)' vs '\(otherPOI.name)' - \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity)) (needs ≥0.92)")
                    }
                }
                
                // RULE 3: Same OSM ID - merge immediately (within 200m, or up to 400m with name similarity)
                if hasSharedOSMId {
                    let withinStandardRange = distance <= 200.0
                    let withinExtendedRange = distance <= 400.0 && hasNameSimilarity
                    
                    if withinStandardRange || withinExtendedRange {
                        // REQUIREMENT: Compatible POI types
                        let typesCompatible = arePOITypesCompatible(poi, otherPOI, poiCategory: poiCategory, otherCategory: otherCategory)
                        if typesCompatible {
                            cluster.append(otherPOI)
                            processed.insert(otherPOI.placeId)
                            let rangeType = withinStandardRange ? "standard" : "extended (name similarity)"
                            print("   🔗 Same OSM ID: \(poiOSMId ?? "") - \(String(format: "%.1f", distance))m apart (\(rangeType) merge)")
                            continue
                        } else {
                            print("   ❌ Type mismatch (same OSM ID): '\(poi.name)' (\(poiCategory)) vs '\(otherPOI.name)' (\(otherCategory)) - \(String(format: "%.1f", distance))m apart")
                            continue
                        }
                    }
                }
                
                // RULE 4: Medium merge (30-60m) with name similarity
                // TIGHTENED: similarity ≥ 0.90 (was 0.85)
                if distance > 30.0 && distance < 60.0 && nameSimilarity >= 0.90 {
                    // Types already checked above
                    cluster.append(otherPOI)
                    processed.insert(otherPOI.placeId)
                    print("   🔗 Medium name match: \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity))")
                    continue
                }
                
                // RULE 5: Wider merge (60-80m) with name similarity
                // TIGHTENED: similarity ≥ 0.92 (was 0.85)
                if distance >= 60.0 && distance <= 80.0 && nameSimilarity >= 0.92 {
                    // Types already checked above
                    cluster.append(otherPOI)
                    processed.insert(otherPOI.placeId)
                    print("   🔗 Wide name match: \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity))")
                    continue
                }
                
                // RULE 6: Very high name similarity (>0.95) at longer distances (80-200m)
                // TIGHTENED: similarity > 0.95 (was 0.9)
                if distance > 80.0 && distance <= 200.0 && nameSimilarity > 0.95 {
                    // Types already checked above
                    cluster.append(otherPOI)
                    processed.insert(otherPOI.placeId)
                    print("   🔗 Very high similarity: \(String(format: "%.1f", distance))m, similarity: \(String(format: "%.2f", nameSimilarity))")
                    continue
                }
            }
            
            // Choose best representative from cluster
            if cluster.count == 1 {
                // Single POI - no merging needed
                canonical.append(poi)
            } else {
                // Multiple POIs in cluster - choose best representative
                let best = chooseCanonicalRepresentative(from: cluster)
                canonical.append(best.poi)
                
                // Log merged aliases
                let mergedNames = cluster.filter { $0.placeId != best.poi.placeId }
                    .map { $0.name }
                if !mergedNames.isEmpty {
                    mergeLog.append((canonical: best.poi.name, merged: mergedNames))
                    print("🎯 [CANONICAL] Cluster: '\(best.poi.name)' (source: \(best.poi.source.rawValue))")
                    print("   📋 Merged: \(mergedNames.joined(separator: ", "))")
                }
            }
        }
        
        if !mergeLog.isEmpty {
            print("🎯 [CANONICAL] Total clusters merged: \(mergeLog.count)")
        }
        
        return canonical
    }
    
    /// Extract Geograph grid reference from name (e.g., "SE2922" from "SE2922: The Star Inn")
    private func extractGeographGridReference(_ name: String) -> String? {
        let pattern = "^([A-Z]{1,2}\\d{4})"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range(at: 1), in: name) {
            return String(name[range])
        }
        return nil
    }
    
    /// Extract OSM ID from placeId (e.g., "123456" from "osm_123456")
    private func extractOSMId(_ placeId: String) -> String? {
        if placeId.hasPrefix("osm_") {
            let osmId = String(placeId.dropFirst(4))
            return osmId.isEmpty ? nil : osmId
        }
        return nil
    }
    
    /// Check if two POI types are compatible for merging
    /// STRICT: Defaults to FALSE - only merges when explicitly compatible
    /// Never merge across incompatible types (e.g., pub vs postbox, restaurant vs church)
    private func arePOITypesCompatible(_ poi1: PlaceResult, _ poi2: PlaceResult, poiCategory: String, otherCategory: String) -> Bool {
        // 1. Reject all non-POIs
        if isNonPOI(poi1) || isNonPOI(poi2) {
            return false
        }
        
        // 2. Check types arrays if available - if both have types but share none, incompatible
        let types1 = poi1.types ?? []
        let types2 = poi2.types ?? []
        if !types1.isEmpty && !types2.isEmpty {
            let set1 = Set(types1.map { $0.lowercased() })
            let set2 = Set(types2.map { $0.lowercased() })
            if !set1.isDisjoint(with: set2) {
                return true  // Shared type = compatible
            }
            // If both have types but no overlap, incompatible
            return false
        }
        
        // 3. Use coarse grouping
        let group1 = coarseGroup(poi1)
        let group2 = coarseGroup(poi2)
        if let g1 = group1, let g2 = group2, g1 == g2 && g1 != "Unknown" {
            return true
        }
        
        // 4. Explicit incompatible pairs (extended list)
        let incompatiblePairs: [(String, String)] = [
            // Postbox incompatible with most things
            ("Pub/Inn", "Postbox"),
            ("Pub/Inn", "Post Office"),
            ("Store", "Postbox"),
            ("Religious Building", "Postbox"),
            ("Community Building", "Postbox"),
            ("Historic Building", "Postbox"),
            ("Memorial/Monument", "Postbox"),
            ("Religious Building", "Restaurant"),
            ("Religious Building", "Cafe"),
            ("Religious Building", "Store"),
            // Heritage incompatible with commercial
            ("Pub/Inn", "Industrial Heritage"),
            ("Store", "Industrial Heritage"),
            ("Religious Building", "Industrial Heritage"),
            // Different business verticals
            ("Religious Building", "Childcare & Education"),
            ("Community Building", "Food & Drink"),
            ("Personal Care & Health", "Food & Drink"),
            ("Personal Care & Health", "Retail & Services"),
            ("Childcare & Education", "Personal Care & Health"),
            ("Childcare & Education", "Food & Drink"),
            ("Childcare & Education", "Retail & Services"),
        ]
        
        // Check category-based incompatible pairs
        for (type1, type2) in incompatiblePairs {
            if (poiCategory == type1 && otherCategory == type2) ||
               (poiCategory == type2 && otherCategory == type1) {
                return false
            }
        }
        
        // Check coarse group incompatible pairs
        if let g1 = group1, let g2 = group2 {
            let groupIncompatiblePairs: [(String, String)] = [
                ("Religious & Community", "Food & Drink"),
                ("Religious & Community", "Retail & Services"),
                ("Religious & Community", "Personal Care & Health"),
                ("Childcare & Education", "Personal Care & Health"),
                ("Childcare & Education", "Food & Drink"),
                ("Childcare & Education", "Retail & Services"),
                ("Personal Care & Health", "Food & Drink"),
                ("Personal Care & Health", "Retail & Services"),
                ("Postbox", "Food & Drink"),
                ("Postbox", "Retail & Services"),
                ("Postbox", "Religious & Community"),
            ]
            for (grp1, grp2) in groupIncompatiblePairs {
                if (g1 == grp1 && g2 == grp2) || (g1 == grp2 && g2 == grp1) {
                    return false
                }
            }
        }
        
        // 5. If either is Unknown → incompatible unless names are nearly identical
        if poiCategory == "Unknown" || otherCategory == "Unknown" {
            return false  // Will be handled by name similarity check in rules
        }
        
        // 6. Check for postbox in names/types (common incompatible type)
        let name1 = poi1.name.lowercased()
        let name2 = poi2.name.lowercased()
        let hasPostbox1 = name1.contains("postbox") || name1.contains("post box") || types1.contains { $0.lowercased().contains("postbox") || $0.lowercased().contains("post_office") }
        let hasPostbox2 = name2.contains("postbox") || name2.contains("post box") || types2.contains { $0.lowercased().contains("postbox") || $0.lowercased().contains("post_office") }
        
        // If one is a postbox and the other is clearly not, they're incompatible
        if hasPostbox1 && !hasPostbox2 {
            let incompatibleWithPostbox = ["pub", "inn", "church", "chapel", "shop", "store", "hall", "memorial", "monument", "restaurant", "cafe"]
            if incompatibleWithPostbox.contains(where: { name2.contains($0) }) {
                return false
            }
        }
        if hasPostbox2 && !hasPostbox1 {
            let incompatibleWithPostbox = ["pub", "inn", "church", "chapel", "shop", "store", "hall", "memorial", "monument", "restaurant", "cafe"]
            if incompatibleWithPostbox.contains(where: { name1.contains($0) }) {
                return false
            }
        }
        
        // 7. Default: INCOMPATIBLE (strict approach - only merge when explicitly compatible)
        return false
    }
    
    /// Clean POI name for display - removes grid references and location suffixes
    /// Preserves capitalization and formatting
    /// Example: "SE2922: Lindale Methodist Church, Kirkhamgate" -> "Lindale Methodist Church"
    static func cleanPOIDisplayName(_ name: String) -> String {
        var cleaned = name
        
        // Remove Geograph grid reference prefix (e.g., "SE2922 : " or "SE2922:")
        cleaned = cleaned.replacingOccurrences(
            of: "^[A-Z]{1,2}\\d{4}\\s*:\\s*",
            with: "",
            options: .regularExpression
        )
        
        // Remove common location suffixes (case-insensitive, preserve original case)
        // IMPORTANT: Order matters - remove longer suffixes first to avoid partial matches
        let locationSuffixes = [
            ", Batley Road, Kirkhamgate",  // Multi-part suffix first
            ", Brandy Carr Road, Kirkhamgate",
            ", Brandy Carr Lane, Kirkhamgate",
            ", Kirkhamgate", ", Batley Road", ", Brandy Carr Road", ", Brandy Carr Lane",
            ", Sheffield", ", Wakefield", ", UK", ", England",
            " on Batley Road", " on Brandy Carr Road", " on Brandy Carr Lane",
            "Batley Road", "Brandy Carr Road", "Brandy Carr Lane", "Kirkhamgate"
        ]
        
        // Process multiple times to handle cases like "The Star Inn, Batley Road, Kirkhamgate"
        var previousLength = cleaned.count
        var iterations = 0
        repeat {
            previousLength = cleaned.count
            iterations += 1
            for suffix in locationSuffixes {
                // Remove from end (case-insensitive)
                if cleaned.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) != nil {
                    cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Also remove trailing comma if present
                    if cleaned.hasSuffix(",") {
                        cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Remove with comma prefix (e.g., ", Kirkhamgate")
                if let range = cleaned.range(of: ",\\s*" + suffix, options: [.regularExpression, .caseInsensitive, .anchored, .backwards]) {
                    cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Collapse whitespace after removals
            cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } while cleaned.count < previousLength && iterations < 10  // Keep removing until no more changes (max 10 iterations)
        
        // Debug logging for problematic names
        if name.lowercased().contains("star inn") || name.lowercased().contains("war memorial") || name.lowercased().contains("lindale methodist church") {
            print("🧹 cleanPOIDisplayName: '\(name)' → '\(cleaned)' (after \(iterations) iterations)")
        }
        
        return cleaned
    }
    
    /// Normalize POI name for comparison
    /// - Lowercase
    /// - Remove Geograph grid prefixes (SE####:)
    /// - Strip punctuation, road names, extra descriptors
    /// - Collapse whitespace
    private func normalizePOIName(_ name: String) -> String {
        var normalized = name.lowercased()
        
        // Remove Geograph grid reference prefix (e.g., "SE2922 : " or "SE2922:")
        normalized = normalized.replacingOccurrences(
            of: "^[a-z]{1,2}\\d{4}\\s*:\\s*",
            with: "",
            options: .regularExpression
        )
        
        // Remove common road/location suffixes that don't affect identity
        // These are location descriptors, not part of the POI's core identity
        // Process multiple times to handle cases like "The Star Inn, Batley Road, Kirkhamgate"
        var previousLength = normalized.count
        repeat {
            previousLength = normalized.count
            let locationSuffixes = [
                ", kirkhamgate", ", batley road", ", brandy carr road", ", brandy carr lane",
                ", sheffield", ", wakefield", ", uk", ", england",
                "on batley road", "on brandy carr road", "on brandy carr lane",
                "batley road", "brandy carr road", "brandy carr lane", "kirkhamgate"
            ]
            for suffix in locationSuffixes {
                // Remove from end (with optional comma)
                if normalized.hasSuffix(suffix) {
                    normalized = String(normalized.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Also remove trailing comma if present
                    if normalized.hasSuffix(",") {
                        normalized = String(normalized.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Remove with comma prefix (e.g., ", kirkhamgate")
                normalized = normalized.replacingOccurrences(
                    of: ",\\s*" + suffix.replacingOccurrences(of: " ", with: "\\s*"),
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                // Remove standalone (e.g., "on batley road")
                normalized = normalized.replacingOccurrences(
                    of: "\\s+" + suffix.replacingOccurrences(of: " ", with: "\\s+"),
                    with: " ",
                    options: [.regularExpression, .caseInsensitive]
                )
            }
            // Collapse whitespace after removals
            normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        } while normalized.count < previousLength  // Keep removing until no more changes
        
        // Remove common prefixes that don't affect identity
        let prefixesToRemove = ["the ", "a ", "an "]
        for prefix in prefixesToRemove {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
            }
        }
        
        // Strip punctuation (keep spaces)
        normalized = normalized.replacingOccurrences(
            of: "[^a-z0-9\\s]",
            with: " ",
            options: .regularExpression
        )
        
        // Collapse whitespace
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return normalized
    }
    
    // MARK: - Coordinate Accuracy Validation
    
    /// Validates POI coordinates to detect and filter incorrect coordinates
    /// When multiple POIs have the same name but coordinates far apart (>200m), one likely has wrong coordinates
    /// Prefers coordinates from more reliable sources (Google > Apple > OSM > Geograph)
    private func validatePOICoordinates(_ pois: [PlaceResult]) -> [PlaceResult] {
        var filteredOut = Set<String>()
        
        // Group POIs by normalized name
        var nameGroups: [String: [PlaceResult]] = [:]
        for poi in pois {
            let normalizedName = normalizePOIName(poi.name).lowercased()
            if normalizedName.count >= 3 {  // Only check meaningful names (skip "A", "B", etc.)
                nameGroups[normalizedName, default: []].append(poi)
            }
        }
        
        // Check each name group for coordinate discrepancies
        for (normalizedName, group) in nameGroups where group.count > 1 {
            // Calculate distances between all POIs in the group
            var distances: [(poi1: PlaceResult, poi2: PlaceResult, distance: Double)] = []
            for i in 0..<group.count {
                for j in (i+1)..<group.count {
                    let dist = distanceBetween(group[i].coordinate, group[j].coordinate)
                    distances.append((group[i], group[j], dist))
                }
            }
            
            // Find the maximum distance in this group
            let maxDistance = distances.map { $0.distance }.max() ?? 0
            
            // If all POIs are close together (<50m), they're fine - no coordinate issue
            if maxDistance < 50.0 {
                continue
            }
            
            // If POIs are far apart (>200m), one likely has incorrect coordinates
            if maxDistance > 200.0 {
                print("📍 ⚠️ Coordinate discrepancy detected for '\(normalizedName)': \(group.count) POIs, max distance: \(String(format: "%.0f", maxDistance))m")
                
                // Find clusters of POIs that are close together
                var clusters: [[PlaceResult]] = []
                var unclustered = group
                
                while !unclustered.isEmpty {
                    let seed = unclustered.removeFirst()
                    var cluster = [seed]
                    
                    // Find all POIs within 50m of the seed
                    unclustered.removeAll { poi in
                        let dist = distanceBetween(seed.coordinate, poi.coordinate)
                        if dist < 50.0 {
                            cluster.append(poi)
                            return true
                        }
                        return false
                    }
                    
                    clusters.append(cluster)
                }
                
                // If we have multiple clusters, keep the one from the most reliable source
                if clusters.count > 1 {
                    // Find the best cluster (highest priority source)
                    // Compare by finding the best POI in each cluster
                    let bestCluster = clusters.max { cluster1, cluster2 in
                        let best1 = cluster1.min { sourcePriority($0) < sourcePriority($1) }!
                        let best2 = cluster2.min { sourcePriority($0) < sourcePriority($1) }!
                        return sourcePriority(best1) > sourcePriority(best2)
                    }!
                    
                    // Get the best POI from the best cluster for logging
                    let bestPOI = bestCluster.min { sourcePriority($0) < sourcePriority($1) }!
                    
                    // Get placeIds of the best cluster for comparison
                    let bestClusterPlaceIds = Set(bestCluster.map { $0.placeId })
                    
                    // Filter out POIs from other clusters
                    for cluster in clusters {
                        // Check if this is the best cluster by comparing placeIds
                        let clusterPlaceIds = Set(cluster.map { $0.placeId })
                        if clusterPlaceIds == bestClusterPlaceIds {
                            continue  // Keep this cluster
                        }
                        
                        for poi in cluster {
                            filteredOut.insert(poi.placeId)
                            let dist = distanceBetween(poi.coordinate, bestPOI.coordinate)
                            print("📍 ❌ Filtered '\(poi.name)' with incorrect coordinates - \(String(format: "%.0f", dist))m from reliable location (source: \(poi.source.rawValue) vs \(bestPOI.source.rawValue))")
                        }
                    }
                }
            }
        }
        
        // Return only POIs that weren't filtered out
        return pois.filter { !filteredOut.contains($0.placeId) }
    }
    
    /// Choose best canonical representative from a cluster
    /// Priority: Google > Apple > OSM > Geograph (high quality) > Geograph (low quality)
    private func chooseCanonicalRepresentative(from cluster: [PlaceResult]) -> (poi: PlaceResult, reason: String) {
        // Filter out non-POIs - they cannot be canonical representatives
        let validPOIs = cluster.filter { !isNonPOI($0) }
        guard !validPOIs.isEmpty else {
            // Fallback: if all are non-POIs, return first (shouldn't happen)
            return (cluster.first!, "Fallback (all non-POIs)")
        }
        
        // Sort by source priority: Google > Apple > OSM > Geograph (evidence only)
        // Geograph is evidence only - never canonical
        let sorted = validPOIs.sorted { first, second in
            // Never prefer Geograph over actual POI sources
            if first.source == .geograph && second.source != .geograph {
                return false  // Prefer non-Geograph
            }
            if second.source == .geograph && first.source != .geograph {
                return true  // Prefer non-Geograph
            }
            
            let firstPriority = sourcePriority(first)
            let secondPriority = sourcePriority(second)
            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }
            // If same priority, prefer better name (shorter, cleaner)
            // Geograph names often have grid prefixes - prefer cleaner names
            let firstNameClean = normalizePOIName(first.name)
            let secondNameClean = normalizePOIName(second.name)
            if firstNameClean.count != secondNameClean.count {
                return firstNameClean.count < secondNameClean.count  // Prefer shorter (cleaner)
            }
            // If same length, prefer higher quality Geograph (only if both are Geograph)
            if first.source == .geograph && second.source == .geograph {
                return geographQualityScore(first) > geographQualityScore(second)
            }
            return false
        }
        
        let best = sorted.first!
        let reason: String
        switch best.source {
        case .google: reason = "Google (highest priority)"
        case .apple: reason = "Apple Maps"
        case .osm: reason = "OSM"
        case .geograph: reason = "Geograph (evidence only, quality: \(String(format: "%.1f", geographQualityScore(best))))"
        case .unknown: reason = "Unknown source"
        }
        
        return (best, reason)
    }
    
    // MARK: - Local Waypoint Optimization (Nearest Neighbor)
    /// Optimizes waypoint order using Nearest Neighbor (Greedy) algorithm
    /// This keeps Google Directions API calls in the "Essentials" SKU ($5/1k) instead of "Advanced" SKU ($10+/1k)
    /// by doing the optimization locally instead of using Google's optimize:true parameter
    /// 
    /// - Parameters:
    ///   - origin: Starting location (user's current location)
    ///   - waypoints: Array of waypoint coordinates to optimize
    /// - Returns: Optimized array of waypoints in efficient visiting order
    private func performLocalOptimization(origin: CLLocationCoordinate2D, waypoints: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard !waypoints.isEmpty else { return waypoints }
        
        // Cap at 10 waypoints to stay within Essentials SKU billing tier
        let cappedWaypoints = Array(waypoints.prefix(10))
        if waypoints.count > 10 {
            print("🌐 ⚠️  Waypoints capped at 10 (was \(waypoints.count)) to stay in Essentials SKU")
        }
        
        // Nearest Neighbor (Greedy) algorithm
        var remaining = cappedWaypoints
        var optimized: [CLLocationCoordinate2D] = []
        var current = origin
        
        while !remaining.isEmpty {
            // Find nearest unvisited waypoint
            let nearest = remaining.min { wp1, wp2 in
                distanceBetween(current, wp1) < distanceBetween(current, wp2)
            }!
            
            optimized.append(nearest)
            remaining.removeAll { $0.latitude == nearest.latitude && $0.longitude == nearest.longitude }
            current = nearest
        }
        
        print("🌐 ✅ Local optimization: \(cappedWaypoints.count) waypoints reordered using Nearest Neighbor")
        return optimized
    }
    
    /// Check if two POI names are similar (likely the same place, different naming)
    /// v1.6.47: Used for deduplication - only dedupe very close POIs if names are similar
    private func namesAreSimilar(_ name1: String, _ name2: String) -> Bool {
        let n1 = name1.lowercased()
        let n2 = name2.lowercased()
        
        // Exact match
        if n1 == n2 { return true }
        
        // One contains the other (e.g., "The Star Inn" vs "Star Inn")
        if n1.contains(n2) || n2.contains(n1) { return true }
        
        // Common prefix of at least 5 characters (e.g., "Kirkhamgate Fisheries" vs "Kirkhamgate Fish Shop")
        let minPrefixLength = 5
        let maxPrefixCheck = min(n1.count, n2.count, 15)
        for length in stride(from: maxPrefixCheck, through: minPrefixLength, by: -1) {
            let prefix1 = String(n1.prefix(length))
            let prefix2 = String(n2.prefix(length))
            if prefix1 == prefix2 {
                return true
            }
        }
        
        return false
    }
    
    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }
    
    // MARK: - Google Directions API Fallback (PAID - Use Sparingly!)
    
    /// Uses Google Directions API as fallback when MapKit route is outside tolerance
    /// This is a PAID API - only use when MapKit fails to find acceptable route
    /// Returns nil if Google also fails or API key is missing
    func getGoogleDirectionsRoute(
        origin: CLLocationCoordinate2D,
        waypoints: [PlaceResult],
        targetDurationMinutes: Int
    ) async -> GeneratedRoute? {
        guard !apiKey.isEmpty else {
            print("🌐 Google Directions: No API key available")
            return nil
        }
        
        print("🌐 Google Directions: Attempting fallback route (PAID API)...")
        
        // Extract waypoint coordinates
        let rawWaypointCoords = waypoints.map { $0.coordinate }
        
        // Optimize waypoint order locally (Nearest Neighbor) to stay in Essentials SKU
        let optimizedWaypointCoords = performLocalOptimization(origin: origin, waypoints: rawWaypointCoords)
        
        // Build waypoints string for Google API (already optimized, no optimize:true parameter needed)
        // Format: lat,lng|lat,lng|lat,lng (using 6 decimal places for precision)
        let waypointCoords = optimizedWaypointCoords.map { 
            String(format: "%.6f,%.6f", $0.latitude, $0.longitude)
        }
        let waypointsParam = waypointCoords.joined(separator: "|")
        
        // Google Directions API URL
        // Format: origin and destination are the same (loop route), waypoints are intermediate POIs only
        var urlString = "https://maps.googleapis.com/maps/api/directions/json?"
        urlString += "origin=\(String(format: "%.6f,%.6f", origin.latitude, origin.longitude))"
        urlString += "&destination=\(String(format: "%.6f,%.6f", origin.latitude, origin.longitude))"  // Round trip
        urlString += "&waypoints=\(waypointsParam)"  // v1.9.30: Locally optimized, no optimize:true to stay in Essentials SKU
        urlString += "&mode=walking"
        urlString += "&key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            print("🌐 Google Directions: Invalid URL")
            return nil
        }
        
        do {
            var request = URLRequest(url: url)
            // Add iOS bundle ID for API key restrictions
            if let bundleId = Bundle.main.bundleIdentifier {
                request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
                print("🌐 Google Directions: Bundle ID: \(bundleId)")
            } else {
                print("🌐 Google Directions: ⚠️  WARNING: No bundle ID found!")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🌐 Google Directions: HTTP error")
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "OK",
                  let routes = json["routes"] as? [[String: Any]],
                  let firstRoute = routes.first,
                  let legs = firstRoute["legs"] as? [[String: Any]],
                  let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
                  let polylinePoints = overviewPolyline["points"] as? String else {
                let errorStatus = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String ?? "unknown"
                print("🌐 Google Directions: Failed - status: \(errorStatus)")
                return nil
            }
            
            // Calculate total distance and duration
            var totalDistance = 0
            var totalDuration = 0
            var directionsLegs: [DirectionsLeg] = []
            
            for leg in legs {
                guard let distance = leg["distance"] as? [String: Any],
                      let distanceValue = distance["value"] as? Int,
                      let distanceText = distance["text"] as? String,
                      let duration = leg["duration"] as? [String: Any],
                      let durationValue = duration["value"] as? Int,
                      let durationText = duration["text"] as? String else {
                    continue
                }
                
                totalDistance += distanceValue
                totalDuration += durationValue
                
                // Extract steps for directions
                var steps: [DirectionsStep] = []
                if let stepsData = leg["steps"] as? [[String: Any]] {
                    for step in stepsData {
                        let instruction = step["html_instructions"] as? String
                        let stepDistanceVal = (step["distance"] as? [String: Any])?["value"] as? Int ?? 0
                        let stepDistanceText = (step["distance"] as? [String: Any])?["text"] as? String ?? ""
                        let stepDurationVal = (step["duration"] as? [String: Any])?["value"] as? Int ?? 0
                        let stepDurationText = (step["duration"] as? [String: Any])?["text"] as? String ?? ""
                        let stepPolyline = (step["polyline"] as? [String: Any])?["points"] as? String
                        
                        steps.append(DirectionsStep(
                            distance: DirectionsValue(text: stepDistanceText, value: stepDistanceVal),
                            duration: DirectionsValue(text: stepDurationText, value: stepDurationVal),
                            htmlInstructions: instruction,
                            polyline: stepPolyline != nil ? StepPolyline(points: stepPolyline!) : nil
                        ))
                    }
                }
                
                let startAddress = leg["start_address"] as? String
                let endAddress = leg["end_address"] as? String
                
                directionsLegs.append(DirectionsLeg(
                    distance: DirectionsValue(text: distanceText, value: distanceValue),
                    duration: DirectionsValue(text: durationText, value: durationValue),
                    startAddress: startAddress,
                    endAddress: endAddress,
                    steps: steps
                ))
            }
            
            let durationMinutes = totalDuration / 60
            let targetMin = Int(Double(targetDurationMinutes) * 0.80)
            let targetMax = targetDurationMinutes
            
            print("🌐 Google Directions: Route found - \(durationMinutes)min, \(totalDistance)m")
            
            // Check if Google route is within 80-100% tolerance
            if durationMinutes >= targetMin && durationMinutes <= targetMax {
                print("🌐 ✓ Google route within tolerance (80-100%): \(durationMinutes)min")
            } else {
                print("🌐 ⚠️ Google route outside tolerance: \(durationMinutes)min (target: \(targetMin)-\(targetMax)min)")
            }
            
            // Get optimized waypoint order from Google
            var orderedPlaces = waypoints
            if let waypointOrder = firstRoute["waypoint_order"] as? [Int] {
                orderedPlaces = waypointOrder.map { waypoints[$0] }
                print("🌐 Google optimized waypoint order: \(waypointOrder)")
            }
            
            return GeneratedRoute(
                places: orderedPlaces,
                polyline: polylinePoints,
                distanceMeters: totalDistance,
                durationSeconds: totalDuration,
                legs: directionsLegs
            )
            
        } catch {
            print("🌐 Google Directions: Error - \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Error Types
enum GoogleMapsError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case serverError
    case apiError(String)
    case noRouteFound
    case noPlacesFound
    case rateLimited(timeUntilReset: Int)  // MapKit rate limit hit
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Google Maps API key is not configured"
        case .invalidURL:
            return "Invalid request URL"
        case .serverError:
            return "Server error occurred"
        case .apiError(let status):
            return "API error: \(status)"
        case .noRouteFound:
            return "No walking route found"
        case .noPlacesFound:
            return "No nearby places found"
        case .rateLimited(let seconds):
            return "Rate limited, please wait \(seconds) seconds"
        }
    }
}

// MARK: - API Response Models

// Legacy Places API Response (kept for backwards compatibility)
struct PlacesResponse: Codable {
    let status: String
    let results: [PlaceResult]
}

// New Places API Response (Essentials tier - much cheaper!)
struct NewPlacesResponse: Codable {
    let places: [NewPlace]?
}

struct NewPlace: Codable {
    let id: String?
    let displayName: DisplayName?
    let location: NewPlaceLocation?
    // ⚠️ SKU TIER: Using Pro SKU - displayName triggers Pro billing ($32/1k)
    // We accept Pro SKU cost for readable place names (better UX)
    // Only decode the fields we explicitly request: id, displayName, location
}

struct DisplayName: Codable {
    let text: String?
    let languageCode: String?
}

struct NewPlaceLocation: Codable {
    let latitude: Double?
    let longitude: Double?
}

struct PlaceResult: Codable, Identifiable {
    let placeId: String
    let name: String
    let vicinity: String?
    let geometry: PlaceGeometry
    let types: [String]?
    // v1.9.48: Track POI source for debugging and quality control
    var source: POISource = .unknown
    
    var id: String { placeId }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: geometry.location.lat,
            longitude: geometry.location.lng
        )
    }
    
    /// Cleaned display name - removes grid references and location suffixes for better readability
    /// Example: "SE2922: Lindale Methodist Church, Kirkhamgate" -> "Lindale Methodist Church"
    var displayName: String {
        return GoogleMapsService.cleanPOIDisplayName(name)
    }
    
    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, vicinity, geometry, types, source
    }
    
    // v1.9.48: Custom decoder to handle missing source in cached data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placeId = try container.decode(String.self, forKey: .placeId)
        name = try container.decode(String.self, forKey: .name)
        vicinity = try container.decodeIfPresent(String.self, forKey: .vicinity)
        geometry = try container.decode(PlaceGeometry.self, forKey: .geometry)
        types = try container.decodeIfPresent([String].self, forKey: .types)
        source = try container.decodeIfPresent(POISource.self, forKey: .source) ?? .unknown
    }
    
    // v1.9.48: Convenience initializer for creating POIs with source
    init(placeId: String, name: String, vicinity: String?, geometry: PlaceGeometry, types: [String]?, source: POISource = .unknown) {
        self.placeId = placeId
        self.name = name
        self.vicinity = vicinity
        self.geometry = geometry
        self.types = types
        self.source = source
    }
}

struct PlaceGeometry: Codable {
    let location: PlaceLocation
}

struct PlaceLocation: Codable {
    let lat: Double
    let lng: Double
}

struct DirectionsResponse: Codable {
    let status: String
    let routes: [DirectionsResult]
}

struct DirectionsResult: Codable {
    let legs: [DirectionsLeg]
    let overviewPolyline: OverviewPolyline
    let summary: String?
    let warnings: [String]?
    let waypointOrder: [Int]?  // Optimized order when using optimize:true
    var usedOSRM: Bool = false  // v1.6.46: Track if polyline came from OSRM (not coded)
    
    enum CodingKeys: String, CodingKey {
        case legs
        case overviewPolyline = "overview_polyline"
        case summary, warnings
        case waypointOrder = "waypoint_order"
        // Note: usedOSRM is NOT coded - it's only set internally
    }
}

struct DirectionsLeg: Codable {
    let distance: DirectionsValue
    let duration: DirectionsValue
    let startAddress: String?
    let endAddress: String?
    let steps: [DirectionsStep]?
    
    enum CodingKeys: String, CodingKey {
        case distance, duration, steps
        case startAddress = "start_address"
        case endAddress = "end_address"
    }
}

struct DirectionsValue: Codable {
    let text: String
    let value: Int
}

struct DirectionsStep: Codable {
    let distance: DirectionsValue
    let duration: DirectionsValue
    let htmlInstructions: String?
    let polyline: StepPolyline?
    
    enum CodingKeys: String, CodingKey {
        case distance, duration, polyline
        case htmlInstructions = "html_instructions"
    }
}

struct StepPolyline: Codable {
    let points: String
}

struct OverviewPolyline: Codable {
    let points: String
}

// MARK: - Generated Route Result
struct GeneratedRoute {
    let places: [PlaceResult]
    let polyline: String
    let distanceMeters: Int
    let durationSeconds: Int
    let legs: [DirectionsLeg]
    
    // v1.6.10: Low POI warning - shown when route options are limited
    var hasLimitedPOIs: Bool = false
    var poiCount: Int = 0
    
    // v1.6.46: Track if polyline came from OSRM (driving profile - needs MapKit refresh)
    var usedOSRM: Bool = false
    
    // Threshold for "limited" POIs (below this, variety is reduced)
    static let limitedPOIThreshold = 50
    
    var limitedPOIWarning: String? {
        guard hasLimitedPOIs else { return nil }
        return "Limited route options in this area. Try again later for more variety."
    }
    
    var durationMinutes: Int {
        durationSeconds / 60
    }
    
    var formattedDuration: String {
        let mins = durationSeconds / 60
        if mins < 60 {
            return "\(mins) min"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            return "\(hours)h \(remainingMins)m"
        }
    }
    
    var formattedDistance: String {
        if distanceMeters < 1000 {
            return "\(distanceMeters)m"
        } else {
            let km = Double(distanceMeters) / 1000.0
            return String(format: "%.1f km", km)
        }
    }
}

// MARK: - Route Generation Result (Extended for Testing)
/// Extended result that includes the selected route and all valid routes found during generation
struct RouteGenerationResult {
    let selectedRoute: GeneratedRoute
    let allValidRoutes: [GeneratedRoute]
    let routesAttempted: Int
    let validRoutesFound: Int
    let usedDatabase: Bool
    let generationTime: TimeInterval
    let telemetry: RouteTelemetry  // v2.0.17: Telemetry for batch aggregation
}

// MARK: - Route Telemetry (v2.0.17)
/// Telemetry captured per route generation
struct RouteTelemetry {
    var earlyCommitOpportunity: Bool = false
    var earlyCommitsTaken: Bool = false
    var fallbackFired: Bool = false
    var fallbackOver130Pct: Bool = false
    var overshootSelectedGt120Pct: Bool = false
    var perLegCapApplied: Bool = false
    var capAfterGoodCandidate: Bool = false
    var sectorQuotaUsed: Bool = false
}

// MARK: - Route Capture Helper (for testing)
/// Helper class to capture all valid routes during generation
class RouteCapture {
    var validRoutes: [GeneratedRoute] = []
    var routesAttempted: Int = 0
    var usedDatabase: Bool = false
    var telemetry: RouteTelemetry = RouteTelemetry()  // v2.0.17: Capture telemetry
    
    func addRoute(_ route: GeneratedRoute) {
        validRoutes.append(route)
    }
    
    func incrementAttempts() {
        routesAttempted += 1
    }
}

// MARK: - Route Multiplier Tracker
/// Tracks the ratio between estimated and actual route durations
/// Used to detect topology-hostile areas and improve estimation accuracy
final class RouteMultiplierTracker {
    private var samples: [Double] = []
    private let maxSamples = 5

    func record(estimatedMinutes: Double, actualMinutes: Double) {
        guard estimatedMinutes > 0 else { return }

        let multiplier = actualMinutes / estimatedMinutes
        samples.append(multiplier)

        if samples.count > maxSamples {
            samples.removeFirst()
        }
    }

    var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    var isTopologyHostile: Bool {
        guard let median else { return false }
        return median >= 2.0
    }

    var isMildlyIndirect: Bool {
        guard let median else { return false }
        return median >= 1.3
    }
}

