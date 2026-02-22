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
    /// Start a Live Activity when the user starts a walk.
    static func startIfAvailable(routeName: String, totalMinutes: Int, backByText: String? = nil, clinicianName: String? = nil) {
        guard #available(iOS 16.2, *) else { return }
        let att = WalkActivityAttributes(routeName: routeName, totalMinutes: totalMinutes, backByText: backByText, clinicianName: clinicianName)
        let state = WalkActivityAttributes.ContentState(
            elapsedSeconds: 0,
            minutesLeft: totalMinutes,
            isHeadingBack: false
        )
        do {
            let content = ActivityContent(state: state, staleDate: nil as Date?)
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
    static func updateIfAvailable(elapsedSeconds: Int, minutesLeft: Int?, isHeadingBack: Bool) {
        guard #available(iOS 16.2, *) else { return }
        let state = WalkActivityAttributes.ContentState(
            elapsedSeconds: elapsedSeconds,
            minutesLeft: minutesLeft,
            isHeadingBack: isHeadingBack
        )
        let content = ActivityContent(state: state, staleDate: nil as Date?)
        Task {
            for activity in Activity<WalkActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    /// End the Live Activity when the walk ends. Call from endWalk().
    static func endIfAvailable() {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<WalkActivityAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
