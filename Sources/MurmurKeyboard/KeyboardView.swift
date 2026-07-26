import SwiftUI
import UIKit

private let keyboardAlternateLetters: [String: [String]] = [
    "a": ["a", "à", "á", "â", "ä", "æ", "ã", "å", "ā"],
    "c": ["c", "ç", "ć", "č"],
    "e": ["e", "è", "é", "ê", "ë", "ē", "ė", "ę"],
    "i": ["i", "î", "ï", "í", "ī", "į", "ì"],
    "l": ["l", "ł"],
    "n": ["n", "ñ", "ń"],
    "o": ["o", "ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
    "s": ["s", "ß", "ś", "š"],
    "u": ["u", "û", "ü", "ù", "ú", "ū"],
    "y": ["y", "ÿ"],
    "z": ["z", "ž", "ź", "ż"],
]
private let keyboardLeftEdgeKeys: Set<String> = [
    "Q", "A", "Z", "1", "-", "[", ".",
]
private let keyboardRightEdgeKeys: Set<String> = [
    "P", "L", "M", "0", "\"", "=", "'",
]

/// The main SwiftUI keyboard view — native iOS QWERTY layout with a
/// Murmur dictation button integrated into the predictive-text row.
struct KeyboardView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var backspaceLongPressed = false

    // MARK: - Native iOS Keyboard Layout Constants

    private let keySpacing: CGFloat = 6
    private var rowSpacing: CGFloat { verticalSizeClass == .compact ? 5 : 11 }
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 32 : 42 }
    private let edgePadding: CGFloat = 3
    private let middleRowInset: CGFloat = 18
    /// Height of Apple's predictive text / suggestion row
    private var predictionRowHeight: CGFloat {
        verticalSizeClass == .compact ? 30 : 36
    }

    // MARK: - Key Definitions

    private static let letterRow1 = ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
    private static let letterRow2 = ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
    private static let letterRow3 = ["Z", "X", "C", "V", "B", "N", "M"]

    private static let numberRow1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private static let numberRow2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
    private static let numberRow3 = [".", ",", "?", "!", "'"]

    private static let symbolRow1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    private static let symbolRow2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    private static let symbolRow3 = [".", ",", "?", "!", "'"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            banners
            predictionRow
            Rectangle()
                .fill(separatorColor)
                .frame(height: 0.5)
            glassKeyboardRows
        }
        .background { keyboardBackdrop }
        .animation(.snappy(duration: 0.18), value: viewModel.showNumbers)
        .animation(.snappy(duration: 0.18), value: viewModel.showSymbols)
    }

    @ViewBuilder
    private var glassKeyboardRows: some View {
        // Each key owns its glass surface. A single container around the entire
        // matrix causes adjacent caps to merge and can wash out glyph contrast
        // in the iOS 27 beta keyboard-extension renderer.
        keyboardRows
    }

    private var keyboardRows: some View {
        VStack(spacing: rowSpacing) {
            Group {
                if viewModel.showNumbers || viewModel.showSymbols {
                    numbersOrSymbolsLayout
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    lettersLayout
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            bottomRow
        }
        .padding(.horizontal, edgePadding)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    // MARK: - Banners (error / full-access warning)

    @ViewBuilder
    private var banners: some View {
        if let error = viewModel.handoffError {
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.85))
        }

    }

    // MARK: - Prediction Row (with Murmur logo button)

    /// Mimics Apple's predictive-text suggestion row.
    /// Center slot holds the Murmur dictation button; side slots are empty
    /// (like a keyboard with no active suggestions).
    private var predictionRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text(viewModel.hasFullAccess ? "On-device" : "Full Access")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(
                viewModel.hasFullAccess
                    ? Color.secondary
                    : Color.orange
            )
                .frame(maxWidth: .infinity)
                .frame(height: predictionRowHeight)

            Rectangle()
                .fill(separatorColor)
                .frame(width: 0.5, height: 18)

            Button {
                viewModel.handleMurmurButtonTap()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: dictationButtonImage)
                        .font(.system(size: 13, weight: .semibold))
                    Text(dictationButtonTitle)
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(murmurButtonColor)
                .frame(maxWidth: .infinity)
                .frame(height: predictionRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                !viewModel.hasFullAccess ||
                viewModel.dictationPhase == .preparing ||
                viewModel.dictationPhase == .processing
            )
            .accessibilityLabel(dictationButtonAccessibilityLabel)
            .accessibilityHint(dictationButtonAccessibilityHint)

            Rectangle()
                .fill(separatorColor)
                .frame(width: 0.5, height: 18)

            HStack(spacing: 4) {
                Circle()
                    .fill(dictationStatusColor)
                    .frame(width: 6, height: 6)
                Text(dictationStatusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: predictionRowHeight)
        }
        .background(predictionRowBackground)
    }

    private var dictationButtonImage: String {
        if viewModel.hasPendingDictation { return "checkmark.circle.fill" }
        switch viewModel.dictationPhase {
        case .recording: return "stop.fill"
        case .preparing, .processing: return "ellipsis"
        case .ready: return "checkmark.circle.fill"
        case .idle, .failed: return viewModel.isModelWarm ? "mic.fill" : "waveform"
        }
    }

    private var dictationButtonTitle: String {
        if viewModel.hasPendingDictation { return "Insert" }
        switch viewModel.dictationPhase {
        case .recording: return "Stop"
        case .preparing: return "Starting…"
        case .processing: return "Transcribing…"
        case .ready: return "Insert"
        case .idle, .failed: return "Murmur"
        }
    }

    private var dictationStatusTitle: String {
        switch viewModel.dictationPhase {
        case .recording: return "Listening"
        case .preparing: return "Starting"
        case .processing: return "Working"
        case .ready: return "Done"
        case .failed: return "Retry"
        case .idle: return viewModel.isModelWarm ? "Ready" : "Loading"
        }
    }

    private var dictationStatusColor: Color {
        switch viewModel.dictationPhase {
        case .recording: return .red
        case .preparing, .processing: return .orange
        case .ready: return .green
        case .failed: return .red
        case .idle: return viewModel.isModelWarm ? .green : .orange
        }
    }

    private var dictationButtonAccessibilityLabel: String {
        if viewModel.hasPendingDictation { return "Insert completed dictation" }
        switch viewModel.dictationPhase {
        case .recording: return "Stop Murmur dictation"
        case .preparing: return "Murmur dictation is starting"
        case .processing: return "Murmur is transcribing"
        case .ready: return "Insert completed dictation"
        case .idle, .failed: return "Start Murmur dictation"
        }
    }

    private var dictationButtonAccessibilityHint: String {
        if !viewModel.hasFullAccess {
            return "Enable Full Access to use dictation."
        }
        switch viewModel.dictationPhase {
        case .recording:
            return "Stops recording. Murmur will transcribe, clean up, and insert the result automatically."
        case .preparing, .processing:
            return "Please wait."
        case .ready:
            return "Inserts the completed text into this field."
        case .idle, .failed:
            return "Briefly opens Murmur so iOS can start microphone recording. Use the system back control to return here."
        }
    }

    // MARK: - Letters Layout (matches Apple QWERTY)

    private var lettersLayout: some View {
        VStack(spacing: rowSpacing) {
            HStack(spacing: keySpacing) {
                ForEach(Self.letterRow1, id: \.self) { key in
                    letterKey(key)
                }
            }

            HStack(spacing: keySpacing) {
                ForEach(Self.letterRow2, id: \.self) { key in
                    letterKey(key)
                }
            }
            .padding(.horizontal, middleRowInset)

            HStack(spacing: keySpacing) {
                shiftKey
                Spacer(minLength: 0)
                HStack(spacing: keySpacing) {
                    ForEach(Self.letterRow3, id: \.self) { key in
                        letterKey(key)
                    }
                }
                Spacer(minLength: 0)
                backspaceKey
            }
        }
    }

    // MARK: - Numbers/Symbols Layout

    private var numbersOrSymbolsLayout: some View {
        let row1 = viewModel.showSymbols ? Self.symbolRow1 : Self.numberRow1
        let row2 = viewModel.showSymbols ? Self.symbolRow2 : Self.numberRow2
        let row3 = viewModel.showSymbols ? Self.symbolRow3 : Self.numberRow3

        return VStack(spacing: rowSpacing) {
            HStack(spacing: keySpacing) {
                ForEach(row1, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: keySpacing) {
                ForEach(row2, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: keySpacing) {
                symbolToggleKey
                Spacer(minLength: 0)
                HStack(spacing: keySpacing) {
                    ForEach(row3, id: \.self) { key in
                        characterKey(key)
                    }
                }
                Spacer(minLength: 0)
                backspaceKey
            }
        }
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack(spacing: keySpacing) {
            numberToggleKey
            if viewModel.showGlobeKey {
                globeKey
            }
            spaceKey
            if let shortcut = contextualShortcut {
                characterKey(
                    shortcut,
                    fixedWidth: 42,
                    alternatives: contextualAlternatives
                )
            }
            returnKey
        }
    }

    // MARK: - Key Views

    private func letterKey(_ letter: String) -> some View {
        let displayLetter = viewModel.isUppercase ? letter : letter.lowercased()
        let alternatives = alternateLetters(for: displayLetter)
        return AlternateInputKey(
            displayText: displayLetter,
            alternatives: alternatives,
            isDarkMode: viewModel.isDarkMode,
            paletteAlignment: paletteAlignment(for: displayLetter),
            action: viewModel.insertAlternate
        ) {
            Text(displayLetter)
                .font(.system(size: 22.5, weight: .light))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background { keySurface() }
        }
        .foregroundStyle(keyTextColor)
        .accessibilityLabel(displayLetter)
        .accessibilityHint(alternatives.isEmpty ? "" : "Touch and hold for alternate characters.")
    }

    private func characterKey(
        _ character: String,
        fixedWidth: CGFloat? = nil,
        alternatives: [String]? = nil
    ) -> some View {
        let availableAlternatives = alternatives ?? alternateSymbols(for: character)
        return AlternateInputKey(
            displayText: character,
            alternatives: availableAlternatives,
            isDarkMode: viewModel.isDarkMode,
            paletteAlignment: fixedWidth == nil
                ? paletteAlignment(for: character)
                : .trailing,
            action: viewModel.insertCharacter
        ) {
            Text(character)
                .font(.system(size: 20.5, weight: .regular))
                .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
                .frame(width: fixedWidth)
                .frame(height: keyHeight)
                .background { keySurface() }
        }
        .foregroundStyle(keyTextColor)
        .accessibilityLabel(character)
        .accessibilityHint(availableAlternatives.isEmpty ? "" : "Touch and hold for alternate characters.")
    }

    private var shiftKey: some View {
        Button {
            viewModel.triggerMediumHaptic()
            viewModel.toggleShift()
        } label: {
            Image(systemName: viewModel.isCapsLocked ? "capslock.fill" :
                    (viewModel.isShifted ? "shift.fill" : "shift"))
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background {
                    keySurface(isAction: !(viewModel.isShifted || viewModel.isCapsLocked))
                }
        }
        .buttonStyle(IOSKeyboardPressStyle(isDarkMode: viewModel.isDarkMode))
        .foregroundStyle(keyTextColor)
        .accessibilityLabel(viewModel.isCapsLocked ? "Caps Lock on" : (viewModel.isShifted ? "Shift on" : "Shift"))
    }

    private var backspaceKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(keyTextColor)
            .frame(width: 42, height: keyHeight)
            .background { keySurface(isAction: true) }
            .onLongPressGesture(
                minimumDuration: 0.4,
                maximumDistance: 20,
                perform: {
                    viewModel.startContinuousDelete()
                    backspaceLongPressed = true
                },
                onPressingChanged: { pressing in
                    if pressing {
                        // finger down — wait
                    } else if backspaceLongPressed {
                        viewModel.stopContinuousDelete()
                        backspaceLongPressed = false
                    } else {
                        viewModel.deleteBackward()
                    }
                }
            )
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                viewModel.deleteBackward()
            }
    }

    private var numberToggleKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.toggleNumbers()
        } label: {
            Text(viewModel.showNumbers || viewModel.showSymbols ? "ABC" : "123")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 50, height: keyHeight)
                .background { keySurface(isAction: true) }
        }
        .buttonStyle(IOSKeyboardPressStyle(isDarkMode: viewModel.isDarkMode))
        .foregroundStyle(keyTextColor)
    }

    private var symbolToggleKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.toggleSymbols()
        } label: {
            Text(viewModel.showSymbols ? "123" : "#+=")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background { keySurface(isAction: true) }
        }
        .buttonStyle(IOSKeyboardPressStyle(isDarkMode: viewModel.isDarkMode))
        .foregroundStyle(keyTextColor)
    }

    private var globeKey: some View {
        InputModeSwitchButton(viewModel: viewModel)
            .frame(width: 42, height: keyHeight)
            .background { keySurface(isAction: true) }
            .foregroundStyle(keyTextColor)
        .accessibilityLabel("Switch keyboard")
        .accessibilityHint("Touch and hold to choose a keyboard.")
    }

    private var spaceKey: some View {
        SpaceInputButton(viewModel: viewModel)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background { keySurface() }
    }

    private var returnKey: some View {
        Button {
            viewModel.insertReturn()
        } label: {
            Group {
                if returnKeyUsesSymbol {
                    Image(systemName: returnKeySymbol)
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Text(returnKeyTitle)
                        .font(.system(size: 15.5, weight: .medium))
                }
            }
            .frame(width: 84, height: keyHeight)
            .background { keySurface(isAction: true, isProminent: returnKeyIsProminent) }
        }
        .buttonStyle(IOSKeyboardPressStyle(isDarkMode: viewModel.isDarkMode))
        .disabled(!viewModel.returnKeyEnabled)
        .opacity(viewModel.returnKeyEnabled ? 1 : 0.45)
        .foregroundStyle(returnKeyIsProminent ? .white : keyTextColor)
        .accessibilityLabel(returnKeyTitle)
    }

    private var contextualShortcut: String? {
        switch viewModel.keyboardType {
        case .URL, .webSearch:
            return "."
        case .emailAddress:
            return "@"
        default:
            return nil
        }
    }

    private var contextualAlternatives: [String] {
        switch viewModel.keyboardType {
        case .URL, .webSearch:
            return [".", ".com", ".net", ".org", ".edu"]
        default:
            return []
        }
    }

    private func alternateLetters(for letter: String) -> [String] {
        guard let values = keyboardAlternateLetters[letter.lowercased()] else {
            return []
        }
        guard letter == letter.uppercased() else {
            return values
        }
        return values.map { value in
            value == "ß" ? "ẞ" : value.uppercased()
        }
    }

    private func alternateSymbols(for symbol: String) -> [String] {
        switch symbol {
        case "0": return ["0", "°"]
        case "-": return ["-", "–", "—", "•"]
        case "/": return ["/", "\\"]
        case "$": return ["$", "¢", "€", "£", "¥", "₩"]
        case "&": return ["&", "§"]
        case "\"": return ["\"", "“", "”", "„", "«", "»"]
        case ".": return [".", "…"]
        case ",": return [",", "„"]
        case "?": return ["?", "¿"]
        case "!": return ["!", "¡"]
        case "'": return ["'", "’", "‘", "`"]
        case "=": return ["=", "≠", "≈"]
        case "%": return ["%", "‰"]
        default: return []
        }
    }

    private func paletteAlignment(for character: String) -> HorizontalAlignment {
        let normalized = character.uppercased()
        if keyboardLeftEdgeKeys.contains(normalized) {
            return .leading
        }
        if keyboardRightEdgeKeys.contains(normalized) {
            return .trailing
        }
        return .center
    }

    private var returnKeyTitle: String {
        switch viewModel.returnKeyType {
        case .go: return "go"
        case .google: return "Google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .yahoo: return "Yahoo"
        case .done: return "done"
        case .continue: return "continue"
        case .emergencyCall: return "emergency"
        default: return "return"
        }
    }

    private var returnKeyUsesSymbol: Bool {
        viewModel.returnKeyType == .go || viewModel.returnKeyType == .default
    }

    private var returnKeySymbol: String {
        viewModel.returnKeyType == .go ? "arrow.right" : "return"
    }

    private var returnKeyIsProminent: Bool {
        switch viewModel.returnKeyType {
        case .go, .search, .send, .done, .continue, .join, .next:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func keySurface(
        isAction: Bool = false,
        isProminent: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(
                    .regular
                        .tint(isProminent ? Color.accentColor : (isAction ? actionKeyTint : letterKeyTint))
                        .interactive(),
                    in: .rect(cornerRadius: 8)
                )
                .shadow(color: keyShadow.opacity(0.55), radius: 0.5, y: 1)
        } else {
            shape
                .fill(isProminent ? Color.accentColor : (isAction ? darkKeyBackground : lightKeyBackground))
                .overlay(shape.stroke(Color.white.opacity(viewModel.isDarkMode ? 0.08 : 0.45), lineWidth: 0.5))
                .shadow(color: keyShadow, radius: 0, y: 1)
        }
    }

    private var letterKeyTint: Color {
        // Keep a light glass cap even when a beta host reports the wrong
        // keyboardAppearance so black glyphs retain sufficient contrast.
        Color.white.opacity(viewModel.isDarkMode ? 0.30 : 0.42)
    }

    private var actionKeyTint: Color {
        Color.gray.opacity(viewModel.isDarkMode ? 0.30 : 0.18)
    }

    @ViewBuilder
    private var keyboardBackdrop: some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(viewModel.isDarkMode ? Color.black.opacity(0.22) : Color.white.opacity(0.10))
        } else {
            keyboardBackground
        }
    }

    // MARK: - Colors (match native iOS keyboard)

    private var keyboardBackground: Color {
        viewModel.isDarkMode
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    private var lightKeyBackground: Color {
        viewModel.isDarkMode
            ? Color(red: 0.72, green: 0.72, blue: 0.74)
            : .white
    }

    private var darkKeyBackground: Color {
        viewModel.isDarkMode
            ? Color(red: 0.52, green: 0.53, blue: 0.55)
            : Color(red: 0.68, green: 0.71, blue: 0.75)
    }

    private var keyTextColor: Color {
        .black
    }

    /// Prediction row background — slightly lighter than the keyboard tray,
    /// matching Apple's suggestion bar appearance.
    private var predictionRowBackground: Color {
        viewModel.isDarkMode
            ? Color(red: 0.14, green: 0.14, blue: 0.15)
            : Color(red: 0.86, green: 0.87, blue: 0.89)
    }

    /// Murmur button accent color in the prediction row
    private var murmurButtonColor: Color {
        if !viewModel.hasFullAccess { return .gray }
        return viewModel.isModelWarm ? Color.accentColor : .secondary
    }

    /// Thin dividers between prediction slots and below the prediction row
    private var separatorColor: Color {
        viewModel.isDarkMode
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    private var keyShadow: Color {
        viewModel.isDarkMode
            ? Color.black.opacity(0.4)
            : Color(red: 0.53, green: 0.54, blue: 0.56)
    }
}

private struct SpaceInputButton: UIViewRepresentable {
    let viewModel: KeyboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.setTitle("space", for: .normal)
        button.setTitleColor(.black, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.backgroundColor = .clear
        button.accessibilityLabel = "Space"
        button.accessibilityHint =
            "Touch and hold, then drag to move the cursor."
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.insertSpace),
            for: .touchUpInside
        )

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTrackpad(_:))
        )
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = true
        button.addGestureRecognizer(longPress)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        if !context.coordinator.isTracking {
            button.setTitle("space", for: .normal)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let viewModel: KeyboardViewModel
        var isTracking = false
        private var lastOffset = 0
        private var trackingStartX: CGFloat = 0

        init(viewModel: KeyboardViewModel) {
            self.viewModel = viewModel
        }

        @objc func insertSpace() {
            viewModel.insertSpace()
        }

        @objc func handleTrackpad(_ recognizer: UILongPressGestureRecognizer) {
            guard let button = recognizer.view as? UIButton else { return }
            switch recognizer.state {
            case .began:
                isTracking = true
                lastOffset = 0
                trackingStartX = recognizer.location(in: button).x
                button.setTitle("", for: .normal)
            case .changed:
                let currentX = recognizer.location(in: button).x
                let offset = Int((currentX - trackingStartX) / 12)
                let delta = offset - lastOffset
                if delta != 0 {
                    viewModel.moveCursor(byCharacterOffset: delta)
                    lastOffset = offset
                }
            case .ended, .cancelled, .failed:
                isTracking = false
                lastOffset = 0
                trackingStartX = 0
                button.setTitle("space", for: .normal)
            default:
                break
            }
        }
    }
}

private struct InputModeSwitchButton: UIViewRepresentable {
    let viewModel: KeyboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: "globe")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)),
            for: .normal
        )
        button.tintColor = .black
        button.accessibilityLabel = "Switch keyboard"
        button.accessibilityHint = "Touch and hold to choose a keyboard."
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.forwardInputModeEvent(_:event:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.tintColor = .black
    }

    @MainActor
    final class Coordinator: NSObject {
        let viewModel: KeyboardViewModel

        init(viewModel: KeyboardViewModel) {
            self.viewModel = viewModel
        }

        @objc func forwardInputModeEvent(_ sender: UIButton, event: UIEvent) {
            viewModel.handleInputModeList(from: sender, with: event)
        }
    }
}

private struct AlternateInputKey<Label: View>: View {
    let displayText: String
    let alternatives: [String]
    let isDarkMode: Bool
    let paletteAlignment: HorizontalAlignment
    let action: (String) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showsAlternatives = false

    var body: some View {
        ZStack(
            alignment: Alignment(
                horizontal: paletteAlignment,
                vertical: .top
            )
        ) {
            Button {
                guard !showsAlternatives else { return }
                action(displayText)
            } label: {
                label()
            }
            .buttonStyle(
                IOSKeyboardPressStyle(
                    isDarkMode: isDarkMode,
                    popupText: displayText
                )
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.38)
                    .onEnded { _ in
                        guard !alternatives.isEmpty else { return }
                        withAnimation(.snappy(duration: 0.14)) {
                            showsAlternatives = true
                        }
                    }
            )

            if showsAlternatives {
                HStack(spacing: 2) {
                    ForEach(alternatives, id: \.self) { alternative in
                        Button {
                            action(alternative)
                            withAnimation(.easeOut(duration: 0.1)) {
                                showsAlternatives = false
                            }
                        } label: {
                            Text(alternative)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.black)
                                .frame(minWidth: 31, minHeight: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(alternative)
                    }
                }
                .padding(4)
                .background {
                    if #available(iOS 26.0, *) {
                        Color.clear
                            .glassEffect(
                                .regular.tint(
                                    Color.white.opacity(isDarkMode ? 0.58 : 0.72)
                                ),
                                in: .rect(cornerRadius: 10)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                Color.white
                            )
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                .fixedSize()
                .offset(y: -42)
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .zIndex(showsAlternatives ? 100 : 0)
    }
}

private struct IOSKeyboardPressStyle: ButtonStyle {
    let isDarkMode: Bool
    var popupText: String?

    init(isDarkMode: Bool, popupText: String? = nil) {
        self.isDarkMode = isDarkMode
        self.popupText = popupText
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.035 : 1)
            .brightness(configuration.isPressed ? 0.07 : 0)
            .overlay(alignment: .top) {
                if configuration.isPressed, let popupText {
                    KeyPopup(text: popupText, isDarkMode: isDarkMode)
                        .offset(y: -42)
                        .transition(.scale(scale: 0.82, anchor: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.09), value: configuration.isPressed)
    }
}

private struct KeyPopup: View {
    let text: String
    let isDarkMode: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.black)
            .frame(width: 48, height: 58)
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                        .glassEffect(
                            .regular.tint(Color.white.opacity(isDarkMode ? 0.40 : 0.55)),
                            in: .rect(cornerRadius: 12)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                }
            }
            .shadow(color: .black.opacity(isDarkMode ? 0.45 : 0.22), radius: 4, y: 2)
    }
}
