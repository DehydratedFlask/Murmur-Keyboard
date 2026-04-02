import SwiftUI

/// The main SwiftUI keyboard view — QWERTY layout with dictation bar, predictive text, and key popups.
struct KeyboardView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    @Environment(\.colorScheme) private var envColorScheme
    @State private var backspaceLongPressed = false

    // MARK: - Layout Constants

    private let keySpacing: CGFloat = 6
    private let rowSpacing: CGFloat = 10
    private let keyHeight: CGFloat = 42
    private let edgePadding: CGFloat = 3

    // MARK: - Key Definitions

    private var letterRows: [[String]] {
        [
            ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
            ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
            ["Z", "X", "C", "V", "B", "N", "M"],
        ]
    }

    private var numberRows: [[String]] {
        [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'"],
        ]
    }

    private var symbolRows: [[String]] {
        [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
            [".", ",", "?", "!", "'"],
        ]
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    // Handoff error banner
                    if let error = viewModel.handoffError {
                        Text(error)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(envColorScheme == .dark ? 0.72 : 0.85))
                    }

                    // Full Access required banner
                    if !viewModel.hasFullAccess {
                        Text("Enable Full Access in Settings \u{2192} Keyboards to use dictation.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(envColorScheme == .dark ? Color.orange.opacity(0.95) : .orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(keyboardBackground.opacity(envColorScheme == .dark ? 0.96 : 0.9))
                    }
                }

                // Dictation bar
                dictationBar

                // Predictive text bar
                predictiveTextBar

                if viewModel.showNumbers || viewModel.showSymbols {
                    numbersOrSymbolsLayout
                } else {
                    lettersLayout
                }
                bottomRow
            }
            .padding(.horizontal, edgePadding)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .background(
                LinearGradient(
                    colors: envColorScheme == .dark
                        ? [Color(red: 0.09, green: 0.09, blue: 0.10), Color(red: 0.13, green: 0.13, blue: 0.14)]
                        : [keyboardBackground, keyboardBackground.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Key popup overlay — extends above keyboard bounds
            keyPopupOverlay
        }
    }

    // MARK: - Dictation Bar

    private var dictationBar: some View {
        Button {
            viewModel.openMurmurForDictation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isModelWarm ? "bolt.fill" : "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.isModelWarm ? "Dictation ready" : "Loading model")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(viewModel.dictationStatusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.isModelWarm ? Color.green : .secondary)
            }
            .foregroundColor(viewModel.hasFullAccess ? (envColorScheme == .dark ? Color.accentColor.opacity(0.95) : Color.accentColor) : .gray)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(barBackground)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
            .cornerRadius(6)
        }
        .disabled(!viewModel.hasFullAccess)
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityLabel("Start dictation")
        .accessibilityHint(viewModel.hasFullAccess ? "Opens the Murmur app to capture speech and return the transcription here." : "Enable Full Access before starting dictation.")
    }

    // MARK: - Predictive Text Bar

    @ViewBuilder
    private var predictiveTextBar: some View {
        if viewModel.suggestions.allSatisfy(\.isEmpty) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(envColorScheme == .dark ? Color.white.opacity(0.7) : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Suggestions appear as you type")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(keyTextColor.opacity(0.82))
                    Text("Pick one when Murmur has a match")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(barBackground)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
            .cornerRadius(6)
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 {
                        Divider()
                            .frame(height: 20)
                    }
                    Button {
                        let suggestion = index < viewModel.suggestions.count ? viewModel.suggestions[index] : ""
                        if !suggestion.isEmpty {
                            viewModel.applySuggestion(suggestion)
                        }
                    } label: {
                        Text(index < viewModel.suggestions.count ? viewModel.suggestions[index] : "")
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .foregroundColor(keyTextColor)
                    }
                    .disabled(index >= viewModel.suggestions.count || viewModel.suggestions[index].isEmpty)
                    .accessibilityLabel(index < viewModel.suggestions.count ? viewModel.suggestions[index] : "No suggestion")
                }
            }
            .background(barBackground)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
            .cornerRadius(6)
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Letters Layout

    private var lettersLayout: some View {
        VStack(spacing: rowSpacing) {
            // Row 1: Q-P
            HStack(spacing: keySpacing) {
                ForEach(letterRows[0], id: \.self) { key in
                    letterKey(key)
                }
            }

            // Row 2: A-L
            HStack(spacing: keySpacing) {
                ForEach(letterRows[1], id: \.self) { key in
                    letterKey(key)
                }
            }

            // Row 3: Shift + Z-M + Backspace
            HStack(spacing: keySpacing) {
                shiftKey
                HStack(spacing: keySpacing) {
                    ForEach(letterRows[2], id: \.self) { key in
                        letterKey(key)
                    }
                }
                backspaceKey
            }
        }
    }

    // MARK: - Numbers/Symbols Layout

    private var numbersOrSymbolsLayout: some View {
        let rows = viewModel.showSymbols ? symbolRows : numberRows

        return VStack(spacing: rowSpacing) {
            HStack(spacing: keySpacing) {
                ForEach(rows[0], id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: keySpacing) {
                ForEach(rows[1], id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: keySpacing) {
                symbolToggleKey
                HStack(spacing: keySpacing) {
                    ForEach(rows[2], id: \.self) { key in
                        characterKey(key)
                    }
                }
                backspaceKey
            }
        }
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack(spacing: keySpacing) {
            numberToggleKey
            globeKey
            micButton
            spaceKey
            returnKey
        }
        .padding(.top, rowSpacing)
    }

    // MARK: - Key Views

    private func letterKey(_ letter: String) -> some View {
        let displayLetter = viewModel.isUppercase ? letter : letter.lowercased()
        return GeometryReader { geo in
            Text(displayLetter)
                .font(.system(size: 22, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(keyColor)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isTouchInsideKey(value.location, in: geo.size) else {
                                viewModel.hidePopup()
                                return
                            }
                            viewModel.showPopup(key: displayLetter, frame: geo.frame(in: .global))
                        }
                        .onEnded { value in
                            viewModel.hidePopup()
                            guard isTouchInsideKey(value.location, in: geo.size) else { return }
                            viewModel.insertText(letter)
                        }
                )
        }
        .frame(height: keyHeight)
    }

    private func characterKey(_ character: String) -> some View {
        GeometryReader { geo in
            Text(character)
                .font(.system(size: 20, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(keyColor)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isTouchInsideKey(value.location, in: geo.size) else {
                                viewModel.hidePopup()
                                return
                            }
                            viewModel.showPopup(key: character, frame: geo.frame(in: .global))
                        }
                        .onEnded { value in
                            viewModel.hidePopup()
                            guard isTouchInsideKey(value.location, in: geo.size) else { return }
                            viewModel.insertCharacter(character)
                        }
                )
        }
        .frame(height: keyHeight)
    }

    private var shiftKey: some View {
        Button {
            viewModel.triggerMediumHaptic()
            viewModel.toggleShift()
        } label: {
            Image(systemName: viewModel.isCapsLocked ? "capslock.fill" :
                    (viewModel.isShifted ? "shift.fill" : "shift"))
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(viewModel.isShifted || viewModel.isCapsLocked ? keyColor : specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(NSLocalizedString(viewModel.isCapsLocked ? "Caps Lock on" : (viewModel.isShifted ? "Shift on" : "Shift"), comment: "Shift key accessibility label"))
        .accessibilityHint(NSLocalizedString("Tap to toggle shift. Tap again for caps lock.", comment: "Shift key accessibility hint"))
    }

    private var backspaceKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .medium))
            .frame(width: 42, height: keyHeight)
            .background(specialKeyColor)
            .cornerRadius(5)
            .foregroundColor(keyTextColor)
            .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
            .onLongPressGesture(
                minimumDuration: 0.4,
                maximumDistance: 20,
                perform: {
                    // Long-press committed — start continuous delete
                    viewModel.startContinuousDelete()
                    backspaceLongPressed = true
                },
                onPressingChanged: { pressing in
                    if pressing {
                        // Finger just went down — nothing yet
                    } else if backspaceLongPressed {
                        // Was a long press that just ended — clean up
                        viewModel.stopContinuousDelete()
                        backspaceLongPressed = false
                    } else {
                        // Tap (finger up before long-press threshold) — single delete
                        viewModel.triggerMediumHaptic()
                        viewModel.deleteBackward()
                    }
                }
            )
            .accessibilityLabel(NSLocalizedString("Delete", comment: "Backspace key accessibility label"))
            .accessibilityHint(NSLocalizedString("Double-tap to delete one character. Touch and hold to delete continuously.", comment: "Backspace key accessibility hint"))
    }

    private var numberToggleKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.toggleNumbers()
        } label: {
            Text(NSLocalizedString(viewModel.showNumbers || viewModel.showSymbols ? "ABC" : "123", comment: "Toggle key label"))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 50, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(viewModel.showNumbers || viewModel.showSymbols ? "Show letters" : "Show numbers")
    }

    private var symbolToggleKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.toggleSymbols()
        } label: {
            Text(NSLocalizedString(viewModel.showSymbols ? "123" : "#+=", comment: "Symbol toggle key label"))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(viewModel.showSymbols ? "Show numbers" : "Show symbols")
    }

    private var globeKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.advanceToNextInputMode()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(NSLocalizedString("Switch keyboard", comment: "Globe key accessibility label"))
        .accessibilityHint(NSLocalizedString("Double-tap to switch to the next keyboard.", comment: "Globe key accessibility hint"))
    }

    private var micButton: some View {
        Button {
            viewModel.openMurmurForDictation()
        } label: {
            Image(systemName: viewModel.isModelWarm ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: keyHeight)
                .background(viewModel.hasFullAccess ? (viewModel.isModelWarm ? Color.accentColor : Color.orange) : Color.gray)
                .cornerRadius(5)
                .foregroundColor(.white)
                .shadow(color: (viewModel.isModelWarm ? Color.accentColor : Color.orange).opacity(0.3), radius: 2, x: 0, y: 1)
        }
        .disabled(!viewModel.hasFullAccess)
        .accessibilityLabel(NSLocalizedString("Dictate", comment: "Mic button accessibility label"))
        .accessibilityHint(NSLocalizedString(viewModel.hasFullAccess ? "Double-tap to start voice dictation." : "Full Access required for dictation.", comment: "Mic button accessibility hint"))
    }

    private var spaceKey: some View {
        Button {
            viewModel.insertSpace()
        } label: {
            // No label — clean bar like system keyboard
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(keyColor)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
                .cornerRadius(5)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel("Space")
    }

    private var returnKey: some View {
        Button {
            viewModel.insertReturn()
        } label: {
            Image(systemName: "return")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 44, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel("Return")
    }

    // MARK: - Key Popup Overlay

    @ViewBuilder
    private var keyPopupOverlay: some View {
        if let key = viewModel.popupKey {
            GeometryReader { outerGeo in
                let globalFrame = viewModel.popupFrame
                let localOrigin = CGPoint(
                    x: globalFrame.midX - outerGeo.frame(in: .global).minX,
                    y: globalFrame.minY - outerGeo.frame(in: .global).minY
                )
                let popupWidth: CGFloat = 46
                let popupHeight: CGFloat = 56

                Text(key)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(keyTextColor)
                    .frame(width: popupWidth, height: popupHeight)
                    .background(popupBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(keyBorderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(envColorScheme == .dark ? 0.32 : 0.25), radius: 3, x: 0, y: 2)
                    .position(
                        x: localOrigin.x,
                        y: localOrigin.y - popupHeight / 2 + 4
                    )
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Colors

    private var keyboardBackground: Color {
        envColorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.10)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    private var keyColor: Color {
        envColorScheme == .dark
            ? Color(red: 0.28, green: 0.28, blue: 0.30)
            : .white
    }

    private var specialKeyColor: Color {
        envColorScheme == .dark
            ? Color(red: 0.18, green: 0.18, blue: 0.20)
            : Color(red: 0.68, green: 0.71, blue: 0.74)
    }

    private var keyTextColor: Color {
        envColorScheme == .dark ? .white : .black
    }

    private var barBackground: Color {
        envColorScheme == .dark
            ? Color(red: 0.18, green: 0.18, blue: 0.20)
            : Color(white: 0.96)
    }

    private var popupBackground: Color {
        envColorScheme == .dark
            ? Color(red: 0.26, green: 0.26, blue: 0.28)
            : .white
    }

    private func isTouchInsideKey(_ location: CGPoint, in size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).contains(location)
    }

    private var keyBorderColor: Color { envColorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    private var keyShadowColor: Color { envColorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.15) }
}
