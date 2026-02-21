//
//  WaitTimeLiveActivityBridge.swift
//  WalkingWR
//
//  Starts, updates, and ends the Wait Time Live Activity (clinician + delay when no walk).
//

import Foundation
import ActivityKit

enum WaitTimeLiveActivityBridge {
    /// Start the wait-time Live Activity when user has a clinician and no walk.
    static func startIfAvailable(clinicianName: String, delayMinutes: Int, backByText: String? = nil) {
        guard #available(iOS 16.2, *) else { return }
        let att = WaitTimeActivityAttributes(clinicianName: clinicianName, backByText: backByText)
        let state = WaitTimeActivityAttributes.ContentState(delayMinutes: delayMinutes)
        do {
            let content = ActivityContent(state: state, staleDate: nil)
            _ = try Activity<WaitTimeActivityAttributes>.request(
                attributes: att,
                content: content,
                pushType: nil
            )
        } catch {
            print("WaitTimeLiveActivity: failed to start — \(error)")
        }
    }

    /// Update the delay (e.g. when Firebase pushes new wait time).
    static func updateIfAvailable(delayMinutes: Int) {
        guard #available(iOS 16.2, *) else { return }
        let state = WaitTimeActivityAttributes.ContentState(delayMinutes: delayMinutes)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            for activity in Activity<WaitTimeActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    /// End the wait-time Live Activity (e.g. when user clears clinician or starts a walk).
    static func endIfAvailable() {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<WaitTimeActivityAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
