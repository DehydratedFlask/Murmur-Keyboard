import Combine
import SwiftUI

/// App-lifetime owner of capture, recovery and delivery. Navigation never owns audio work.
@MainActor
final class CaptureCoordinator: ObservableObject {
    let recorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    let store = TranscriptionStore()
    let snippetStore = SnippetStore()
    let draftStore = RecordingDraftStore()
    private let appState = AppState.shared
    @Published var activeDraft: RecordingDraft?
    @Published var captureDestination: CaptureDestination = .note
    @Published var livePreview = ""
    @Published var captureStartPending = false
    @Published var isProcessing = false
    @Published private(set) var processingCancellationRequested = false
    @Published var errorMessage: String?
    @Published var showCopiedToast = false
    @Published var isDictationFromKeyboard = false
    @Published var keyboardDictationSessionID: String?
    @Published var keyboardCompletionMessage: String?
    @Published var showMicPermissionAlert = false
    @Published var showCloudFallbackToast = false
    @Published private(set) var recordingStartedAt: Date?
    private var previewTask: Task<Void, Never>?
    private var pendingClipboardText: String?
    private var dictationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionTaskID: UInt = 0
    private var toastDismissTask: Task<Void, Never>?
    private var cloudFallbackDismissTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var holdsCaptureLease = false
    private var lifecycle = CaptureLifecycle()
    private var processingDraft: RecordingDraft?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var subscriptions: Set<AnyCancellable> = []
    private let recordHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let successHaptic = UINotificationFeedbackGenerator()

    init() {
        // Bubble dependency changes through one stable app-owned observable object.
        for publisher in [recorder.objectWillChange.eraseToAnyPublisher(),
                          transcriptionService.objectWillChange.eraseToAnyPublisher(),
                          store.objectWillChange.eraseToAnyPublisher(),
                          snippetStore.objectWillChange.eraseToAnyPublisher(),
                          draftStore.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        recorder.$vadDidAutoStop.dropFirst().sink { [weak self] stop in
            guard let self, stop, self.recorder.isRecording, !self.recorder.isPaused else { return }
            self.stopAndTranscribe()
        }.store(in: &subscriptions)
        recorder.$lastInterruptionError.compactMap { $0 }.sink { [weak self] message in
            self?.recordingInterrupted(message)
        }.store(in: &subscriptions)
    }

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        MurmurDictationLiveActivity.endAllImmediately()
        startHeartbeat()
        SharedDefaults.setDictationSessionDurationMinutes(max(1, MurmurPreferences.sessionDuration.minutes))
        // Model preparation and permission are independent of handling a capture request.
        prepareModel()
        handleStartDictationRequest()
        handleCaptureRequest()
    }

    private func prepareModel() {
        guard modelPreparationTask == nil else { return }
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            await transcriptionService.loadModel()
            modelPreparationTask = nil
        }
    }

    private func releaseCaptureLease() {
        guard holdsCaptureLease else { return }
        holdsCaptureLease = false
        transcriptionService.endCapture()
    }

    private func recordingInterrupted(_ message: String) {
        appState.isCapturing = false
        previewTask?.cancel()
        MurmurDictationLiveActivity.end()
        if let draft = activeDraft {
            do { try draftStore.update(draft, message: message + " Retry the saved recording in History.") }
            catch { presentError(error.localizedDescription) }
        }
        activeDraft = nil
        recordingStartedAt = nil
        if let operation = lifecycle.operation { lifecycle.finish(operation.id) }
        recorder.cleanupRecording()
        releaseCaptureLease()
        if isDictationFromKeyboard { signalKeyboardDictationAbandoned(reason: message + " Your recording is saved in Murmur.") }
        presentError(message)
    }

    private func beginFinalization() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cancelProcessing()
                self.presentError("Background processing ended. Your recording is saved in History; open it to retry.")
                self.endFinalization()
            }
        }
    }

    private func endFinalization() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func cancelProcessing() {
        if isProcessing { processingCancellationRequested = true }
        transcriptionTask?.cancel()
        previewTask?.cancel()
        if let operation = lifecycle.operation { lifecycle.finish(operation.id) }
        if let draft = processingDraft,
           let current = draftStore.drafts.first(where: { $0.id == draft.id }) {
            do { try draftStore.update(current, message: "Processing stopped. Retry this saved recording when you are ready.") }
            catch { presentError(error.localizedDescription) }
        }
    }

    func copyText(_ text: String) {
        pendingClipboardText = text
        finishClipboardDeliveryIfPossible()
    }

    func cancelKeyboardDictationFromScreen() {
        appState.isCapturing = false
        dictationTask?.cancel()
        previewTask?.cancel()
        MurmurDictationLiveActivity.end()
        if recorder.isRecording {
            _ = recorder.stopRecording()
            recorder.cleanupRecording()
        }
        cancelProcessing()
        if let operation = lifecycle.operation { lifecycle.finish(operation.id) }
        if let draft = activeDraft {
            do { try draftStore.update(draft, message: "Capture canceled. Your recording is kept for later.") }
            catch { presentError(error.localizedDescription) }
            activeDraft = nil
        }
        recordingStartedAt = nil
        if !isProcessing { releaseCaptureLease() }
        SharedDefaults.clearPendingText()
        SharedDefaults.setDictationRequested(false)
        SharedDefaults.clearDictationSession()
        keyboardCompletionMessage = nil
        keyboardDictationSessionID = nil
        isDictationFromKeyboard = false
    }

    /// Rebuilds the audio session and retries whatever just failed, so a
    /// "microphone not available" moment is never a dead end.
    func retryAfterError() {
        let wasKeyboardDictation = isDictationFromKeyboard
        clearErrorMessage()
        Task {
            await recorder.recoverAudioSession()
            if wasKeyboardDictation {
                dictationTask?.cancel()
                dictationTask = handleDictationRequest()
            } else {
                handleRecordingTap()
            }
        }
    }

    func presentError(_ rawMessage: String) {
        errorMessage = saneErrorText(rawMessage)
    }

    /// Raw system error text such as "The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)" tells the user nothing and is never
    /// worth showing. Anything we cannot make meaningful gets the one message
    /// the user can actually act on.
    private func saneErrorText(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("cancellation")
            || lowered.contains("the operation couldn")
            || lowered.contains("required condition is false")
            || lowered.contains("osstatus")
            || lowered.contains("error 1") {
            return NSLocalizedString(
                "Couldn't start the microphone. Please try again.",
                comment: "Fallback message for an unfriendly audio error"
            )
        }
        if raw == "Audio device disconnected" {
            return NSLocalizedString(
                "Recording interrupted. Please try again.",
                comment: "Audio route lost mid-recording"
            )
        }
        return raw
    }

    func clearErrorMessage() {
        errorMessage = nil
    }

    // MARK: - Recording Actions

    func handleRecordingTap() {
        guard !recorder.isStarting, !isProcessing, !captureStartPending else { return }
        recordHaptic.impactOccurred()
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            if captureDestination == .keyboard { captureDestination = .note }
            isDictationFromKeyboard = false
            keyboardDictationSessionID = nil
            dictationTask?.cancel()
            dictationTask = Task { await startRecording() }
        }
    }

    @discardableResult
    private func handleDictationRequest() -> Task<Void, Never> {
        Task {
            guard !Task.isCancelled else { return }
            keyboardCompletionMessage = nil
            await startRecording()
        }
    }

    private func startRecording() async {
        guard !captureStartPending, !recorder.isRecording, !isProcessing,
              let operationID = lifecycle.begin(sessionID: keyboardDictationSessionID) else { return }
        captureStartPending = true
        defer {
            captureStartPending = false
            if !recorder.isRecording, !isProcessing { lifecycle.finish(operationID) }
        }
        clearErrorMessage()
        await recorder.requestPermission()
        guard !Task.isCancelled, lifecycle.owns(operationID) else { return }
        guard recorder.hasPermission else {
            showMicPermissionAlert = true
            handleRecordingStartFailure(RecordingError.noPermission)
            return
        }
        transcriptionService.beginCapture()
        holdsCaptureLease = true
        prepareModel()

        // Activating the audio session is refused while the app is still coming
        // to the foreground, which is exactly when a keyboard-initiated
        // dictation starts. Wait for it to be active instead of failing.
        var waited = 0
        while UIApplication.shared.applicationState != .active, waited < 30 {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                releaseCaptureLease()
                return
            }
            waited += 1
        }
        guard UIApplication.shared.applicationState == .active, !Task.isCancelled else {
            releaseCaptureLease()
            if !Task.isCancelled { presentError("Open Murmur to start the microphone.") }
            return
        }
        let hint = isDictationFromKeyboard ? SharedDefaults.consumeDictationContext() : (surface: nil as String?, before: nil as String?, after: nil as String?)
        let configured = MurmurPreferences.formattingSurface
        let surface = configured == .automatic ? (hint.surface.flatMap(DictationSurface.init(rawValue:)) ?? .general) : configured
        let draft: RecordingDraft
        do {
            draft = try draftStore.create(
                destination: captureDestination, surface: surface,
                languageCode: MurmurPreferences.primaryLanguageCode, before: hint.before, after: hint.after
            )
        } catch {
            handleRecordingStartFailure(error)
            return
        }
        activeDraft = draft
        let silence = MurmurPreferences.silenceMode.seconds
        recorder.vadEnabled = silence != nil
        recorder.vadSilenceDuration = silence ?? 10

        do {
            try await recorder.startRecording(to: draftStore.audioURL(for: draft))
        } catch is CancellationError {
            // A newer dictation request replaced this one — most often right
            // after stopping and starting again. Nothing failed, so nothing to
            // report: the previous session must not be marked abandoned either,
            // because the keyboard already owns a fresh session.
            releaseCaptureLease()
            return
        } catch {
            if case RecordingError.noPermission = error {
                showMicPermissionAlert = recorder.permissionDenied
                handleRecordingStartFailure(error)
                return
            }

            // One silent recovery before bothering the user: a session iOS
            // released while the app sat in the background is the usual reason a
            // second dictation reports "couldn't start the microphone".
            await recorder.recoverAudioSession()
            do {
                try await recorder.startRecording(to: draftStore.audioURL(for: draft))
            } catch is CancellationError {
                releaseCaptureLease()
                return
            } catch {
                handleRecordingStartFailure(error)
                return
            }
        }
        guard !Task.isCancelled, activeDraft?.id == draft.id else {
            recorder.stopRecording()
            recorder.cleanupRecording()
            releaseCaptureLease()
            return
        }
        didStartRecording()
    }

    /// Everything that follows a successful start, shared by the first attempt
    /// and the silent retry.
    private func didStartRecording() {
        if let operation = lifecycle.operation { lifecycle.move(operation.id, to: .recording) }
        appState.isCapturing = true
        recordingStartedAt = Date()
        MurmurDictationLiveActivity.start()
        startLivePreview()

        // Trust the shared session as well as the local flag: a duplicate
        // request can consume the one-shot flag before this runs, and then the
        // keyboard would sit on "Starting…" while the microphone was open.
        if captureDestination == .keyboard && !isDictationFromKeyboard {
            let state = SharedDefaults.dictationState()
            if state.phase == .preparing, let sessionID = SharedDefaults.currentDictationSessionID() {
                isDictationFromKeyboard = true
                keyboardDictationSessionID = sessionID
            }
        }

        guard isDictationFromKeyboard, let keyboardDictationSessionID else { return }

        SharedDefaults.setDictationPhase(
            .recording,
            sessionID: keyboardDictationSessionID
        )
        keyboardCompletionMessage =
            "Recording started. Return to your app, then finish from Murmur’s keyboard."

        // The request flag is persistent, so this also catches a stop signal
        // delivered while the app was finishing startup.
        if SharedDefaults.consumeDictationStopRequest(
            matching: keyboardDictationSessionID
        ) {
            stopAndTranscribe()
        }
    }

    private func handleRecordingStartFailure(_ error: Error) {
        releaseCaptureLease()
        if let draft = activeDraft {
            do { try draftStore.discard(draft) }
            catch { presentError(error.localizedDescription) }
            activeDraft = nil
        }
        if case RecordingError.noPermission = error {
            showMicPermissionAlert = recorder.permissionDenied
        }
        let message = saneErrorText(error.localizedDescription)
        if isDictationFromKeyboard {
            signalKeyboardDictationAbandoned(reason: message)
        }
        presentError(message)
    }

    /// Keeps the app-group heartbeat fresh while this process is alive, so the
    /// keyboard knows it can request a warm dictation without a redirect.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        SharedDefaults.markAppAlive()
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                SharedDefaults.markAppAlive()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopAndTranscribe() {
        appState.isCapturing = false
        guard !isProcessing, let draft = activeDraft else { return }
        beginFinalization()
        MurmurDictationLiveActivity.end()
        recorder.stopRecording()
        recorder.cleanupRecording()
        recordingStartedAt = nil
        activeDraft = nil
        transcribeDraft(draft, sessionID: keyboardDictationSessionID, destination: captureDestination)
    }

    func retryDraft(_ draft: RecordingDraft) {
        guard !recorder.isRecording, !recorder.isStarting, !isProcessing, !captureStartPending else { return }
        // A retry is a fresh app action; never send it to a field from an old session.
        isDictationFromKeyboard = false
        keyboardDictationSessionID = nil
        transcribeDraft(draft, sessionID: nil, destination: draft.destination == .clipboard ? .clipboard : .note)
    }

    private func transcribeDraft(_ draft: RecordingDraft, sessionID: String?, destination: CaptureDestination) {
        guard !isProcessing else { return }
        let operationID: UUID
        if let operation = lifecycle.operation { operationID = operation.id }
        else if let fresh = lifecycle.begin(sessionID: sessionID) { operationID = fresh }
        else { return }
        guard lifecycle.move(operationID, to: .processing) else { return }
        processingDraft = draft
        processingCancellationRequested = false
        isProcessing = true
        if !holdsCaptureLease {
            transcriptionService.beginCapture()
            holdsCaptureLease = true
        }
        beginFinalization()
        clearErrorMessage()
        if let sessionID { SharedDefaults.setDictationPhase(.processing, sessionID: sessionID) }
        let preview = previewTask
        previewTask?.cancel()
        previewTask = nil
        transcriptionTaskID &+= 1
        let taskID = transcriptionTaskID
        let audioURL = draftStore.audioURL(for: draft)
        transcriptionTask = Task { @MainActor in
            // Cancellation may not interrupt a model call. Join it before final decoding.
            await preview?.value
            defer {
                if transcriptionTaskID == taskID {
                    isProcessing = false
                    processingCancellationRequested = false
                    transcriptionTask = nil
                    processingDraft = nil
                }
                lifecycle.finish(operationID)
                releaseCaptureLease()
                endFinalization()
            }
            var latestDraft = draft
            do {
                try Task.checkCancellation()
                guard lifecycle.owns(operationID) else { throw CancellationError() }
                // Retry recognition from saved audio. Cached words are a fallback
                // only if the recording itself is no longer available.
                var rawText: String? = FileManager.default.fileExists(atPath: audioURL.path) ? nil : draft.rawText
                var didFallback = false
                if rawText == nil {
                    let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
                    guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 44 else {
                        throw DictationCaptureError.noAudio
                    }
                    let scan = await SpeechSegmenter.scan(audioURL)
                    if let scan, !scan.hasSpeech { throw DictationCaptureError.noSpeech }
                    let inputURL = scan?.audioURL ?? audioURL
                    defer {
                        if inputURL != audioURL { try? FileManager.default.removeItem(at: inputURL) }
                    }
                    if CloudTranscriptionService.isReady {
                        do {
                            rawText = try await CloudTranscriptionService.transcribe(audioURL: inputURL, languageCode: draft.languageCode)
                        } catch {
                            try Task.checkCancellation()
                            rawText = try await transcriptionService.transcribe(audioURL: inputURL, languageCode: draft.languageCode)
                            didFallback = true
                        }
                    } else {
                        rawText = try await transcriptionService.transcribe(audioURL: inputURL, languageCode: draft.languageCode)
                    }
                    try Task.checkCancellation()
                    latestDraft = try draftStore.update(draft, message: "Transcribed. Finishing text…", rawText: rawText)
                }
                let original = rawText ?? ""
                let surface = DictationSurface(rawValue: draft.surface) ?? .general
                let polished = await TranscriptCleanupService.process(
                    original, useFoundationModel: MurmurPreferences.aiCleanupEnabled,
                    surface: surface, contextBefore: draft.contextBefore, contextAfter: draft.contextAfter
                )
                let text = surface == .verbatim ? polished : SnippetStore.apply(snippetStore.snippets, to: polished)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationCaptureError.noSpeech }
                try Task.checkCancellation()
                let entry = TranscriptionEntry(id: draft.id, text: text, rawText: original, polishedText: text)
                try await store.saveDurably(entry)
                // History is safely written before the recovery audio is removed.
                do { try draftStore.discard(latestDraft) }
                catch { presentError("Text saved, but the recording could not be deleted: " + error.localizedDescription) }

                try Task.checkCancellation()
                guard lifecycle.owns(operationID) else { throw CancellationError() }
                if let sessionID, lifecycle.canDeliver(operationID, to: SharedDefaults.currentDictationSessionID()) {
                    SharedDefaults.setPendingText(text, sessionID: sessionID, entryID: entry.id.uuidString)
                    successHaptic.notificationOccurred(.success)
                } else if destination == .clipboard {
                    pendingClipboardText = text
                    finishClipboardDeliveryIfPossible()
                }
                if didFallback {
                    showCloudFallbackToast = true
                    cloudFallbackDismissTask?.cancel()
                    cloudFallbackDismissTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { showCloudFallbackToast = false }
                    }
                }
                isDictationFromKeyboard = false
                keyboardDictationSessionID = nil
            } catch {
                let message = error is CancellationError ? "Transcription paused. Retry the saved recording." : saneErrorText(error.localizedDescription)
                do { try draftStore.update(latestDraft, message: message) }
                catch { presentError(error.localizedDescription) }
                if let sessionID, SharedDefaults.currentDictationSessionID() == sessionID {
                    signalKeyboardDictationAbandoned(reason: message + " Your recording is saved in Murmur.")
                }
                presentError(message + " Your recording is saved below.")
            }
        }
    }

    func handleKeyboardStopRequest() {
        if let sessionID = keyboardDictationSessionID {
            guard SharedDefaults.consumeDictationStopRequest(matching: sessionID) else { return }
            if SharedDefaults.currentDictationSessionID() != sessionID {
                cancelKeyboardDictationFromScreen()
                return
            }
        }
        if recorder.isRecording { stopAndTranscribe() }
    }

    private func startLivePreview() {
        let previous = previewTask
        previous?.cancel()
        livePreview = ""
        guard MurmurPreferences.livePreviewEnabled, let draft = activeDraft else { return }
        previewTask = Task { @MainActor in
            await previous?.value
            while !Task.isCancelled, recorder.isRecording, activeDraft?.id == draft.id {
                do { try await Task.sleep(for: .seconds(4)) }
                catch { return }
                guard !Task.isCancelled, recorder.isRecording, !recorder.isPaused,
                      !isProcessing, !ProcessInfo.processInfo.isLowPowerModeEnabled,
                      ProcessInfo.processInfo.thermalState == .nominal,
                      transcriptionService.modelState == .loaded,
                      !transcriptionService.isTranscribing else { continue }
                do {
                    guard let url = try await recorder.previewSnapshot() else { continue }
                    defer { try? FileManager.default.removeItem(at: url) }
                    try Task.checkCancellation()
                    let scan = await SpeechSegmenter.scan(url)
                    let input = scan?.audioURL ?? url
                    defer { if input != url { try? FileManager.default.removeItem(at: input) } }
                    if let scan, !scan.hasSpeech { continue }
                    guard let text = try await transcriptionService.transcribePreview(audioURL: input, languageCode: draft.languageCode) else { continue }
                    guard !Task.isCancelled, recorder.isRecording, activeDraft?.id == draft.id else { return }
                    livePreview = TextProcessor.removeSpeechArtifacts(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let sessionID = keyboardDictationSessionID {
                        SharedDefaults.setLivePreview(livePreview, sessionID: sessionID)
                    }
                } catch {
                    // Provisional decoding is best effort; the durable final recording remains intact.
                    if Task.isCancelled { return }
                }
            }
        }
    }

    func setRecordingPaused(_ paused: Bool) {
        guard recorder.isRecording else { return }
        do {
            if paused { recorder.pauseRecording() }
            else { try recorder.resumeRecording() }
            MurmurDictationLiveActivity.setPaused(recorder.isPaused)
            if let operation = lifecycle.operation {
                lifecycle.move(operation.id, to: recorder.isPaused ? .paused : .recording)
            }
            if let sessionID = keyboardDictationSessionID {
                SharedDefaults.setDictationPhase(recorder.isPaused ? .paused : .recording, sessionID: sessionID)
            }
        } catch { presentError(error.localizedDescription) }
    }

    func keepActiveDraft() {
        appState.isCapturing = false
        guard let draft = activeDraft else { return }
        previewTask?.cancel()
        recorder.stopRecording()
        recorder.cleanupRecording()
        activeDraft = nil
        recordingStartedAt = nil
        if let operation = lifecycle.operation { lifecycle.finish(operation.id) }
        releaseCaptureLease()
        MurmurDictationLiveActivity.end()
        do { try draftStore.update(draft, message: "Kept for later. Retry when you are ready.") }
        catch { presentError(error.localizedDescription) }
        if isDictationFromKeyboard { signalKeyboardDictationAbandoned(reason: "Recording kept in Murmur for later.") }
    }

    func handleStartDictationRequest() {
        if appState.shouldStartDictation {
            appState.shouldStartDictation = false

            // A duplicate request — two taps, or a redirect arriving while
            // a start is in flight — must not tear down work in progress.
            // Doing that left the keyboard on "Starting…" with the
            // microphone open and the checkmark disabled.
            guard !recorder.isStarting, !recorder.isRecording, !isProcessing, !captureStartPending else { return }

            // Cancel any prior stale / background task before starting new work.
            dictationTask?.cancel()

            // The keyboard's session id is the source of truth for whether
            // this dictation belongs to it — the one-shot request flag can
            // already have been consumed by a duplicate.
            let sharedState = SharedDefaults.dictationState()
            isDictationFromKeyboard = SharedDefaults.consumeDictationRequested()
                || (sharedState.phase == .preparing && sharedState.sessionID != nil)
            keyboardDictationSessionID = isDictationFromKeyboard
                ? (SharedDefaults.currentDictationSessionID() ?? sharedState.sessionID)
                : nil
            keyboardCompletionMessage = nil
            captureDestination = isDictationFromKeyboard ? .keyboard : .note

            dictationTask = handleDictationRequest()
        }
    }

    func handleCaptureRequest() {
        guard let request = appState.captureRequest else { return }
        appState.captureRequest = nil
        guard !recorder.isRecording, !recorder.isStarting, !isProcessing, !captureStartPending else {
            presentError("Finish the current dictation before starting another.")
            return
        }
        captureDestination = request.destination
        isDictationFromKeyboard = false
        keyboardDictationSessionID = nil
        dictationTask?.cancel()
        dictationTask = handleDictationRequest()
    }

    func finishClipboardDeliveryIfPossible() {
        guard UIApplication.shared.applicationState == .active, let text = pendingClipboardText else { return }
        UIPasteboard.general.string = text
        pendingClipboardText = nil
        showCopiedToast = true
        toastDismissTask?.cancel()
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { showCopiedToast = false }
        }
    }

    // MARK: - Memory Warning

    func handleMemoryWarning() {
        // Only unload the model if we are NOT actively recording or transcribing.
        // This prevents data loss during an in-progress dictation.
        guard !recorder.isRecording, !isProcessing, !transcriptionService.isTranscribing else {
            print("[Murmur] Memory warning received but recording/transcribing is active — skipping model unload.")
            return
        }
        print("[Murmur] Memory warning received — unloading WhisperKit model to free memory.")
        SharedDefaults.setModelReady(false, progressText: nil)
        Task {
            await transcriptionService.unloadModel()
        }
    }

    private func signalKeyboardDictationAbandoned(reason: String) {
        MurmurDictationLiveActivity.end()
        SharedDefaults.abandonDictationSession(reason: saneErrorText(reason))
        SharedDefaults.setDictationRequested(false)
        keyboardCompletionMessage = nil
        isDictationFromKeyboard = false
        keyboardDictationSessionID = nil
    }
}
