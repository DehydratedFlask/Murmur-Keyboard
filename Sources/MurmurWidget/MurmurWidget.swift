import ActivityKit
import SwiftUI
import WidgetKit

/// Mirrors the definition in the app target. ActivityKit matches activities by
/// type name, so this must stay identical to `MurmurDictationAttributes` there.
struct MurmurDictationAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var startedAt: Date
    }

    var title: String
}

@main
struct MurmurWidgetBundle: WidgetBundle {
    var body: some Widget {
        MurmurDictationLiveActivity()
    }
}

struct MurmurDictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MurmurDictationAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                    Text("Tap Murmur's keyboard to insert")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.purple)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.purple)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.purple)
                            Text(context.attributes.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.purple)
                    }
                    .padding(.vertical, 4)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.purple)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .keylineTint(.purple)
        }
    }
}
