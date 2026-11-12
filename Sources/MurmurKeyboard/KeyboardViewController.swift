import UIKit
import SwiftUI

/// Main controller for the MurmurKeyboard extension.
/// Uses UIHostingController to embed the SwiftUI keyboard view.
class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardView>?
    private var pendingTextTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?

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
        viewModel.inputViewController = self
        viewModel.hasFullAccess = hasFullAccess
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.prepareHaptics()
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits()
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
        // spacing) + 36 (globe footer) ≈ 315
        let desiredHeight = view.heightAnchor.constraint(equalToConstant: 318)
        desiredHeight.priority = .init(999)
        desiredHeight.isActive = true
        heightConstraint = desiredHeight
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        SharedDefaults.setFullAccessGranted(hasFullAccess)
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits()
        viewModel.restoreActiveDictationSession()
        viewModel.refreshSharedState()
        checkForPendingText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.autoCapitalize()
        viewModel.refreshTextTraits()
        viewModel.refreshSharedState()
        startDarwinObservers()
        startPendingTextTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDarwinObservers()
        stopPendingTextTimer()
        viewModel.stopContinuousDelete()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        heightConstraint?.constant = size.width > size.height ? 262 : 318
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.refreshTextTraits()
        viewModel.autoCapitalize()
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

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
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
    @Published var keyboardType: UIKeyboardType = .default
    @Published var returnKeyType: UIReturnKeyType = .default
    @Published var autocapitalizationType: UITextAutocapitalizationType = .sentences
    @Published var enablesReturnKeyAutomatically = false
    @Published var returnKeyEnabled = true
    @Published var isDarkMode = false
    /// Briefly true right after a finished dictation is inserted, so the
    /// toolbar can confirm that the text landed.
    @Published var showsInsertionConfirmation = false
    var activeSessionID: String?
    private var handoffDismissTask: Task<Void, Never>?
    private var insertionConfirmationTask: Task<Void, Never>?
    private var warmFallbackTask: Task<Void, Never>?

    /// Set when the user cancels from the keyboard, so the failure signal the
    /// container app sends back is not surfaced as an error banner.
    private var suppressesAbandonmentNotice = false

    // Haptic feedback generators
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Continuous backspace
    private var backspaceTimer: Timer?
    private var backspaceStartTime: Date?
    private var lastWordDeleteTime: Date?
    private var suppressNextBackspaceTap = false

    // Double-space period shortcut
    private var lastSpaceTime: Date?
    private var lastShiftTapTime: Date?

    /// The proxy through which the keyboard inserts/deletes text.
    var textDocumentProxy: UITextDocumentProxy?

    /// Reference to the input view controller (for advanceToNextInputMode).
    weak var inputViewController: UIInputViewController?

    // MARK: - Init

    func prepareHaptics() {
        lightHaptic.prepare()
        mediumHaptic.prepare()
    }

    func refreshSharedState() {
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
    }

    func restoreActiveDictationSession() {
        guard activeSessionID == nil else { return }
        activeSessionID = SharedDefaults.currentDictationSessionID()
    }

    func refreshTextTraits() {
        let newKeyboardType = textDocumentProxy?.keyboardType ?? .default
        let newReturnKeyType = textDocumentProxy?.returnKeyType ?? .default
        let newAutocapitalizationType =
            textDocumentProxy?.autocapitalizationType ?? .sentences
        let newDarkMode = textDocumentProxy?.keyboardAppearance == .dark
        let newEnablesReturnKeyAutomatically =
            textDocumentProxy?.enablesReturnKeyAutomatically ?? false
        let hasText = !(textDocumentProxy?.documentContextBeforeInput ?? "").isEmpty
        let newReturnKeyEnabled =
            !newEnablesReturnKeyAutomatically || hasText

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

    func presentHandoffError(_ message: String) {
        handoffError = message
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

    /// Whether the recording panel replaces the key grid.
    var showsDictationPanel: Bool {
        dictationPhase == .preparing
            || dictationPhase == .recording
            || dictationPhase == .processing
    }

    // MARK: - Haptics

    func triggerLightHaptic() {
        UIDevice.current.playInputClick()
        guard hasFullAccess else { return }
        lightHaptic.impactOccurred()
        lightHaptic.prepare()
    }

    func triggerMediumHaptic() {
        UIDevice.current.playInputClick()
        guard hasFullAccess else { return }
        mediumHaptic.impactOccurred()
        mediumHaptic.prepare()
    }

    // MARK: - Text Input

    func insertText(_ text: String) {
        triggerLightHaptic()
        let textToInsert =
            (isUppercase || autocapitalizationType == .allCharacters)
                ? text.uppercased()
                : text.lowercased()
        textDocumentProxy?.insertText(textToInsert)
        lastSpaceTime = nil

        // Auto-unshift after typing a letter (unless caps lock)
        if isShifted &&
            !isCapsLocked &&
            autocapitalizationType != .allCharacters {
            isShifted = false
        }
    }

    func insertCharacter(_ character: String) {
        triggerLightHaptic()
        textDocumentProxy?.insertText(character)
        lastSpaceTime = nil
    }

    func insertAlternate(_ character: String) {
        triggerLightHaptic()
        textDocumentProxy?.insertText(character)
        lastSpaceTime = nil
        if isShifted && !isCapsLocked {
            isShifted = false
        }
    }

    func deleteBackward() {
        if suppressNextBackspaceTap {
            suppressNextBackspaceTap = false
            return
        }
        triggerMediumHaptic()
        textDocumentProxy?.deleteBackward()
        lastSpaceTime = nil
    }

    func insertSpace() {
        triggerLightHaptic()

        // Double-space period shortcut (matches Apple behavior)
        let now = Date()
        let context = textDocumentProxy?.documentContextBeforeInput ?? ""
        if let last = lastSpaceTime,
           now.timeIntervalSince(last) < 0.3,
           canReplaceDoubleSpace(in: context) {
            textDocumentProxy?.deleteBackward()
            textDocumentProxy?.insertText(". ")
            lastSpaceTime = nil
            autoCapitalize()
            return
        }

        textDocumentProxy?.insertText(" ")
        lastSpaceTime = now
        autoCapitalize()
    }

    func insertReturn() {
        triggerMediumHaptic()
        textDocumentProxy?.insertText("\n")
        lastSpaceTime = nil
        autoCapitalize()
    }

    // MARK: - Auto-capitalization (matches Apple behavior)

    func autoCapitalize() {
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

        let context = textDocumentProxy?.documentContextBeforeInput ?? ""
        if autocapitalizationType == .words {
            let shouldShift =
                context.isEmpty ||
                context.last?.isWhitespace == true ||
                context.last?.isNewline == true
            if isShifted != shouldShift { isShifted = shouldShift }
            return
        }

        let trimmed = context.trimmingCharacters(in: .whitespaces)
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
        suppressNextBackspaceTap = true
        triggerMediumHaptic()
        textDocumentProxy?.deleteBackward()
        backspaceStartTime = Date()
        lastWordDeleteTime = nil
        lastSpaceTime = nil
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.backspaceStartTime else { return }
                let now = Date()
                let elapsed = now.timeIntervalSince(start)
                if elapsed > 1.6 {
                    if self.lastWordDeleteTime == nil ||
                        now.timeIntervalSince(self.lastWordDeleteTime!) >= 0.24 {
                        self.deleteWordBackward()
                        self.lastWordDeleteTime = now
                    }
                } else if elapsed > 0.12 {
                    self.textDocumentProxy?.deleteBackward()
                }
            }
        }
    }

    func stopContinuousDelete() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceStartTime = nil
        lastWordDeleteTime = nil
    }

    private func deleteWordBackward() {
        guard let proxy = textDocumentProxy, let context = proxy.documentContextBeforeInput, !context.isEmpty else {
            textDocumentProxy?.deleteBackward()
            return
        }
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
        textDocumentProxy?.adjustTextPosition(byCharacterOffset: offset)
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
            _ = insertPendingDictationIfAvailable()
            return
        }

        switch dictationPhase {
        case .recording:
            requestStop()
        case .preparing, .processing, .ready:
            break
        case .idle, .failed:
            triggerLightHaptic()
            openMurmurForDictation()
        }
    }

    @discardableResult
    func insertPendingDictationIfAvailable() -> Bool {
        guard let payload = SharedDefaults.peekPendingTextPayload(),
              let activeSessionID,
              payload.sessionID == nil || payload.sessionID == activeSessionID,
              let consumed = SharedDefaults.consumePendingTextPayload()
        else {
            refreshSharedState()
            return false
        }

        triggerMediumHaptic()
        textDocumentProxy?.insertText(textForInsertion(consumed.text))
        SharedDefaults.clearDictationSession()
        self.activeSessionID = nil
        refreshSharedState()
        autoCapitalize()
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
        triggerMediumHaptic()
        SharedDefaults.setDictationPhase(.processing, sessionID: activeSessionID)
        SharedDefaults.requestDictationStop(sessionID: activeSessionID)
        refreshSharedState()
    }

    /// Stops recording from the dictation panel and lets Murmur transcribe,
    /// clean up and insert the result.
    func finishDictation() {
        guard dictationPhase == .recording else { return }
        requestStop()
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

        SharedDefaults.clearPendingText()
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

    private func textForInsertion(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let previousCharacter = textDocumentProxy?.documentContextBeforeInput?.last
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

    func openMurmurForDictation() {
        guard hasFullAccess else { return }

        suppressesAbandonmentNotice = false
        let sessionID = UUID().uuidString
        activeSessionID = sessionID
        SharedDefaults.beginDictationSession(sessionID: sessionID)
        SharedDefaults.setDictationRequested(true)

        // Warm session: the app is still running and the user's Session
        // duration has not expired, so it can start recording in the
        // background without us leaving the current app.
        if SharedDefaults.isWarmSessionActive(), SharedDefaults.isAppAlive() {
            DarwinNotificationCenter.post(.dictationRequested)
            scheduleWarmFallback(for: sessionID)
            return
        }

        guard let url = URL(string: "murmur://dictate") else { return }
        openContainingApp(url)
    }

    /// If the background app doesn't start recording within a couple of
    /// seconds, fall back to opening it — the old, always-works path.
    private func scheduleWarmFallback(for sessionID: String) {
        warmFallbackTask?.cancel()
        warmFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            guard activeSessionID == sessionID else { return }
            guard SharedDefaults.dictationState().phase != .recording else { return }
            guard let url = URL(string: "murmur://dictate") else { return }
            openContainingApp(url)
        }
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
