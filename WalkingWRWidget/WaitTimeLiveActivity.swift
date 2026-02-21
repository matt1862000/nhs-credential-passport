//
//  WaitTimeLiveActivity.swift
//  WalkingWRWidget
//
//  Live Activity for clinician wait time (Dynamic Island + Lock Screen) when no walk is active.
//

import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct WaitTimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WaitTimeActivityAttributes.self) { context in
            WaitTimeExpandedView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    WaitTimeExpandedView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(delayString(context.state.delayMinutes))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.teal)
                    Spacer(minLength: 0)
                }
            } compactTrailing: {
                EmptyView()
            } minimal: {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.teal)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func delayString(_ minutes: Int) -> String {
        if minutes == 0 { return "On time" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

@available(iOS 16.2, *)
private struct WaitTimeExpandedView: View {
    let context: ActivityViewContext<WaitTimeActivityAttributes>

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack {
                Spacer(minLength: 0)
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.teal)
                Spacer(minLength: 0)
            }
            Text(context.attributes.clinicianName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(waitTimeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let backBy = context.attributes.backByText, !backBy.isEmpty {
                Label("Back by \(backBy)", systemImage: "clock.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var waitTimeLabel: String {
        let m = context.state.delayMinutes
        if m == 0 { return "On time" }
        if m < 60 { return "\(m) min delay" }
        let h = m / 60
        let min = m % 60
        return min == 0 ? "\(h) hr delay" : "\(h) hr \(min) min delay"
    }
}
