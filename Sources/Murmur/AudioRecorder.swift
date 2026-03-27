import AVFoundation
import Foundation

/// Handles audio recording using AVAudioEngine, outputting a 16kHz mono WAV file
/// suitable for WhisperKit transcription.
@MainActor
final class AudioRecorder: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRecording = false
    @Published private(set) var hasPermission = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var audioLevel: Float = 0.0

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    /// Target sample rate for WhisperKit (16 kHz)
    private let targetSampleRate: Double = 16000.0

    // MARK: - Initialization

    init() {
        checkPermission()
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

    /// Starts recording audio. Returns immediately; audio is saved to a temp file.
    func startRecording() throws {
        guard !isRecording else { return }

        guard hasPermission else {
            throw RecordingError.noPermission
        }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw RecordingError.engineStartFailed
        }

        // Create engine
        let engine = AVAudioEngine()
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

        let file = try AVAudioFile(forWriting: url, settings: outputSettings)

        // Create converter from input format to 16kHz mono
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.formatError
        }

        // Remove any existing tap before installing a new one
        inputNode.removeTap(onBus: 0)

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Calculate audio level for UI visualization
            self?.calculateAudioLevel(buffer: buffer)

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (self?.targetSampleRate ?? 16000.0) / inputFormat.sampleRate
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
        }

        try engine.start()

        self.audioEngine = engine
        self.audioFile = file
        self.recordingURL = url
        self.isRecording = true
    }

    /// Stops recording and returns the URL of the recorded WAV file.
    @discardableResult
    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false
        audioLevel = 0.0

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return recordingURL
    }

    /// Cleans up any temporary recording files.
    func cleanupRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    // MARK: - Audio Level

    private nonisolated func calculateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(frames, 1)))
        // Convert to a 0-1 range with some amplification
        let level = min(max(rms * 3.0, 0), 1.0)

        Task { @MainActor [weak self] in
            self?.audioLevel = level
        }
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case noPermission
    case formatError
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Microphone permission is required to record audio."
        case .formatError:
            return "Failed to configure audio format."
        case .engineStartFailed:
            return "Failed to start the audio engine."
        }
    }
}
