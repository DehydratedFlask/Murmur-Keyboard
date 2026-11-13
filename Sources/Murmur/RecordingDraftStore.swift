import Foundation
import Combine

enum CaptureDestination: String, Codable, Sendable {
    case note, clipboard, keyboard
}

enum DictationCaptureError: LocalizedError {
    case noAudio, noSpeech
    var errorDescription: String? {
        switch self {
        case .noAudio: return "No readable audio was recorded. You can keep or discard this draft."
        case .noSpeech: return "No speech was detected. You can keep or discard this draft."
        }
    }
}

struct RecordingDraft: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let destination: CaptureDestination
    let surface: String
    let languageCode: String?
    let contextBefore: String?
    let contextAfter: String?
    var message: String
    var rawText: String?
}

/// One manifest per recording keeps an interrupted write isolated from other drafts.
/// The recorder writes directly here so iOS cannot purge the audio as temporary data.
@MainActor
final class RecordingDraftStore: ObservableObject {
    @Published private(set) var drafts: [RecordingDraft] = []
    @Published private(set) var lastError: String?
    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordingDrafts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for folder in folders {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                let manifest = folder.appendingPathComponent("draft.json")
                do {
                    let draft = try JSONDecoder().decode(RecordingDraft.self, from: Data(contentsOf: manifest))
                    guard draft.id == id else { continue }
                    drafts.append(draft)
                } catch {
                    // Even damaged metadata must not hide otherwise recoverable audio.
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.wav").path) {
                        drafts.append(RecordingDraft(
                            id: id, createdAt: Date(), destination: .note, surface: "general",
                            languageCode: nil, contextBefore: nil, contextAfter: nil,
                            message: "Recovered recording. Retry transcription or discard it."
                        ))
                    }
                    lastError = "Some draft details could not be loaded. Your recordings have been kept."
                }
            }
            drafts.sort { $0.createdAt > $1.createdAt }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func create(destination: CaptureDestination, surface: DictationSurface, languageCode: String?, before: String?, after: String?) throws -> RecordingDraft {
        let draft = RecordingDraft(
            id: UUID(), createdAt: Date(), destination: destination, surface: surface.rawValue,
            languageCode: languageCode, contextBefore: before, contextAfter: after,
            message: "Recording saved on this iPhone."
        )
        let folder = folderURL(for: draft)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(draft)
        drafts.insert(draft, at: 0)
        return draft
    }

    func audioURL(for draft: RecordingDraft) -> URL {
        folderURL(for: draft).appendingPathComponent("recording.wav")
    }

    @discardableResult
    func update(_ draft: RecordingDraft, message: String, rawText: String? = nil) throws -> RecordingDraft {
        var updated = draft
        updated.message = message
        if let rawText { updated.rawText = rawText }
        try write(updated)
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index] = updated }
        return updated
    }

    func discard(_ draft: RecordingDraft) throws {
        let folder = folderURL(for: draft)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        drafts.removeAll { $0.id == draft.id }
    }

    private func folderURL(for draft: RecordingDraft) -> URL {
        directory.appendingPathComponent(draft.id.uuidString, isDirectory: true)
    }

    private func write(_ draft: RecordingDraft) throws {
        let data = try JSONEncoder().encode(draft)
        try data.write(to: folderURL(for: draft).appendingPathComponent("draft.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
