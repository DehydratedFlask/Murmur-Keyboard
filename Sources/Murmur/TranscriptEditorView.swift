import SwiftUI
import UIKit

struct TranscriptEditorView: View {
    let entry: TranscriptionEntry
    @ObservedObject var store: TranscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var wrongPhrase = ""
    @State private var rightPhrase = ""
    @State private var errorMessage: String?
    @State private var dictionaryMessage: String?
    @State private var isSaving = false
    @State private var showOriginal = false

    init(entry: TranscriptionEntry, store: TranscriptionStore) {
        self.entry = entry
        self.store = store
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcript") {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .accessibilityLabel("Edit transcription")
                    if let raw = entry.rawText {
                        Button("Restore original words") { text = raw }
                        DisclosureGroup("View original", isExpanded: $showOriginal) {
                            Text(raw).textSelection(.enabled)
                        }
                    } else {
                        Text("The original words were not stored for this older entry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let polished = entry.polishedText {
                        Button("Restore polished text") { text = polished }
                    }
                    ShareLink(item: text) { Label("Share text", systemImage: "square.and.arrow.up") }
                    Button("Copy text") { UIPasteboard.general.string = text }
                }

                Section {
                    if text != entry.text {
                        Button("Use my edit as a correction") { suggestCorrection() }
                    }
                    TextField("Murmur heard", text: $wrongPhrase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Use this spelling", text: $rightPhrase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Remember this correction") { rememberCorrection() }
                        .disabled(wrongPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rightPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let dictionaryMessage {
                        Text(dictionaryMessage).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Teach Murmur")
                } footer: {
                    Text("Saves a phrase and its mishearing in your personal dictionary. Corrections stay on this device and apply to future dictations.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Edit transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        isSaving = true
                        Task {
                            do {
                                try await store.updateText(for: entry, to: text)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                                isSaving = false
                            }
                        }
                    }
                    .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(isSaving || text != entry.text)
        }
    }

    private func rememberCorrection() {
        let wrong = wrongPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rightPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wrong.caseInsensitiveCompare(right) != .orderedSame else {
            dictionaryMessage = "Enter the misheard phrase and a different preferred spelling."
            return
        }
        guard right.count <= 80, wrong.count <= 80 else {
            dictionaryMessage = "Keep each phrase to 80 characters or fewer."
            return
        }
        var entries = PersonalDictionary.entries
        if let index = entries.firstIndex(where: { $0.phrase.caseInsensitiveCompare(right) == .orderedSame }) {
            guard entries[index].spokenAliases.count < 5 || entries[index].spokenAliases.contains(wrong) else {
                dictionaryMessage = "This word already has five aliases. Edit it in Vocabulary to replace one."
                return
            }
            entries[index].isEnabled = true
            entries[index].spokenAliases.append(wrong)
        } else {
            guard entries.count < 250 else {
                dictionaryMessage = "Your dictionary is full. Remove an entry in Vocabulary first."
                return
            }
            entries.append(PersonalDictionaryEntry(phrase: right, spokenAliases: [wrong]))
        }
        let saved = PersonalDictionary.save(entries)
        if saved.contains(where: { $0.phrase.caseInsensitiveCompare(right) == .orderedSame && $0.spokenAliases.contains(where: { $0.caseInsensitiveCompare(wrong) == .orderedSame }) }) {
            dictionaryMessage = "Saved. Murmur will use “\(right)” in future dictations."
        } else {
            dictionaryMessage = "The correction could not be saved. Check Vocabulary."
        }
    }

    private func suggestCorrection() {
        let before = entry.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let wrong = before[prefix..<(before.count - suffix)].joined(separator: " ")
        let right = after[prefix..<(after.count - suffix)].joined(separator: " ")
        guard !wrong.isEmpty, !right.isEmpty, wrong.count <= 80, right.count <= 80 else {
            dictionaryMessage = "Enter a short misheard phrase and its preferred spelling below."
            return
        }
        wrongPhrase = wrong
        rightPhrase = right
        dictionaryMessage = "Check these phrases, then tap Remember this correction."
    }
}
