import Foundation

/// Shared constants and helpers for App Group communication between
/// the main Murmur app and the MurmurKeyboard extension.
enum SharedDefaults {

    // MARK: - App Group

    /// The App Group identifier shared between the main app and the keyboard extension.
    static let appGroupID = "group.com.murmurkeyboard.shared"

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

    /// Key to signal that the keyboard initiated a dictation request.
    private static let dictationRequestedKey = "dictationRequested"

    // MARK: - Pending Text

    /// Stores transcribed text for the keyboard extension to pick up.
    static func setPendingText(_ text: String) {
        suite.set(text, forKey: pendingTextKey)
        suite.set(Date().timeIntervalSince1970, forKey: pendingTextTimestampKey)
        suite.synchronize()
    }

    /// Reads and clears the pending transcribed text.
    /// Returns `nil` if no text is pending or if the text is stale (older than 60 seconds).
    static func consumePendingText() -> String? {
        guard let text = suite.string(forKey: pendingTextKey), !text.isEmpty else {
            return nil
        }

        let timestamp = suite.double(forKey: pendingTextTimestampKey)
        let age = Date().timeIntervalSince1970 - timestamp

        // Discard text older than 60 seconds — likely stale from a failed round-trip
        guard age < 60 else {
            clearPendingText()
            return nil
        }

        clearPendingText()
        return text
    }

    /// Peeks at pending text without consuming it.
    static func peekPendingText() -> String? {
        guard let text = suite.string(forKey: pendingTextKey), !text.isEmpty else {
            return nil
        }
        let timestamp = suite.double(forKey: pendingTextTimestampKey)
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < 60 else {
            clearPendingText()
            return nil
        }
        return text
    }

    /// Clears any pending transcribed text.
    static func clearPendingText() {
        suite.removeObject(forKey: pendingTextKey)
        suite.removeObject(forKey: pendingTextTimestampKey)
        suite.synchronize()
    }

    // MARK: - Dictation Request Flag

    /// Sets a flag indicating the keyboard has requested dictation.
    static func setDictationRequested(_ requested: Bool) {
        suite.set(requested, forKey: dictationRequestedKey)
        suite.synchronize()
    }

    /// Checks and clears the dictation-requested flag.
    static func consumeDictationRequested() -> Bool {
        let requested = suite.bool(forKey: dictationRequestedKey)
        if requested {
            suite.set(false, forKey: dictationRequestedKey)
            suite.synchronize()
        }
        return requested
    }

    // MARK: - Keyboard Active Flag

    private static let keyboardActiveKey = "keyboardExtensionActive"

    /// Called by the keyboard extension when it loads, to signal the main app.
    static func setKeyboardActive(_ active: Bool) {
        suite.set(active, forKey: keyboardActiveKey)
        suite.synchronize()
    }

    /// Returns whether the keyboard extension has been activated at least once.
    static func isKeyboardActive() -> Bool {
        suite.bool(forKey: keyboardActiveKey)
    }
}
