import Foundation

// MARK: - Cloud Provider

/// Supported cloud speech-to-text providers.
enum CloudProvider: String, CaseIterable, Identifiable, Codable {
    case groq
    case openai
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .deepgram: return "Deepgram"
        }
    }

    /// Whether this provider is the recommended default.
    var isRecommended: Bool { self == .groq }

    /// URL where the user can sign up / get an API key.
    var apiKeyURL: URL {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        }
    }

    /// Short call-to-action text for the API key link.
    var apiKeyCTA: String {
        switch self {
        case .groq: return "Get a free Groq API key"
        case .openai: return "Get an OpenAI API key"
        case .deepgram: return "Get a Deepgram API key"
        }
    }

    /// Brief helper text shown below the provider picker.
    var apiKeyHelperText: String {
        switch self {
        case .groq:
            return "Groq offers free speech-to-text with fast processing. Create a free account to get your API key."
        case .openai:
            return "OpenAI's Whisper API is pay-per-use. Sign up and add billing to get an API key."
        case .deepgram:
            return "Deepgram offers a free tier with 200 hours. Sign up to get your API key."
        }
    }

    /// Keychain service key for storing this provider's API key.
    var keychainService: String {
        "com.murmur.apikey.\(rawValue)"
    }

    /// UserDefaults key for storing privacy disclosure acceptance.
    var disclosureAcceptedKey: String {
        "cloudDisclosureAccepted_\(rawValue)"
    }

    /// UserDefaults key for the user's selected model for this provider.
    var selectedModelKey: String {
        "cloudSelectedModel_\(rawValue)"
    }

    /// UserDefaults key for cached model list.
    var cachedModelsKey: String {
        "cloudCachedModels_\(rawValue)"
    }

    /// UserDefaults key for cache timestamp.
    var cachedModelsTimestampKey: String {
        "cloudCachedModelsTimestamp_\(rawValue)"
    }

    /// The transcription API endpoint URL.
    var transcriptionEndpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        case .openai:
            return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .deepgram:
            // Model is appended dynamically as a query parameter
            return URL(string: "https://api.deepgram.com/v1/listen")!
        }
    }

    /// The models list API endpoint (nil for providers without one).
    var modelsEndpoint: URL? {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/models")
        case .openai:
            return URL(string: "https://api.openai.com/v1/models")
        case .deepgram:
            return nil // No model list endpoint; use hardcoded list
        }
    }

    /// The preferred default model ID for this provider.
    var defaultModelID: String {
        switch self {
        case .groq: return "whisper-large-v3"
        case .openai: return "whisper-1"
        case .deepgram: return "nova-2"
        }
    }
}

// MARK: - Cloud Model

/// A model available from a cloud provider for audio transcription.
struct CloudModel: Identifiable, Codable, Equatable, Hashable {
    /// The model ID sent to the API (e.g. "whisper-large-v3").
    let id: String
    /// A human-readable display name.
    let displayName: String

    /// Whether this looks like an audio/whisper model based on ID.
    var isAudioModel: Bool {
        let lower = id.lowercased()
        return lower.contains("whisper") || lower.contains("audio")
    }
}

// MARK: - Connection Status

enum CloudConnectionStatus: Equatable {
    case notConfigured
    case connected
    case invalidKey
    case testing
    case error(String)

    var displayText: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .connected: return "Connected"
        case .invalidKey: return "Invalid key"
        case .testing: return "Testing…"
        case .error(let msg): return msg
        }
    }

    var symbolName: String {
        switch self {
        case .notConfigured: return "minus.circle"
        case .connected: return "checkmark.circle.fill"
        case .invalidKey: return "xmark.circle.fill"
        case .testing: return "arrow.trianglehead.2.clockwise"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var symbolColor: String {
        switch self {
        case .notConfigured: return "secondary"
        case .connected: return "green"
        case .invalidKey: return "red"
        case .testing: return "blue"
        case .error: return "orange"
        }
    }
}

// MARK: - Cloud Transcription Errors

enum CloudTranscriptionError: LocalizedError {
    case noAPIKey
    case invalidResponse(Int)
    case rateLimited
    case networkError(String)
    case decodingError(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured for the selected cloud provider."
        case .invalidResponse(let code):
            return "Server returned an error (HTTP \(code))."
        case .rateLimited:
            return "Rate limited. Please wait and try again."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .decodingError(let msg):
            return "Failed to parse response: \(msg)"
        case .unauthorized:
            return "Invalid API key. Please check your key in Settings."
        }
    }
}

// MARK: - Cloud Transcription Service

/// Handles sending audio to cloud providers for transcription.
/// This is a stateless utility — configuration lives in UserDefaults
/// and Keychain, read on demand.
enum CloudTranscriptionService {

    /// Whether cloud dictation is enabled by the user.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "cloudDictationEnabled")
    }

    /// The currently selected cloud provider.
    static var selectedProvider: CloudProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: "cloudProvider"),
               let provider = CloudProvider(rawValue: raw) {
                return provider
            }
            return .groq
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cloudProvider")
        }
    }

    /// Whether the user has accepted the privacy disclosure for a given provider.
    static func isDisclosureAccepted(for provider: CloudProvider) -> Bool {
        UserDefaults.standard.bool(forKey: provider.disclosureAcceptedKey)
    }

    /// Records that the user accepted the privacy disclosure for a provider.
    static func acceptDisclosure(for provider: CloudProvider) {
        UserDefaults.standard.set(true, forKey: provider.disclosureAcceptedKey)
    }

    /// Returns the stored API key for a provider, or nil.
    static func apiKey(for provider: CloudProvider) -> String? {
        KeychainHelper.load(service: provider.keychainService)
    }

    /// Saves an API key for a provider.
    @discardableResult
    static func setAPIKey(_ key: String, for provider: CloudProvider) -> Bool {
        if key.isEmpty {
            return KeychainHelper.delete(service: provider.keychainService)
        }
        return KeychainHelper.save(key, service: provider.keychainService)
    }

    /// Whether cloud transcription is fully ready (enabled + key configured).
    static var isReady: Bool {
        guard isEnabled else { return false }
        guard let key = apiKey(for: selectedProvider), !key.isEmpty else { return false }
        return true
    }

    // MARK: - Model Selection

    /// Returns the user-selected model ID for a provider, falling back to the provider default.
    static func selectedModel(for provider: CloudProvider) -> String {
        if let saved = UserDefaults.standard.string(forKey: provider.selectedModelKey), !saved.isEmpty {
            return saved
        }
        return provider.defaultModelID
    }

    /// Saves the user's model selection for a provider.
    static func setSelectedModel(_ modelID: String, for provider: CloudProvider) {
        UserDefaults.standard.set(modelID, forKey: provider.selectedModelKey)
    }

    // MARK: - Model List Caching

    /// How long cached model lists remain valid (24 hours).
    private static let modelCacheTTL: TimeInterval = 86400

    /// Returns cached models for a provider, or nil if cache is missing or stale.
    static func cachedModels(for provider: CloudProvider) -> [CloudModel]? {
        let ts = UserDefaults.standard.double(forKey: provider.cachedModelsTimestampKey)
        guard ts > 0, Date().timeIntervalSince1970 - ts < modelCacheTTL else {
            return nil
        }
        guard let data = UserDefaults.standard.data(forKey: provider.cachedModelsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([CloudModel].self, from: data)
    }

    /// Persists fetched models to the cache.
    private static func cacheModels(_ models: [CloudModel], for provider: CloudProvider) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: provider.cachedModelsKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: provider.cachedModelsTimestampKey)
        }
    }

    /// Clears the cached model list for a provider.
    static func clearModelCache(for provider: CloudProvider) {
        UserDefaults.standard.removeObject(forKey: provider.cachedModelsKey)
        UserDefaults.standard.removeObject(forKey: provider.cachedModelsTimestampKey)
    }

    // MARK: - Fetch Models

    /// Fetches the available audio/transcription models from the provider's API.
    /// For Deepgram (no list endpoint), returns a hardcoded set of known models.
    /// Results are cached automatically.
    static func fetchModels(for provider: CloudProvider) async throws -> [CloudModel] {
        switch provider {
        case .deepgram:
            let models = deepgramKnownModels()
            cacheModels(models, for: provider)
            return models
        case .groq, .openai:
            guard let endpoint = provider.modelsEndpoint else {
                return []
            }
            guard let key = apiKey(for: provider), !key.isEmpty else {
                throw CloudTranscriptionError.noAPIKey
            }
            let models = try await fetchOpenAICompatibleModels(endpoint: endpoint, apiKey: key, provider: provider)
            cacheModels(models, for: provider)
            return models
        }
    }

    /// Hardcoded Deepgram models. Easy to update — just add entries here.
    private static func deepgramKnownModels() -> [CloudModel] {
        [
            CloudModel(id: "nova-2", displayName: "Nova-2 (latest, most accurate)"),
            CloudModel(id: "nova-2-general", displayName: "Nova-2 General"),
            CloudModel(id: "nova-2-meeting", displayName: "Nova-2 Meeting"),
            CloudModel(id: "nova-2-phonecall", displayName: "Nova-2 Phone Call"),
            CloudModel(id: "nova-2-voicemail", displayName: "Nova-2 Voicemail"),
            CloudModel(id: "nova", displayName: "Nova (previous generation)"),
            CloudModel(id: "enhanced", displayName: "Enhanced"),
            CloudModel(id: "base", displayName: "Base"),
        ]
    }

    /// Fetches models from an OpenAI-compatible /v1/models endpoint and filters for audio models.
    private static func fetchOpenAICompatibleModels(
        endpoint: URL,
        apiKey: String,
        provider: CloudProvider
    ) async throws -> [CloudModel] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw CloudTranscriptionError.unauthorized
        case 429:
            throw CloudTranscriptionError.rateLimited
        default:
            throw CloudTranscriptionError.invalidResponse(httpResponse.statusCode)
        }

        struct ModelsResponse: Decodable {
            struct Model: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [Model]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)

        // Filter for audio/whisper models
        let audioModels = decoded.data
            .filter { model in
                let lower = model.id.lowercased()
                return lower.contains("whisper") || lower.contains("audio")
            }
            .map { model in
                CloudModel(id: model.id, displayName: formatModelName(model.id, provider: provider))
            }
            .sorted { lhs, rhs in
                // Sort: prefer the provider's default first, then by name
                if lhs.id == provider.defaultModelID { return true }
                if rhs.id == provider.defaultModelID { return false }
                return lhs.id < rhs.id
            }

        return audioModels
    }

    /// Makes a model ID human-readable.
    private static func formatModelName(_ id: String, provider: CloudProvider) -> String {
        // Turn "whisper-large-v3" → "Whisper Large V3"
        // Turn "whisper-1" → "Whisper 1"
        let parts = id.split(separator: "-").map { part in
            let s = String(part)
            // Keep version strings like "v3" as-is but capitalize first letter
            if s.count <= 3 {
                return s.uppercased()
            }
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Transcription

    /// Transcribes audio from a WAV file URL using the selected cloud provider.
    /// - Parameter audioURL: Path to a 16kHz mono WAV file.
    /// - Returns: Transcribed text.
    static func transcribe(audioURL: URL) async throws -> String {
        let provider = selectedProvider
        guard let key = apiKey(for: provider), !key.isEmpty else {
            throw CloudTranscriptionError.noAPIKey
        }

        let model = selectedModel(for: provider)
        let audioData = try Data(contentsOf: audioURL)

        switch provider {
        case .groq, .openai:
            return try await transcribeOpenAICompatible(
                endpoint: provider.transcriptionEndpoint,
                apiKey: key,
                model: model,
                audioData: audioData
            )
        case .deepgram:
            return try await transcribeDeepgram(
                endpoint: deepgramEndpoint(model: model),
                apiKey: key,
                audioData: audioData
            )
        }
    }

    /// Builds the Deepgram transcription URL with the selected model.
    private static func deepgramEndpoint(model: String) -> URL {
        var components = URLComponents(url: CloudProvider.deepgram.transcriptionEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        return components.url!
    }

    /// Tests the connection by sending a minimal audio payload.
    /// Also fetches and caches available models on success.
    /// Returns a tuple of (status, fetched models or nil).
    static func testConnection(for provider: CloudProvider) async -> (CloudConnectionStatus, [CloudModel]?) {
        guard let key = apiKey(for: provider), !key.isEmpty else {
            return (.notConfigured, nil)
        }

        let model = selectedModel(for: provider)

        // Generate a tiny 0.5-second silent WAV for the test
        let testAudio = generateSilentWAV(durationSeconds: 0.5, sampleRate: 16000)

        do {
            switch provider {
            case .groq, .openai:
                _ = try await transcribeOpenAICompatible(
                    endpoint: provider.transcriptionEndpoint,
                    apiKey: key,
                    model: model,
                    audioData: testAudio
                )
            case .deepgram:
                _ = try await transcribeDeepgram(
                    endpoint: deepgramEndpoint(model: model),
                    apiKey: key,
                    audioData: testAudio
                )
            }
        } catch let error as CloudTranscriptionError {
            switch error {
            case .unauthorized:
                return (.invalidKey, nil)
            case .rateLimited:
                break // Rate limited but the key IS valid — continue to fetch models
            default:
                return (.error(error.localizedDescription), nil)
            }
        } catch {
            return (.error(error.localizedDescription), nil)
        }

        // Connection verified — now fetch available models
        let models: [CloudModel]?
        do {
            models = try await fetchModels(for: provider)
        } catch {
            // Models fetch failed but connection itself worked
            models = nil
        }

        return (.connected, models)
    }

    // MARK: - OpenAI-Compatible (Groq, OpenAI)

    private static func transcribeOpenAICompatible(
        endpoint: URL,
        apiKey: String,
        model: String,
        audioData: Data
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()

        // Model field
        body.appendMultipartField(name: "model", value: model, boundary: boundary)

        // Audio file field
        body.appendMultipartFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData, boundary: boundary)

        // Response format
        body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)

        // Language hint
        body.appendMultipartField(name: "language", value: "en", boundary: boundary)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw CloudTranscriptionError.unauthorized
        case 429:
            throw CloudTranscriptionError.rateLimited
        default:
            throw CloudTranscriptionError.invalidResponse(httpResponse.statusCode)
        }

        // Parse JSON: { "text": "..." }
        struct WhisperResponse: Decodable {
            let text: String
        }

        do {
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CloudTranscriptionError.decodingError(
                String(data: data.prefix(200), encoding: .utf8) ?? "unreadable"
            )
        }
    }

    // MARK: - Deepgram

    private static func transcribeDeepgram(
        endpoint: URL,
        apiKey: String,
        audioData: Data
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = audioData

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw CloudTranscriptionError.unauthorized
        case 429:
            throw CloudTranscriptionError.rateLimited
        default:
            throw CloudTranscriptionError.invalidResponse(httpResponse.statusCode)
        }

        // Deepgram response structure:
        // { "results": { "channels": [{ "alternatives": [{ "transcript": "..." }] }] } }
        struct DeepgramResponse: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String
                    }
                    let alternatives: [Alternative]
                }
                let channels: [Channel]
            }
            let results: Results
        }

        do {
            let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            let transcript = decoded.results.channels
                .flatMap { $0.alternatives }
                .map { $0.transcript }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript
        } catch {
            throw CloudTranscriptionError.decodingError(
                String(data: data.prefix(200), encoding: .utf8) ?? "unreadable"
            )
        }
    }

    // MARK: - Networking

    private static func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw CloudTranscriptionError.networkError("No internet connection.")
            case .timedOut:
                throw CloudTranscriptionError.networkError("Request timed out.")
            default:
                throw CloudTranscriptionError.networkError(error.localizedDescription)
            }
        }
    }

    // MARK: - Test Audio Generator

    /// Generates a minimal silent WAV file in memory for connection testing.
    private static func generateSilentWAV(durationSeconds: Double, sampleRate: Int) -> Data {
        let numSamples = Int(durationSeconds * Double(sampleRate))
        let dataSize = numSamples * 2 // 16-bit samples
        let fileSize = 44 + dataSize  // WAV header is 44 bytes

        var wav = Data(capacity: fileSize)

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLittleEndian(UInt32(fileSize - 8))
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLittleEndian(UInt32(16))         // chunk size
        wav.appendLittleEndian(UInt16(1))          // PCM format
        wav.appendLittleEndian(UInt16(1))          // mono
        wav.appendLittleEndian(UInt32(sampleRate)) // sample rate
        wav.appendLittleEndian(UInt32(sampleRate * 2)) // byte rate
        wav.appendLittleEndian(UInt16(2))          // block align
        wav.appendLittleEndian(UInt16(16))         // bits per sample

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.appendLittleEndian(UInt32(dataSize))

        // Silent samples (all zeros)
        wav.append(Data(count: dataSize))

        return wav
    }
}

// MARK: - Data Extensions for Multipart

private extension Data {

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
