import AppIntents

struct DictateToClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate to Clipboard"
    static let description = IntentDescription("Open Murmur and dictate. Finish recording to copy the text. Run again while recording to finish.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if AppState.shared.isCapturing {
            AppState.shared.finishCapture()
        } else {
            AppState.shared.captureRequest = CaptureRequest(destination: .clipboard)
        }
        return .result()
    }
}

struct CaptureVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Voice Note"
    static let description = IntentDescription("Open Murmur to dictate a note saved in your local transcription history.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if AppState.shared.isCapturing {
            AppState.shared.finishCapture()
        } else {
            AppState.shared.captureRequest = CaptureRequest(destination: .note)
        }
        return .result()
    }
}

struct FinishDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Dictation"
    static let description = IntentDescription("Finish the current Murmur recording and transcribe it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.finishCapture()
        return .result()
    }
}

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateToClipboardIntent(),
            phrases: ["Dictate to clipboard with \(.applicationName)"],
            shortTitle: "Dictate to Clipboard", systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: CaptureVoiceNoteIntent(),
            phrases: ["Capture a note with \(.applicationName)"],
            shortTitle: "Capture a Note", systemImageName: "mic"
        )
        AppShortcut(
            intent: FinishDictationIntent(),
            phrases: ["Finish dictation in \(.applicationName)"],
            shortTitle: "Finish Dictation", systemImageName: "stop.circle"
        )
    }
}
