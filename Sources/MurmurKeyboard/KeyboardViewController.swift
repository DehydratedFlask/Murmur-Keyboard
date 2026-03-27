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

        SharedDefaults.setKeyboardActive(true)

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
        checkForPendingText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Start a timer to periodically check for pending text
        // (handles the case where the app returns after dictation)
        startPendingTextTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPendingTextTimer()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        viewModel.textDocumentProxy = textDocumentProxy
    }

    // MARK: - Pending Text Handling

    private func checkForPendingText() {
        if let text = SharedDefaults.consumePendingText(), !text.isEmpty {
            textDocumentProxy.insertText(text)
        }
    }

    private func startPendingTextTimer() {
        stopPendingTextTimer()
        pendingTextTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
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

    /// The proxy through which the keyboard inserts/deletes text.
    var textDocumentProxy: UITextDocumentProxy?

    /// Reference to the input view controller (for advanceToNextInputMode).
    weak var inputViewController: UIInputViewController?

    // MARK: - Computed

    var isUppercase: Bool {
        isShifted || isCapsLocked
    }

    // MARK: - Actions

    func insertText(_ text: String) {
        let textToInsert = isUppercase ? text.uppercased() : text.lowercased()
        textDocumentProxy?.insertText(textToInsert)

        // Auto-unshift after typing a letter (unless caps lock)
        if isShifted && !isCapsLocked {
            isShifted = false
        }
    }

    func deleteBackward() {
        textDocumentProxy?.deleteBackward()
    }

    func insertSpace() {
        textDocumentProxy?.insertText(" ")
    }

    func insertReturn() {
        textDocumentProxy?.insertText("\n")
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
            DispatchQueue.main.async {
                guard let self else { return }
                if !success {
                    SharedDefaults.setDictationRequested(false)
                    self.handoffError = "Could not open Murmur. Please open the app manually."
                    // Auto-dismiss error after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.handoffError = nil
                    }
                }
            }
        }
    }
}
