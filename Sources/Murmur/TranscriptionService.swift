import Foundation
import WhisperKit
import FluidAudio

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
    @Published private(set) var selectedEngine: TranscriptionEngine = .whisper
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
    private let parakeet = ParakeetTranscriptionService()

    init() {
        selectedEngine = TranscriptionEngine.persisted
    }

    // MARK: - Engine Selection

    /// Switches the recognizer used for dictation. The previous engine's
    /// weights are released immediately and the new engine starts loading, so
    /// both models are never resident together.
    func setEngine(_ engine: TranscriptionEngine) {
        guard engine != selectedEngine else { return }

        selectedEngine = engine
        engine.persist()

        whisperKit = nil
        currentModelName = nil
        modelState = .unloaded
        loadingProgress = ""
        SharedDefaults.setModelReady(false, progressText: nil)

        Task { [weak self] in
            await self?.parakeet.unloadModel()
            guard let self, self.selectedEngine == engine else { return }
            await self.loadModel()
        }
    }

    // MARK: - Model Loading

    /// Loads the active engine's model. Automatically downloads on first launch, then cached locally.
    func loadModel() async {
        switch selectedEngine {
        case .whisper:
            await loadWhisperModel()
        case .parakeet:
            await loadParakeetModel()
        }
    }

    private func loadWhisperModel() async {
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
        loadingProgress = "Preparing \(selectedModel.displayName) model…"
        SharedDefaults.updateModelLoadingProgress(loadingProgress)

        do {
            // Update progress — download happens automatically on first launch
            loadingProgress = "Downloading \(selectedModel.displayName) model (first launch only)\u{2026}"
            SharedDefaults.updateModelLoadingProgress(loadingProgress)

            // WhisperKit 0.9+ accepts a WhisperKitConfig for initialization.
            // download: true ensures automatic download on first launch.
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
            // Provide user-friendly messages for common failure modes
            let desc = error.localizedDescription.lowercased()
            let userMessage: String
            if desc.contains("network") || desc.contains("internet") || desc.contains("offline") || desc.contains("timed out") {
                userMessage = "Model download failed. Check your internet connection and try again."
            } else {
                userMessage = "Failed to load model: \(error.localizedDescription)"
            }
            self.modelState = .error(userMessage)
            self.loadingProgress = ""
            SharedDefaults.setModelReady(false, progressText: nil)
        }
    }

    private func loadParakeetModel() async {
        SharedDefaults.setModelReady(false, progressText: nil)

        if modelState == .loaded {
            SharedDefaults.setModelReady(true, progressText: nil)
            return
        }

        guard modelState != .loading else { return }

        modelState = .loading
        loadingProgress = "Downloading Parakeet model (first launch only)\u{2026}"
        SharedDefaults.updateModelLoadingProgress(loadingProgress)

        do {
            try await parakeet.loadModel()
            self.modelState = .loaded
            self.loadingProgress = ""
            SharedDefaults.setModelReady(true, progressText: nil)
        } catch {
            let desc = error.localizedDescription.lowercased()
            let userMessage: String
            if desc.contains("network") || desc.contains("internet") || desc.contains("offline") || desc.contains("timed out") {
                userMessage = "Parakeet download failed. Check your internet connection and try again."
            } else {
                userMessage = "Failed to load Parakeet: \(error.localizedDescription)"
            }
            self.modelState = .error(userMessage)
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

        switch selectedEngine {
        case .whisper:
            whisperKit = nil
            currentModelName = nil
            modelState = .unloaded
            loadingProgress = ""
            SharedDefaults.setModelReady(false, progressText: nil)
        case .parakeet:
            await parakeet.unloadModel()
            modelState = .unloaded
            loadingProgress = ""
            SharedDefaults.setModelReady(false, progressText: nil)
        }
    }

    // MARK: - Transcription

    /// Transcribes audio from the file at the given URL with the active engine.
    /// - Parameter audioURL: Path to a WAV/M4A audio file.
    /// - Returns: Raw transcription text.
    func transcribe(audioURL: URL, languageCode: String?) async throws -> String {
        try Task.checkCancellation()
        if modelState == .unloaded || modelState.isError { await loadModel() }
        // Cloud fallback may arrive while the initial local model is still loading.
        while modelState == .loading || isTranscribing {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        switch selectedEngine {
        case .whisper:
            return try await transcribeWithWhisper(audioURL: audioURL, languageCode: languageCode)
        case .parakeet:
            return try await transcribeWithParakeet(audioURL: audioURL, languageCode: languageCode)
        }
    }

    private func transcribeWithParakeet(audioURL: URL, languageCode: String?) async throws -> String {
        guard modelState == .loaded else {
            throw TranscriptionError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

        return try await parakeet.transcribe(
            audioURL: audioURL,
            languageCode: languageCode
        )
    }

    private func transcribeWithWhisper(audioURL: URL, languageCode: String?) async throws -> String {
        guard let whisperKit = whisperKit, modelState == .loaded else {
            throw TranscriptionError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let wrapper = UnsafeSendableBox(whisperKit)
        let path = audioURL.path
        let dictionary = PersonalDictionary.enabledEntries
        let language = languageCode
        let fullText = try await Self.runTranscription(
            kit: wrapper,
            audioPath: path,
            dictionary: dictionary,
            language: language
        )
        return fullText
    }

    /// Runs the actual WhisperKit transcription off the main actor to satisfy Swift 6 sendability.
    private nonisolated static func runTranscription(
        kit: UnsafeSendableBox<WhisperKit>,
        audioPath: String,
        dictionary: [PersonalDictionaryEntry],
        language: String?
    ) async throws -> String {
        let whisperKit = kit.value
        let promptTokens: [Int]?
        if let prompt = PersonalDictionary.recognitionPrompt(entries: dictionary),
           let tokenizer = whisperKit.tokenizer {
            // Whisper reserves half of its text context for the previous-text
            // prompt. Keep the most recent 200 tokens within that budget.
            promptTokens = Array(tokenizer.encode(text: prompt).suffix(200))
        } else {
            promptTokens = nil
        }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Trim the tail of each window: the model most often invents
            // "Thank you." and "Please subscribe" over the last second of
            // mostly-silent audio.
            windowClipTime: 1.0,
            promptTokens: promptTokens,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            // Reject a first token the model is not confident about, which is
            // how a hallucinated opening word over noise gets thrown away.
            firstTokenLogProbThreshold: -1.2,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
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



// MARK: - Recognition Engine

/// The on-device recognition engines Murmur supports.
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case whisper
    case parakeet

    static let storageKey = "transcriptionEngine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    var detail: String {
        switch self {
        case .whisper: return "WhisperKit · smallest download"
        case .parakeet: return "NVIDIA Parakeet · Neural Engine · larger download"
        }
    }

    /// The engine the user last picked, defaulting to Whisper so existing
    /// installs keep the behaviour they already had.
    static var persisted: TranscriptionEngine {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let engine = TranscriptionEngine(rawValue: raw)
        else {
            return .whisper
        }
        return engine
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

// MARK: - Parakeet

/// Runs NVIDIA Parakeet (TDT 0.6B) fully on-device through FluidAudio, which
/// executes the Core ML encoder/decoder on the Neural Engine.
///
/// The first `loadModel()` downloads the Core ML bundles (~600 MB) from
/// Hugging Face; afterwards they load from disk. Nothing is uploaded to a
/// server — the download is model weights only.
@MainActor
final class ParakeetTranscriptionService {

    private var manager: AsrManager?

    var isLoaded: Bool { manager != nil }

    func loadModel() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unloadModel() async {
        guard let manager else { return }
        await manager.cleanup()
        self.manager = nil
    }

    func transcribe(audioURL: URL, languageCode: String?) async throws -> String {
        guard let manager else { throw TranscriptionError.modelNotLoaded }
        // A fresh decoder state per dictation; Parakeet is otherwise stateless
        // across utterances.
        var decoderState = try TdtDecoderState()
        // Parakeet v3 is multilingual; the language is a decoding hint, so an
        // unsupported code is left to auto-detection rather than forced.
        let language = languageCode.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
