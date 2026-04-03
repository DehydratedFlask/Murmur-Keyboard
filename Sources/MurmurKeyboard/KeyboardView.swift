import SwiftUI

/// The main SwiftUI keyboard view — native iOS QWERTY layout with a
/// Murmur dictation button integrated into the predictive-text row.
struct KeyboardView: View {
    @ObservedObject var viewModel: KeyboardViewModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var backspaceLongPressed = false

    // MARK: - Native iOS Keyboard Layout Constants

    private let keySpacing: CGFloat = 6
    private let rowSpacing: CGFloat = 11
    private let keyHeight: CGFloat = 42
    private let edgePadding: CGFloat = 3
    private let middleRowInset: CGFloat = 18
    /// Height of Apple's predictive text / suggestion row
    private let predictionRowHeight: CGFloat = 36

    // MARK: - Key Definitions

    private let letterRow1 = ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
    private let letterRow2 = ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
    private let letterRow3 = ["Z", "X", "C", "V", "B", "N", "M"]

    private let numberRow1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private let numberRow2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
    private let numberRow3 = [".", ",", "?", "!", "'"]

    private let symbolRow1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    private let symbolRow2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    private let symbolRow3 = [".", ",", "?", "!", "'"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Error / warning banners (only when needed)
            banners

            // Predictive-text row with Murmur dictation button
            predictionRow

            // Thin separator matching Apple's divider between suggestions and keys
            Rectangle()
                .fill(separatorColor)
                .frame(height: 0.5)

            // Standard keyboard rows
            VStack(spacing: rowSpacing) {
                if viewModel.showNumbers || viewModel.showSymbols {
                    numbersOrSymbolsLayout
                } else {
                    lettersLayout
                }
                bottomRow
            }
            .padding(.horizontal, edgePadding)
            .padding(.top, 8)
            .padding(.bottom, 3)
        }
        .background(keyboardBackground)
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

        if !viewModel.hasFullAccess {
            Text("Enable Full Access in Settings → Keyboards to use dictation.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(keyboardBackground)
        }
    }

    // MARK: - Prediction Row (with Murmur logo button)

    /// Mimics Apple's predictive-text suggestion row.
    /// Center slot holds the Murmur dictation button; side slots are empty
    /// (like a keyboard with no active suggestions).
    private var predictionRow: some View {
        HStack(spacing: 0) {
            // Left slot (empty, matches Apple's 3-slot layout)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: predictionRowHeight)

            // Divider
            Rectangle()
                .fill(separatorColor)
                .frame(width: 0.5, height: 18)

            // Center slot — Murmur dictation button
            Button {
                viewModel.openMurmurForDictation()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Murmur")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(murmurButtonColor)
                .frame(maxWidth: .infinity)
                .frame(height: predictionRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasFullAccess)
            .accessibilityLabel("Start Murmur dictation")
            .accessibilityHint(viewModel.hasFullAccess
                ? "Opens the Murmur app to capture speech."
                : "Enable Full Access to use dictation.")

            // Divider
            Rectangle()
                .fill(separatorColor)
                .frame(width: 0.5, height: 18)

            // Right slot — model status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isModelWarm ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(viewModel.isModelWarm ? "Ready" : "Loading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: predictionRowHeight)
        }
        .background(predictionRowBackground)
    }

    // MARK: - Letters Layout (matches Apple QWERTY)

    private var lettersLayout: some View {
        VStack(spacing: rowSpacing) {
            HStack(spacing: keySpacing) {
                ForEach(letterRow1, id: \.self) { key in
                    letterKey(key)
                }
            }

            HStack(spacing: keySpacing) {
                ForEach(letterRow2, id: \.self) { key in
                    letterKey(key)
                }
            }
            .padding(.horizontal, middleRowInset)

            HStack(spacing: keySpacing) {
                shiftKey
                Spacer(minLength: 0)
                HStack(spacing: keySpacing) {
                    ForEach(letterRow3, id: \.self) { key in
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
        let row1 = viewModel.showSymbols ? symbolRow1 : numberRow1
        let row2 = viewModel.showSymbols ? symbolRow2 : numberRow2
        let row3 = viewModel.showSymbols ? symbolRow3 : numberRow3

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
            micButton
            spaceKey
            returnKey
        }
    }

    // MARK: - Key Views

    private func letterKey(_ letter: String) -> some View {
        let displayLetter = viewModel.isUppercase ? letter : letter.lowercased()
        return Button {
            viewModel.insertText(letter)
        } label: {
            Text(displayLetter)
                .font(.system(size: 22.5, weight: .light))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(lightKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
    }

    private func characterKey(_ character: String) -> some View {
        Button {
            viewModel.insertCharacter(character)
        } label: {
            Text(character)
                .font(.system(size: 20.5, weight: .regular))
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(lightKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
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
                .background(viewModel.isShifted || viewModel.isCapsLocked ? lightKeyBackground : darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
        .accessibilityLabel(viewModel.isCapsLocked ? "Caps Lock on" : (viewModel.isShifted ? "Shift on" : "Shift"))
    }

    private var backspaceKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(keyTextColor)
            .frame(width: 42, height: keyHeight)
            .background(darkKeyBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
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
                        viewModel.triggerMediumHaptic()
                        viewModel.deleteBackward()
                    }
                }
            )
            .accessibilityLabel("Delete")
    }

    private var numberToggleKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.toggleNumbers()
        } label: {
            Text(viewModel.showNumbers || viewModel.showSymbols ? "ABC" : "123")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 50, height: keyHeight)
                .background(darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
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
                .background(darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
    }

    private var globeKey: some View {
        Button {
            viewModel.triggerLightHaptic()
            viewModel.advanceToNextInputMode()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
        .accessibilityLabel("Switch keyboard")
    }

    private var micButton: some View {
        Button {
            viewModel.openMurmurForDictation()
        } label: {
            Image(systemName: viewModel.isModelWarm ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: keyHeight)
                .background(viewModel.hasFullAccess && viewModel.isModelWarm ? Color.accentColor : darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.hasFullAccess && viewModel.isModelWarm ? .white : keyTextColor)
        .disabled(!viewModel.hasFullAccess)
        .accessibilityLabel("Dictate")
    }

    private var spaceKey: some View {
        Button {
            viewModel.insertSpace()
        } label: {
            Text("space")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(keyTextColor)
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(lightKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Space")
    }

    private var returnKey: some View {
        Button {
            viewModel.insertReturn()
        } label: {
            Text("return")
                .font(.system(size: 15.5, weight: .medium))
                .frame(width: 88, height: keyHeight)
                .background(darkKeyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: keyShadow, radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(keyTextColor)
        .accessibilityLabel("Return")
    }

    // MARK: - Colors (match native iOS keyboard)

    private var keyboardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    private var lightKeyBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.26, green: 0.26, blue: 0.28)
            : .white
    }

    private var darkKeyBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.68, green: 0.71, blue: 0.75)
    }

    private var keyTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    /// Prediction row background — slightly lighter than the keyboard tray,
    /// matching Apple's suggestion bar appearance.
    private var predictionRowBackground: Color {
        colorScheme == .dark
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
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    private var keyShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.4)
            : Color(red: 0.53, green: 0.54, blue: 0.56)
    }
}
