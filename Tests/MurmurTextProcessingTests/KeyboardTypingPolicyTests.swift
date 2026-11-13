import XCTest
@testable import MurmurKeyboardTyping

final class KeyboardTypingPolicyTests: XCTestCase {
    func testKnownTyposAndContractionsPreserveCase() {
        let policy = KeyboardTypingPolicy()
        XCTAssertEqual(policy.correction(for: "teh"), "the")
        XCTAssertEqual(policy.correction(for: "Teh"), "The")
        XCTAssertEqual(policy.correction(for: "TEH"), "THE")
        XCTAssertEqual(policy.correction(for: "dont"), "don't")
        XCTAssertEqual(policy.correction(for: "ive"), "I've")
        XCTAssertEqual(policy.correction(for: "i"), "I")
        XCTAssertNil(policy.correction(for: "I"))
    }

    func testNoGuessedCorrectionForUnknownWordsOrIntentionalCase() {
        let policy = KeyboardTypingPolicy()
        for word in ["helo", "helllo", "Murmur", "tEh", "teH", "café", "你好", "a1ot", "dont.com"] {
            XCTAssertNil(policy.correction(for: word), word)
        }
    }

    func testPreparedVocabularyIsExactAndProtectsUserSpellings() {
        let policy = KeyboardTypingPolicy(vocabulary: [
            (input: "mrmr", replacement: "Murmur"),
            (input: "teh", replacement: "Teh"),
            (input: "mrmr", replacement: "Ignored"),
        ])
        XCTAssertEqual(policy.correction(for: "mrmr"), "Murmur")
        XCTAssertEqual(policy.correction(for: "MRMR"), "MURMUR")
        XCTAssertNil(policy.correction(for: "mrm"))
        XCTAssertNil(policy.correction(for: "teh"))
        XCTAssertNil(policy.correction(for: "Murmur"))
    }

    func testVocabularyAndWordLengthsAreBounded() {
        let entries = (0..<KeyboardTypingPolicy.maximumVocabularyEntries).map { _ in
            (input: "same", replacement: "Same")
        } + [(input: "extra", replacement: "Extraordinary")]
        let policy = KeyboardTypingPolicy(vocabulary: entries)
        XCTAssertNil(policy.correction(for: "extra"))
        let tooLong = String(repeating: "a", count: KeyboardTypingPolicy.maximumWordLength + 1)
        let longPolicy = KeyboardTypingPolicy(vocabulary: [(input: "short", replacement: tooLong)])
        XCTAssertNil(longPolicy.correction(for: "short"))
        XCTAssertNil(policy.correction(for: tooLong))
    }

    func testTrailingWordHandlesPunctuationApostrophesAndLongTokens() {
        XCTAssertEqual(KeyboardTypingPolicy.trailingWord(in: "hello teh"), "teh")
        XCTAssertEqual(KeyboardTypingPolicy.trailingWord(in: "don't"), "don't")
        XCTAssertEqual(KeyboardTypingPolicy.trailingWord(in: "isn’t"), "isn’t")
        XCTAssertNil(KeyboardTypingPolicy.trailingWord(in: "teh "))
        XCTAssertNil(KeyboardTypingPolicy.trailingWord(in: "teh."))
        XCTAssertNil(KeyboardTypingPolicy.trailingWord(in: String(repeating: "a", count: 25)))
        XCTAssertEqual(KeyboardTypingPolicy.trailingWord(in: String(repeating: "a", count: 1000) + " teh"), "teh")
    }

    func testOverlappingPressCannotRetractIdenticalCharacterFromAnotherPress() {
        let document = UUID()
        let olderToken = UUID()
        let newerToken = UUID()
        let latest = KeyboardPressCommit(token: newerToken, text: "a", documentID: document)
        XCTAssertFalse(latest.canRetract(token: olderToken, documentID: document, context: "aa"))
        XCTAssertTrue(latest.canRetract(token: newerToken, documentID: document, context: "aa"))
        XCTAssertFalse(latest.canRetract(token: newerToken, documentID: UUID(), context: "aa"))
        XCTAssertFalse(latest.canRetract(token: newerToken, documentID: document, context: "ab"))
    }

    func testSuggestionContextChangesOnCursorFieldOrSelectionChange() {
        let document = UUID()
        let original = KeyboardSuggestionContext(before: "teh", after: " same", documentID: document)
        XCTAssertNotEqual(original, KeyboardSuggestionContext(before: "other teh", after: " same", documentID: document))
        XCTAssertNotEqual(original, KeyboardSuggestionContext(before: "teh", after: " different", documentID: document))
        XCTAssertNotEqual(original, KeyboardSuggestionContext(before: "teh", after: " same", documentID: UUID()))
        XCTAssertNotEqual(original, KeyboardSuggestionContext(before: "teh", after: " same", documentID: document, selectedText: "selected"))
    }
}
