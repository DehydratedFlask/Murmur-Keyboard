import Foundation

/// Cleans up raw transcription output by removing filler words and
/// normalizing whitespace and capitalization.
struct TextProcessor {

    // MARK: - Filler Words

    /// Default set of filler words and phrases to remove.
    /// NOTE: Only includes unambiguous fillers. Words like "like", "so", "right",
    /// "well", "actually", "literally" are omitted because they are frequently
    /// used as legitimate words in normal speech. If false positives are observed,
    /// further trim this list.
    static let defaultFillerWords: [String] = [
        "um", "uh", "erm", "er", "umm", "uhh",
        "you know",
        "i mean",
        "kind of", "kinda",
        "sort of", "sorta",
        "okay so",
        "yeah so",
    ]

    /// Regex compilation is relatively expensive compared with processing a
    /// short transcription. Cache the default expression once for the common
    /// path instead of rebuilding one expression per filler on every result.
    private static let defaultFillerRegex: NSRegularExpression? = {
        let alternatives = defaultFillerWords
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "\\b(?:\(alternatives))\\b",
            options: .caseInsensitive
        )
    }()

    // MARK: - Processing

    /// Processes raw transcription text: removes filler words and cleans formatting.
    /// - Parameters:
    ///   - text: Raw text from the transcription engine.
    ///   - fillerWords: Optional custom list of fillers. Defaults to `defaultFillerWords`.
    /// - Returns: Cleaned text ready for the user.
    static func process(_ text: String, fillerWords: [String]? = nil) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        var result = text

        if let fillerWords {
            // Custom lists are uncommon and remain dynamic.
            for filler in fillerWords.sorted(by: { $0.count > $1.count }) {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: ""
                    )
                }
            }
        } else if let regex = defaultFillerRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Clean up punctuation left dangling after filler removal
        result = collapseRepeatedPunctuation(result)

        // Collapse multiple spaces into one
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        // Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove leading comma or period
        while result.hasPrefix(",") || result.hasPrefix(".") {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Capitalize the first letter of each sentence
        result = capitalizeSentences(result)

        // Final trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    // MARK: - Helpers

    /// Capitalizes the first letter of each sentence.
    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = ""
        var capitalizeNext = true

        for char in text {
            if capitalizeNext && char.isLetter {
                result.append(char.uppercased())
                capitalizeNext = false
            } else {
                result.append(char)
            }

            if char == "." || char == "!" || char == "?" {
                capitalizeNext = true
            }
        }

        return result
    }

    /// Collapses repeated commas/periods caused by filler removal.
    private static func collapseRepeatedPunctuation(_ text: String) -> String {
        var result = text

        // ", ," or ",," → ","
        result = result.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)

        // ". ." or ".." → "."
        result = result.replacingOccurrences(of: "\\.\\s*\\.", with: ".", options: .regularExpression)

        // ",." → "."
        result = result.replacingOccurrences(of: ",\\s*\\.", with: ".", options: .regularExpression)

        // " ," → ","
        result = result.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)

        return result
    }
}
