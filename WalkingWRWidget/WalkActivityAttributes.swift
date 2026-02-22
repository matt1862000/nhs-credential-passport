//
//  WalkActivityAttributes.swift
//  WalkingWRWidget
//
//  Live Activity data model for Dynamic Island & Lock Screen during an active walk.
//

import ActivityKit
import Foundation

/// Attributes for the Walk Live Activity (Dynamic Island + Lock Screen).
/// Static data is set when the activity starts; ContentState is updated as the walk progresses.
struct WalkActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Elapsed seconds since walk start.
        var elapsedSeconds: Int
        /// Minutes left (outbound) for the pill; nil if not yet set.
        var minutesLeft: Int?
        /// True when user has tapped "Head back".
        var isHeadingBack: Bool
        /// When delay/live data was last updated (for "last updated xx:xx").
        var lastUpdatedAt: Date?
    }

    /// Route name (fixed for the activity).
    var routeName: String
    /// Total duration in minutes (fixed for the activity).
    var totalMinutes: Int
    /// "Back by" time for appointment (e.g. "2:30 PM"). Nil if no appointment set.
    var backByText: String?
    /// Clinician name for "Appointment with [name]" (e.g. "Dr. Smith"). Nil if none selected.
    var clinicianName: String?
}
