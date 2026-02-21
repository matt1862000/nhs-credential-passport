//
//  WaitTimeActivityAttributes.swift
//  WalkingWRWidget
//
//  Live Activity for "waiting for clinician" – shows clinician name and delay when no walk is active.
//

import ActivityKit
import Foundation

/// Attributes for the Wait Time Live Activity (Dynamic Island + Lock Screen).
/// Shown when user has selected a clinician but has not started a walk.
struct WaitTimeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Current wait/delay in minutes (updated when Firebase pushes new delay).
        var delayMinutes: Int
    }

    /// Clinician name (fixed for the activity).
    var clinicianName: String
    /// "Back by" time for appointment (e.g. "23:15" or "2:30 PM"). Nil if no appointment set.
    var backByText: String?
}
