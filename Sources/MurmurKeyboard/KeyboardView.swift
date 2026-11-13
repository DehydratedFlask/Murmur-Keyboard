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

/// The main SwiftUI keyboard view — native iOS QWERTY layout with a
/// Murmur dictation button integrated into the predictive-text row.
struct KeyboardView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Murmur's accent, matching the container app so the keyboard reads as
    /// the same product rather than a generic extension.
    private let murmurAccent = Color(red: 0.39, green: 0.28, blue: 0.95)

    // MARK: - Native iOS Keyboard Layout Constants

    private let keySpacing: CGFloat = 6
    private var rowSpacing: CGFloat { verticalSizeClass == .compact ? 7 : 10 }
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 36 : 46 }
    private let edgePadding: CGFloat = 6
    private let middleRowInset: CGFloat = 20
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
            if viewModel.showsDictationPanel {
                dictationPanel
                    .transition(.opacity)
            } else {
                toolbarRow
                keyboardRows
            }
        }
        // Fill the height the system gave the input view. Without this the
        // content only reaches its ideal height and the host app shows through
        // a strip under the bottom key row.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { keyboardBackdrop }
        // One flat keyboard surface: no inset card, so there is no seam between
        // the keys and the area around them. Key popups are drawn by the keys
        // themselves, so nothing here can clip them.
        .animation(.snappy(duration: 0.18), value: viewModel.showNumbers)
        .animation(.snappy(duration: 0.18), value: viewModel.showSymbols)
        .animation(.snappy(duration: 0.24), value: viewModel.showsDictationPanel)
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

    // MARK: - Toolbar Row

    /// Floating chrome inside the keyboard card: a quiet status line on the
    /// left and the white microphone pill on the right, as in Amical's
    /// keyboard.
    private var toolbarRow: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.openMurmurApp()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(toolbarForeground)
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Murmur")
            .accessibilityHint("Opens the Murmur app.")

            if let suggestion = viewModel.suggestions.first {
                suggestionChip(suggestion)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)

            dictationPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(height: predictionRowHeight + 12)
    }

    /// The correction the keyboard would make, shown before it happens — the
    /// same job Apple's prediction bar does. Tapping it applies it immediately.
    private func suggestionChip(_ suggestion: String) -> some View {
        Button {
            viewModel.applySuggestion(suggestion)
        } label: {
            Text(suggestion)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(toolbarForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 12)
                .frame(height: dictationPillHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            viewModel.isDarkMode
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.06)
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Replace with \(suggestion)")
        .accessibilityHint("Fixes the word you are typing.")
    }

    private var toolbarForeground: Color {
        viewModel.isDarkMode ? .white : .black
    }

    /// The white pill from Amical's toolbar, labelled Start and carrying
    /// Murmur's waveform mark. It becomes an accent "Insert" pill when a result
    /// is waiting.
    private var dictationPill: some View {
        Button {
            viewModel.handleMurmurButtonTap()
        } label: {
            HStack(spacing: 6) {
                Text(dictationPillTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(dictationButtonGlyph)
                Image(systemName: viewModel.hasPendingDictation ? "checkmark" : "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(viewModel.hasPendingDictation ? Color.white : murmurAccent)
            }
            .padding(.horizontal, 16)
            .frame(height: dictationPillHeight)
            .background(Capsule(style: .continuous).fill(dictationPillFill))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DictationButtonPressStyle())
        .accessibilityLabel(dictationButtonAccessibilityLabel)
        .accessibilityHint(dictationButtonAccessibilityHint)
    }

    private var dictationPillTitle: String {
        if viewModel.hasPendingDictation { return "Insert" }
        return "Start"
    }

    private var dictationPillHeight: CGFloat {
        verticalSizeClass == .compact ? 30 : 36
    }

    private var dictationPillFill: Color {
        if viewModel.hasPendingDictation { return murmurAccent }
        if !viewModel.hasFullAccess {
            return viewModel.isDarkMode
                ? Color.white.opacity(0.14)
                : Color.white.opacity(0.60)
        }
        return .white
    }

    private var dictationButtonGlyph: Color {
        if viewModel.hasPendingDictation { return .white }
        if !viewModel.hasFullAccess {
            return viewModel.isDarkMode ? .white.opacity(0.50) : .black.opacity(0.35)
        }
        return .black
    }

    private var toolbarStatusTitle: String {
        if viewModel.showsInsertionConfirmation { return "Inserted" }
        if !viewModel.hasFullAccess { return "Full Access" }
        if viewModel.hasPendingDictation { return "Ready to insert" }
        if !viewModel.isModelWarm { return "Warming up" }
        return "On-device"
    }

    private var toolbarStatusIcon: String {
        if viewModel.showsInsertionConfirmation { return "checkmark.circle.fill" }
        if !viewModel.hasFullAccess { return "exclamationmark.triangle.fill" }
        if viewModel.hasPendingDictation { return "checkmark.circle.fill" }
        return "lock.shield"
    }

    private var toolbarStatusColor: Color {
        if viewModel.showsInsertionConfirmation { return .green }
        if !viewModel.hasFullAccess { return .orange }
        if viewModel.hasPendingDictation { return .green }
        return .secondary
    }

    private var dictationButtonAccessibilityLabel: String {
        if viewModel.hasPendingDictation { return "Insert completed dictation" }
        return viewModel.isModelWarm ? "Start Murmur dictation" : "Murmur is warming up"
    }

    private var dictationButtonAccessibilityHint: String {
        if !viewModel.hasFullAccess {
            return "Enable Full Access in Settings to dictate with Murmur."
        }
        if viewModel.hasPendingDictation {
            return "Puts the finished text into this field."
        }
        return "Briefly opens Murmur so iOS can start the microphone. Come back here when you have finished speaking."
    }

    // MARK: - Dictation Panel

    /// Full-width recording surface shown while Murmur owns the microphone.
    /// Cancel on the left, confirm on the right, live waveform in the middle —
    /// the arrangement Wispr Flow uses, minus its live transcript.
    private var dictationPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                panelControl(
                    systemImage: "xmark",
                    isPrimary: false,
                    enabled: true,
                    label: viewModel.dictationPhase == .failed ? "Close" : "Cancel dictation",
                    hint: viewModel.dictationPhase == .failed
                        ? "Dismisses this message."
                        : "Stops this dictation without inserting any text."
                ) {
                    if viewModel.dictationPhase == .failed {
                        viewModel.dismissDictationError()
                    } else {
                        viewModel.cancelDictation()
                    }
                }

                Spacer(minLength: 0)

                panelControl(
                    systemImage: viewModel.dictationPhase == .failed ? "arrow.clockwise" : "checkmark",
                    isPrimary: true,
                    enabled: viewModel.dictationPhase == .recording
                        || viewModel.dictationPhase == .preparing
                        || viewModel.dictationPhase == .failed,
                    label: viewModel.dictationPhase == .failed ? "Try again" : "Finish dictation",
                    hint: viewModel.dictationPhase == .failed
                        ? "Releases the microphone and starts again."
                        : "Murmur transcribes, cleans up and inserts the result."
                ) {
                    if viewModel.dictationPhase == .failed {
                        viewModel.retryDictation()
                    } else {
                        viewModel.finishDictation()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            Spacer(minLength: 0)

            panelStatus

            Spacer(minLength: 0)

            panelFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    @ViewBuilder
    private var panelStatus: some View {
        VStack(spacing: 12) {
            switch viewModel.dictationPhase {
            case .processing:
                ProgressView()
                    .tint(murmurAccent)
                    .scaleEffect(1.25)
                    .frame(height: 56)
            default:
                ListeningWaveform(
                    isActive: viewModel.dictationPhase == .recording,
                    tint: panelForeground
                )
            }

            VStack(spacing: 4) {
                Text(panelTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panelForeground)

                if let detail = panelDetail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(panelForeground.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 28)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var panelTitle: String {
        switch viewModel.dictationPhase {
        case .preparing: return "Starting…"
        case .processing: return "Transcribing…"
        case .failed: return "Couldn't start"
        case .recording, .ready, .idle: return "Listening"
        }
    }

    private var panelDetail: String? {
        switch viewModel.dictationPhase {
        case .preparing:
            return NSLocalizedString(
                "Getting the microphone ready",
                comment: "Keyboard dictation panel detail while preparing"
            )
        case .recording:
            return NSLocalizedString(
                "On-device microphone",
                comment: "Keyboard dictation panel detail while listening"
            )
        case .processing:
            return NSLocalizedString(
                "Turning speech into text",
                comment: "Keyboard dictation panel detail while transcribing"
            )
        case .idle, .ready:
            return nil
        case .failed:
            return viewModel.handoffError ?? "Tap the arrow to try again."
        }
    }

    private var panelFooter: some View {
        HStack(spacing: 12) {
            if viewModel.showGlobeKey {
                Button {
                    viewModel.advanceToNextInputMode()
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 17))
                        .foregroundStyle(panelForeground.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next keyboard")
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                Text("Murmur")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(panelForeground.opacity(0.4))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .frame(height: 38)
    }

    private func panelControl(
        systemImage: String,
        isPrimary: Bool,
        enabled: Bool,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        let diameter: CGFloat = verticalSizeClass == .compact ? 38 : 46
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.36, weight: .semibold))
                .foregroundStyle(controlGlyphColor(isPrimary: isPrimary))
                .frame(width: diameter, height: diameter)
                .background {
                    chromeSurface(
                        Circle(),
                        tint: controlTint(isPrimary: isPrimary)
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(PanelControlPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func controlTint(isPrimary: Bool) -> Color {
        isPrimary ? .white : Color(red: 0.13, green: 0.13, blue: 0.14)
    }

    private func controlGlyphColor(isPrimary: Bool) -> Color {
        isPrimary ? .black : .white
    }

    private var panelForeground: Color {
        viewModel.isDarkMode
            ? Color.white.opacity(0.92)
            : Color(red: 0.22, green: 0.22, blue: 0.24)
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

    /// Equal-width side keys keep the space bar exactly centred on screen.
    private var bottomSideKeyWidth: CGFloat { 92 }

    private var bottomRow: some View {
        HStack(spacing: keySpacing) {
            numberToggleKey
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

    // Every key below is a UIKit view (see KeyboardKey.swift) rather than a
    // SwiftUI Button or a drag gesture, so a fast tap can never be dropped and
    // the click lands on touch-down, as on Apple's keyboard.

    private func letterKey(_ letter: String) -> some View {
        let displayLetter = viewModel.isUppercase ? letter : letter.lowercased()
        let alternatives = alternateLetters(for: displayLetter)
        return KeyboardKey(
            style: KeyboardKeyStyle(
                title: displayLetter,
                font: .systemFont(ofSize: 24, weight: .light),
                glyphColor: keyTextUIColor,
                capColor: letterCapUIColor,
                pressedCapColor: letterPressedCapUIColor,
                showsPopup: true,
                alternatives: alternatives,
                insertText: displayLetter,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: displayLetter,
                accessibilityHint: alternatives.isEmpty
                    ? nil
                    : "Touch and hold for alternate characters."
            ),
            onTouchDown: { viewModel.triggerLightHaptic() },
            onInsert: { viewModel.insertAlternate($0) },
            onSelectionChange: { viewModel.triggerSelectionHaptic() },
            onRetract: { viewModel.retractLastKeyPress() }
        )
        .frame(maxWidth: .infinity)
        .frame(height: keyHeight)
    }

    private func characterKey(
        _ character: String,
        fixedWidth: CGFloat? = nil,
        alternatives: [String]? = nil
    ) -> some View {
        let availableAlternatives = alternatives ?? alternateSymbols(for: character)
        return KeyboardKey(
            style: KeyboardKeyStyle(
                title: character,
                font: .systemFont(ofSize: 22, weight: .regular),
                glyphColor: keyTextUIColor,
                capColor: letterCapUIColor,
                pressedCapColor: letterPressedCapUIColor,
                showsPopup: true,
                alternatives: availableAlternatives,
                insertText: character,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: character,
                accessibilityHint: availableAlternatives.isEmpty
                    ? nil
                    : "Touch and hold for alternate characters."
            ),
            onTouchDown: { viewModel.triggerLightHaptic() },
            onInsert: { viewModel.insertCharacter($0) },
            onSelectionChange: { viewModel.triggerSelectionHaptic() },
            onRetract: { viewModel.retractLastKeyPress() }
        )
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
        .frame(width: fixedWidth)
        .frame(height: keyHeight)
    }

    private var shiftKey: some View {
        KeyboardKey(
            style: KeyboardKeyStyle(
                symbolName: shiftSymbolName,
                glyphColor: keyTextUIColor,
                capColor: actionCapUIColor,
                pressedCapColor: actionPressedCapUIColor,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: shiftAccessibilityLabel
            ),
            onTouchDown: { viewModel.triggerMediumHaptic() },
            onTap: { viewModel.toggleShift() }
        )
        .frame(width: 46)
        .frame(height: keyHeight)
    }

    private var shiftSymbolName: String {
        if viewModel.isCapsLocked { return "capslock.fill" }
        return viewModel.isShifted ? "shift.fill" : "shift"
    }

    private var shiftAccessibilityLabel: String {
        if viewModel.isCapsLocked { return "Caps Lock on" }
        return viewModel.isShifted ? "Shift on" : "Shift"
    }

    private var backspaceKey: some View {
        KeyboardKey(
            style: KeyboardKeyStyle(
                symbolName: "delete.left",
                glyphColor: keyTextUIColor,
                capColor: actionCapUIColor,
                pressedCapColor: actionPressedCapUIColor,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: "Delete",
                accessibilityHint: "Touch and hold to delete faster."
            ),
            onTouchDown: { viewModel.startContinuousDelete() },
            onTouchEnd: { viewModel.stopContinuousDelete() }
        )
        .frame(width: 46)
        .frame(height: keyHeight)
    }

    private var numberToggleKey: some View {
        KeyboardKey(
            style: KeyboardKeyStyle(
                title: viewModel.showNumbers || viewModel.showSymbols ? "ABC" : "123",
                font: .systemFont(ofSize: 16, weight: .medium),
                glyphColor: keyTextUIColor,
                capColor: actionCapUIColor,
                pressedCapColor: actionPressedCapUIColor,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: viewModel.showNumbers || viewModel.showSymbols
                    ? "Letters"
                    : "Numbers"
            ),
            onTouchDown: { viewModel.triggerLightHaptic() },
            onTap: { viewModel.toggleNumbers() }
        )
        .frame(width: bottomSideKeyWidth)
        .frame(height: keyHeight)
    }

    private var symbolToggleKey: some View {
        KeyboardKey(
            style: KeyboardKeyStyle(
                title: viewModel.showSymbols ? "123" : "#+=",
                font: .systemFont(ofSize: 15, weight: .medium),
                glyphColor: keyTextUIColor,
                capColor: actionCapUIColor,
                pressedCapColor: actionPressedCapUIColor,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: viewModel.showSymbols ? "Numbers" : "Symbols"
            ),
            onTouchDown: { viewModel.triggerLightHaptic() },
            onTap: { viewModel.toggleSymbols() }
        )
        .frame(width: 46)
        .frame(height: keyHeight)
    }

    private var spaceKey: some View {
        SpaceInputButton(viewModel: viewModel)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background { keySurface() }
    }

    private var returnKey: some View {
        KeyboardKey(
            style: KeyboardKeyStyle(
                title: returnKeyUsesSymbol ? "" : returnKeyTitle,
                symbolName: returnKeyUsesSymbol ? returnKeySymbol : nil,
                font: .systemFont(ofSize: 15.5, weight: .medium),
                symbolPointSize: 17,
                symbolWeight: .semibold,
                glyphColor: returnKeyIsProminent ? .white : keyTextUIColor,
                capColor: returnKeyIsProminent ? prominentCapUIColor : actionCapUIColor,
                pressedCapColor: returnKeyIsProminent
                    ? prominentPressedCapUIColor
                    : actionPressedCapUIColor,
                isEnabled: viewModel.returnKeyEnabled,
                isDarkMode: viewModel.isDarkMode,
                accessibilityLabel: returnKeyTitle
            ),
            onTouchDown: { viewModel.triggerMediumHaptic() },
            onTap: { viewModel.insertReturn() }
        )
        .frame(width: bottomSideKeyWidth)
        .frame(height: keyHeight)
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
        // Borderless, translucent caps sitting on the glass tray. No stroke and
        // no drop shadow: the key reads as a tonal shift in the glass rather
        // than a separate tile.
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(
                isProminent
                    ? murmurAccent
                    : (isAction ? darkKeyBackground : lightKeyBackground)
            )
    }

    /// On iOS 26 the system already draws the keyboard's Liquid Glass plate, so
    /// we paint nothing there and let Apple's surface (and its edge) be the
    /// only one on screen. Earlier systems get a translucent material.
    @ViewBuilder
    private var keyboardBackdrop: some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    viewModel.isDarkMode
                        ? Color.black.opacity(0.42)
                        : Color.white.opacity(0.20)
                )
        }
    }

    // MARK: - Palette

    private var keyboardBackground: Color {
        viewModel.isDarkMode
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.82, green: 0.83, blue: 0.85)
    }

    /// Letter caps: a light film of glass, so the tray tone shows through.
    private var lightKeyBackground: Color {
        viewModel.isDarkMode
            ? Color.white.opacity(0.11)
            : Color.white.opacity(0.62)
    }

    /// Modifier keys: the faintest possible tint difference, no outline.
    private var darkKeyBackground: Color {
        viewModel.isDarkMode
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.05)
    }

    private var keyTextColor: Color {
        viewModel.isDarkMode ? .white : .black
    }

    // The UIKit keys take their colours directly, so the same palette is
    // published once in Color and once in UIColor.

    private var keyTextUIColor: UIColor {
        viewModel.isDarkMode ? .white : .black
    }

    private var letterCapUIColor: UIColor {
        UIColor(lightKeyBackground)
    }

    private var letterPressedCapUIColor: UIColor {
        viewModel.isDarkMode
            ? UIColor.white.withAlphaComponent(0.26)
            : UIColor.black.withAlphaComponent(0.12)
    }

    private var actionCapUIColor: UIColor {
        UIColor(darkKeyBackground)
    }

    private var actionPressedCapUIColor: UIColor {
        viewModel.isDarkMode
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.14)
    }

    private var prominentCapUIColor: UIColor {
        UIColor(murmurAccent)
    }

    private var prominentPressedCapUIColor: UIColor {
        UIColor(murmurAccent).withAlphaComponent(0.82)
    }

    /// Shared Liquid Glass chrome for the microphone, panel controls and other
    /// small controls, so they read as the same material as the tray.
    @ViewBuilder
    private func chromeSurface<S: Shape>(
        _ shape: S,
        tint: Color
    ) -> some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(
                    .regular
                        .tint(tint)
                        .interactive(),
                    in: shape
                )
        } else {
            shape.fill(tint)
        }
    }
}

/// A control whose touch area reaches into the gap around it, so the space bar
/// has no dead strip beside it either. Matches the key caps' hit slop.
private final class SlopButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -5, dy: -5).contains(point)
    }
}

private struct SpaceInputButton: UIViewRepresentable {
    let viewModel: KeyboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = SlopButton(type: .custom)
        button.setTitle("Murmur", for: .normal)
        // Dynamic system label colour, so the space bar follows light/dark
        // instead of being pinned to black.
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17)
        button.backgroundColor = .clear
        button.accessibilityLabel = "Space"
        button.accessibilityHint =
            "Touch and hold, then drag to move the cursor."
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.pressSpace),
            for: .touchDown
        )
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
        button.setTitleColor(.label, for: .normal)
        if !context.coordinator.isTracking {
            button.setTitle("Murmur", for: .normal)
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

        @objc func pressSpace() {
            viewModel.triggerLightHaptic()
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
                button.setTitle("", for: .normal)            case .changed:
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
                button.setTitle("Murmur", for: .normal)
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
        button.tintColor = .secondaryLabel
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
        button.tintColor = .secondaryLabel
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

// MARK: - Listening Waveform

/// A calm, level-independent waveform for the dictation panel. The keyboard
/// extension cannot read the microphone (the container app owns it), so the
/// bars animate on a fixed envelope shaped like a spoken phrase.
private struct ListeningWaveform: View {
    let isActive: Bool
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let amplitudes: [CGFloat] = [
        0.20, 0.42, 0.26, 0.58, 0.78, 0.95, 0.38, 0.68, 0.54, 0.30, 0.18, 0.40,
    ]

    private let barWidth: CGFloat = 7
    private let barSpacing: CGFloat = 6
    private let stripHeight: CGFloat = 56

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 24.0, paused: !isActive || reduceMotion)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Self.amplitudes.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: barWidth, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let envelope = Self.amplitudes[index]
        guard isActive, !reduceMotion else {
            return 9 + envelope * 36
        }
        let phase = Double(index) * 0.9
        let wave = 0.5
            + 0.30 * sin(time * 3.4 + phase)
            + 0.20 * sin(time * 1.9 + phase * 1.7)
        let clamped = min(max(wave, 0.05), 1.0)
        return 9 + envelope * 47 * (0.35 + 0.65 * CGFloat(clamped))
    }
}

// MARK: - Press Styles

private struct DictationButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PanelControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
