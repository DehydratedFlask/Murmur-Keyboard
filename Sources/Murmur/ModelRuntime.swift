import Foundation
@preconcurrency import WhisperKit
import FluidAudio

actor NativeModelRuntime: ModelRuntimeBackend {
    private var whisperKit: WhisperKit?
    private var parakeet: AsrManager?

    func load(_ selection: ModelSelection, progress: @escaping @Sendable (ModelRuntimeProgress) -> Void) async throws {
        // The scheduler has already unloaded the previous engine; this check also
        // makes accidental backend misuse fail without overlapping engines.
        guard whisperKit == nil, parakeet == nil else {
            throw TranscriptionError.transcriptionFailed("A model operation is already active.")
        }
        try Task.checkCancellation()
        progress(.init(stage: .checkingCache))
        switch selection.engine {
        case .whisper:
            let root = Self.whisperCacheRoot
            let folder: URL
            if let cached = Self.cachedWhisperFolder(for: selection.whisperModel) {
                folder = cached
            } else {
                progress(.init(stage: .downloading))
                folder = try await WhisperKit.download(
                    variant: selection.whisperModel.whisperKitName,
                    downloadBase: root,
                    progressCallback: { update in
                        let fraction = update.totalUnitCount > 0 ? update.fractionCompleted : nil
                        progress(.init(stage: .downloading, fraction: fraction))
                    }
                )
                UserDefaults.standard.set(folder.path, forKey: Self.folderKey(selection.whisperModel))
            }
            try Task.checkCancellation()
            progress(.init(stage: .compiling))
            // A modelFolder bypasses WhisperKit's remote filename resolution.
            // Supplying the tokenizer cache explicitly also permits offline warm
            // startup once both weights and tokenizer have been downloaded.
            let tokenizerFolder = Self.cachedTokenizerFolder(for: selection.whisperModel) ?? root
            let kit = try await WhisperKit(WhisperKitConfig(
                model: selection.whisperModel.whisperKitName,
                downloadBase: root,
                modelFolder: folder.path,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: false,
                download: false
            ))
            do {
                try Task.checkCancellation()
                progress(.init(stage: .loading))
                try await kit.loadModels()
                try Task.checkCancellation()
            } catch {
                await kit.unloadModels()
                throw error
            }
            whisperKit = kit
        case .parakeet:
            let cache = AsrModels.defaultCacheDirectory(for: .v3)
            let models: AsrModels
            if AsrModels.modelsExist(at: cache, version: .v3) {
                progress(.init(stage: .loading))
                models = try await AsrModels.load(from: cache, version: .v3)
            } else {
                progress(.init(stage: .downloading))
                models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { update in
                    let stage: ModelReadinessStage
                    switch update.phase {
                    case .listing, .downloading: stage = .downloading
                    case .compiling: stage = .compiling
                    }
                    progress(.init(stage: stage, fraction: stage == .downloading ? update.fractionCompleted : nil))
                })
            }
            try Task.checkCancellation()
            progress(.init(stage: .loading))
            let manager = AsrManager(config: .default)
            do {
                try await manager.loadModels(models)
                try Task.checkCancellation()
            } catch {
                await manager.cleanup()
                throw error
            }
            parakeet = manager
        }
    }

    func unload() async {
        // Never called while recognition is running, including cancelled SDK
        // work that has not returned yet. No arbitrary timeout frees weights.
        if let kit = whisperKit { await kit.unloadModels() }
        whisperKit = nil
        if let manager = parakeet { await manager.cleanup() }
        parakeet = nil
    }

    func transcribe(audioURL: URL, languageCode: String?, prompt: String?) async throws -> String {
        try Task.checkCancellation()
        if let manager = parakeet {
            var decoderState = try TdtDecoderState()
            let language = languageCode.flatMap { Language(rawValue: $0) }
            let result = try await manager.transcribe(audioURL, decoderState: &decoderState, language: language)
            try Task.checkCancellation()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let promptTokens = prompt.flatMap { text in
            whisperKit.tokenizer.map { Array($0.encode(text: text).suffix(200)) }
        }
        let language = languageCode
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
            audioPath: audioURL.path,
            decodeOptions: options
        )

        let fullText = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try Task.checkCancellation()
        return fullText
    }

    func cachedBytes() async -> Int64 { measureCachedBytes() }

    private func measureCachedBytes() -> Int64 {
        let directories = [Self.whisperCacheRoot, AsrModels.defaultCacheDirectory(for: .v3)]
            + WhisperModel.allCases.compactMap { Self.cachedWhisperFolder(for: $0) }
        var seen = Set<String>()
        var total: Int64 = 0
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                guard seen.insert(url.standardizedFileURL.path).inserted,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static var whisperCacheRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Murmur/Models/Whisper", isDirectory: true)
    }

    private static func folderKey(_ model: WhisperModel) -> String { "whisperModelFolder.\(model.rawValue)" }

    private static var cacheSearchRoots: [URL] {
        // The document root includes WhisperKit's previous default Hub cache.
        [whisperCacheRoot, URL.documentsDirectory, URL.cachesDirectory]
    }

    private static func cachedWhisperFolder(for model: WhisperModel) -> URL? {
        if let path = UserDefaults.standard.string(forKey: folderKey(model)) {
            let folder = URL(fileURLWithPath: path)
            if containsWhisperWeights(folder) { return folder }
        }
        for root in cacheSearchRoots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let folder as URL in enumerator {
                let name = folder.lastPathComponent
                // Exclude English-only and compressed variants, preserving the
                // exact multilingual Tiny/Base choice used by existing installs.
                if name == model.whisperKitName, containsWhisperWeights(folder) {
                    UserDefaults.standard.set(folder.path, forKey: folderKey(model))
                    return folder
                }
                if folder.pathExtension == "mlmodelc" { enumerator.skipDescendants() }
            }
        }
        return nil
    }

    private static func containsWhisperWeights(_ folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
            }
        }
    }

    private static func cachedTokenizerFolder(for model: WhisperModel) -> URL? {
        for root in cacheSearchRoots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "whisper-\(model.rawValue)",
                   FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path),
                   FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer_config.json").path) {
                    return url
                }
                if url.pathExtension == "mlmodelc" { enumerator.skipDescendants() }
            }
        }
        return nil
    }
}

@MainActor
extension TranscriptionService {
    convenience init() {
        self.init(runtime: NativeModelRuntime()) { ready, progress in
            SharedDefaults.setModelReady(ready, progressText: progress)
        }
    }
}
