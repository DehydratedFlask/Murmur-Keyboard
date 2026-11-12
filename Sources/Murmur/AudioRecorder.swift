@preconcurrency import AVFoundation
import Accelerate
import Foundation

private actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private var generation = 0

    func activate() throws -> Int {
        generation &+= 1
        let activeGeneration = generation
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        return activeGeneration
    }

    func deactivate(ifCurrent requestedGeneration: Int?) {
        guard requestedGeneration == nil || requestedGeneration == generation else {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

/// Handles audio recording using AVAudioEngine, outputting a 16kHz mono WAV file
/// suitable for WhisperKit transcription.
@MainActor
final class AudioRecorder: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var hasPermission = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var lastInterruptionError: String?

    /// Fires when VAD detects silence after speech — the UI layer should
    /// call `stopRecording()` and begin transcription.
    @Published private(set) var vadDidAutoStop = false

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var recordingURL: URL?
    private var audioSessionGeneration: Int?
    private nonisolated(unsafe) var interruptionObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var routeChangeObserver: (any NSObjectProtocol)?

    /// Target sample rate for WhisperKit (16 kHz)
    private let targetSampleRate: Double = 16000.0

    // MARK: - VAD Configuration

    /// Whether Voice Activity Detection auto-stop is enabled.
    var vadEnabled = true

    /// RMS threshold above which we consider "speech" present.
    /// Typical quiet rooms: 0.005–0.01; speech: 0.02–0.15+.
    private let vadSpeechThreshold: Float = 0.015

    /// How long silence must persist after speech to trigger auto-stop (seconds).
    private let vadSilenceDuration: TimeInterval = 10.0

    /// Minimum recording duration before VAD can auto-stop (seconds).
    /// Prevents premature stops during brief pauses at the start.
    private let vadMinRecordingDuration: TimeInterval = 1.0

    /// VAD state — tracked on the audio tap's queue, results dispatched to MainActor.
    private nonisolated(unsafe) var vadHasDetectedSpeech = false
    private nonisolated(unsafe) var vadSilenceStart: Date?
    private nonisolated(unsafe) var vadRecordingStart: Date?

    /// Releases the warm audio session once the Session-duration window ends.
    private var warmSessionReleaseTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        checkPermission()
        observeAudioSessionNotifications()
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Audio Session Observers

    private nonisolated func observeAudioSessionNotifications() {
        let interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Extract sendable values before crossing isolation boundary
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
        let routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
        self.interruptionObserver = interruptionToken
        self.routeChangeObserver = routeChangeToken
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            guard isRecording else { return }
            finishInterruptedRecording(with: .sessionInterrupted)
        case .ended:
            // The `.began` path intentionally finishes the recording. Starting
            // a fresh audio engine requires an explicit user action; merely
            // reactivating the session here leaves an orphan session active and
            // can recreate iOS 27's main-thread Core Audio hang.
            _ = optionsValue
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard isRecording else { return }
        guard let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            finishInterruptedRecording(with: .audioDeviceDisconnected)
        default:
            break
        }
    }

    private func finishInterruptedRecording(with error: RecordingError) {
        lastInterruptionError = error.errorDescription
        stopRecording()
        cleanupRecording()
    }

    // MARK: - Permission

    func checkPermission() {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                hasPermission = true
                permissionDenied = false
            case .denied:
                hasPermission = false
                permissionDenied = true
            case .undetermined:
                hasPermission = false
                permissionDenied = false
            @unknown default:
                hasPermission = false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                hasPermission = true
                permissionDenied = false
            case .denied:
                hasPermission = false
                permissionDenied = true
            case .undetermined:
                hasPermission = false
                permissionDenied = false
            @unknown default:
                hasPermission = false
            }
        }
    }

    func requestPermission() async {
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            hasPermission = granted
            permissionDenied = !granted
        } else {
            hasPermission = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            permissionDenied = !hasPermission
        }
    }

    // MARK: - Recording

    /// Starts recording audio. Audio-session activation is performed away from
    /// the main actor because iOS 27 reports synchronous activation on the UI
    /// thread as a hang risk and may abort the process in Simulator.
    func startRecording() async throws {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        lastInterruptionError = nil
        vadDidAutoStop = false
        vadHasDetectedSpeech = false
        vadSilenceStart = nil
        vadRecordingStart = Date()
        cleanupRecording()
        warmSessionReleaseTask?.cancel()

        guard hasPermission else {
            throw RecordingError.noPermission
        }

        do {
            audioSessionGeneration = try await Self.activateAudioSessionWithRetry()
        } catch {
            throw RecordingError.engineStartFailed
        }

        let engine = AVAudioEngine()
        var temporaryURL: URL?
        var tapInstalled = false

        do {
            try Task.checkCancellation()

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            // Guard against invalid format (e.g. simulator with no mic hardware)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecordingError.formatError
            }

            // Create recording file at 16kHz mono
            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            temporaryURL = url

            let file = try AVAudioFile(forWriting: url, settings: outputSettings)

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw RecordingError.formatError
            }

            inputNode.removeTap(onBus: 0)
            let tapHandler = Self.makeRecordingTap(
                recorder: self,
                targetSampleRate: targetSampleRate,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                converter: converter,
                file: file,
                vadEnabled: vadEnabled,
                speechThreshold: vadSpeechThreshold,
                silenceDuration: vadSilenceDuration,
                minRecordingDuration: vadMinRecordingDuration
            )
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: inputFormat,
                block: tapHandler
            )
            tapInstalled = true

            try engine.start()
            self.audioEngine = engine
            self.recordingURL = url
            self.isRecording = true
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            await Self.deactivateAudioSession(
                generation: audioSessionGeneration
            )
            audioSessionGeneration = nil
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            if let recordingError = error as? RecordingError {
                throw recordingError
            }
            if error is CancellationError {
                throw error
            }
            throw RecordingError.engineStartFailed
        }
    }

    /// Constructs the realtime callback outside MainActor isolation. AVAudioEngine
    /// invokes this block on its own realtime queue, so inheriting MainActor here
    /// triggers Swift 6's executor check and crashes under iOS 27.
    private nonisolated static func makeRecordingTap(
        recorder: AudioRecorder,
        targetSampleRate: Double,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        file: AVAudioFile,
        vadEnabled: Bool,
        speechThreshold: Float,
        silenceDuration: TimeInterval,
        minRecordingDuration: TimeInterval
    ) -> AVAudioNodeTapBlock {
        { [weak recorder] buffer, _ in
            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetSampleRate / inputFormat.sampleRate
            )

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            do {
                try file.write(from: convertedBuffer)
            } catch {
                // Silently handle write errors during recording
            }

            // --- Voice Activity Detection ---
            if vadEnabled {
                recorder?.processVAD(
                    buffer: convertedBuffer,
                    speechThreshold: speechThreshold,
                    silenceDuration: silenceDuration,
                    minRecordingDuration: minRecordingDuration
                )
            }
        }
    }

    /// Stops recording and returns the URL of the recorded WAV file.
    @discardableResult
    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        // Keep the audio session active for the user's Session duration so the
        // next dictation can start from the background (the keyboard's warm
        // path). "Immediate" releases it straight away.
        let sessionGeneration = audioSessionGeneration
        let warmMinutes = MurmurPreferences.sessionDuration.minutes
        if warmMinutes > 0 {
            scheduleWarmSessionRelease(after: warmMinutes)
        } else {
            audioSessionGeneration = nil
            // Avoid blocking the main actor while Core Audio tears down.
            Task {
                await Self.deactivateAudioSession(generation: sessionGeneration)
            }
        }

        let url = recordingURL
        // Note: recordingURL is intentionally NOT cleared here.
        // cleanupRecording() owns deletion + clearing so that
        // interruption / route-change callers can still remove the temp file.
        return url
    }

    private func scheduleWarmSessionRelease(after minutes: Int) {
        warmSessionReleaseTask?.cancel()
        warmSessionReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            let generation = self.audioSessionGeneration
            self.audioSessionGeneration = nil
            await Self.deactivateAudioSession(generation: generation)
        }
    }

    /// Cleans up any temporary recording files.
    func cleanupRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    private nonisolated static func activateAudioSession() async throws -> Int {
        try await AudioSessionCoordinator.shared.activate()
    }

    /// Tries to activate, tearing down and retrying when the system refuses —
    /// a session left behind by an interruption or another app can block the
    /// first attempt.
    private nonisolated static func activateAudioSessionWithRetry() async throws -> Int {
        do {
            return try await AudioSessionCoordinator.shared.activate()
        } catch {
            await AudioSessionCoordinator.shared.deactivate(ifCurrent: nil)
            try? await Task.sleep(for: .milliseconds(250))
            do {
                return try await AudioSessionCoordinator.shared.activate()
            } catch {
                await AudioSessionCoordinator.shared.deactivate(ifCurrent: nil)
                try? await Task.sleep(for: .milliseconds(500))
                return try await AudioSessionCoordinator.shared.activate()
            }
        }
    }

    /// Releases and rebuilds the audio session. Backs the "Try again" action
    /// shown when the microphone couldn't be started.
    func recoverAudioSession() async {
        warmSessionReleaseTask?.cancel()
        audioSessionGeneration = nil
        await Self.deactivateAudioSession(generation: nil)
        audioSessionGeneration = try? await Self.activateAudioSessionWithRetry()
    }

    private nonisolated static func deactivateAudioSession(
        generation: Int?
    ) async {
        await AudioSessionCoordinator.shared.deactivate(
            ifCurrent: generation
        )
    }

    // MARK: - Voice Activity Detection

    /// Called on the audio tap thread for each converted buffer.
    /// Computes RMS energy and decides whether to auto-stop.
    private nonisolated func processVAD(
        buffer: AVAudioPCMBuffer,
        speechThreshold: Float,
        silenceDuration: TimeInterval,
        minRecordingDuration: TimeInterval
    ) {
        let rms = Self.rmsLevel(of: buffer)

        if rms >= speechThreshold {
            // Speech detected
            vadHasDetectedSpeech = true
            vadSilenceStart = nil
        } else if vadHasDetectedSpeech {
            // Silence after speech
            let now = Date()
            if vadSilenceStart == nil {
                vadSilenceStart = now
            }

            if let silenceStart = vadSilenceStart,
               let recordingStart = vadRecordingStart,
               now.timeIntervalSince(silenceStart) >= silenceDuration,
               now.timeIntervalSince(recordingStart) >= minRecordingDuration {
                // Auto-stop: reset state and signal main thread
                vadHasDetectedSpeech = false
                vadSilenceStart = nil
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.vadDidAutoStop = true
                }
            }
        }
    }

    /// Computes RMS (root mean square) energy of a float PCM buffer.
    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }
        let samples = channelData[0]
        let count = Int(buffer.frameLength)
        var meanSquare: Float = 0
        vDSP_measqv(
            samples,
            1,
            &meanSquare,
            vDSP_Length(count)
        )
        return sqrtf(meanSquare)
    }

}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case noPermission
    case formatError
    case engineStartFailed
    case audioDeviceDisconnected
    case sessionInterrupted

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Microphone permission is required to record audio."
        case .formatError:
            return "Failed to configure audio format."
        case .engineStartFailed:
            return "Couldn't start the microphone. Please try again."
        case .audioDeviceDisconnected:
            return "Audio device disconnected"
        case .sessionInterrupted:
            return "Recording interrupted"
        }
    }
}
