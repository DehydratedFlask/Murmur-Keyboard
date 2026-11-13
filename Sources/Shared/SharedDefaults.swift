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

    /// Current phase of the keyboard-initiated dictation handoff.
    private static let dictationPhaseKey = "dictationPhase"

    /// Session owning the current dictation phase.
    private static let dictationPhaseSessionIDKey = "dictationPhaseSessionID"

    /// Whether the keyboard has asked the containing app to stop recording.
    private static let dictationStopRequestedKey = "dictationStopRequested"

    /// Session associated with the stop request.
    private static let dictationStopSessionIDKey = "dictationStopSessionID"

    /// Whether the Whisper model is actually ready for a warm handoff.
    private static let modelReadyKey = "modelReady"

    /// Timestamp for when modelReady was most recently updated.
    private static let modelReadyTimestampKey = "modelReadyTimestamp"

    /// Optional human-readable progress text while the model is loading.
    private static let modelLoadingProgressKey = "modelLoadingProgress"

    private static let pendingTextTTL: TimeInterval = 60

    /// How long a keyboard dictation session stays valid between dictations.
    /// Written by the app from Settings › Session duration.
    private static let dictationSessionDurationKey = "dictationSessionDurationMinutes"

    static func setDictationSessionDurationMinutes(_ minutes: Int) {
        suite.set(max(1, minutes), forKey: dictationSessionDurationKey)
    }

    static func dictationSessionDurationMinutes() -> Int {
        let stored = suite.integer(forKey: dictationSessionDurationKey)
        return stored > 0 ? stored : 5
    }

    // MARK: - Warm Session

    /// When the app may accept a dictation request without being brought to the
    /// foreground: it is alive and the user's Session duration has not expired.
    private static let warmSessionExpiryKey = "warmSessionExpiry"
    private static let appHeartbeatKey = "appHeartbeat"

    /// Called by the app roughly once a second while its process is running.
    static func markAppAlive() {
        suite.set(Date().timeIntervalSince1970, forKey: appHeartbeatKey)
    }

    static func isAppAlive(maxAge: TimeInterval = 4) -> Bool {
        let beat = suite.double(forKey: appHeartbeatKey)
        guard beat > 0 else { return false }
        return Date().timeIntervalSince1970 - beat < maxAge
    }

    /// Opens a new warm window after a dictation finishes. A duration of 0
    /// (Immediate) clears it, so the next dictation takes the app route.
    static func extendWarmSession(minutes: Int) {
        guard minutes > 0 else {
            clearWarmSession()
            return
        }
        suite.set(
            Date().timeIntervalSince1970 + TimeInterval(minutes * 60),
            forKey: warmSessionExpiryKey
        )
    }

    static func clearWarmSession() {
        suite.removeObject(forKey: warmSessionExpiryKey)
    }

    static func isWarmSessionActive() -> Bool {
        let expiry = suite.double(forKey: warmSessionExpiryKey)
        guard expiry > 0 else { return false }
        return Date().timeIntervalSince1970 < expiry
    }

    // MARK: - Key Haptics

    private static let keyHapticsKey = "keyHapticsEnabled"

    /// Off unless the user turns it on: typing should be silent and still by
    /// default.
    static func isKeyHapticsEnabled() -> Bool {
        if suite.object(forKey: keyHapticsKey) == nil { return false }
        return suite.bool(forKey: keyHapticsKey)
    }

    static func setKeyHapticsEnabled(_ enabled: Bool) {
        suite.set(enabled, forKey: keyHapticsKey)
    }

    // MARK: - Dictation preferences and provisional text

    /// One-time migration; both processes subsequently use the App Group values.
    static func migrateDictationPreferences() {
        for key in ["formattingSurface", "dictationAutoDetectLanguage", "dictationSelectedLanguages"] {
            if suite.object(forKey: key) == nil, let value = UserDefaults.standard.object(forKey: key) {
                suite.set(value, forKey: key)
            }
        }
    }

    static var formattingStyle: String {
        get { suite.string(forKey: "formattingSurface") ?? "automatic" }
        set { suite.set(newValue, forKey: "formattingSurface") }
    }

    static var autoDetectLanguage: Bool {
        get { suite.object(forKey: "dictationAutoDetectLanguage") == nil || suite.bool(forKey: "dictationAutoDetectLanguage") }
        set { suite.set(newValue, forKey: "dictationAutoDetectLanguage") }
    }

    static var selectedLanguages: [String] {
        get { suite.stringArray(forKey: "dictationSelectedLanguages") ?? ["en"] }
        set { suite.set(newValue.isEmpty ? ["en"] : newValue, forKey: "dictationSelectedLanguages") }
    }

    static var languageNames: [String: String] {
        get { suite.dictionary(forKey: "dictationLanguageNames") as? [String: String] ?? ["en": "English"] }
        set { suite.set(newValue, forKey: "dictationLanguageNames") }
    }

    static var reviewBeforeInsertion: Bool {
        get { suite.bool(forKey: "reviewBeforeInsertion") }
        set { suite.set(newValue, forKey: "reviewBeforeInsertion") }
    }

    static func setLivePreview(_ text: String, sessionID: String) {
        suite.set(["text": String(text.suffix(1500)), "sessionID": sessionID], forKey: "dictationLivePreview")
    }

    static func livePreview(sessionID: String?) -> String {
        guard let sessionID,
              let value = suite.dictionary(forKey: "dictationLivePreview") as? [String: String],
              value["sessionID"] == sessionID else { return "" }
        return value["text"] ?? ""
    }

    static func clearLivePreview() {
        suite.removeObject(forKey: "dictationLivePreview")
    }

    /// A desired state rather than a toggle makes duplicate notifications safe.
    static func requestPause(_ paused: Bool, sessionID: String) {
        suite.set(["sessionID": sessionID, "paused": paused ? "true" : "false"], forKey: "dictationPauseRequest")
        DarwinNotificationCenter.post(.dictationPauseRequested)
    }

    static func consumePauseRequest(sessionID: String?) -> Bool? {
        guard let sessionID,
              let value = suite.dictionary(forKey: "dictationPauseRequest") as? [String: String],
              value["sessionID"] == sessionID else { return nil }
        suite.removeObject(forKey: "dictationPauseRequest")
        return value["paused"] == "true"
    }

    // MARK: - Pending Text

    /// Stores transcribed text for the keyboard extension to pick up.
    static func setPendingText(_ text: String, sessionID: String? = nil, entryID: String? = nil) {
        if let entryID { suite.set(entryID, forKey: "pendingTextEntryID") }
        else { suite.removeObject(forKey: "pendingTextEntryID") }
        suite.set(text, forKey: pendingTextKey)
        suite.set(Date().timeIntervalSince1970, forKey: pendingTextTimestampKey)
        if let sessionID {
            suite.set(sessionID, forKey: pendingTextSessionIDKey)
        } else {
            suite.removeObject(forKey: pendingTextSessionIDKey)
        }
        setDictationPhase(.ready, sessionID: sessionID)
        // Signal the keyboard that a transcription result is available
        DarwinNotificationCenter.post(.transcriptionReady)
    }

    /// Reads and clears the pending transcribed text.
    /// Automatic handoff expires after a minute; explicit review allows fifteen minutes.
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
        let lifetime = reviewBeforeInsertion ? 15 * 60.0 : pendingTextTTL
        guard age < lifetime else {
            clearPendingText()
            return nil
        }
        return PendingTextPayload(
            text: text,
            sessionID: suite.string(forKey: pendingTextSessionIDKey),
            entryID: suite.string(forKey: "pendingTextEntryID"),
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    /// Clears any pending transcribed text.
    static func clearPendingText() {
        suite.removeObject(forKey: "pendingTextEntryID")
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
        clearLivePreview()
        suite.removeObject(forKey: "dictationPauseRequest")
        suite.set(sessionID, forKey: dictationSessionIDKey)
        suite.set(Date().timeIntervalSince1970, forKey: dictationSessionTimestampKey)
        suite.set(false, forKey: dictationAbandonedKey)
        suite.removeObject(forKey: dictationFailureReasonKey)
        suite.set(false, forKey: dictationStopRequestedKey)
        suite.removeObject(forKey: dictationStopSessionIDKey)
        clearPendingText()
        setDictationPhase(.preparing, sessionID: sessionID)
    }

    static func currentDictationSessionID() -> String? {
        guard let sessionID = suite.string(forKey: dictationSessionIDKey), !sessionID.isEmpty else {
            return nil
        }

        let phase = dictationState().phase
        let timestamp = phase == .ready
            ? suite.double(forKey: pendingTextTimestampKey)
            : suite.double(forKey: dictationSessionTimestampKey)
        let lifetime: TimeInterval
        switch phase {
        case .recording, .paused, .processing:
            lifetime = 60 * 60
        case .ready:
            lifetime = reviewBeforeInsertion ? 15 * 60 : pendingTextTTL
        default:
            lifetime = TimeInterval(dictationSessionDurationMinutes() * 60)
        }
        if timestamp > 0, Date().timeIntervalSince1970 - timestamp >= lifetime {
            abandonDictationSession(reason: "Dictation timed out. Saved text and recordings remain in Murmur.")
            clearDictationSession()
            return nil
        }

        return sessionID
    }

    static func dictationSessionAge() -> TimeInterval? {
        let timestamp = suite.double(forKey: dictationSessionTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date().timeIntervalSince1970 - timestamp
    }

    static func clearDictationSession() {
        clearLivePreview()
        suite.removeObject(forKey: "dictationPauseRequest")
        suite.removeObject(forKey: dictationSessionIDKey)
        suite.removeObject(forKey: dictationSessionTimestampKey)
        suite.removeObject(forKey: dictationFailureReasonKey)
        suite.set(false, forKey: dictationStopRequestedKey)
        suite.removeObject(forKey: dictationStopSessionIDKey)
        setDictationPhase(.idle, sessionID: nil)
    }

    static func abandonDictationSession(reason: String? = nil) {
        suite.set(true, forKey: dictationAbandonedKey)
        if let reason, !reason.isEmpty {
            suite.set(reason, forKey: dictationFailureReasonKey)
        } else {
            suite.removeObject(forKey: dictationFailureReasonKey)
        }
        setDictationPhase(
            .failed,
            sessionID: suite.string(forKey: dictationSessionIDKey)
        )
        // Signal the keyboard that the dictation was abandoned
        DarwinNotificationCenter.post(.dictationAbandoned)
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

    // MARK: - Dictation State

    static func setDictationPhase(_ phase: DictationPhase, sessionID: String?) {
        suite.set(phase.rawValue, forKey: dictationPhaseKey)
        if let sessionID, !sessionID.isEmpty {
            suite.set(sessionID, forKey: dictationPhaseSessionIDKey)
        } else {
            suite.removeObject(forKey: dictationPhaseSessionIDKey)
        }
        DarwinNotificationCenter.post(.dictationStateChanged)
    }

    static func dictationState() -> DictationState {
        let phase = suite.string(forKey: dictationPhaseKey)
            .flatMap(DictationPhase.init(rawValue:)) ?? .idle
        return DictationState(
            phase: phase,
            sessionID: suite.string(forKey: dictationPhaseSessionIDKey)
        )
    }

    static func requestDictationStop(sessionID: String) {
        suite.set(true, forKey: dictationStopRequestedKey)
        suite.set(sessionID, forKey: dictationStopSessionIDKey)
        DarwinNotificationCenter.post(.dictationStopRequested)
    }

    static func consumeDictationStopRequest(matching sessionID: String?) -> Bool {
        guard suite.bool(forKey: dictationStopRequestedKey) else { return false }
        let requestedSessionID = suite.string(forKey: dictationStopSessionIDKey)
        guard requestedSessionID == nil || requestedSessionID == sessionID else {
            return false
        }
        suite.set(false, forKey: dictationStopRequestedKey)
        suite.removeObject(forKey: dictationStopSessionIDKey)
        return true
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
        // Signal the keyboard that model state changed
        DarwinNotificationCenter.post(.modelStateChanged)
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

    // MARK: - Full Access Flag

    private static let fullAccessKey = "keyboardFullAccessGranted"

    /// Called by the keyboard extension to signal whether Full Access is granted.
    static func setFullAccessGranted(_ granted: Bool) {
        suite.set(granted, forKey: fullAccessKey)
    }

    /// Returns whether the keyboard extension has Full Access.
    static func isFullAccessGranted() -> Bool {
        suite.bool(forKey: fullAccessKey)
    }

    // MARK: - Formatting Context

    private static let dictationSurfaceKey = "dictationSurfaceHint"
    private static let dictationContextBeforeKey = "dictationContextBefore"
    private static let dictationContextAfterKey = "dictationContextAfter"

    /// Records the kind of field a dictation started from, plus the text on
    /// either side of the cursor, so the formatter can shape the result for the
    /// surface (a chat reply reads differently from an email) and join an
    /// existing sentence cleanly — the iOS version of the context Amical reads
    /// from the active app. The surface travels as a raw string because the
    /// keyboard extension and the app keep separate copies of the type.
    static func setDictationContext(
        surface: String,
        before: String?,
        after: String?
    ) {
        suite.set(surface, forKey: dictationSurfaceKey)
        if let before, !before.isEmpty {
            suite.set(before, forKey: dictationContextBeforeKey)
        } else {
            suite.removeObject(forKey: dictationContextBeforeKey)
        }
        if let after, !after.isEmpty {
            suite.set(after, forKey: dictationContextAfterKey)
        } else {
            suite.removeObject(forKey: dictationContextAfterKey)
        }
    }

    /// Drops a context that will never be used — a cancelled dictation must not
    /// shape the next one.
    static func clearDictationContext() {
        suite.removeObject(forKey: dictationSurfaceKey)
        suite.removeObject(forKey: dictationContextBeforeKey)
        suite.removeObject(forKey: dictationContextAfterKey)
    }

    /// Reads the context and clears it, so a hint never leaks into the next
    /// dictation and the before/after text is only sent once.
    static func consumeDictationContext() -> (
        surface: String?,
        before: String?,
        after: String?
    ) {
        let surface = suite.string(forKey: dictationSurfaceKey)
        let before = suite.string(forKey: dictationContextBeforeKey)
        let after = suite.string(forKey: dictationContextAfterKey)

        clearDictationContext()

        return (surface, before, after)
    }
}

struct PendingTextPayload: Sendable {
    let text: String
    let sessionID: String?
    let entryID: String?
    let timestamp: Date
}

struct AbandonedSessionPayload: Sendable {
    let sessionID: String?
    let reason: String?
}

enum DictationPhase: String, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case processing
    case ready
    case failed
}

struct DictationState: Sendable {
    let phase: DictationPhase
    let sessionID: String?
}
