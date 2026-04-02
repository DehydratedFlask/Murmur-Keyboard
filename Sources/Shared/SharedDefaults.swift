import Foundation

/// Shared constants and helpers for App Group communication between
/// the main Murmur app and the MurmurKeyboard extension.
enum SharedDefaults {

    // MARK: - App Group

    /// The App Group identifier shared between the main app and the keyboard extension.
    static let appGroupID = "group.murmurkeyboard.shared"

    /// The shared `UserDefaults` suite backed by the App Group container.
    nonisolated(unsafe) static let suite: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            print("[SharedDefaults] WARNING: Failed to create UserDefaults for App Group: \(appGroupID). Falling back to UserDefaults.standard.")
            return UserDefaults.standard
        }
        return defaults
    }()

    // MARK: - Keys

    /// Key for the transcribed text waiting to be inserted by the keyboard.
    private static let pendingTextKey = "pendingTranscribedText"

    /// Key for the timestamp of the last transcription (used to avoid stale reads).
    private static let pendingTextTimestampKey = "pendingTranscribedTextTimestamp"

    /// Key for the session ID associated with the pending transcription.
    private static let pendingTextSessionIDKey = "pendingTranscribedTextSessionID"

    /// Key to signal that the keyboard initiated a dictation request.
    private static let dictationRequestedKey = "dictationRequested"

    /// Key for the active dictation session ID.
    private static let dictationSessionIDKey = "dictationSessionID"

    /// Key for when the current dictation session started.
    private static let dictationSessionTimestampKey = "dictationSessionTimestamp"

    /// Key for an abandoned or failed dictation session signal.
    private static let dictationAbandonedKey = "dictationAbandoned"

    /// Optional detail describing why the session was abandoned.
    private static let dictationFailureReasonKey = "dictationFailureReason"

    /// Whether the Whisper model is actually ready for a warm handoff.
    private static let modelReadyKey = "modelReady"

    /// Timestamp for when modelReady was most recently updated.
    private static let modelReadyTimestampKey = "modelReadyTimestamp"

    /// Optional human-readable progress text while the model is loading.
    private static let modelLoadingProgressKey = "modelLoadingProgress"

    private static let pendingTextTTL: TimeInterval = 60
    private static let dictationSessionTTL: TimeInterval = 120

    // MARK: - Pending Text

    /// Stores transcribed text for the keyboard extension to pick up.
    static func setPendingText(_ text: String, sessionID: String? = nil) {
        suite.set(text, forKey: pendingTextKey)
        suite.set(Date().timeIntervalSince1970, forKey: pendingTextTimestampKey)
        if let sessionID {
            suite.set(sessionID, forKey: pendingTextSessionIDKey)
        } else {
            suite.removeObject(forKey: pendingTextSessionIDKey)
        }
    }

    /// Reads and clears the pending transcribed text.
    /// Returns `nil` if no text is pending or if the text is stale (older than 60 seconds).
    static func consumePendingText() -> String? {
        consumePendingTextPayload()?.text
    }

    static func consumePendingTextPayload() -> PendingTextPayload? {
        guard let payload = peekPendingTextPayload() else { return nil }
        clearPendingText()
        return payload
    }

    /// Peeks at pending text without consuming it.
    static func peekPendingText() -> String? {
        peekPendingTextPayload()?.text
    }

    static func peekPendingTextPayload() -> PendingTextPayload? {
        guard let text = suite.string(forKey: pendingTextKey), !text.isEmpty else {
            return nil
        }
        let timestamp = suite.double(forKey: pendingTextTimestampKey)
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < pendingTextTTL else {
            clearPendingText()
            return nil
        }
        return PendingTextPayload(
            text: text,
            sessionID: suite.string(forKey: pendingTextSessionIDKey),
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    /// Clears any pending transcribed text.
    static func clearPendingText() {
        suite.removeObject(forKey: pendingTextKey)
        suite.removeObject(forKey: pendingTextTimestampKey)
        suite.removeObject(forKey: pendingTextSessionIDKey)
    }

    // MARK: - Dictation Request Flag

    /// Sets a flag indicating the keyboard has requested dictation.
    static func setDictationRequested(_ requested: Bool) {
        suite.set(requested, forKey: dictationRequestedKey)
    }

    /// Checks and clears the dictation-requested flag.
    static func consumeDictationRequested() -> Bool {
        let requested = suite.bool(forKey: dictationRequestedKey)
        if requested {
            suite.set(false, forKey: dictationRequestedKey)
        }
        return requested
    }

    // MARK: - Dictation Session

    static func beginDictationSession(sessionID: String) {
        suite.set(sessionID, forKey: dictationSessionIDKey)
        suite.set(Date().timeIntervalSince1970, forKey: dictationSessionTimestampKey)
        suite.set(false, forKey: dictationAbandonedKey)
        suite.removeObject(forKey: dictationFailureReasonKey)
        clearPendingText()
    }

    static func currentDictationSessionID() -> String? {
        guard let sessionID = suite.string(forKey: dictationSessionIDKey), !sessionID.isEmpty else {
            return nil
        }

        let timestamp = suite.double(forKey: dictationSessionTimestampKey)
        if timestamp > 0 {
            let age = Date().timeIntervalSince1970 - timestamp
            if age >= dictationSessionTTL {
                abandonDictationSession(reason: "Dictation timed out.")
                clearDictationSession()
                return nil
            }
        }

        return sessionID
    }

    static func dictationSessionAge() -> TimeInterval? {
        let timestamp = suite.double(forKey: dictationSessionTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date().timeIntervalSince1970 - timestamp
    }

    static func clearDictationSession() {
        suite.removeObject(forKey: dictationSessionIDKey)
        suite.removeObject(forKey: dictationSessionTimestampKey)
        suite.removeObject(forKey: dictationFailureReasonKey)
        suite.set(false, forKey: dictationAbandonedKey)
    }

    static func abandonDictationSession(reason: String? = nil) {
        suite.set(true, forKey: dictationAbandonedKey)
        if let reason, !reason.isEmpty {
            suite.set(reason, forKey: dictationFailureReasonKey)
        } else {
            suite.removeObject(forKey: dictationFailureReasonKey)
        }
    }

    static func consumeAbandonedDictationSession() -> AbandonedSessionPayload? {
        guard suite.bool(forKey: dictationAbandonedKey) else { return nil }
        let payload = AbandonedSessionPayload(
            sessionID: suite.string(forKey: dictationSessionIDKey),
            reason: suite.string(forKey: dictationFailureReasonKey)
        )
        suite.set(false, forKey: dictationAbandonedKey)
        suite.removeObject(forKey: dictationFailureReasonKey)
        return payload
    }

    // MARK: - Model Ready

    static func setModelReady(_ ready: Bool, progressText: String? = nil) {
        suite.set(ready, forKey: modelReadyKey)
        suite.set(Date().timeIntervalSince1970, forKey: modelReadyTimestampKey)
        if let progressText, !progressText.isEmpty {
            suite.set(progressText, forKey: modelLoadingProgressKey)
        } else if ready {
            suite.removeObject(forKey: modelLoadingProgressKey)
        }
    }

    static func updateModelLoadingProgress(_ text: String?) {
        if let text, !text.isEmpty {
            suite.set(text, forKey: modelLoadingProgressKey)
        } else {
            suite.removeObject(forKey: modelLoadingProgressKey)
        }
        suite.set(Date().timeIntervalSince1970, forKey: modelReadyTimestampKey)
    }

    static func isModelReady() -> Bool {
        suite.bool(forKey: modelReadyKey)
    }

    static func modelReadyTimestamp() -> Date? {
        let timestamp = suite.double(forKey: modelReadyTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func modelLoadingProgress() -> String? {
        suite.string(forKey: modelLoadingProgressKey)
    }

    // MARK: - Keyboard Active Flag

    private static let keyboardActiveKey = "keyboardExtensionActive"

    /// Called by the keyboard extension when it loads, to signal the main app.
    static func setKeyboardActive(_ active: Bool) {
        suite.set(active, forKey: keyboardActiveKey)
    }

    /// Returns whether the keyboard extension has been activated at least once.
    static func isKeyboardActive() -> Bool {
        suite.bool(forKey: keyboardActiveKey)
    }
}

struct PendingTextPayload: Sendable {
    let text: String
    let sessionID: String?
    let timestamp: Date
}

struct AbandonedSessionPayload: Sendable {
    let sessionID: String?
    let reason: String?
}
