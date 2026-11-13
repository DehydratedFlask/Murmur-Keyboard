import UIKit
import SwiftUI

/// Main controller for the MurmurKeyboard extension.
/// Uses UIHostingController to embed the SwiftUI keyboard view.
class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardView>?
    private var pendingTextTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    /// Last time the field's traits were read, for the typing-path throttle.
    private var lastTraitRefresh: Date?
    /// A text-change pass is already queued for the next runloop turn.
    private var textChangeScheduled = false
    private var lastDocumentID: UUID?

    /// Stale-session timeout, driven by the app's Session duration setting.
    private var dictationTimeout: TimeInterval {
        TimeInterval(SharedDefaults.dictationSessionDurationMinutes() * 60)
    }

    /// ViewModel shared with the SwiftUI view layer.
    private let viewModel = KeyboardViewModel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        viewModel.textDocumentProxy = textDocumentProxy
        lastDocumentID = textDocumentProxy.documentIdentifier
        viewModel.inputViewController = self
        viewModel.hasFullAccess = hasFullAccess
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.prepareHaptics()
        viewModel.prepareVocabulary()
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits(interfaceStyle: traitCollection.userInterfaceStyle)
        viewModel.refreshSharedState()

        SharedDefaults.setKeyboardActive(true)
        SharedDefaults.setFullAccessGranted(hasFullAccess)

        let keyboardView = KeyboardView(viewModel: viewModel)
        let hosting = UIHostingController(rootView: keyboardView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        // CRITICAL: In keyboard extensions, UIHostingController can collapse
        // to zero height if it tries to size itself from intrinsic content.
        // Disable automatic sizing so our explicit height constraint wins.
        if #available(iOS 16.0, *) {
            hosting.sizingOptions = []
        }

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

        // Explicit height so the system allocates space for the keyboard.
        // 48 (toolbar) + 8/3 (key padding) + 4×46 (key rows) + 3×12 (row
        // spacing) ≈ 279. The system adds its own language-switch / dictation
        // strip below this, so we don't reserve any room for it.
        let desiredHeight = view.heightAnchor.constraint(equalToConstant: 282)
        desiredHeight.priority = .init(999)
        desiredHeight.isActive = true
        heightConstraint = desiredHeight

        // A field can report `.default` keyboard appearance even inside a dark
        // app — Spotlight's search field does — so for those the keyboard's own
        // trait collection decides light or dark. Keep it live while the system
        // appearance changes.
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (controller: KeyboardViewController, _: UITraitCollection) in
                controller.viewModel.refreshTextTraits(
                    interfaceStyle: controller.traitCollection.userInterfaceStyle
                )
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        SharedDefaults.setFullAccessGranted(hasFullAccess)
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.invalidateTypingContext()
        lastDocumentID = textDocumentProxy.documentIdentifier
        lastTraitRefresh = nil
        viewModel.prepareVocabulary()
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits(interfaceStyle: traitCollection.userInterfaceStyle)
        viewModel.restoreActiveDictationSession()
        viewModel.refreshSharedState()
        viewModel.refreshSuggestions()
        checkForPendingText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits(interfaceStyle: traitCollection.userInterfaceStyle)
        viewModel.refreshSharedState()
        startDarwinObservers()
        startPendingTextTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDarwinObservers()
        stopPendingTextTimer()
        viewModel.stopContinuousDelete()
        viewModel.invalidateTypingContext()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        heightConstraint?.constant = size.width > size.height ? 226 : 282
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        viewModel.invalidateSuggestions()
        scheduleTextChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        viewModel.invalidateSuggestions()
        scheduleTextChange()
    }

    private func scheduleTextChange() {
        // Never touch the text proxy from inside its own change callback. Doing
        // that re-enters the host's text system, and several hosts (Notes among
        // them) will block there — the keyboard then looks frozen: keys highlight
        // and nothing arrives. Coalesce every change into one pass on the next
        // runloop turn instead.
        guard !textChangeScheduled else { return }
        textChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textChangeScheduled = false
            self.processTextChange()
        }
    }

    private func processTextChange() {
        viewModel.textDocumentProxy = textDocumentProxy

        guard let snapshot = viewModel.contextSnapshot() else { return }
        let context = snapshot.before ?? ""
        if lastDocumentID != snapshot.documentID {
            lastDocumentID = snapshot.documentID
            lastTraitRefresh = nil
            viewModel.invalidateTypingContext()
        }
        viewModel.observeTypingContext(snapshot)
        refreshTraitsIfStale(context: context)
        viewModel.refreshReturnKeyState(context: context)
        viewModel.autoCapitalize(context: context)
        viewModel.refreshSuggestions(snapshot: snapshot)
    }

    /// Traits change when the field changes, not per letter. A short throttle
    /// keeps the layout and appearance right without paying for it on every
    /// keystroke.
    private func refreshTraitsIfStale(context: String) {
        let now = Date()
        if let last = lastTraitRefresh, now.timeIntervalSince(last) < 0.6 {
            return
        }
        lastTraitRefresh = now
        viewModel.refreshTextTraits(interfaceStyle: traitCollection.userInterfaceStyle, context: context)
    }

    // MARK: - Pending Text Handling

    private func checkForPendingText() {
        viewModel.restoreActiveDictationSession()

        if let abandoned = SharedDefaults.consumeAbandonedDictationSession() {
            if viewModel.consumeAbandonmentSuppression() {
                SharedDefaults.clearDictationSession()
                viewModel.activeSessionID = nil
                viewModel.refreshSharedState()
                return
            }
            if abandoned.sessionID == nil || abandoned.sessionID == viewModel.activeSessionID {
                SharedDefaults.clearDictationSession()
                viewModel.activeSessionID = nil
                viewModel.presentHandoffError(abandoned.reason ?? "Dictation ended before a transcription was ready.")
                viewModel.refreshSharedState()
                return
            }
        }

        if viewModel.insertPendingDictationIfAvailable() {
            return
        }

        viewModel.refreshSharedState()

        if viewModel.activeSessionID != nil,
           viewModel.dictationPhase == .preparing,
           let age = SharedDefaults.dictationSessionAge(),
           age >= dictationTimeout {
            SharedDefaults.abandonDictationSession(reason: "Murmur took too long to respond. Please try again.")
            SharedDefaults.clearPendingText()
            SharedDefaults.clearDictationSession()
            viewModel.activeSessionID = nil
            viewModel.presentHandoffError("Murmur took too long to respond. Please try again.")
            viewModel.refreshSharedState()
        }
    }

    // MARK: - Darwin Notification Observers

    private func startDarwinObservers() {
        // Listen for instant cross-process signals from the main app
        DarwinNotificationCenter.observe(.transcriptionReady) { [weak self] in
            Task { @MainActor in
                self?.checkForPendingText()
            }
        }
        DarwinNotificationCenter.observe(.dictationAbandoned) { [weak self] in
            Task { @MainActor in
                self?.checkForPendingText()
            }
        }
        DarwinNotificationCenter.observe(.modelStateChanged) { [weak self] in
            Task { @MainActor in
                self?.viewModel.refreshSharedState()
            }
        }
        DarwinNotificationCenter.observe(.dictationStateChanged) { [weak self] in
            Task { @MainActor in
                self?.checkForPendingText()
            }
        }
    }

    private func stopDarwinObservers() {
        DarwinNotificationCenter.removeObserver(.transcriptionReady)
        DarwinNotificationCenter.removeObserver(.dictationAbandoned)
        DarwinNotificationCenter.removeObserver(.modelStateChanged)
        DarwinNotificationCenter.removeObserver(.dictationStateChanged)
    }

    private func startPendingTextTimer() {
        stopPendingTextTimer()
        // Fallback safety-net poll at a relaxed interval — Darwin notifications
        // handle the fast path; this catches edge cases where a notification is missed.
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
    @Published var showGlobeKey = true
    @Published var handoffError: String?
    @Published var isModelWarm = false
    @Published var hasPendingDictation = false
    @Published var dictationPhase: DictationPhase = .idle
    @Published var displayedDictationText = ""
    @Published var formattingStyle = SharedDefaults.formattingStyle
    @Published var dictationLanguage = SharedDefaults.autoDetectLanguage ? "auto" : (SharedDefaults.selectedLanguages.first ?? "en")
    @Published var keyboardType: UIKeyboardType = .default
    @Published var returnKeyType: UIReturnKeyType = .default
    @Published var autocapitalizationType: UITextAutocapitalizationType = .sentences
    @Published var enablesReturnKeyAutomatically = false
    @Published var returnKeyEnabled = true
    @Published var isDarkMode = false
    /// Briefly true right after a finished dictation is inserted, so the
    /// toolbar can confirm that the text landed.
    @Published var showsInsertionConfirmation = false
    /// The correction the keyboard would make to the word being typed, shown
    /// in the toolbar like Apple's prediction bar.
    @Published var suggestions: [String] = []
    var activeSessionID: String?
    private var handoffDismissTask: Task<Void, Never>?
    private var insertionConfirmationTask: Task<Void, Never>?
    private var warmFallbackTask: Task<Void, Never>?
    private var pauseFallbackTask: Task<Void, Never>?

    /// Set when the user cancels from the keyboard, so the failure signal the
    /// container app sends back is not surfaced as an error banner.
    private var suppressesAbandonmentNotice = false

    // Haptic feedback generators
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    // Continuous backspace
    private var backspaceTimer: Timer?
    private var deleteGeneration: UInt64 = 0

    // Double-space period shortcut
    private var lastSpaceTime: Date?
    private var lastShiftTapTime: Date?

    /// The autocorrection that a single delete press can still undo, exactly as
    /// Apple's keyboard restores the word you actually typed.
    private var lastCorrection: Correction?
    /// What the press in progress typed, so a long press that opens the accent
    /// palette can take it back.
    private var lastPressCommit: KeyboardPressCommit?
    private var lastPressContext: KeyboardSuggestionContext?
    private var retractedPress: KeyboardPressCommit?
    private var keyHapticsEnabled = false
    private var allowsAutocorrection = true
    private var suggestionGeneration: UInt64 = 0
    private var suggestionContext: KeyboardSuggestionContext?
    private var suggestionTask: Task<Void, Never>?

    /// The proxy through which the keyboard inserts/deletes text.
    var textDocumentProxy: UITextDocumentProxy?

    /// Reference to the input view controller (for advanceToNextInputMode).
    weak var inputViewController: UIInputViewController?

    // MARK: - Init

    func prepareHaptics() {
        lightHaptic.prepare()
        mediumHaptic.prepare()
        selectionHaptic.prepare()
    }

    func refreshSharedState() {
        keyHapticsEnabled = SharedDefaults.isKeyHapticsEnabled()
        let style = SharedDefaults.formattingStyle
        if formattingStyle != style { formattingStyle = style }
        let language = SharedDefaults.autoDetectLanguage ? "auto" : (SharedDefaults.selectedLanguages.first ?? "en")
        if dictationLanguage != language { dictationLanguage = language }
        let newModelWarm = SharedDefaults.isModelReady()
        if isModelWarm != newModelWarm {
            isModelWarm = newModelWarm
        }

        let payload = SharedDefaults.peekPendingTextPayload()
        let canPaste = payload.map { payload in
            guard let activeSessionID else { return false }
            return payload.sessionID == nil || payload.sessionID == activeSessionID
        } ?? false
        if hasPendingDictation != canPaste {
            hasPendingDictation = canPaste
        }

        let sharedState = SharedDefaults.dictationState()
        let newPhase: DictationPhase
        if let activeSessionID,
           sharedState.sessionID == nil || sharedState.sessionID == activeSessionID {
            newPhase = sharedState.phase
        } else {
            newPhase = .idle
        }
        if dictationPhase != newPhase {
            dictationPhase = newPhase
        }
        let text = canPaste ? (payload?.text ?? "") : SharedDefaults.livePreview(sessionID: activeSessionID)
        if displayedDictationText != text { displayedDictationText = text }
    }

    func restoreActiveDictationSession() {
        guard activeSessionID == nil else { return }
        activeSessionID = SharedDefaults.currentDictationSessionID()
    }

    func refreshTextTraits(
        interfaceStyle: UIUserInterfaceStyle = .unspecified,
        context: String? = nil
    ) {
        KeyboardPerformance.measure("ProxyTraits") {
            applyTextTraits(interfaceStyle: interfaceStyle, context: context)
        }
    }

    private func applyTextTraits(interfaceStyle: UIUserInterfaceStyle, context: String?) {
        let newKeyboardType = textDocumentProxy?.keyboardType ?? .default
        let newAllowsAutocorrection = textDocumentProxy?.autocorrectionType != .no
        if newKeyboardType != keyboardType || newAllowsAutocorrection != allowsAutocorrection {
            invalidateSuggestions()
        }
        allowsAutocorrection = newAllowsAutocorrection
        let newReturnKeyType = textDocumentProxy?.returnKeyType ?? .default
        let newAutocapitalizationType =
            textDocumentProxy?.autocapitalizationType ?? .sentences
        let newEnablesReturnKeyAutomatically =
            textDocumentProxy?.enablesReturnKeyAutomatically ?? false

        // A field can report `.default` keyboard appearance even inside a dark
        // app — Spotlight's search field does — and then the keyboard's own
        // trait collection is the only honest answer. Without this the caps
        // stayed white on the dark glass tray.
        let newDarkMode: Bool
        switch textDocumentProxy?.keyboardAppearance ?? .default {
        case .dark:
            newDarkMode = true
        case .light:
            newDarkMode = false
        default:
            newDarkMode = interfaceStyle == .unspecified
                ? isDarkMode
                : interfaceStyle == .dark
        }

        let documentContext = context ?? (proxyContextBefore() ?? "")
        let newReturnKeyEnabled =
            !newEnablesReturnKeyAutomatically || !documentContext.isEmpty

        if keyboardType != newKeyboardType { keyboardType = newKeyboardType }
        if returnKeyType != newReturnKeyType { returnKeyType = newReturnKeyType }
        if autocapitalizationType != newAutocapitalizationType {
            autocapitalizationType = newAutocapitalizationType
        }
        if isDarkMode != newDarkMode { isDarkMode = newDarkMode }
        if enablesReturnKeyAutomatically != newEnablesReturnKeyAutomatically {
            enablesReturnKeyAutomatically = newEnablesReturnKeyAutomatically
        }
        if returnKeyEnabled != newReturnKeyEnabled {
            returnKeyEnabled = newReturnKeyEnabled
        }

        switch newKeyboardType {
        case .numberPad, .decimalPad, .phonePad, .namePhonePad,
             .asciiCapableNumberPad:
            showNumbers = true
            showSymbols = false
        default:
            break
        }
    }

    /// The only trait that actually changes while typing. Re-reading the other
    /// five from the host on every keystroke was latency, not information.
    func refreshReturnKeyState(context: String) {
        guard enablesReturnKeyAutomatically else {
            if !returnKeyEnabled { returnKeyEnabled = true }
            return
        }
        let enabled = !context.isEmpty
        if returnKeyEnabled != enabled { returnKeyEnabled = enabled }
    }

    func presentHandoffError(_ message: String) {        handoffError = message
        handoffDismissTask?.cancel()
        handoffDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                self.handoffError = nil
            }
        }
    }

    // MARK: - Computed

    var isUppercase: Bool {
        isShifted || isCapsLocked
    }

    /// The kind of field the user is typing into, as far as a keyboard
    /// extension can tell: iOS exposes the keyboard type and the return key,
    /// not the host app. Sent as the raw `DictationSurface` value, which the
    /// app parses.
    private var dictationSurfaceHint: String {
        switch keyboardType {
        case .emailAddress:
            return "email"
        case .webSearch, .URL:
            return "search"
        default:
            switch returnKeyType {
            case .send, .google:
                return "chat"
            case .search:
                return "search"
            default:
                return "general"
            }
        }
    }

    /// A short tail of the surrounding text, capped so the formatter prompt
    /// stays small and only ever carries what it needs.
    private func dictationSnippet(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.suffix(200))
    }

    /// Whether the recording panel replaces the key grid. A failed start keeps
    /// the panel up with a retry action rather than dropping back to an error
    /// banner the user can't act on.
    var showsDictationPanel: Bool {
        switch dictationPhase {
        case .preparing, .recording, .paused, .processing, .failed:
            return true
        case .ready:
            return hasPendingDictation && SharedDefaults.reviewBeforeInsertion
        case .idle:
            return false
        }
    }

    // MARK: - Haptics

    /// Feedback uses the cached preference and haptics only, keeping shared
    /// preference reads and audio-system work out of key delivery.
    func triggerLightHaptic() {
        guard keyHapticsEnabled, hasFullAccess else { return }
        KeyboardPerformance.measure("Feedback") {
            lightHaptic.impactOccurred()
            lightHaptic.prepare()
        }
    }

    func triggerMediumHaptic() {
        guard keyHapticsEnabled, hasFullAccess else { return }
        KeyboardPerformance.measure("Feedback") {
            mediumHaptic.impactOccurred()
            mediumHaptic.prepare()
        }
    }

    /// A light tick as the accent palette's selection moves, matching the feel
    /// of Apple's keyboard rather than a full key press.
    func triggerSelectionHaptic() {
        guard keyHapticsEnabled, hasFullAccess else { return }
        KeyboardPerformance.measure("Feedback") {
            selectionHaptic.selectionChanged()
            selectionHaptic.prepare()
        }
    }

    private func proxyContextBefore(_ proxy: UITextDocumentProxy? = nil) -> String? {
        KeyboardPerformance.measure("ProxyContext") {
            (proxy ?? textDocumentProxy)?.documentContextBeforeInput
        }
    }

    private func proxyContextAfter(_ proxy: UITextDocumentProxy? = nil) -> String? {
        KeyboardPerformance.measure("ProxyContext") {
            (proxy ?? textDocumentProxy)?.documentContextAfterInput
        }
    }

    private func insertIntoProxy(_ text: String, proxy: UITextDocumentProxy? = nil) {
        invalidateSuggestions()
        KeyboardPerformance.measure("ProxyInsert") {
            (proxy ?? textDocumentProxy)?.insertText(text)
        }
    }

    private func deleteFromProxy(_ proxy: UITextDocumentProxy? = nil) {
        invalidateSuggestions()
        KeyboardPerformance.measure("ProxyDelete") {
            (proxy ?? textDocumentProxy)?.deleteBackward()
        }
    }

    // MARK: - Text Input

    // Press feedback is fired by the keys themselves on touch-down (see
    // KeyboardKey.swift), so nothing here clicks a second time on lift.

    func insertText(_ text: String) {
        lastPressCommit = nil
        lastPressContext = nil
        let textToInsert =
            (isUppercase || autocapitalizationType == .allCharacters)
                ? text.uppercased()
                : text.lowercased()
        insertIntoProxy(textToInsert)
        lastSpaceTime = nil
        lastCorrection = nil

        // Auto-unshift after typing a letter (unless caps lock)
        if isShifted &&
            !isCapsLocked &&
            autocapitalizationType != .allCharacters {
            isShifted = false
        }
    }

    func insertCharacter(_ character: String, pressToken: UUID = UUID()) {
        retractedPress = nil
        if Self.punctuationCommittingWord.contains(character) {
            autocorrectTrailingWord()
            // Apple drops a space typed just before punctuation: "Hello ,"
            // becomes "Hello,".
            removeSpaceBeforePunctuation()
        } else {
            lastCorrection = nil
        }
        insertIntoProxy(character)
        lastSpaceTime = nil
        lastPressContext = nil
        lastPressCommit = textDocumentProxy.map {
            KeyboardPressCommit(token: pressToken, text: character, documentID: $0.documentIdentifier)
        }
    }

    /// Removes the single space before a punctuation mark, as the system
    /// keyboard does, but only when a word (or a closing bracket) precedes it.
    private func removeSpaceBeforePunctuation() {
        guard let proxy = textDocumentProxy,
              let context = proxyContextBefore(proxy),
              context.hasSuffix(" ")
        else { return }

        guard let beforeSpace = String(context.dropLast()).last,
              beforeSpace.isLetter
                || beforeSpace.isNumber
                || [")", "]", "\"", "'"].contains(beforeSpace)
        else { return }

        deleteFromProxy(proxy)
    }

    func insertAlternate(_ character: String, pressToken: UUID = UUID()) {
        lastCorrection = nil
        // Resolve the case here instead of trusting the key's label: with the
        // text bookkeeping deferred by a runloop turn, a stale shift state would
        // otherwise type the rest of the sentence in capitals.
        // A held accent replaces the same press, including its original case
        // after the initial letter has already consumed one-shot shift.
        let uppercase = retractedPress?.token == pressToken
            ? retractedPress?.text.first?.isUppercase == true
            : isUppercase
        retractedPress = nil
        let resolved = uppercase ? character.uppercased() : character.lowercased()
        insertIntoProxy(resolved)
        lastSpaceTime = nil
        lastPressContext = nil
        lastPressCommit = textDocumentProxy.map {
            KeyboardPressCommit(token: pressToken, text: resolved, documentID: $0.documentIdentifier)
        }
        if isShifted && !isCapsLocked {
            isShifted = false
        }
    }

    /// Undoes the character typed by a press that has turned into an accent
    /// choice. Only removes text whose final character is still the one this
    /// press inserted, so it can never eat anything else.
    @discardableResult
    func retractKeyPress(_ token: UUID) -> Bool {
        guard let committed = lastPressCommit, committed.token == token else { return false }
        let expectedContext = lastPressContext
        lastPressCommit = nil
        lastPressContext = nil
        guard let snapshot = contextSnapshot(), snapshot.selectedText == nil,
              let context = snapshot.before,
              expectedContext == nil || expectedContext == snapshot,
              committed.canRetract(token: token, documentID: snapshot.documentID, context: context)
        else { return false }

        invalidateSuggestions()
        for _ in 0..<committed.text.count { deleteFromProxy() }
        retractedPress = committed
        lastSpaceTime = nil
        return true
    }

    func deleteBackward() {
        lastPressCommit = nil
        lastPressContext = nil
        if !revertLastCorrection() {
            deleteFromProxy()
        }
        lastSpaceTime = nil
    }

    func insertSpace() {
        lastPressCommit = nil
        lastPressContext = nil
        // Double-space period shortcut (matches Apple behavior)
        let now = Date()
        let context = proxyContextBefore() ?? ""
        if let last = lastSpaceTime,
           now.timeIntervalSince(last) < 0.3,
           canReplaceDoubleSpace(in: context) {
            lastCorrection = nil
            deleteFromProxy()
            insertIntoProxy(". ")
            lastSpaceTime = nil
            autoCapitalize()
            refreshSuggestions()
            return
        }

        autocorrectTrailingWord()
        insertIntoProxy(" ")
        lastSpaceTime = now
        autoCapitalize()
        refreshSuggestions()
    }

    func insertReturn() {
        lastPressCommit = nil
        lastPressContext = nil
        autocorrectTrailingWord()
        insertIntoProxy("\n")
        lastSpaceTime = nil
        autoCapitalize()
        refreshSuggestions()
    }

    // MARK: - Autocorrection

    // Apple's contract: a word is corrected when it is *committed* — space,
    // punctuation or return — not while it is still being typed, and one press
    // of delete puts the original spelling back. Everything runs on-device
    // through a bounded exact mapping, so nothing leaves the phone.

    private var typingPolicy = KeyboardTypingPolicy()
    private var hasRequestedVocabulary = false

    private struct Correction {
        let original: String
        let replacement: String
        let date: Date
    }

    private static let punctuationCommittingWord: Set<String> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}",
    ]

    /// Apple does not autocorrect URL, email or web-search fields, and neither
    /// does Murmur.
    private var supportsCorrection: Bool {
        guard allowsAutocorrection else { return false }
        switch keyboardType {
        case .URL, .emailAddress, .webSearch, .numberPad, .decimalPad,
             .phonePad, .namePhonePad, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
    }

    /// UIKit supplies the user's supplementary lexicon asynchronously. Prepare
    /// a bounded exact mapping once per extension instance, never on key-down.
    func prepareVocabulary() {
        guard !hasRequestedVocabulary, let inputViewController else { return }
        hasRequestedVocabulary = true
        inputViewController.requestSupplementaryLexicon { [weak self] lexicon in
            let entries = lexicon.entries.prefix(KeyboardTypingPolicy.maximumVocabularyEntries)
                .map { (input: $0.userInput, replacement: $0.documentText) }
            Task { @MainActor [weak self] in
                self?.typingPolicy = KeyboardTypingPolicy(vocabulary: entries)
                self?.invalidateSuggestions()
            }
        }
    }

    /// Replaces an obvious typo in the word before the caret.
    private func autocorrectTrailingWord() {
        lastCorrection = nil

        guard supportsCorrection,
              let proxy = textDocumentProxy,
              proxy.selectedText == nil,
              let context = proxyContextBefore(proxy),
              let word = Self.trailingWord(in: context),
              let replacement = correction(for: word),
              replacement != word
        else { return }

        for _ in 0..<word.count {
            deleteFromProxy(proxy)
        }
        insertIntoProxy(replacement, proxy: proxy)
        lastCorrection = Correction(
            original: word,
            replacement: replacement,
            date: Date()
        )
    }

    /// Apple lets a single press of delete take an autocorrection back: the
    /// word returns to the spelling the user actually typed.
    @discardableResult
    private func revertLastCorrection() -> Bool {
        guard let correction = lastCorrection else { return false }
        lastCorrection = nil

        guard Date().timeIntervalSince(correction.date) < 4,
              let proxy = textDocumentProxy,
              let context = proxyContextBefore(proxy)
        else { return false }

        let hasTrailingSpace = context.hasSuffix(" ")
        let trimmed = hasTrailingSpace ? String(context.dropLast()) : context
        guard trimmed.hasSuffix(correction.replacement) else { return false }

        for _ in 0..<correction.replacement.count {
            deleteFromProxy(proxy)
        }
        if hasTrailingSpace {
            deleteFromProxy(proxy)
        }
        insertIntoProxy(correction.original + (hasTrailingSpace ? " " : ""), proxy: proxy)
        autoCapitalize()
        refreshSuggestions()
        return true
    }

    private func correction(for word: String) -> String? {
        KeyboardPerformance.measure("Correction") { typingPolicy.correction(for: word) }
    }

    // MARK: - Suggestions

    func contextSnapshot() -> KeyboardSuggestionContext? {
        guard let proxy = textDocumentProxy else { return nil }
        return KeyboardPerformance.measure("ProxyContext") {
            KeyboardSuggestionContext(
                before: proxy.documentContextBeforeInput,
                after: proxy.documentContextAfterInput,
                documentID: proxy.documentIdentifier,
                selectedText: proxy.selectedText
            )
        }
    }

    func invalidateSuggestions() {
        suggestionGeneration &+= 1
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionContext = nil
        if !suggestions.isEmpty { suggestions = [] }
    }

    /// Reuse the controller's deferred snapshot to detect cursor / host edits
    /// while a key is held, without adding a proxy context read per key-down.
    func observeTypingContext(_ snapshot: KeyboardSuggestionContext) {
        guard let committed = lastPressCommit else { return }
        guard snapshot.selectedText == nil,
              committed.canRetract(token: committed.token, documentID: snapshot.documentID, context: snapshot.before ?? ""),
              lastPressContext == nil || lastPressContext == snapshot
        else {
            lastPressCommit = nil
            lastPressContext = nil
            return
        }
        lastPressContext = snapshot
    }

    func invalidateTypingContext() {
        retractedPress = nil
        lastPressCommit = nil
        lastPressContext = nil
        lastCorrection = nil
        lastSpaceTime = nil
        invalidateSuggestions()
    }

    /// Publish only after a short pause and only for the exact document / cursor
    /// context that produced the candidate. Clear the old chip immediately.
    func refreshSuggestions(snapshot: KeyboardSuggestionContext? = nil) {
        invalidateSuggestions()
        guard let snapshot = snapshot ?? contextSnapshot(), supportsCorrection,
              snapshot.selectedText == nil,
              let word = Self.trailingWord(in: snapshot.before ?? ""), word.count >= 2
        else { return }
        let generation = suggestionGeneration
        suggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  self.suggestionGeneration == generation,
                  self.supportsCorrection,
                  self.contextSnapshot() == snapshot,
                  let replacement = self.correction(for: word), replacement != word
            else { return }
            self.suggestionContext = snapshot
            self.suggestions = [replacement]
        }
    }

    /// A displayed candidate is never allowed to act on a different word.
    func applySuggestion(_ suggestion: String) {
        guard suggestions.contains(suggestion), supportsCorrection,
              let expectedContext = suggestionContext,
              contextSnapshot() == expectedContext,
              let proxy = textDocumentProxy,
              let word = Self.trailingWord(in: expectedContext.before ?? ""),
              correction(for: word) == suggestion
        else {
            invalidateSuggestions()
            return
        }
        invalidateSuggestions()
        lastPressCommit = nil
        lastPressContext = nil
        for _ in 0..<word.count { deleteFromProxy(proxy) }
        insertIntoProxy(suggestion, proxy: proxy)
        lastCorrection = Correction(original: word, replacement: suggestion, date: Date())
        lastSpaceTime = nil
        autoCapitalize()
    }

    private static func trailingWord(in context: String) -> String? {
        KeyboardTypingPolicy.trailingWord(in: context)
    }

    // MARK: - Auto-capitalization (matches Apple behavior)

    func autoCapitalize(context: String? = nil) {
        guard !isCapsLocked else { return }

        if autocapitalizationType == .none ||
            keyboardType == .URL ||
            keyboardType == .emailAddress ||
            keyboardType == .webSearch {
            if isShifted { isShifted = false }
            return
        }
        if autocapitalizationType == .allCharacters {
            if !isShifted { isShifted = true }
            return
        }

        let documentContext = context ?? (proxyContextBefore() ?? "")
        if autocapitalizationType == .words {
            let shouldShift =
                documentContext.isEmpty ||
                documentContext.last?.isWhitespace == true ||
                documentContext.last?.isNewline == true
            if isShifted != shouldShift { isShifted = shouldShift }
            return
        }

        let trimmed = documentContext.trimmingCharacters(in: .whitespaces)
        let shouldShift =
            trimmed.isEmpty ||
            trimmed.hasSuffix(".") ||
            trimmed.hasSuffix("!") ||
            trimmed.hasSuffix("?") ||
            trimmed.hasSuffix("\n")
        if isShifted != shouldShift {
            isShifted = shouldShift
        }
    }

    // MARK: - Continuous Backspace

    func startContinuousDelete() {
        stopContinuousDelete()
        lastPressCommit = nil
        lastPressContext = nil
        triggerMediumHaptic()
        if !revertLastCorrection() {
            deleteFromProxy()
        }
        lastSpaceTime = nil

        // Apple's keyboard: one character on touch-down, then a held key repeats
        // at a steady rate after a short delay. It never jumps to deleting whole
        // words, and the timer runs in the common modes so it keeps ticking while
        // the finger is down.
        let generation = deleteGeneration
        let timer = Timer(
            fire: Date().addingTimeInterval(0.4),
            interval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.deleteGeneration == generation,
                      self.backspaceTimer != nil else { return }
                self.deleteFromProxy()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backspaceTimer = timer
    }

    func stopContinuousDelete() {
        deleteGeneration &+= 1
        backspaceTimer?.invalidate()
        backspaceTimer = nil
    }

    private func canReplaceDoubleSpace(in context: String) -> Bool {
        guard context.last == " " else { return false }
        var characters = context.reversed().makeIterator()
        guard characters.next() != nil, let previousCharacter = characters.next() else { return false }
        return previousCharacter.isLetter || previousCharacter.isNumber
    }

    // MARK: - Mode Toggles

    func toggleShift() {
        if isCapsLocked {
            isCapsLocked = false
            isShifted = false
            lastShiftTapTime = nil
        } else {
            let now = Date()
            if let previousTap = lastShiftTapTime,
               now.timeIntervalSince(previousTap) < 0.35 {
                isCapsLocked = true
                isShifted = true
                lastShiftTapTime = nil
            } else {
                isShifted.toggle()
                lastShiftTapTime = now
            }
        }
    }

    func toggleNumbers() {
        withAnimation(.snappy(duration: 0.18)) {
            showNumbers.toggle()
            showSymbols = false
        }
    }

    func toggleSymbols() {
        withAnimation(.snappy(duration: 0.18)) {
            showSymbols.toggle()
        }
    }

    func advanceToNextInputMode() {
        inputViewController?.advanceToNextInputMode()
    }

    func handleInputModeList(from sender: UIView, with event: UIEvent) {
        inputViewController?.handleInputModeList(from: sender, with: event)
    }

    func moveCursor(byCharacterOffset offset: Int) {
        guard offset != 0 else { return }
        invalidateTypingContext()
        KeyboardPerformance.measure("ProxyMoveCursor") {
            textDocumentProxy?.adjustTextPosition(byCharacterOffset: offset)
        }
    }

    // MARK: - Dictation

    func handleMurmurButtonTap() {
        refreshSharedState()
        guard hasFullAccess else {
            // A dead control teaches nothing; explain the missing switch.
            presentHandoffError(
                NSLocalizedString(
                    "Turn on Full Access for Murmur in Settings › General › Keyboard › Keyboards.",
                    comment: "Keyboard dictation requested without Full Access"
                )
            )
            return
        }
        if hasPendingDictation {
            _ = insertPendingDictationIfAvailable(confirmed: true)
            return
        }

        switch dictationPhase {
        case .recording, .paused:
            requestStop()
        case .preparing:
            // Nothing was confirmed for long enough to be useful; drop it and
            // start over instead of leaving a dead Start button.
            retryDictation()
        case .processing, .ready:
            break
        case .idle, .failed:
            triggerLightHaptic()
            openMurmurForDictation()
        }
    }

    @discardableResult
    func insertPendingDictationIfAvailable(confirmed: Bool = false) -> Bool {
        guard confirmed || !SharedDefaults.reviewBeforeInsertion else {
            refreshSharedState()
            return false
        }
        guard let payload = SharedDefaults.peekPendingTextPayload(),
              let activeSessionID,
              payload.sessionID == nil || payload.sessionID == activeSessionID,
              let consumed = SharedDefaults.consumePendingTextPayload()
        else {
            refreshSharedState()
            return false
        }

        triggerMediumHaptic()
        lastPressCommit = nil
        lastPressContext = nil
        insertIntoProxy(textForInsertion(consumed.text))
        SharedDefaults.clearDictationSession()
        self.activeSessionID = nil
        refreshSharedState()
        autoCapitalize()
        refreshSuggestions()
        confirmInsertion()
        return true
    }

    private func confirmInsertion() {
        showsInsertionConfirmation = true
        insertionConfirmationTask?.cancel()
        insertionConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled {
                self.showsInsertionConfirmation = false
            }
        }
    }

    private func requestStop() {
        guard let activeSessionID else { return }
        let wasPaused = dictationPhase == .paused
        pauseFallbackTask?.cancel()
        triggerMediumHaptic()
        // A pending fallback must never reopen the app now that the user has
        // stopped; it would pull them out of whatever they were typing in.
        warmFallbackTask?.cancel()
        warmFallbackTask = nil
        SharedDefaults.setDictationPhase(.processing, sessionID: activeSessionID)
        SharedDefaults.requestDictationStop(sessionID: activeSessionID)
        refreshSharedState()
        if wasPaused, let url = URL(string: "murmur://finish") { openContainingApp(url) }
    }

    /// Stops recording from the dictation panel and lets Murmur transcribe,
    /// clean up and insert the result.
    func finishDictation() {
        switch dictationPhase {
        case .recording, .paused:
            requestStop()
        case .ready:
            _ = insertPendingDictationIfAvailable(confirmed: true)
        case .preparing:
            // The app never confirmed recording. Release the microphone and let
            // the user start again rather than leaving the panel stuck.
            cancelDictation()
        default:
            break
        }
    }

    /// Drops the current dictation. Nothing is inserted into the document, and
    /// the container app is asked to release the microphone.
    func cancelDictation() {
        guard let sessionID = activeSessionID else {
            refreshSharedState()
            return
        }
        triggerMediumHaptic()
        suppressesAbandonmentNotice = true
        warmFallbackTask?.cancel()
        pauseFallbackTask?.cancel()

        SharedDefaults.clearPendingText()
        SharedDefaults.clearDictationContext()
        SharedDefaults.clearDictationSession()
        activeSessionID = nil

        // Sent after clearing: clearDictationSession() also resets the
        // persistent stop flag, which would cancel the request.
        SharedDefaults.requestDictationStop(sessionID: sessionID)
        refreshSharedState()
    }

    /// Consumes the flag set by `cancelDictation()` so the deliberate cancel is
    /// not reported back to the user as a failed dictation.
    func consumeAbandonmentSuppression() -> Bool {
        defer { suppressesAbandonmentNotice = false }
        return suppressesAbandonmentNotice
    }

    /// Retries a dictation that failed to start (busy microphone, interrupted
    /// session) without leaving the current app when that is possible.
    func retryDictation() {
        handoffError = nil
        warmFallbackTask?.cancel()
        if let activeSessionID {
            SharedDefaults.requestDictationStop(sessionID: activeSessionID)
        }
        SharedDefaults.clearPendingText()
        SharedDefaults.clearDictationSession()
        activeSessionID = nil
        dictationPhase = .idle
        suppressesAbandonmentNotice = false
        openMurmurForDictation()
    }

    /// Dismisses the failed-dictation panel without retrying.
    func dismissDictationError() {
        handoffError = nil
        warmFallbackTask?.cancel()
        warmFallbackTask = nil
        SharedDefaults.clearPendingText()
        SharedDefaults.clearDictationContext()
        SharedDefaults.clearDictationSession()
        SharedDefaults.setDictationRequested(false)
        activeSessionID = nil
        dictationPhase = .idle
        refreshSharedState()
    }

    private func textForInsertion(_ text: String) -> String {
        // The formatter decides the seam spacing when it can see the text
        // around the cursor; never second-guess a leading space it added.
        if text.first?.isWhitespace == true {
            return text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let previousCharacter = proxyContextBefore()?.last
        else {
            return text
        }

        let spacingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}"]
        let previousNeedsSeparation =
            previousCharacter.isLetter ||
            previousCharacter.isNumber ||
            spacingPunctuation.contains(previousCharacter)
        let insertedStartsInline = trimmed.first?.isLetter == true || trimmed.first?.isNumber == true
        return previousNeedsSeparation && insertedStartsInline ? " " + text : text
    }

    /// Opens the app without starting a dictation (the toolbar's menu button).
    func openMurmurApp() {
        guard let url = URL(string: "murmur://") else { return }
        openContainingApp(url)
    }

    func setFormattingStyle(_ style: String) {
        guard hasFullAccess, dictationPhase == .idle || dictationPhase == .failed else { return }
        SharedDefaults.formattingStyle = style
        refreshSharedState()
    }

    func setDictationLanguage(_ code: String) {
        guard hasFullAccess, dictationPhase == .idle || dictationPhase == .failed else { return }
        SharedDefaults.autoDetectLanguage = code == "auto"
        if code != "auto" {
            var languages = SharedDefaults.selectedLanguages.filter { $0 != code }
            languages.insert(code, at: 0)
            SharedDefaults.selectedLanguages = languages
        }
        refreshSharedState()
    }

    func toggleRecordingPause() {
        guard let sessionID = activeSessionID, dictationPhase == .recording || dictationPhase == .paused else { return }
        let desiredPause = dictationPhase != .paused
        SharedDefaults.requestPause(desiredPause, sessionID: sessionID)
        pauseFallbackTask?.cancel()
        if !desiredPause {
            // iOS can suspend the app while its engine is paused. Resume visibly if needed.
            pauseFallbackTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.activeSessionID == sessionID,
                      SharedDefaults.dictationState().phase == .paused,
                      let url = URL(string: "murmur://resume") else { return }
                self.openContainingApp(url)
            }
        }
    }

    func editPendingDictation() {
        guard let entryID = SharedDefaults.peekPendingTextPayload()?.entryID,
              let url = URL(string: "murmur://edit?id=\(entryID)") else { return }
        openContainingApp(url)
    }

    func openMurmurForDictation() {
        guard hasFullAccess else { return }

        // One fallback at a time: a timer left over from the previous request
        // could otherwise reopen the app while this one is already recording.
        warmFallbackTask?.cancel()
        warmFallbackTask = nil

        suppressesAbandonmentNotice = false

        // Hand the formatter the two things only the keyboard knows: which
        // kind of field this is, and the text around the cursor.
        SharedDefaults.setDictationContext(
            surface: dictationSurfaceHint,
            before: dictationSnippet(proxyContextBefore()),
            after: dictationSnippet(proxyContextAfter())
        )

        let sessionID = UUID().uuidString
        activeSessionID = sessionID
        SharedDefaults.beginDictationSession(sessionID: sessionID)
        SharedDefaults.setDictationRequested(true)

        // Always bring the app forward for a dictation. Starting audio from the
        // background raced the app's own start and left the keyboard on
        // "Starting…" with the microphone open and nothing to stop, so the
        // reliable path — the app records in the foreground — is the only path.
        guard let url = URL(string: "murmur://dictate") else { return }
        openContainingApp(url)
    }

    /// If the background app doesn't start recording within a couple of
    /// seconds, fall back to opening it — the old, always-works path.
    private func scheduleWarmFallback(for sessionID: String) {
        warmFallbackTask?.cancel()
        // While the model is loading the app legitimately takes longer to
        // begin recording, so give it much more room before opening it.
        let delay: Double = isModelWarm ? 2.5 : 20
        warmFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard stillNeedsApp(for: sessionID) else { return }

            // The app is alive but has not begun yet: nudge it once more and
            // give it a moment. Opening it here used to race its own start and
            // cancel it, which left nothing recording.
            if SharedDefaults.isAppAlive() {
                DarwinNotificationCenter.post(.dictationRequested)
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                guard stillNeedsApp(for: sessionID) else { return }
            }

            guard let url = URL(string: "murmur://dictate") else { return }
            openContainingApp(url)
        }
    }

    /// True only while the session exists and has not begun recording. A session
    /// that already moved on to processing (the user stopped before this fired)
    /// must never be reopened.
    private func stillNeedsApp(for sessionID: String) -> Bool {
        guard activeSessionID == sessionID else { return false }
        let phase = SharedDefaults.dictationState().phase
        return phase == .idle || phase == .preparing || phase == .failed
    }

    private func openContainingApp(_ url: URL) {
        // Prefer the public extension API. Some older iOS releases reject
        // opening a containing app from a keyboard, so retain the responder
        // fallback only when the supported path explicitly reports failure.
        guard let extensionContext = inputViewController?.extensionContext else {
            openContainingAppFallback(url)
            return
        }
        extensionContext.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    self.openContainingAppFallback(url)
                }
            }
        }
    }

    private func openContainingAppFallback(_ url: URL) {
        var responder: UIResponder? = inputViewController
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            // Try the selector-based approach for the host app
            let selector = sel_registerName("openURL:")
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }

        SharedDefaults.setDictationRequested(false)
        SharedDefaults.abandonDictationSession(
            reason: "Could not open Murmur. Please open the app manually."
        )
        SharedDefaults.clearDictationSession()
        activeSessionID = nil
        presentHandoffError("Could not open Murmur. Please open the app manually.")
    }
}
