import Foundation
import Combine

/// Main-actor UI coordinator. Model objects live only in NativeModelRuntime;
/// the policy admits exactly one load, decode or unload across actor suspension.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var modelState: ModelLoadState = .unloaded
    @Published private(set) var isTranscribing = false
    @Published private(set) var loadingProgress = ""
    @Published private(set) var selectedEngine: TranscriptionEngine = .whisper
    @Published private(set) var activeModelLabel: String?
    @Published private(set) var readinessStage: ModelReadinessStage = .unloaded
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var cachedModelBytes: Int64 = 0
    @Published var selectedModel: WhisperModel = {
        if let raw = UserDefaults.standard.string(forKey: "selectedWhisperModel"),
           let model = WhisperModel(rawValue: raw) { return model }
        return .tiny
    }() {
        didSet {
            guard selectedModel != oldValue else { return }
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhisperModel")
            selectionChanged()
        }
    }

    private let runtime: any ModelRuntimeBackend
    private let readinessChanged: @MainActor (Bool, String?) -> Void
    private var policy = ModelSchedulingPolicy(selection: ModelSelection(engine: .whisper, whisperModel: .tiny))
    private var activeSelection: ModelSelection?
    private var failedSelection: ModelSelection?
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?
    private var wantsModelLoaded = false

    var isModelSwitchDeferred: Bool { policy.isSwitchDeferred }

    init(runtime: any ModelRuntimeBackend, readinessChanged: @escaping @MainActor (Bool, String?) -> Void = { _, _ in }) {
        self.runtime = runtime
        self.readinessChanged = readinessChanged
        selectedEngine = TranscriptionEngine.persisted
        policy.select(selection)
        Task { [weak self, runtime] in
            let bytes = await runtime.cachedBytes()
            self?.cachedModelBytes = bytes
        }
    }

    private var selection: ModelSelection {
        ModelSelection(engine: selectedEngine, whisperModel: selectedModel)
    }

    func setEngine(_ engine: TranscriptionEngine) {
        guard engine != selectedEngine else { return }
        selectedEngine = engine
        engine.persist()
        selectionChanged()
    }

    private func selectionChanged() {
        policy.select(selection)
        wantsModelLoaded = true
        // During capture the old choice stays pinned through final recognition.
        // endCapture applies the latest choice, coalescing intermediate changes.
        if policy.captureCount == 0 { startLoadingIfNeeded() }
    }

    /// Pin selection before starting capture. Keep the lease until final
    /// processing/cancellation has finished; nested recognition leases are safe.
    func beginCapture() {
        policy.beginCapture()
    }

    func endCapture() {
        policy.endCapture()
        objectWillChange.send()
        if policy.captureCount == 0, wantsModelLoaded { startLoadingIfNeeded() }
    }

    /// Duplicate callers await one worker. Recognition uses a cancellable wait
    /// below so cancelling a recording does not cancel another caller's load.
    func loadModel() async {
        wantsModelLoaded = true
        failedSelection = nil
        startLoadingIfNeeded()
        await loadTask?.value
    }

    private func startLoadingIfNeeded() {
        guard wantsModelLoaded, loadTask == nil, failedSelection != policy.effectiveSelection else { return }
        if activeSelection == policy.effectiveSelection, modelState == .loaded { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoadCycle()
        }
    }

    private func acquire(_ operation: ModelSchedulingPolicy<ModelSelection>.Operation) async throws {
        while !policy.acquire(operation) {
            try await Task.sleep(for: .milliseconds(40))
        }
        // A cancelled waiter must not acquire and then abandon the gate.
        if Task.isCancelled {
            policy.release()
            throw CancellationError()
        }
    }

    private func performLoadCycle() async {
        defer { loadTask = nil }
        while wantsModelLoaded, !Task.isCancelled {
            do { try await acquire(.maintenance) }
            catch { return }
            let target = policy.effectiveSelection
            if activeSelection == target, modelState == .loaded {
                policy.release()
                return
            }
            let operationID = UUID()
            loadID = operationID
            modelState = .loading
            activeModelLabel = nil
            report(.init(stage: .checkingCache), for: target)
            await runtime.unload()
            activeSelection = nil
            do {
                try Task.checkCancellation()
                try await runtime.load(target) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadID == operationID,
                              self.policy.effectiveSelection == target else { return }
                        self.report(update, for: target)
                    }
                }
                try Task.checkCancellation()
                // Selection may change while the SDK is suspended. Such a model
                // is released before loading the latest choice and never ready.
                guard target == policy.effectiveSelection, wantsModelLoaded else {
                    loadID = nil
                    await runtime.unload()
                    policy.release()
                    continue
                }
                activeSelection = target
                failedSelection = nil
                activeModelLabel = target.label
                modelState = .loaded
                readinessStage = .ready
                loadingProgress = ""
                downloadFraction = nil
                loadID = nil
                readinessChanged(true, nil)
                cachedModelBytes = await runtime.cachedBytes()
                policy.release()
                if target != policy.effectiveSelection { continue }
                return
            } catch {
                loadID = nil
                await runtime.unload()
                activeSelection = nil
                activeModelLabel = nil
                downloadFraction = nil
                loadingProgress = ""
                readinessChanged(false, nil)
                if error is CancellationError || !wantsModelLoaded {
                    modelState = .unloaded
                    readinessStage = .unloaded
                    policy.release()
                    return
                }
                // A failure for a superseded choice must not poison the newest
                // selection. Retry only that new choice, never an endless loop.
                if target != policy.effectiveSelection {
                    policy.release()
                    continue
                }
                failedSelection = target
                modelState = .error(Self.modelErrorMessage(error))
                readinessStage = .failed
                cachedModelBytes = await runtime.cachedBytes()
                policy.release()
                if target != policy.effectiveSelection { continue }
                return
            }
        }
    }

    private func report(_ progress: ModelRuntimeProgress, for target: ModelSelection) {
        readinessStage = progress.stage
        downloadFraction = progress.fraction.map { min(1, max(0, $0)) }
        let suffix = downloadFraction.map { " \(Int($0 * 100))%" } ?? ""
        loadingProgress = "\(target.label): \(progress.stage.title.lowercased())\(suffix)…"
        readinessChanged(false, loadingProgress)
    }

    /// Wait for the SDK to return and for all capture leases to end before
    /// releasing resources. Cancellation can abandon the wait, never its model.
    func unloadModel() async {
        wantsModelLoaded = false
        loadTask?.cancel()
        await loadTask?.value
        do {
            while policy.captureCount > 0 {
                try await Task.sleep(for: .milliseconds(40))
            }
            try await acquire(.maintenance)
        } catch { return }
        defer { policy.release() }
        await runtime.unload()
        activeSelection = nil
        failedSelection = nil
        activeModelLabel = nil
        loadID = nil
        modelState = .unloaded
        readinessStage = .unloaded
        loadingProgress = ""
        downloadFraction = nil
        readinessChanged(false, nil)
        // An explicit new load request arriving during unload is honored later.
        if wantsModelLoaded { Task { [weak self] in self?.startLoadingIfNeeded() } }
    }

    func transcribe(audioURL: URL, languageCode: String?) async throws -> String {
        try Task.checkCancellation()
        beginCapture()
        policy.addFinalWaiter()
        defer {
            policy.removeFinalWaiter()
            endCapture()
        }
        failedSelection = nil
        while true {
            wantsModelLoaded = true
            startLoadingIfNeeded()
            // Task.value is not a cancellable wait. Poll only coordinator state;
            // cancellation returns while the shared SDK load finishes safely.
            while loadTask != nil {
                try await Task.sleep(for: .milliseconds(40))
            }
            try Task.checkCancellation()
            if case .error(let message) = modelState {
                throw TranscriptionError.transcriptionFailed(message)
            }
            // An unload already holding the gate can finish after this capture
            // starts. Recheck readiness after acquiring rather than decoding a
            // model that was released during the wait.
            guard modelState == .loaded, activeSelection == policy.effectiveSelection else { continue }
            try await acquire(.finalRecognition)
            if modelState == .loaded, activeSelection == policy.effectiveSelection { break }
            policy.release()
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            policy.release()
        }
        let result = try await runtime.transcribe(audioURL: audioURL, languageCode: languageCode, prompt: recognitionPrompt)
        try Task.checkCancellation()
        return result
    }

    /// Opportunistic only: never queues behind loading, final decoding, or any
    /// other preview. The coordinator cancels an active preview before final.
    func transcribePreview(audioURL: URL, languageCode: String?) async throws -> String? {
        try Task.checkCancellation()
        guard loadTask == nil, modelState == .loaded,
              activeSelection == policy.effectiveSelection,
              policy.acquire(.preview) else { return nil }
        beginCapture()
        isTranscribing = true
        defer {
            isTranscribing = false
            policy.release()
            endCapture()
        }
        let result = try await runtime.transcribe(audioURL: audioURL, languageCode: languageCode, prompt: recognitionPrompt)
        try Task.checkCancellation()
        return result
    }

    private var recognitionPrompt: String? {
        PersonalDictionary.recognitionPrompt(entries: PersonalDictionary.enabledEntries)
    }

    private static func modelErrorMessage(_ error: Error) -> String {
        let description = error.localizedDescription.lowercased()
        if description.contains("network") || description.contains("internet") || description.contains("offline") || description.contains("timed out") {
            return "Model download failed. Check your internet connection and try again. Downloaded models work offline."
        }
        return "Failed to load model: \(error.localizedDescription)"
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

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
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
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
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
