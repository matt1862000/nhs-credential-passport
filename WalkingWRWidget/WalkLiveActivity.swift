//
//  WalkLiveActivity.swift
//  WalkingWRWidget
//
//  Live Activity UI for Dynamic Island (compact + expanded) and Lock Screen.
//

import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            WalkExpandedView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    WalkExpandedView(context: context)
                }
            } compactLeading: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                Text(formatCompactTrailing(context: context))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            } minimal: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.teal)
            }
        }
    }

    private func formatCompactTrailing(context: ActivityViewContext<WalkActivityAttributes>) -> String {
        if let minLeft = context.state.minutesLeft {
            return "\(minLeft)m"
        }
        let minElapsed = context.state.elapsedSeconds / 60
        return "\(minElapsed)m"
    }
}

@available(iOS 16.2, *)
private struct WalkExpandedView: View {
    let context: ActivityViewContext<WalkActivityAttributes>

    private var showClinicianName: Bool {
        guard let name = context.attributes.clinicianName, !name.isEmpty else { return false }
        return name != "Select your clinician"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(context.attributes.routeName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if context.state.isHeadingBack {
                        Text("Heading back")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Tap for live map")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if showClinicianName, let name = context.attributes.clinicianName {
                    Text("Appointment with \(name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    Label(elapsedString, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let left = context.state.minutesLeft {
                        Text("\(left) min left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress)
                    .tint(.teal)
                    .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "figure.walk")
                .font(.title2)
                .foregroundStyle(.teal)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 14, trailing: 10))
    }

    private var elapsedString: String {
        let total = context.state.elapsedSeconds
        let m = total / 60
        let s = total % 60
        if m > 0 {
            return "\(m):\(s < 10 ? "0" : "")\(s)"
        }
        return "0:\(s < 10 ? "0" : "")\(s)"
    }

    private var progress: Double {
        let totalSec = Double(context.attributes.totalMinutes * 60)
        return min(Double(context.state.elapsedSeconds) / totalSec, 1.0)
    }
}

#if DEBUG
@available(iOS 16.2, *)
#Preview("Lock Screen", as: .content, using: WalkActivityAttributes(routeName: "Riverside Loop", totalMinutes: 15, backByText: "2:30 PM", clinicianName: "Dr. Smith")) {
    WalkLiveActivity()
} contentStates: {
    WalkActivityAttributes.ContentState(elapsedSeconds: 270, minutesLeft: 11, isHeadingBack: false)
    WalkActivityAttributes.ContentState(elapsedSeconds: 600, minutesLeft: nil, isHeadingBack: true)
}
#endif
