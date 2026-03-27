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

    /// Whether the initial load from disk has completed.
    private(set) var isLoaded = false

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("transcriptions.json")
        load()
    }

    // MARK: - Public API

    func save(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        if isLoaded {
            persist()
        }
    }

    func delete(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        if isLoaded {
            persist()
        }
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        if isLoaded {
            persist()
        }
    }

    func fetchAll() -> [TranscriptionEntry] {
        entries.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Derived Stats

    var totalWordCount: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    /// Average words per dictation session.
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

                // Merge: keep any entries created in-memory before load finished
                let inMemoryIDs = Set(entries.map { $0.id })
                let diskOnly = decoded.filter { !inMemoryIDs.contains($0.id) }
                let merged = (entries + diskOnly).sorted { $0.timestamp > $1.timestamp }
                entries = merged
                isLoaded = true
                persist()
            } catch {
                print("[TranscriptionStore] Failed to load transcriptions: \(error)")
                isLoaded = true
            }
        }
    }

    private func persist() {
        saveTask?.cancel()
        let entriesToSave = entries
        let url = fileURL
        saveTask = Task {
            do {
                try await Task.detached {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(entriesToSave)
                    try data.write(to: url, options: .atomicWrite)
                }.value
            } catch {
                if !(error is CancellationError) {
                    print("[TranscriptionStore] Failed to persist transcriptions: \(error)")
                    self.lastError = error
                }
            }
        }
    }
}
