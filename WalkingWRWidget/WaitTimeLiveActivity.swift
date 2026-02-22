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
            Text("Tap for current wait time")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
