import Foundation
import WhisperKit

/// Wrapper to pass non-Sendable types across isolation boundaries when
/// the developer has ensured safety (e.g., no concurrent mutation).
struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Manages WhisperKit model loading and audio transcription entirely on-device.
@MainActor
final class TranscriptionService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var modelState: ModelLoadState = .unloaded
    @Published private(set) var isTranscribing = false
    @Published private(set) var loadingProgress: String = ""
    @Published var selectedModel: WhisperModel = {
        if let raw = UserDefaults.standard.string(forKey: "selectedWhisperModel"),
           let model = WhisperModel(rawValue: raw) {
            return model
        }
        return .tiny
    }() {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhisperModel")
        }
    }

    // MARK: - Private Properties

    private var whisperKit: WhisperKit?
    private var currentModelName: String?

    // MARK: - Model Loading

    /// Loads the WhisperKit model. Downloads on first launch, then cached locally.
    func loadModel() async {
        let modelName = selectedModel.whisperKitName

        SharedDefaults.setModelReady(false, progressText: nil)

        // Skip if already loaded with the same model
        if modelState == .loaded, currentModelName == modelName {
            SharedDefaults.setModelReady(true, progressText: nil)
            return
        }

        // Prevent parallel loads
        guard modelState != .loading else { return }

        modelState = .loading
        loadingProgress = "Loading \(selectedModel.displayName) model…"
        SharedDefaults.updateModelLoadingProgress(loadingProgress)

        do {
            // WhisperKit 0.9+ accepts a WhisperKitConfig for initialization.
            // If the WhisperKitConfig API changes, fall back to the simpler init.
            let kit = try await WhisperKit(
                WhisperKitConfig(
                    model: modelName,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: true
                )
            )
            self.whisperKit = kit
            self.currentModelName = modelName
            self.modelState = .loaded
            self.loadingProgress = ""
            SharedDefaults.setModelReady(true, progressText: nil)
        } catch {
            self.modelState = .error(error.localizedDescription)
            self.loadingProgress = ""
            SharedDefaults.setModelReady(false, progressText: nil)
        }
    }

    /// Unloads the current model to free memory.
    /// Waits for any active transcription to finish before unloading.
    func unloadModel() async {
        // Wait up to 10 seconds for any active transcription to finish.
        var waited = 0
        while isTranscribing, waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        whisperKit = nil
        currentModelName = nil
        modelState = .unloaded
        loadingProgress = ""
        SharedDefaults.setModelReady(false, progressText: nil)
    }

    // MARK: - Transcription

    /// Transcribes audio from the file at the given URL.
    /// - Parameter audioURL: Path to a WAV/M4A audio file.
    /// - Returns: Raw transcription text.
    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit = whisperKit, modelState == .loaded else {
            throw TranscriptionError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let wrapper = UnsafeSendableBox(whisperKit)
        let path = audioURL.path
        let fullText = try await Self.runTranscription(kit: wrapper, audioPath: path)
        return fullText
    }

    /// Runs the actual WhisperKit transcription off the main actor to satisfy Swift 6 sendability.
    private nonisolated static func runTranscription(kit: UnsafeSendableBox<WhisperKit>, audioPath: String) async throws -> String {
        let whisperKit = kit.value
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )

        let fullText = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return fullText
    }
}

// MARK: - Supporting Types

enum ModelLoadState: Equatable {
    case unloaded
    case loading
    case loaded
    case error(String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    static func == (lhs: ModelLoadState, rhs: ModelLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.unloaded, .unloaded): return true
        case (.loading, .loading): return true
        case (.loaded, .loaded): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny
    case base

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (fastest)"
        case .base: return "Base (better accuracy)"
        }
    }

    /// The model identifier that WhisperKit uses internally.
    /// WhisperKit resolves short names like "tiny" or "base" to the appropriate
    /// architecture-specific variant (e.g. "openai_whisper-tiny") during download.
    var whisperKitName: String {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .base: return "openai_whisper-base"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "The transcription model is not loaded. Please wait for it to finish loading."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
