//
//  ORSDirectionsRateLimiter.swift
//  WalkingWR
//
//  Limits ORS Directions V2 to 50 requests per 60-second rolling window to avoid HTTP 429.
//  High-priority (main route) waiters get slots before low-priority (second route, pregen, background).
//

import Foundation

enum ORSDirectionsPriority {
    case high  // main route topology attempt 1
    case low   // second route, pregen, MAINS OUT-OF-BAND, refresh, etc.
}

final class ORSDirectionsRateLimiter {
    static let shared = ORSDirectionsRateLimiter()
    
    private let limit = 50
    private let windowSec: TimeInterval = 60
    private let lock = NSLock()
    private var timestamps: [Date] = []
    private var waiters: [(priority: ORSDirectionsPriority, continuation: CheckedContinuation<Void, Never>)] = []
    private var coordinatorRunning = false
    
    /// Call from route UI before main vs retry/background so ORS slots prefer main route.
    func setPriority(_ priority: ORSDirectionsPriority) {
        lock.lock()
        currentPriority = priority
        lock.unlock()
    }
    
    private var currentPriority: ORSDirectionsPriority = .low
    
    /// Priority used when none is passed (e.g. from getOpenRouteServiceWalkingDirections).
    func currentPriorityForRequest() -> ORSDirectionsPriority {
        lock.lock()
        let p = currentPriority
        lock.unlock()
        return p
    }
    
    /// Call before each ORS Directions request. Waits until under 50/min; high-priority waiters get slots first.
    func waitForSlot(priority: ORSDirectionsPriority) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            trimToWindow()
            if timestamps.count < limit {
                timestamps.append(Date())
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((priority: priority, continuation: continuation))
            if !coordinatorRunning {
                coordinatorRunning = true
                startCoordinator()
            }
            lock.unlock()
        }
    }
    
    private func trimToWindow() {
        let cutoff = Date().addingTimeInterval(-windowSec)
        timestamps.removeAll { $0 < cutoff }
    }
    
    private func startCoordinator() {
        Task {
            while true {
                lock.lock()
                trimToWindow()
                if waiters.isEmpty {
                    coordinatorRunning = false
                    lock.unlock()
                    break
                }
                if timestamps.count < limit {
                    // Grant to highest-priority waiter (high first)
                    let idx = waiters.firstIndex { $0.priority == .high } ?? 0
                    let waiter = waiters.remove(at: idx)
                    timestamps.append(Date())
                    lock.unlock()
                    waiter.continuation.resume()
                } else {
                    let oldest = timestamps.min() ?? Date()
                    let sleepUntil = oldest.addingTimeInterval(windowSec)
                    let interval = sleepUntil.timeIntervalSince(Date())
                    lock.unlock()
                    if interval > 0.01 {
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                }
            }
        }
    }
    
    private init() {}
}
