import UIKit
import SwiftUI

/// Main controller for the MurmurKeyboard extension.
/// Uses UIHostingController to embed the SwiftUI keyboard view.
class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardView>?
    private var pendingTextTimer: Timer?

    private let dictationTimeout: TimeInterval = 75

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
        // 36 (prediction row) + 0.5 (separator) + 8 (top pad) + 4×42 (key rows)
        // + 3×11 (row spacing) + 3 (bottom pad) ≈ 282
        let desiredHeight = view.heightAnchor.constraint(equalToConstant: 282)
        desiredHeight.priority = .init(999)
        desiredHeight.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        SharedDefaults.setFullAccessGranted(hasFullAccess)
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.autoCapitalize()
        viewModel.refreshSharedState()
        checkForPendingText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.showGlobeKey = needsInputModeSwitchKey
        viewModel.autoCapitalize()
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

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        viewModel.textDocumentProxy = textDocumentProxy
        viewModel.hasFullAccess = hasFullAccess
        viewModel.autoCapitalize()
        viewModel.refreshSharedState()
    }

    // MARK: - Pending Text Handling

    private func checkForPendingText() {
        viewModel.refreshSharedState()

        if let payload = SharedDefaults.peekPendingTextPayload(),
           let activeSessionID = viewModel.activeSessionID,
           payload.sessionID == nil || payload.sessionID == activeSessionID,
           let consumed = SharedDefaults.consumePendingTextPayload() {
            textDocumentProxy.insertText(textForInsertion(consumed.text))
            SharedDefaults.clearDictationSession()
            viewModel.activeSessionID = nil
            viewModel.refreshSharedState()
            viewModel.autoCapitalize()
            return
        }

        if let abandoned = SharedDefaults.consumeAbandonedDictationSession() {
            if abandoned.sessionID == nil || abandoned.sessionID == viewModel.activeSessionID {
                SharedDefaults.clearDictationSession()
                viewModel.activeSessionID = nil
                viewModel.presentHandoffError(abandoned.reason ?? "Dictation ended before a transcription was ready.")
                viewModel.refreshSharedState()
                return
            }
        }

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
    }

    private func stopDarwinObservers() {
        DarwinNotificationCenter.removeObserver(.transcriptionReady)
        DarwinNotificationCenter.removeObserver(.dictationAbandoned)
        DarwinNotificationCenter.removeObserver(.modelStateChanged)
    }

    private func startPendingTextTimer() {
        stopPendingTextTimer()
        // Fallback safety-net poll at a relaxed interval — Darwin notifications
        // handle the fast path; this catches edge cases where a notification is missed.
        pendingTextTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
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
    @Published var dictationStatusText = "Loading"
    var activeSessionID: String?
    private var handoffDismissTask: Task<Void, Never>?

    // Haptic feedback generators
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Continuous backspace
    private var backspaceTimer: Timer?
    private var backspaceStartTime: Date?
    private var suppressNextBackspaceTap = false

    // Double-space period shortcut
    private var lastSpaceTime: Date?

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
        isModelWarm = SharedDefaults.isModelReady()
        dictationStatusText = isModelWarm ? "Ready" : "Loading"
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

    // MARK: - Text Input

    func insertText(_ text: String) {
        triggerLightHaptic()
        let textToInsert = isUppercase ? text.uppercased() : text.lowercased()
        textDocumentProxy?.insertText(textToInsert)
        lastSpaceTime = nil

        // Auto-unshift after typing a letter (unless caps lock)
        if isShifted && !isCapsLocked {
            isShifted = false
        }
    }

    func insertCharacter(_ character: String) {
        triggerLightHaptic()
        textDocumentProxy?.insertText(character)
        lastSpaceTime = nil
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
                    self.deleteWordBackward()
                } else if elapsed > 0.5 {
                    self.textDocumentProxy?.deleteBackward()
                }
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
        } else if isShifted {
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

    // MARK: - Dictation

    func openMurmurForDictation() {
        guard hasFullAccess else { return }

        let sessionID = UUID().uuidString
        activeSessionID = sessionID
        SharedDefaults.beginDictationSession(sessionID: sessionID)
        SharedDefaults.setDictationRequested(true)
        // Signal the main app instantly via Darwin notification
        DarwinNotificationCenter.post(.dictationRequested)

        guard let url = URL(string: "murmur://dictate") else { return }

        // Keyboard extensions can't use extensionContext.open() reliably.
        // Use the UIResponder chain to reach UIApplication.shared.open().
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

        // Fallback: try extensionContext (may fail on newer iOS)
        inputViewController?.extensionContext?.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    SharedDefaults.setDictationRequested(false)
                    SharedDefaults.abandonDictationSession(reason: "Could not open Murmur. Please open the app manually.")
                    SharedDefaults.clearDictationSession()
                    self.activeSessionID = nil
                    self.presentHandoffError("Could not open Murmur. Please open the app manually.")
                }
            }
        }
    }
}
