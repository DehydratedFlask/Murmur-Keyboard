import Foundation
import Combine

// MARK: - Model

struct TranscriptionEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    /// Recognition output before cleanup. Older entries have no original.
    let rawText: String?
    let polishedText: String?
    let timestamp: Date
    let wordCount: Int

    init(id: UUID = UUID(), text: String, timestamp: Date = Date(), rawText: String? = nil, polishedText: String? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.rawText = rawText
        self.polishedText = polishedText
        self.wordCount = text.split { $0.isWhitespace }.count
    }
}

// MARK: - Store

@MainActor
final class TranscriptionStore: ObservableObject {

    @Published private(set) var entries: [TranscriptionEntry] = []
    @Published var lastError: Error?
    private(set) var totalWordCount = 0

    /// Whether the initial load from disk has completed.
    private(set) var isLoaded = false

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var saveGeneration: UInt = 0
    private var loadTask: Task<Void, Never>?
    private var loadFailure: Error?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("transcriptions.json")
        load()
    }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: - Public API

    func save(_ entry: TranscriptionEntry) {
        if let previous = entries.first(where: { $0.id == entry.id }) {
            entries.removeAll { $0.id == entry.id }
            totalWordCount -= previous.wordCount
        }
        entries.insert(entry, at: 0)
        entries.sort { $0.timestamp > $1.timestamp }
        totalWordCount += entry.wordCount
        if isLoaded {
            persist()
        }
    }

    /// Recovery audio is removed only after this completes successfully.
    func saveDurably(_ entry: TranscriptionEntry) async throws {
        await loadTask?.value
        if let loadFailure { throw loadFailure }
        save(entry)
        // Another history action can supersede the write while we await it.
        // Join the latest generation before declaring recovery audio disposable.
        var generation: UInt
        repeat {
            generation = saveGeneration
            await saveTask?.value
        } while generation != saveGeneration
        if let lastError { throw lastError }
    }

    func updateText(for entry: TranscriptionEntry, to text: String) async throws {
        let updated = TranscriptionEntry(
            id: entry.id, text: text, timestamp: entry.timestamp,
            rawText: entry.rawText, polishedText: entry.polishedText
        )
        try await saveDurably(updated)
        if let pending = SharedDefaults.peekPendingTextPayload(), pending.entryID == entry.id.uuidString {
            SharedDefaults.setPendingText(text, sessionID: pending.sessionID, entryID: pending.entryID)
        }
    }

    func delete(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        totalWordCount = max(0, totalWordCount - entry.wordCount)
        if isLoaded {
            persist()
        }
    }

    func delete(at offsets: IndexSet) {
        let removedWordCount = offsets.reduce(into: 0) { total, index in
            guard entries.indices.contains(index) else { return }
            total += entries[index].wordCount
        }
        entries.remove(atOffsets: offsets)
        totalWordCount = max(0, totalWordCount - removedWordCount)
        if isLoaded {
            persist()
        }
    }

    /// Removes every transcription. Lifetime word totals are cleared with the
    /// history, which is what the "Delete all history" action promises.
    func deleteAll() {
        entries = []
        totalWordCount = 0
        if isLoaded {
            persist()
        }
    }

    /// Drops entries older than the retention window the user picked.
    func applyRetentionPolicy() {
        let days = MurmurPreferences.historyRetention.days
        guard days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return
        }
        let kept = entries.filter { $0.timestamp >= cutoff }
        guard kept.count != entries.count else { return }
        entries = kept
        totalWordCount = kept.reduce(0) { $0 + $1.wordCount }
        if isLoaded {
            persist()
        }
    }

    // MARK: - Derived Stats

    /// Average words per dictation session.
    var avgWordsPerDictation: Int {
        guard !entries.isEmpty else { return 0 }
        return totalWordCount / entries.count
    }

    // MARK: - Persistence

    private func load() {
        let url = fileURL
        let task = Task {
            do {
                let loadResult = try await Task.detached {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return [TranscriptionEntry]()
                    }
                    let data = try Data(contentsOf: url)
                    let decoded = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
                    // History is user-authored data. Never run cleanup over stored
                    // text on load: edits and restored originals must survive relaunch.
                    return decoded
                }.value

                guard !Task.isCancelled else { return }

                // Merge: keep any entries created in-memory before load finished
                let hasNewInMemoryEntries = !entries.isEmpty
                let inMemoryIDs = Set(entries.map { $0.id })
                let diskOnly = loadResult.filter { !inMemoryIDs.contains($0.id) }
                let merged = (entries + diskOnly).sorted { $0.timestamp > $1.timestamp }
                entries = merged
                totalWordCount = merged.reduce(0) { $0 + $1.wordCount }
                isLoaded = true
                lastError = nil
                applyRetentionPolicy()
                if hasNewInMemoryEntries {
                    persist()
                }
            } catch is CancellationError {
                // Task was cancelled — bail out silently
                ()
            } catch {
                print("[TranscriptionStore] Failed to load transcriptions: \(error)")
                isLoaded = true
                loadFailure = error
                lastError = error
            }
        }
        loadTask = task
    }

    private func persist() {
        saveTask?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        let entriesToSave = entries
        let url = fileURL
        saveTask = Task {
            do {
                let tempURL = try await Task.detached {
                    guard !Task.isCancelled else { throw CancellationError() }
                    let data = try JSONEncoder().encode(entriesToSave)
                    guard !Task.isCancelled else { throw CancellationError() }
                    let tempURL = url
                        .deletingLastPathComponent()
                        .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(generation)")
                        .appendingPathExtension(url.pathExtension)
                    try data.write(to: tempURL, options: .atomicWrite)
                    return tempURL
                }.value

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                guard generation == saveGeneration else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: url)
                }
                lastError = nil
            } catch {
                if !(error is CancellationError) {
                    print("[TranscriptionStore] Failed to persist transcriptions: \(error)")
                    self.lastError = error
                }
            }
        }
    }
}



// MARK: - Preferences

/// Small UserDefaults-backed preferences shared by the settings screens and
/// the transcription pipeline.
enum MurmurPreferences {

    static let autoDetectLanguageKey = "dictationAutoDetectLanguage"
    static let selectedLanguagesKey = "dictationSelectedLanguages"
    static let sessionDurationKey = "dictationSessionDuration"
    static let historyRetentionKey = "historyRetentionDays"
    static let aiCleanupKey = "aiCleanupEnabled"

    /// Whether transcripts are polished by Apple's on-device model when it is
    /// available, instead of the deterministic cleanup alone.
    static var aiCleanupEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: aiCleanupKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: aiCleanupKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: aiCleanupKey) }
    }

    static var autoDetectLanguage: Bool {
        get { SharedDefaults.autoDetectLanguage }
        set { SharedDefaults.autoDetectLanguage = newValue }
    }

    static var selectedLanguageCodes: [String] {
        get { SharedDefaults.selectedLanguages }
        set { SharedDefaults.selectedLanguages = newValue }
    }

    static var sessionDuration: DictationSessionDuration {
        get {
            UserDefaults.standard.string(forKey: sessionDurationKey)
                .flatMap(DictationSessionDuration.init(rawValue:)) ?? .fiveMinutes
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sessionDurationKey)
            SharedDefaults.setDictationSessionDurationMinutes(max(1, newValue.minutes))
        }
    }

    static var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: UserDefaults.standard.integer(forKey: historyRetentionKey)) ?? .forever }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: historyRetentionKey) }
    }

    /// The language code handed to Whisper, or nil when auto-detect should run.
    static var primaryLanguageCode: String? {
        if autoDetectLanguage { return nil }
        return selectedLanguageCodes.first
    }

    static let formattingSurfaceKey = "formattingSurface"

    /// How dictated text is shaped. `.automatic` follows the field the keyboard
    /// was in; any other value is the user's explicit choice.
    static var formattingSurface: DictationSurface {
        get { DictationSurface(rawValue: SharedDefaults.formattingStyle) ?? .automatic }
        set { SharedDefaults.formattingStyle = newValue.rawValue }
    }

    static var silenceMode: RecordingSilenceMode {
        get { UserDefaults.standard.string(forKey: "recordingSilenceMode").flatMap(RecordingSilenceMode.init(rawValue:)) ?? .thinkingTime }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recordingSilenceMode") }
    }

    static var livePreviewEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "livePreviewEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "livePreviewEnabled") }
    }

}

// MARK: - Session duration

enum DictationSessionDuration: String, CaseIterable, Identifiable {
    case immediate
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    var id: String { rawValue }

    /// Minutes the microphone session stays ready between dictations.
    var minutes: Int {
        switch self {
        case .immediate: return 0
        case .fiveMinutes: return 5
        case .fifteenMinutes: return 15
        case .oneHour: return 60
        }
    }

    var title: String {
        switch self {
        case .immediate: return "Immediate"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        }
    }

    var detail: String {
        switch self {
        case .immediate: return "Ends as soon as you finish speaking"
        case .fiveMinutes: return "Stays ready for 5 minutes between dictations"
        case .fifteenMinutes: return "Stays ready for 15 minutes between dictations"
        case .oneHour: return "Stays ready for 1 hour between dictations"
        }
    }

    var symbolName: String {
        switch self {
        case .immediate: return "bolt"
        case .fiveMinutes, .fifteenMinutes, .oneHour: return "clock"
        }
    }
}

// MARK: - History retention

enum HistoryRetention: Int, CaseIterable, Identifiable {
    case forever = 0
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14

    var id: Int { rawValue }

    var days: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return "Forever"
        case .oneDay: return "1 day"
        case .sevenDays: return "7 days"
        case .fourteenDays: return "14 days"
        }
    }
}

// MARK: - Snippets

struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var trigger: String
    var expansion: String
}

/// User-defined trigger → expansion pairs applied after a dictation is
/// cleaned up, so "omw" can arrive as "On my way!".
@MainActor
final class SnippetStore: ObservableObject {

    @Published private(set) var snippets: [Snippet] = []

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("snippets.json")
        load()
    }

    func add(trigger: String, expansion: String) {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else { return }
        guard !snippets.contains(where: { $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame }) else {
            return
        }
        snippets.append(Snippet(trigger: trimmedTrigger, expansion: trimmedExpansion))
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    /// Expands every trigger found as a whole word, case-insensitively.
    nonisolated static func apply(_ snippets: [Snippet], to text: String) -> String {
        guard !snippets.isEmpty else { return text }
        var result = text
        for snippet in snippets {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: snippet.trigger) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
            )
        }
        return result
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else {
            return
        }
        snippets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomicWrite)
    }
}

// MARK: - Languages

struct DictationLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let flag: String

    var id: String { code }

    static let all: [DictationLanguage] = [
        DictationLanguage(code: "en", name: "English", flag: "🇺🇸"),
        DictationLanguage(code: "es", name: "Spanish", flag: "🇪🇸"),
        DictationLanguage(code: "fr", name: "French", flag: "🇫🇷"),
        DictationLanguage(code: "de", name: "German", flag: "🇩🇪"),
        DictationLanguage(code: "it", name: "Italian", flag: "🇮🇹"),
        DictationLanguage(code: "pt", name: "Portuguese", flag: "🇵🇹"),
        DictationLanguage(code: "nl", name: "Dutch", flag: "🇳🇱"),
        DictationLanguage(code: "pl", name: "Polish", flag: "🇵🇱"),
        DictationLanguage(code: "ru", name: "Russian", flag: "🇷🇺"),
        DictationLanguage(code: "uk", name: "Ukrainian", flag: "🇺🇦"),
        DictationLanguage(code: "tr", name: "Turkish", flag: "🇹🇷"),
        DictationLanguage(code: "sv", name: "Swedish", flag: "🇸🇪"),
        DictationLanguage(code: "no", name: "Norwegian", flag: "🇳🇴"),
        DictationLanguage(code: "da", name: "Danish", flag: "🇩🇰"),
        DictationLanguage(code: "fi", name: "Finnish", flag: "🇫🇮"),
        DictationLanguage(code: "cs", name: "Czech", flag: "🇨🇿"),
        DictationLanguage(code: "sk", name: "Slovak", flag: "🇸🇰"),
        DictationLanguage(code: "sl", name: "Slovenian", flag: "🇸🇮"),
        DictationLanguage(code: "hr", name: "Croatian", flag: "🇭🇷"),
        DictationLanguage(code: "ro", name: "Romanian", flag: "🇷🇴"),
        DictationLanguage(code: "hu", name: "Hungarian", flag: "🇭🇺"),
        DictationLanguage(code: "el", name: "Greek", flag: "🇬🇷"),
        DictationLanguage(code: "bg", name: "Bulgarian", flag: "🇧🇬"),
        DictationLanguage(code: "et", name: "Estonian", flag: "🇪🇪"),
        DictationLanguage(code: "lv", name: "Latvian", flag: "🇱🇻"),
        DictationLanguage(code: "lt", name: "Lithuanian", flag: "🇱🇹"),
        DictationLanguage(code: "mt", name: "Maltese", flag: "🇲🇹"),
        DictationLanguage(code: "ja", name: "Japanese", flag: "🇯🇵"),
        DictationLanguage(code: "zh", name: "Chinese", flag: "🇨🇳"),
        DictationLanguage(code: "ko", name: "Korean", flag: "🇰🇷"),
        DictationLanguage(code: "hi", name: "Hindi", flag: "🇮🇳"),
        DictationLanguage(code: "ar", name: "Arabic", flag: "🇸🇦"),
        DictationLanguage(code: "he", name: "Hebrew", flag: "🇮🇱"),
        DictationLanguage(code: "id", name: "Indonesian", flag: "🇮🇩"),
        DictationLanguage(code: "vi", name: "Vietnamese", flag: "🇻🇳"),
        DictationLanguage(code: "th", name: "Thai", flag: "🇹🇭"),
    ]

    static func named(_ code: String) -> DictationLanguage? {
        all.first { $0.code == code }
    }

    /// Parakeet v3 covers 25 European languages; Whisper covers the rest.
    var isParakeetSupported: Bool {
        ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk", "tr",
         "sv", "no", "da", "fi", "cs", "sk", "sl", "hr", "ro", "hu", "el",
         "bg", "et", "lv", "lt", "mt"].contains(code)
    }
}

// Separate from the warm microphone session duration between dictations.
enum RecordingSilenceMode: String, CaseIterable, Identifiable {
    case quickMessage, thinkingTime, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quickMessage: return "Quick message"
        case .thinkingTime: return "Thinking time"
        case .manual: return "Stop manually"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .quickMessage: return 2
        case .thinkingTime: return 10
        case .manual: return nil
        }
    }
}
