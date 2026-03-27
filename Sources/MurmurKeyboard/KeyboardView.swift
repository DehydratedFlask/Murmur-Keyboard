import SwiftUI

/// The main SwiftUI keyboard view — QWERTY layout with a prominent mic button.
struct KeyboardView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    @Environment(\.colorScheme) private var envColorScheme

    private var effectiveColorScheme: ColorScheme {
        envColorScheme
    }

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
        VStack(spacing: 0) {
            // Handoff error banner
            if let error = viewModel.handoffError {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
            }

            // Full Access required banner
            if !viewModel.hasFullAccess {
                Text("Enable Full Access in Settings \u{2192} Keyboards to use dictation.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(keyboardBackground.opacity(0.9))
            }

            if viewModel.showNumbers || viewModel.showSymbols {
                numbersOrSymbolsLayout
            } else {
                lettersLayout
            }
            bottomRow
        }
        .padding(.horizontal, edgePadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(keyboardBackground)
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
            // Row 1
            HStack(spacing: keySpacing) {
                ForEach(rows[0], id: \.self) { key in
                    characterKey(key)
                }
            }

            // Row 2
            HStack(spacing: keySpacing) {
                ForEach(rows[1], id: \.self) { key in
                    characterKey(key)
                }
            }

            // Row 3: symbol toggle + characters + backspace
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
        return Button {
            viewModel.insertText(letter)
        } label: {
            Text(displayLetter)
                .font(.system(size: 22, weight: .regular))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(keyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    private func characterKey(_ character: String) -> some View {
        Button {
            viewModel.textDocumentProxy?.insertText(character)
        } label: {
            Text(character)
                .font(.system(size: 20, weight: .regular))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(keyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    private var shiftKey: some View {
        Button {
            viewModel.toggleShift()
        } label: {
            Image(systemName: viewModel.isCapsLocked ? "capslock.fill" :
                    (viewModel.isShifted ? "shift.fill" : "shift"))
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(viewModel.isShifted || viewModel.isCapsLocked ? keyColor : specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(NSLocalizedString(viewModel.isCapsLocked ? "Caps Lock on" : (viewModel.isShifted ? "Shift on" : "Shift"), comment: "Shift key accessibility label"))
        .accessibilityHint(NSLocalizedString("Double-tap to toggle shift. Double-tap twice for caps lock.", comment: "Shift key accessibility hint"))
    }

    private var backspaceKey: some View {
        Button {
            viewModel.deleteBackward()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(NSLocalizedString("Delete", comment: "Backspace key accessibility label"))
        .accessibilityHint(NSLocalizedString("Double-tap to delete the previous character.", comment: "Backspace key accessibility hint"))
    }

    private var numberToggleKey: some View {
        Button {
            viewModel.toggleNumbers()
        } label: {
            Text(NSLocalizedString(viewModel.showNumbers || viewModel.showSymbols ? "ABC" : "123", comment: "Toggle key label"))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 50, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    private var symbolToggleKey: some View {
        Button {
            viewModel.toggleSymbols()
        } label: {
            Text(NSLocalizedString(viewModel.showSymbols ? "123" : "#+=", comment: "Symbol toggle key label"))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    private var globeKey: some View {
        Button {
            viewModel.advanceToNextInputMode()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
        .accessibilityLabel(NSLocalizedString("Switch keyboard", comment: "Globe key accessibility label"))
        .accessibilityHint(NSLocalizedString("Double-tap to switch to the next keyboard.", comment: "Globe key accessibility hint"))
    }

    private var micButton: some View {
        Button {
            viewModel.openMurmurForDictation()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: keyHeight)
                .background(viewModel.hasFullAccess ? Color.accentColor : Color.gray)
                .cornerRadius(5)
                .foregroundColor(.white)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 2, x: 0, y: 1)
        }
        .disabled(!viewModel.hasFullAccess)
        .accessibilityLabel(NSLocalizedString("Dictate", comment: "Mic button accessibility label"))
        .accessibilityHint(NSLocalizedString(viewModel.hasFullAccess ? "Double-tap to start voice dictation." : "Full Access required for dictation.", comment: "Mic button accessibility hint"))
    }

    private var spaceKey: some View {
        Button {
            viewModel.insertSpace()
        } label: {
            Text("space")
                .font(.system(size: 15, weight: .regular))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(keyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    private var returnKey: some View {
        Button {
            viewModel.insertReturn()
        } label: {
            Text("return")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 80, height: keyHeight)
                .background(specialKeyColor)
                .cornerRadius(5)
                .foregroundColor(keyTextColor)
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
        }
    }

    // MARK: - Colors

    private var keyboardBackground: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    private var keyColor: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.35, green: 0.35, blue: 0.37)
            : .white
    }

    private var specialKeyColor: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.24, green: 0.24, blue: 0.26)
            : Color(red: 0.68, green: 0.71, blue: 0.74)
    }

    private var keyTextColor: Color {
        effectiveColorScheme == .dark ? .white : .black
    }
}
