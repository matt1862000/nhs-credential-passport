//
//  WalkLiveActivityBridge.swift
//  WalkingWR
//
//  Starts, updates, and ends the Walk Live Activity (Dynamic Island + Lock Screen).
//  WalkActivityAttributes is compiled in both the app and the widget extension.
//

import Foundation
import ActivityKit

enum WalkLiveActivityBridge {
    /// If the app stops updating (e.g. force-closed), the activity content becomes stale after this interval and the system will dismiss the Live Activity.
    private static let staleAfterSeconds: TimeInterval = 60

    /// Start a Live Activity when the user starts a walk.
    /// - Parameter lastUpdatedAt: When live delay was last updated from the app (e.g. waitTimeInfo.lastUpdated). Nil uses current time.
    static func startIfAvailable(routeName: String, totalMinutes: Int, backByText: String? = nil, clinicianName: String? = nil, lastUpdatedAt: Date? = nil) {
        guard #available(iOS 16.2, *) else { return }
        let att = WalkActivityAttributes(routeName: routeName, totalMinutes: totalMinutes, backByText: backByText, clinicianName: clinicianName)
        let state = WalkActivityAttributes.ContentState(
            elapsedSeconds: 0,
            minutesLeft: totalMinutes,
            isHeadingBack: false,
            lastUpdatedAt: lastUpdatedAt ?? Date()
        )
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfterSeconds))
            _ = try Activity<WalkActivityAttributes>.request(
                attributes: att,
                content: content,
                pushType: nil
            )
        } catch {
            print("WalkLiveActivity: failed to start — \(error)")
        }
    }

    /// Update the Live Activity (elapsed time, mins left, heading back). Call from the walk timer.
    /// - Parameter lastUpdatedAt: When live delay was last updated from the app; pass through so "last updated" doesn't change on every tick.
    static func updateIfAvailable(elapsedSeconds: Int, minutesLeft: Int?, isHeadingBack: Bool, lastUpdatedAt: Date? = nil) {
        guard #available(iOS 16.2, *) else { return }
        let state = WalkActivityAttributes.ContentState(
            elapsedSeconds: elapsedSeconds,
            minutesLeft: minutesLeft,
            isHeadingBack: isHeadingBack,
            lastUpdatedAt: lastUpdatedAt
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfterSeconds))
        Task {
            for activity in Activity<WalkActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    /// End the Live Activity when the walk ends. Call from endWalk() or on launch after force-close.
    /// Runs on MainActor so Activity.activities is read on main thread (required by ActivityKit).
    static func endIfAvailable() {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in
            let activities = Activity<WalkActivityAttributes>.activities
            for activity in activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
