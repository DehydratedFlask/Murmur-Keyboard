import Foundation

/// Bounded, deterministic typing policy. No platform spell checker or I/O.
struct KeyboardTypingPolicy {
    static let maximumVocabularyEntries = 256
    static let maximumWordLength = 24

    private var vocabulary: [String: String] = [:]
    private var protectedWords: Set<String> = []

    /// Prepare outside touch delivery. First entry wins, so duplicate aliases
    /// have a stable result, and contacts / user spellings remain authoritative.
    init(vocabulary entries: [(input: String, replacement: String)] = []) {
        for entry in entries.prefix(Self.maximumVocabularyEntries) {
            guard Self.isWord(entry.input), Self.isWord(entry.replacement) else { continue }
            let key = entry.input.lowercased()
            if vocabulary[key] == nil { vocabulary[key] = entry.replacement }
            protectedWords.insert(entry.replacement.lowercased())
        }
    }

    func correction(for word: String) -> String? {
        guard Self.isWord(word) else { return nil }
        let lower = word.lowercased()
        guard !protectedWords.contains(lower) else { return nil }
        if let replacement = vocabulary[lower], replacement != word {
            return Self.applyCase(of: word, to: replacement)
        }
        if lower == "i" { return word == "I" ? nil : "I" }
        // Preserve camelCase, names and non-ASCII words. There is deliberately
        // no guessed correction for words absent from the prepared mapping.
        guard word.unicodeScalars.allSatisfy(\.isASCII),
              word == word.uppercased() || !word.dropFirst().contains(where: \.isUppercase),
              let replacement = Self.knownCorrections[lower]
        else { return nil }
        return Self.applyCase(of: word, to: replacement)
    }

    static func trailingWord(in context: String) -> String? {
        // A long token is never corrected; scan at most one more than the cap.
        let letters = context.reversed().prefix(maximumWordLength + 1)
            .prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard !letters.isEmpty, letters.count <= maximumWordLength else { return nil }
        return String(letters.reversed())
    }

    private static func isWord(_ word: String) -> Bool {
        !word.isEmpty && word.prefix(maximumWordLength + 1).count <= maximumWordLength &&
            word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
    }

    private static func applyCase(of source: String, to replacement: String) -> String {
        if source.count > 1, source == source.uppercased() { return replacement.uppercased() }
        guard source.first?.isUppercase == true else { return replacement }
        return replacement.prefix(1).uppercased() + String(replacement.dropFirst())
    }

    private static let knownCorrections: [String: String] = [
        "teh": "the", "hte": "the", "thsi": "this", "tihs": "this",
        "thta": "that", "adn": "and", "nad": "and",
        "jsut": "just", "juts": "just", "waht": "what", "taht": "that",
        "yuo": "you", "yuor": "your",
        "thier": "their", "recieve": "receive",
        "seperate": "separate", "definately": "definitely",
        "occured": "occurred", "untill": "until", "wich": "which",
        "becuase": "because", "beacuse": "because", "alot": "a lot",
        "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't",
        "arent": "aren't", "wasnt": "wasn't", "werent": "weren't",
        "didnt": "didn't", "doesnt": "doesn't", "hadnt": "hadn't",
        "hasnt": "hasn't", "havent": "haven't", "couldnt": "couldn't",
        "wouldnt": "wouldn't", "shouldnt": "shouldn't", "mustnt": "mustn't",
        "ive": "I've", "youre": "you're", "youve": "you've",
        "youll": "you'll", "theyre": "they're", "theyve": "they've",
        "theyll": "they'll", "weve": "we've", "thats": "that's",
        "whats": "what's",
    ]

}

/// Only the latest insertion can be retracted. Overlapping keys must never
/// remove another press's text, even when both keys typed the same character.
struct KeyboardPressCommit: Equatable {
    let token: UUID
    let text: String
    let documentID: UUID

    func canRetract(token: UUID, documentID: UUID, context: String) -> Bool {
        self.token == token && self.documentID == documentID && context.hasSuffix(text)
    }
}

/// Context is held only in memory to validate a delayed candidate; never logged.
struct KeyboardSuggestionContext: Equatable {
    let before: String?
    let after: String?
    let documentID: UUID
    var selectedText: String? = nil
}
