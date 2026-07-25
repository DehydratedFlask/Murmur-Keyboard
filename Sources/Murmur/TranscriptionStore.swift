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
    private(set) var totalWordCount = 0

    /// Whether the initial load from disk has completed.
    private(set) var isLoaded = false

    private let fileURL: URL
    private let preCleanupBackupURL: URL
    private var saveTask: Task<Void, Never>?
    private var saveGeneration: UInt = 0
    private var loadTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("transcriptions.json")
        preCleanupBackupURL = docs.appendingPathComponent("transcriptions-pre-cleanup.json")
        load()
    }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: - Public API

    func save(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        totalWordCount += entry.wordCount
        if isLoaded {
            persist()
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

    // MARK: - Derived Stats

    /// Average words per dictation session.
    var avgWordsPerDictation: Int {
        guard !entries.isEmpty else { return 0 }
        return totalWordCount / entries.count
    }

    // MARK: - Persistence

    private func load() {
        let url = fileURL
        let backupURL = preCleanupBackupURL
        let task = Task {
            do {
                let loadResult = try await Task.detached {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return (entries: [TranscriptionEntry](), migrated: false)
                    }
                    let data = try Data(contentsOf: url)
                    let decoded = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
                    let cleaned = decoded.compactMap { entry -> TranscriptionEntry? in
                        let cleanedText = TextProcessor.process(entry.text)
                        guard !cleanedText.isEmpty else { return nil }
                        guard cleanedText != entry.text else { return entry }
                        return TranscriptionEntry(
                            id: entry.id,
                            text: cleanedText,
                            timestamp: entry.timestamp
                        )
                    }
                    let migrated = cleaned.count != decoded.count
                        || zip(cleaned, decoded).contains { $0.text != $1.text || $0.id != $1.id }

                    // Preserve the original history once before upgrading it.
                    if migrated, !FileManager.default.fileExists(atPath: backupURL.path) {
                        try FileManager.default.copyItem(at: url, to: backupURL)
                    }
                    return (entries: cleaned, migrated: migrated)
                }.value

                guard !Task.isCancelled else { return }

                // Merge: keep any entries created in-memory before load finished
                let hasNewInMemoryEntries = !entries.isEmpty
                let inMemoryIDs = Set(entries.map { $0.id })
                let diskOnly = loadResult.entries.filter { !inMemoryIDs.contains($0.id) }
                let merged = (entries + diskOnly).sorted { $0.timestamp > $1.timestamp }
                entries = merged
                totalWordCount = merged.reduce(0) { $0 + $1.wordCount }
                isLoaded = true
                lastError = nil
                if hasNewInMemoryEntries || loadResult.migrated {
                    persist()
                }
            } catch is CancellationError {
                // Task was cancelled — bail out silently
                ()
            } catch {
                print("[TranscriptionStore] Failed to load transcriptions: \(error)")
                isLoaded = true
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
