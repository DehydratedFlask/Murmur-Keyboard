import Foundation

// MARK: - Model

struct TranscriptionEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let timestamp: Date
    let wordCount: Int

    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.wordCount = text.split { $0.isWhitespace }.count
    }
}

// MARK: - Store

@MainActor
final class TranscriptionStore: ObservableObject {

    @Published private(set) var entries: [TranscriptionEntry] = []
    @Published var lastError: Error?

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("transcriptions.json")
        load()
    }

    // MARK: - Public API

    func save(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        persist()
    }

    func delete(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        persist()
    }

    func fetchAll() -> [TranscriptionEntry] {
        entries.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Derived Stats

    var totalWordCount: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    /// Average words per minute: total words / total recording-equivalent minutes.
    /// We use a proxy of 30 WPM floor per entry if duration is unavailable.
    /// Since we don't store duration, we compute average WPM as
    /// totalWords / (count * assumedMinutesPerEntry) where we use 1 min.
    /// In practice a more useful stat is just totalWords / totalEntries * some factor.
    /// We'll estimate by assuming average speaking speed is ~130 wpm and back-calculate,
    /// or simply show (totalWordCount / max(entries.count, 1)) as words per session.
    /// For display purposes: show total wordCount / estimated minutes (wordCount/130).
    var avgWordsPerDictation: Int {
        guard !entries.isEmpty else { return 0 }
        return totalWordCount / entries.count
    }

    // MARK: - Persistence

    private func load() {
        let url = fileURL
        Task {
            do {
                let decoded = try await Task.detached {
                    guard FileManager.default.fileExists(atPath: url.path) else { return [TranscriptionEntry]() }
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode([TranscriptionEntry].self, from: data)
                }.value
                if !decoded.isEmpty {
                    entries = decoded.sorted { $0.timestamp > $1.timestamp }
                }
            } catch {
                print("[TranscriptionStore] Failed to load transcriptions: \(error)")
                // Keep existing entries rather than resetting to []
            }
        }
    }

    private func persist() {
        let entriesToSave = entries
        let url = fileURL
        Task {
            do {
                try await Task.detached {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(entriesToSave)
                    try data.write(to: url, options: .atomicWrite)
                }.value
            } catch {
                print("[TranscriptionStore] Failed to persist transcriptions: \(error)")
                self.lastError = error
            }
        }
    }
}
