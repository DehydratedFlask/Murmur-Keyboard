@preconcurrency import ActivityKit
import Foundation

/// Attributes shared with the widget extension. The identical definition lives
/// in `Sources/MurmurWidget/MurmurWidget.swift`; ActivityKit matches activities
/// by this type's name, so both copies must stay in sync.
struct MurmurDictationAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        /// When dictation started; the island renders a live timer from this.
        var startedAt: Date
    }

    /// Shown on the Lock Screen / expanded island.
    var title: String
}

/// Starts and stops the Live Activity shown in the Dynamic Island while Murmur
/// is recording, so the timer stays visible even in the app you swiped back to.
@MainActor
enum MurmurDictationLiveActivity {

    static func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Never stack activities if a start is requested twice.
        endAllImmediately()

        let attributes = MurmurDictationAttributes(title: "Murmur is listening")
        let content = ActivityContent(
            state: MurmurDictationAttributes.ContentState(startedAt: Date()),
            staleDate: Date().addingTimeInterval(15 * 60)
        )

        do {
            _ = try Activity.request(attributes: attributes, content: content)
        } catch {
            print("[Murmur] Could not start Live Activity: \(error.localizedDescription)")
        }
    }

    static func end() {
        Task {
            for activity in Activity<MurmurDictationAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Clears anything left over from a previous run (for example if the app was
    /// killed mid-recording).
    static func endAllImmediately() {
        for activity in Activity<MurmurDictationAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
