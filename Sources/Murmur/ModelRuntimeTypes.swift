import Foundation

struct ModelSelection: Equatable, Sendable {
    let engine: TranscriptionEngine
    let whisperModel: WhisperModel

    var label: String {
        engine == .whisper ? "Whisper \(whisperModel == .tiny ? "Tiny" : "Base")" : "Parakeet"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine == rhs.engine && (lhs.engine == .parakeet || lhs.whisperModel == rhs.whisperModel)
    }
}

enum ModelReadinessStage: String, Sendable {
    case unloaded, checkingCache, downloading, compiling, loading, ready, failed

    var title: String {
        switch self {
        case .unloaded: return "Not loaded"
        case .checkingCache: return "Checking downloaded model"
        case .downloading: return "Downloading model"
        case .compiling: return "Preparing model for this device"
        case .loading: return "Loading model"
        case .ready: return "Ready on device"
        case .failed: return "Model unavailable"
        }
    }
}

struct ModelRuntimeProgress: Sendable {
    let stage: ModelReadinessStage
    var fraction: Double? = nil
}

/// The service is the sole scheduler; the backend is the sole SDK resource owner.
/// Every SDK call completes before the scheduler admits another operation. In
/// particular an actor suspension never permits a second load or decode.
protocol ModelRuntimeBackend: Sendable {
    func load(_ selection: ModelSelection, progress: @escaping @Sendable (ModelRuntimeProgress) -> Void) async throws
    func unload() async
    func transcribe(audioURL: URL, languageCode: String?, prompt: String?) async throws -> String
    func cachedBytes() async -> Int64
}
