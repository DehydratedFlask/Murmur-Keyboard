import UIKit
import SwiftUI

/// Main controller for the MurmurKeyboard extension.
/// Uses UIHostingController to embed the SwiftUI keyboard view.
class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardView>?
    private var pendingTextTimer: Timer?

    /// ViewModel shared with the SwiftUI view layer.
    private let viewModel = KeyboardViewModel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.inputViewController = self
        viewModel.hasFullAccess = hasFullAccess
        viewModel.prepareHaptics()
        viewModel.autoCapitalize()

        SharedDefaults.setKeyboardActive(true)

        // Load supplementary lexicon for predictive text
        requestSupplementaryLexicon { [weak self] lexicon in
            Task { @MainActor in
                self?.viewModel.supplementaryLexicon = lexicon
                self?.viewModel.updateSuggestions()
            }
        }

        let keyboardView = KeyboardView(viewModel: viewModel)
        let hosting = UIHostingController(rootView: keyboardView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hostingController = hosting
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.autoCapitalize()
        viewModel.updateSuggestions()
        checkForPendingText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.autoCapitalize()
        viewModel.updateSuggestions()
        // Start a timer to periodically check for pending text
        // (handles the case where the app returns after dictation)
        startPendingTextTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPendingTextTimer()
        viewModel.stopContinuousDelete()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.autoCapitalize()
        viewModel.updateSuggestions()
    }

    // MARK: - Pending Text Handling

    private func checkForPendingText() {
        if let text = SharedDefaults.consumePendingText(), !text.isEmpty {
            textDocumentProxy.insertText(textForInsertion(text))
            viewModel.autoCapitalize()
            viewModel.updateSuggestions()
        }
    }

    private func textForInsertion(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard let previousCharacter = textDocumentProxy.documentContextBeforeInput?.last else {
            return text
        }

        let previousNeedsSeparation = previousCharacter.isLetter || previousCharacter.isNumber
        let insertedStartsInline = trimmed.first?.isLetter == true || trimmed.first?.isNumber == true

        guard previousNeedsSeparation && insertedStartsInline else {
            return text
        }

        return " " + text
    }

    private func startPendingTextTimer() {
        stopPendingTextTimer()
        pendingTextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForPendingText()
            }
        }
    }

    private func stopPendingTextTimer() {
        pendingTextTimer?.invalidate()
        pendingTextTimer = nil
    }
}

// MARK: - Keyboard ViewModel

/// Observable view model bridging UIKit (textDocumentProxy) to the SwiftUI keyboard view.
@MainActor
final class KeyboardViewModel: ObservableObject {

    // MARK: - State

    @Published var isShifted = false
    @Published var isCapsLocked = false
    @Published var showNumbers = false
    @Published var showSymbols = false
    @Published var hasFullAccess = false
    @Published var handoffError: String?
    private var handoffDismissTask: Task<Void, Never>?

    // Haptic feedback generators
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Continuous backspace
    private var backspaceTimer: Timer?
    private var backspaceStartTime: Date?
    private var suppressNextBackspaceTap = false

    // Double-space period
    private var lastSpaceTime: Date?

    // Key popup
    @Published var popupKey: String?
    @Published var popupFrame: CGRect = .zero

    // Predictive text
    @Published var suggestions: [String] = []
    private let textChecker = UITextChecker()
    var supplementaryLexicon: UILexicon?

    /// The proxy through which the keyboard inserts/deletes text.
    var textDocumentProxy: UITextDocumentProxy?

    /// Reference to the input view controller (for advanceToNextInputMode).
    weak var inputViewController: UIInputViewController?

    // MARK: - Init

    func prepareHaptics() {
        lightHaptic.prepare()
        mediumHaptic.prepare()
    }

    // MARK: - Computed

    var isUppercase: Bool {
        isShifted || isCapsLocked
    }

    // MARK: - Haptics

    func triggerLightHaptic() {
        guard hasFullAccess else { return }
        lightHaptic.impactOccurred()
        lightHaptic.prepare()
    }

    func triggerMediumHaptic() {
        guard hasFullAccess else { return }
        mediumHaptic.impactOccurred()
        mediumHaptic.prepare()
    }

    // MARK: - Actions

    func insertText(_ text: String) {
        triggerLightHaptic()
        let textToInsert = isUppercase ? text.uppercased() : text.lowercased()
        textDocumentProxy?.insertText(textToInsert)
        lastSpaceTime = nil

        // Auto-unshift after typing a letter (unless caps lock)
        if isShifted && !isCapsLocked {
            isShifted = false
        }

        updateSuggestions()
    }

    /// Inserts a number or symbol character, clearing double-space period state.
    func insertCharacter(_ character: String) {
        triggerLightHaptic()
        textDocumentProxy?.insertText(character)
        lastSpaceTime = nil
        updateSuggestions()
    }

    func deleteBackward() {
        if suppressNextBackspaceTap {
            suppressNextBackspaceTap = false
            return
        }
        triggerMediumHaptic()
        textDocumentProxy?.deleteBackward()
        lastSpaceTime = nil
        updateSuggestions()
    }

    func insertSpace() {
        triggerLightHaptic()

        // Double-space period shortcut
        let now = Date()
        let context = textDocumentProxy?.documentContextBeforeInput ?? ""
        if let last = lastSpaceTime,
           now.timeIntervalSince(last) < 0.3,
           canReplaceDoubleSpace(in: context) {
            // Replace the previously inserted space with ". "
            textDocumentProxy?.deleteBackward()
            textDocumentProxy?.insertText(". ")
            lastSpaceTime = nil
            autoCapitalize()
            updateSuggestions()
            return
        }

        textDocumentProxy?.insertText(" ")
        lastSpaceTime = now
        autoCapitalize()
        updateSuggestions()
    }

    func insertReturn() {
        triggerMediumHaptic()
        textDocumentProxy?.insertText("\n")
        lastSpaceTime = nil
        autoCapitalize()
        updateSuggestions()
    }

    // MARK: - Auto-capitalization

    func autoCapitalize() {
        guard !isCapsLocked else { return }
        let context = textDocumentProxy?.documentContextBeforeInput ?? ""
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") || trimmed.hasSuffix("\n") {
            isShifted = true
        } else {
            isShifted = false
        }
    }

    // MARK: - Continuous Backspace

    func startContinuousDelete() {
        stopContinuousDelete()
        suppressNextBackspaceTap = true
        triggerMediumHaptic()
        textDocumentProxy?.deleteBackward()
        backspaceStartTime = Date()
        lastSpaceTime = nil
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.backspaceStartTime else { return }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > 1.5 {
                    // Word-at-a-time deletion
                    self.deleteWordBackward()
                } else if elapsed > 0.5 {
                    self.textDocumentProxy?.deleteBackward()
                }
                self.updateSuggestions()
            }
        }
    }

    func stopContinuousDelete() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceStartTime = nil
    }

    private func deleteWordBackward() {
        guard let proxy = textDocumentProxy, let context = proxy.documentContextBeforeInput, !context.isEmpty else {
            textDocumentProxy?.deleteBackward()
            return
        }
        // Find last word boundary
        let trimmed = context as NSString
        let range = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        let count = range.location == NSNotFound ? context.count : (context.count - range.location - range.length)
        let toDelete = max(count, 1)
        for _ in 0..<toDelete {
            proxy.deleteBackward()
        }
    }

    private func canReplaceDoubleSpace(in context: String) -> Bool {
        guard context.last == " " else { return false }
        let characters = Array(context)
        guard characters.count >= 2 else { return false }
        let previousCharacter = characters[characters.count - 2]
        return previousCharacter.isLetter || previousCharacter.isNumber
    }

    // MARK: - Key Popup

    func showPopup(key: String, frame: CGRect) {
        popupKey = key
        popupFrame = frame
    }

    func hidePopup() {
        popupKey = nil
    }

    // MARK: - Predictive Text

    func updateSuggestions() {
        guard let proxy = textDocumentProxy, let context = proxy.documentContextBeforeInput else {
            suggestions = []
            return
        }
        let words = context.components(separatedBy: .whitespacesAndNewlines)
        guard let currentWord = words.last, !currentWord.isEmpty else {
            suggestions = []
            return
        }

        var results: [String] = []

        // UITextChecker completions
        let nsWord = currentWord as NSString
        let completions = textChecker.completions(forPartialWordRange: NSRange(location: 0, length: nsWord.length), in: currentWord, language: "en")
        if let completions {
            results.append(contentsOf: completions.prefix(3))
        }

        // UITextChecker guesses (spell check)
        let misspelledRange = textChecker.rangeOfMisspelledWord(in: currentWord, range: NSRange(location: 0, length: nsWord.length), startingAt: 0, wrap: false, language: "en")
        if misspelledRange.location != NSNotFound {
            let guesses = textChecker.guesses(forWordRange: misspelledRange, in: currentWord, language: "en") ?? []
            for guess in guesses where !results.contains(guess) {
                results.append(guess)
                if results.count >= 3 { break }
            }
        }

        // Supplementary lexicon matches
        if let lexicon = supplementaryLexicon {
            for entry in lexicon.entries {
                if entry.userInput.lowercased().hasPrefix(currentWord.lowercased()) && !results.contains(entry.documentText) {
                    results.append(entry.documentText)
                    if results.count >= 3 { break }
                }
            }
        }

        // If no suggestions, show the current word in center
        if results.isEmpty {
            suggestions = ["", currentWord, ""]
        } else {
            // Pad to 3 slots
            while results.count < 3 { results.append("") }
            suggestions = Array(results.prefix(3))
        }
    }

    func applySuggestion(_ suggestion: String) {
        guard !suggestion.isEmpty, let proxy = textDocumentProxy, let context = proxy.documentContextBeforeInput else { return }
        triggerLightHaptic()

        // Delete the current partial word
        let words = context.components(separatedBy: .whitespacesAndNewlines)
        if let currentWord = words.last {
            for _ in 0..<currentWord.count {
                proxy.deleteBackward()
            }
        }
        proxy.insertText(suggestion + " ")
        lastSpaceTime = nil
        suggestions = []
        autoCapitalize()
    }

    func toggleShift() {
        if isCapsLocked {
            isCapsLocked = false
            isShifted = false
        } else if isShifted {
            // Double-tap shift → caps lock
            isCapsLocked = true
        } else {
            isShifted = true
        }
    }

    func toggleNumbers() {
        showNumbers.toggle()
        showSymbols = false
    }

    func toggleSymbols() {
        showSymbols.toggle()
    }

    func advanceToNextInputMode() {
        inputViewController?.advanceToNextInputMode()
    }

    func openMurmurForDictation() {
        guard hasFullAccess else { return }
        SharedDefaults.setDictationRequested(true)
        guard let url = URL(string: "murmur://dictate") else { return }
        inputViewController?.extensionContext?.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    SharedDefaults.setDictationRequested(false)
                    self.handoffError = "Could not open Murmur. Please open the app manually."
                    // Auto-dismiss error after 3 seconds
                    self.handoffDismissTask?.cancel()
                    self.handoffDismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled {
                            self.handoffError = nil
                        }
                    }
                }
            }
        }
    }
}
