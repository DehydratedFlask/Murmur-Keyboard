@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// The audio callback and preview task exchange copied samples under this lock.
/// At most twenty seconds are retained; a preview never grows with session length.
private final class PreviewAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var sampleCount = 0
    private let maximumSamples = 20 * 16_000

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.lock()
        defer { lock.unlock() }
        chunks.append(values)
        sampleCount += values.count
        while sampleCount > maximumSamples, chunks.count > 1 {
            sampleCount -= chunks.removeFirst().count
        }
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.flatMap { $0 }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        chunks.removeAll(keepingCapacity: true)
        sampleCount = 0
    }
}

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
    @Published private(set) var isPaused = false
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
    private let previewAudio = PreviewAudioBuffer()
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
    var vadSilenceDuration: TimeInterval = 10.0

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
        stopRecording()
        // The draft store owns deletion. Publish only after the file is closed.
        lastInterruptionError = error.errorDescription
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
    ///
    /// Starting fails often enough in real use — the previous dictation's
    /// session still releasing, the app having been in the background while iOS
    /// tore the session down, a call or another app holding the microphone, a
    /// route change — that one failed attempt is not worth bothering the user
    /// with. Each retry rebuilds the whole audio stack and waits longer, which
    /// is what the old "Try again" button did by hand.
    func startRecording(to destinationURL: URL) async throws {
        // If another start is already in flight, wait for it instead of
        // returning as though this one had succeeded. The keyboard's warm
        // request and its redirect fallback can both arrive; silently returning
        // left nothing recording and looked like "the microphone failed".
        while isStarting {
            try? await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
        }

        // A session the system released while the app was backgrounded can
        // leave this flag set with no engine behind it. Heal that instead of
        // silently ignoring the new request and making the keyboard time out.
        guard !isRecording else { return }
        isStarting = true
        defer { isStarting = false }

        lastInterruptionError = nil
        vadDidAutoStop = false
        vadHasDetectedSpeech = false
        vadSilenceStart = nil
        vadRecordingStart = Date()
        previewAudio.reset()
        cleanupRecording()
        warmSessionReleaseTask?.cancel()

        guard hasPermission else {
            throw RecordingError.noPermission
        }

        var lastError: Error?
        let attempts = 3
        for attempt in 0..<attempts {
            do {
                try await startEngine(to: destinationURL)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            await resetAudioStack()
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }

        throw (lastError as? RecordingError) ?? RecordingError.engineStartFailed
    }

    /// Tears the engine, tap and session down to a known-empty state before the
    /// next attempt, so a half-configured stack cannot poison the retry.
    func resetAudioStack() async {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        isRecording = false
        isPaused = false
        audioSessionGeneration = nil
        await Self.deactivateAudioSession(generation: nil)
    }

    /// One attempt at activating the session, wiring the input tap and starting
    /// the engine. Cleans up after itself on failure.
    private func startEngine(to url: URL) async throws {
        audioSessionGeneration = try await Self.activateAudioSessionWithRetry()

        let engine = AVAudioEngine()
        var temporaryURL: URL?
        var tapInstalled = false

        do {
            try Task.checkCancellation()

            let inputNode = engine.inputNode
            var inputFormat = inputNode.outputFormat(forBus: 0)

            // Returning from the background, the input route needs a moment to
            // settle; reading it too early reports a 0 Hz format and fails a
            // start that would have worked a heartbeat later.
            if inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0 {
                try? await Task.sleep(for: .milliseconds(150))
                inputFormat = inputNode.outputFormat(forBus: 0)
            }

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
                previewAudio: previewAudio,
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
            let generation = audioSessionGeneration
            audioSessionGeneration = nil
            await Self.deactivateAudioSession(generation: generation)
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
        previewAudio: PreviewAudioBuffer,
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
                previewAudio.append(convertedBuffer)
            } catch {
                Task { @MainActor [weak recorder] in
                    guard let recorder, recorder.isRecording else { return }
                    recorder.stopRecording()
                    recorder.lastInterruptionError = "The recording could not be written. The audio captured so far has been kept."
                }
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
        isPaused = false

        // Recording has stopped. Finalization owns a bounded background task;
        // an idle microphone session is not a keep-alive mechanism.
        warmSessionReleaseTask?.cancel()
        let sessionGeneration = audioSessionGeneration
        audioSessionGeneration = nil
        Task { await Self.deactivateAudioSession(generation: sessionGeneration) }

        let url = recordingURL
        // The draft store owns the durable audio, including after an interruption.
        return url
    }

    /// Releases the recorder's reference; only the draft store deletes recordings.
    func cleanupRecording() {
        recordingURL = nil
        previewAudio.reset()
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioEngine?.pause()
        isPaused = true
    }

    func resumeRecording() throws {
        guard isRecording, isPaused, let engine = audioEngine else { return }
        vadHasDetectedSpeech = false
        vadSilenceStart = nil
        vadRecordingStart = Date()
        vadDidAutoStop = false
        try engine.start()
        isPaused = false
    }

    /// A bounded recent-speech window, copied off the realtime callback.
    func previewSnapshot() async throws -> URL? {
        let samples = previewAudio.snapshot()
        guard samples.count >= 16_000 else { return nil }
        return try await Task.detached(priority: .utility) { () throws -> URL? in
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { return nil }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!, count: samples.count)
                }
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }.value
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
        await resetAudioStack()
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
                    guard let self, self.isRecording, !self.isPaused else { return }
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
