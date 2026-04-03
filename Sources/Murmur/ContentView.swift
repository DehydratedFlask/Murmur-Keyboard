import SwiftUI

// MARK: - Accent colour

private let murmurAccent = Color(red: 0.39, green: 0.28, blue: 0.95)
private let murmurAccentSecondary = Color(red: 0.53, green: 0.44, blue: 1.0)
private let murmurCardShadow = Color.black.opacity(0.16)

private func murmurSurface(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.18) : Color(.secondarySystemGroupedBackground)
}

private func murmurSurfaceElevated(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.21) : Color(.secondarySystemGroupedBackground)
}

private func murmurBorder(_ scheme: ColorScheme, opacity: Double = 0.08) -> Color {
    scheme == .dark ? Color.white.opacity(opacity) : Color.primary.opacity(opacity)
}

// MARK: - Cached formatters

private let cachedTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

private let cachedNumberFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

private let cachedSectionDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMMd", options: 0, locale: Locale.current)
    return f
}()

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriptionService = TranscriptionService()
    @StateObject private var store = TranscriptionStore()

    // UI state
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showCopiedToast = false
    @State private var keyboardIsEnabled = false
    @State private var fullAccessGranted = false
    @State private var shareItem: ShareableString?
    @State private var isDictationFromKeyboard = false
    @State private var keyboardDictationSessionID: String?
    @State private var keyboardCompletionMessage: String?
    @State private var dictationTask: Task<Void, Never>?
    @State private var showMicPermissionAlert = false
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionTaskID: UInt = 0
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var showCloudFallbackToast = false
    @State private var cloudFallbackDismissTask: Task<Void, Never>?

    // Pulse animation for recording button
    @State private var pulseScale: CGFloat = 1.0

    private var recordFABTrailingPadding: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 28 : 24
    }

    private var recordFABBottomPadding: CGFloat {
        UIScreen.main.bounds.height <= 667 ? 42 : 34
    }

    // Haptic feedback for record button
    private let recordHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let successHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                (colorScheme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.09) : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusBar
                    transcriptionList
                }

                if isDictationFromKeyboard {
                    keyboardDictationOverlay
                        .padding(.horizontal, 20)
                        .padding(.top, 92)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showCopiedToast {
                    copiedToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showCloudFallbackToast {
                    cloudFallbackToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        recordFAB
                            .padding(.trailing, recordFABTrailingPadding)
                            .padding(.bottom, recordFABBottomPadding)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [murmurAccent, murmurAccentSecondary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("Murmur")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(transcriptionService: transcriptionService)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(text: item.text)
        }
        .alert("Microphone Access Required", isPresented: $showMicPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable microphone access in Settings to use Murmur.")
        }
        .task {
            SharedDefaults.setModelReady(false, progressText: nil)
            await recorder.requestPermission()
            await transcriptionService.loadModel()
            checkKeyboardEnabled()
        }
        .onDisappear {
            // Only signal abandonment if we are actively recording for a keyboard
            // dictation. Disappearing for benign reasons (Settings sheet, tab
            // switch, app suspend) must NOT tear down a healthy keyboard session.
            if isDictationFromKeyboard, recorder.isRecording {
                signalKeyboardDictationAbandoned(reason: "Dictation was interrupted.")
                dictationTask?.cancel()
            }
            transcriptionTask?.cancel()
            toastDismissTask?.cancel()
            errorDismissTask?.cancel()
            cloudFallbackDismissTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            handleMemoryWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            checkKeyboardEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Immediate check on activation
            checkKeyboardEnabled()
            // Restore model-ready flag for the keyboard extension
            if transcriptionService.modelState == .loaded {
                SharedDefaults.setModelReady(true, progressText: nil)
            }
            // Delayed re-check: activeInputModes can lag briefly after returning from Settings
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                checkKeyboardEnabled()
            }
        }
        .onChange(of: appState.shouldStartDictation) {
            if appState.shouldStartDictation {
                appState.shouldStartDictation = false

                // If there is already an active keyboard dictation in progress,
                // ignore the duplicate trigger instead of tearing recording down.
                guard !isDictationFromKeyboard || !recorder.isRecording else { return }

                // Cancel any prior stale / background task before starting new work.
                dictationTask?.cancel()

                isDictationFromKeyboard = SharedDefaults.consumeDictationRequested()
                keyboardDictationSessionID = isDictationFromKeyboard ? SharedDefaults.currentDictationSessionID() : nil
                keyboardCompletionMessage = nil

                dictationTask = handleDictationRequest()
            }
        }
        .onChange(of: recorder.vadDidAutoStop) {
            if recorder.vadDidAutoStop && recorder.isRecording {
                // VAD detected silence after speech — auto-stop and transcribe
                stopAndTranscribe()
            }
        }
        .onChange(of: recorder.lastInterruptionError) {
            if let error = recorder.lastInterruptionError {
                if isDictationFromKeyboard {
                    signalKeyboardDictationAbandoned(reason: error)
                }
                presentError(error)
            }
        }
        .onReceive(store.$lastError) { error in
            if let error {
                presentError(error.localizedDescription)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
        .animation(.easeInOut(duration: 0.3), value: showCloudFallbackToast)
    }

    // MARK: - Header Bar

    // MARK: - Status Bar

    private var statusBar: some View {
        Group {
            switch transcriptionService.modelState {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(transcriptionService.loadingProgress.isEmpty
                         ? NSLocalizedString("Loading model…", comment: "Status bar loading text")
                         : transcriptionService.loadingProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            case .error(let msg):
                Button {
                    clearErrorMessage()
                    Task { await transcriptionService.loadModel() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(murmurAccent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityHint("Tap to retry model loading")

            default:
                EmptyView()
            }
        }
    }

    private var keyboardDictationOverlay: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(murmurAccent.opacity(0.12))
                    .frame(width: 40, height: 40)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(murmurAccent)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(recorder.isRecording ? "Listening for keyboard dictation" : (isProcessing ? "Transcribing keyboard dictation" : "Dictation ready"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(keyboardCompletionMessage ?? (isProcessing ? "Murmur is turning your speech into text." : "Stay here while Murmur captures your speech, then switch back to paste the result."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(murmurSurfaceElevated(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(murmurBorder(colorScheme, opacity: 0.12), lineWidth: 1)
        )
        .shadow(color: murmurAccent.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 12, y: 6)
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatNumber(store.totalWordCount)) words total")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Avg \(store.avgWordsPerDictation) per dictation")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [murmurAccent.opacity(0.82), murmurAccentSecondary.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func formatNumber(_ n: Int) -> String {
        cachedNumberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: []) {
                if !keyboardIsEnabled || !fullAccessGranted {
                    keyboardSetupBanner
                        .padding(.top, 2)
                }

                statsSection

                if store.entries.isEmpty {
                    emptyState
                } else {
                    if let error = errorMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(murmurSurfaceElevated(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.orange.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }

                    let grouped = groupedEntries()
                    ForEach(grouped, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(group.0)
                            ForEach(group.1) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [murmurAccent.opacity(0.16), murmurAccentSecondary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    .frame(width: 88, height: 88)

                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(murmurAccent)
                    .symbolEffect(.pulse.byLayer, options: .repeating, value: store.entries.isEmpty)
            }

            VStack(spacing: 8) {
                Text("Ready when you are")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Tap the mic to capture a thought, a note, or a message. Murmur keeps every transcription tidy and close at hand.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 300)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(1.0)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func entryRow(_ entry: TranscriptionEntry) -> some View {
        let titleText = previewTitle(for: entry.text)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(murmurAccent.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "text.quote")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(murmurAccent)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(titleText)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(timeString(entry.timestamp))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.text)
                .font(.subheadline)
                .lineSpacing(5)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(murmurSurface(colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(murmurBorder(colorScheme, opacity: 0.09), lineWidth: 1)
        )
        .shadow(color: murmurCardShadow.opacity(colorScheme == .dark ? 0.72 : 1), radius: 16, y: 8)
        .padding(.horizontal, 20)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.text
                showCopiedToast = true
                toastDismissTask?.cancel()
                toastDismissTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled {
                        showCopiedToast = false
                    }
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                shareItem = ShareableString(text: entry.text)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                withAnimation {
                    store.delete(entry)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Date grouping helpers

    private func groupedEntries() -> [(String, [TranscriptionEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        var groups: [(String, [TranscriptionEntry])] = []
        var dict: [String: [TranscriptionEntry]] = [:]
        var order: [String] = []

        for entry in store.entries {
            let entryDay = cal.startOfDay(for: entry.timestamp)
            let key: String
            if entryDay == today {
                key = NSLocalizedString("Today", comment: "Section header for today's entries")
            } else if entryDay == yesterday {
                key = NSLocalizedString("Yesterday", comment: "Section header for yesterday's entries")
            } else {
                key = cachedSectionDateFormatter.string(from: entry.timestamp)
            }
            if dict[key] == nil {
                dict[key] = []
                order.append(key)
            }
            dict[key]!.append(entry)
        }

        for key in order {
            if let items = dict[key] {
                groups.append((key, items))
            }
        }

        return groups
    }

    private func timeString(_ date: Date) -> String {
        cachedTimeFormatter.string(from: date)
    }

    /// Generate a clean preview title from transcription text.
    /// Uses word-count-based truncation with an ellipsis instead of sentence-splitting.
    private func previewTitle(for text: String) -> String {
        let maxChars = 60
        if text.count <= maxChars {
            return text
        }
        // Truncate at word boundary
        let truncated = String(text.prefix(maxChars))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "…"
        }
        return truncated + "…"
    }

    // MARK: - Floating Record Button

    private var recordFAB: some View {
        Button {
            recordHaptic.prepare()
            handleRecordingTap()
        } label: {
            ZStack {
                if recorder.isRecording {
                    Circle()
                        .fill(murmurAccent.opacity(0.18))
                        .frame(width: 102, height: 102)
                        .scaleEffect(pulseScale)
                        .blur(radius: 2)
                        .animation(
                            reduceMotion
                            ? .linear(duration: 0.01)
                            : .easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                            value: pulseScale
                        )

                    Circle()
                        .stroke(murmurAccent.opacity(0.28), lineWidth: 1.5)
                        .frame(width: 92, height: 92)
                        .scaleEffect(pulseScale * 0.98)
                        .opacity(reduceMotion ? 1 : 0.85)
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: recorder.isRecording
                                ? [Color.red, Color.red.opacity(0.84)]
                                : [murmurAccentSecondary, murmurAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)
                    .shadow(
                        color: (recorder.isRecording ? Color.red : murmurAccent).opacity(0.38),
                        radius: recorder.isRecording ? 24 : 18,
                        y: 10
                    )

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .disabled(!recorder.hasPermission || (!CloudTranscriptionService.isReady && transcriptionService.modelState == .loading) || isProcessing)
        .opacity((!recorder.hasPermission || (!CloudTranscriptionService.isReady && (transcriptionService.modelState == .loading || transcriptionService.modelState.isError)) || isProcessing) ? 0.55 : 1.0)
        .onChange(of: recorder.isRecording) {
            if recorder.isRecording {
                pulseScale = 1.18
            } else {
                pulseScale = 1.0
            }
        }
        .accessibilityLabel(NSLocalizedString(recorder.isRecording ? "Stop recording" : "Start recording", comment: "Record button accessibility label"))
    }

    // MARK: - Copied Toast

    private var copiedToast: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Copied to clipboard")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(murmurSurfaceElevated(colorScheme), in: Capsule())
            .overlay(
                Capsule().stroke(murmurBorder(colorScheme, opacity: 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 12, y: 6)
            .padding(.top, 66)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cloud Fallback Toast

    private var cloudFallbackToast: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text("Cloud unavailable — used on-device")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(murmurSurfaceElevated(colorScheme), in: Capsule())
            .overlay(
                Capsule().stroke(murmurBorder(colorScheme, opacity: 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 12, y: 6)
            .padding(.top, 66)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Keyboard Setup Banner

    private var keyboardSetupBanner: some View {
        let needsKeyboard = !keyboardIsEnabled

        let icon = needsKeyboard ? "keyboard.badge.ellipsis" : "lock.shield"
        let title = needsKeyboard ? "Enable Murmur Keyboard" : "Enable Full Access"
        let subtitle = needsKeyboard
            ? "Use Murmur for fast dictation in any app."
            : "Full Access is required for dictation to work properly."
        let buttonText = needsKeyboard ? "Set Up" : "Settings"

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(murmurAccent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(murmurAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                openKeyboardSettings()
            } label: {
                Text(buttonText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(murmurAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            murmurSurfaceElevated(colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(murmurBorder(colorScheme, opacity: 0.12), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private func checkKeyboardEnabled() {
        // Require both: the shared-defaults signal AND the extension appearing
        // in the system's active input modes (using the safe public API).
        let flagActive = SharedDefaults.isKeyboardActive()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let extensionPrefix = bundleID + "."
        let systemActive = UITextInputMode.activeInputModes.contains { mode in
            // primaryLanguage for third-party keyboards includes the extension bundle ID prefix
            guard let lang = mode.primaryLanguage else { return false }
            return lang.hasPrefix(extensionPrefix) || lang.contains("MurmurKeyboard")
        }

        let enabled = flagActive && systemActive

        // If the flag is set but the extension is no longer in activeInputModes,
        // the user has likely disabled the keyboard — reset the flag.
        if flagActive && !systemActive {
            SharedDefaults.setKeyboardActive(false)
        }

        withAnimation {
            keyboardIsEnabled = enabled
            fullAccessGranted = SharedDefaults.isFullAccessGranted()
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func presentError(_ rawMessage: String) {
        let friendlyMessage: String
        switch rawMessage {
        case "Audio device disconnected":
            friendlyMessage = "Recording interrupted. Please try again."
        default:
            friendlyMessage = rawMessage
        }

        errorDismissTask?.cancel()
        errorMessage = friendlyMessage
        errorDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, errorMessage == friendlyMessage else { return }
            errorMessage = nil
        }
    }

    private func clearErrorMessage() {
        errorDismissTask?.cancel()
        errorMessage = nil
    }

    // MARK: - Recording Actions

    private func handleRecordingTap() {
        if recorder.isRecording {
            recordHaptic.impactOccurred()
            stopAndTranscribe()
        } else {
            recordHaptic.impactOccurred()
            // If model was unloaded (e.g. by a memory warning), reload it first
            // Cloud-ready users can start recording immediately
            if transcriptionService.modelState == .unloaded && !CloudTranscriptionService.isReady {
                Task {
                    await transcriptionService.loadModel()
                    if transcriptionService.modelState == .loaded {
                        startRecording()
                    }
                }
            } else {
                // Also kick off model load in the background for fallback
                if transcriptionService.modelState == .unloaded {
                    Task { await transcriptionService.loadModel() }
                }
                startRecording()
            }
        }
    }

    @discardableResult
    private func handleDictationRequest() -> Task<Void, Never> {
        let isWarmLaunch = SharedDefaults.isModelReady()

        return Task {
            for _ in 0..<(isWarmLaunch ? 8 : 60) {
                if transcriptionService.modelState == .loaded && recorder.hasPermission { break }
                if transcriptionService.modelState.isError { break }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard transcriptionService.modelState == .loaded || CloudTranscriptionService.isReady else {
                signalKeyboardDictationAbandoned(reason: NSLocalizedString("Murmur is still loading the speech model. Try again in a moment.", comment: "Warm dictation model not ready"))
                presentError(NSLocalizedString("Cannot start dictation: model not loaded.", comment: "Error when dictation attempted before model is ready"))
                return
            }
            guard recorder.hasPermission else {
                signalKeyboardDictationAbandoned(reason: NSLocalizedString("Microphone access is required for keyboard dictation.", comment: "Keyboard dictation mic permission missing"))
                presentError(NSLocalizedString("Cannot start dictation: no microphone permission.", comment: "Error when dictation attempted without mic permission"))
                showMicPermissionAlert = true
                return
            }
            keyboardCompletionMessage = nil
            startRecording()
        }
    }

    private func startRecording() {
        clearErrorMessage()
        do {
            try recorder.startRecording()
        } catch {
            if case RecordingError.noPermission = error {
                showMicPermissionAlert = recorder.permissionDenied
            }
            if isDictationFromKeyboard {
                signalKeyboardDictationAbandoned(reason: error.localizedDescription)
            }
            presentError(error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        guard let audioURL = recorder.stopRecording() else {
            if isDictationFromKeyboard {
                signalKeyboardDictationAbandoned(reason: NSLocalizedString("No audio was recorded.", comment: "Keyboard dictation missing audio"))
            }
            presentError(NSLocalizedString("No audio was recorded.", comment: "Error when recording produces no audio"))
            return
        }

        // Verify the audio file still exists and has non-zero size before passing to transcription.
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: audioURL.path) {
            if isDictationFromKeyboard {
                signalKeyboardDictationAbandoned(reason: NSLocalizedString("Recording file not found. Please try again.", comment: "Keyboard dictation missing audio file"))
            }
            presentError(NSLocalizedString("Recording file not found. Please try again.", comment: "Error when audio file is missing"))
            return
        }
        do {
            let attrs = try fileManager.attributesOfItem(atPath: audioURL.path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            if fileSize == 0 {
                if isDictationFromKeyboard {
                    signalKeyboardDictationAbandoned(reason: NSLocalizedString("Recording file is empty. Please try again.", comment: "Keyboard dictation empty audio file"))
                }
                presentError(NSLocalizedString("Recording file is empty. Please try again.", comment: "Error when audio file is empty"))
                return
            }
        } catch {
            if isDictationFromKeyboard {
                signalKeyboardDictationAbandoned(reason: NSLocalizedString("Could not read the recording file. Please try again.", comment: "Keyboard dictation audio file attribute failure"))
            }
            presentError(NSLocalizedString("Could not read the recording file. Please try again.", comment: "Error when reading audio file attributes"))
            return
        }

        isProcessing = true
        clearErrorMessage()

        // Cancel any existing transcription task before starting a new one
        transcriptionTask?.cancel()
        transcriptionTaskID &+= 1
        let myTaskID = transcriptionTaskID
        let useCloud = CloudTranscriptionService.isReady
        let task = Task {
            defer {
                // Only clear if this is still the current task (a newer
                // stopAndTranscribe hasn't replaced us).
                if transcriptionTaskID == myTaskID {
                    transcriptionTask = nil
                    isProcessing = false
                }
                recorder.cleanupRecording()
            }
            do {
                var rawText: String
                var didFallback = false

                if useCloud {
                    do {
                        rawText = try await CloudTranscriptionService.transcribe(audioURL: audioURL)
                    } catch {
                        // Cloud failed — fall back to local WhisperKit
                        print("[Murmur] Cloud transcription failed: \(error.localizedDescription). Falling back to on-device.")
                        rawText = try await transcriptionService.transcribe(audioURL: audioURL)
                        didFallback = true
                    }
                } else {
                    rawText = try await transcriptionService.transcribe(audioURL: audioURL)
                }

                let cleanedText = TextProcessor.process(rawText)

                if didFallback {
                    showCloudFallbackToast = true
                    cloudFallbackDismissTask?.cancel()
                    cloudFallbackDismissTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled {
                            showCloudFallbackToast = false
                        }
                    }
                }

                if !cleanedText.isEmpty {
                    let entry = TranscriptionEntry(text: cleanedText)
                    withAnimation {
                        store.save(entry)
                    }

                    if isDictationFromKeyboard {
                        SharedDefaults.setPendingText(cleanedText, sessionID: keyboardDictationSessionID)
                        keyboardCompletionMessage = "Transcription ready. Switch back to your previous app to paste it."
                        successHaptic.notificationOccurred(.success)
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                } else if isDictationFromKeyboard {
                    signalKeyboardDictationAbandoned(reason: NSLocalizedString("No speech was detected.", comment: "Keyboard dictation produced empty text"))
                }
                isDictationFromKeyboard = false
                keyboardDictationSessionID = nil
            } catch is CancellationError {
                if isDictationFromKeyboard {
                    signalKeyboardDictationAbandoned(reason: "Dictation was cancelled.")
                }
                isDictationFromKeyboard = false
                keyboardDictationSessionID = nil
            } catch {
                if isDictationFromKeyboard {
                    signalKeyboardDictationAbandoned(reason: error.localizedDescription)
                }
                isDictationFromKeyboard = false
                keyboardDictationSessionID = nil
                presentError(error.localizedDescription)
            }
        }
        transcriptionTask = task
    }

    // MARK: - Memory Warning

    private func handleMemoryWarning() {
        // Only unload the model if we are NOT actively recording or transcribing.
        // This prevents data loss during an in-progress dictation.
        guard !recorder.isRecording, !isProcessing, !transcriptionService.isTranscribing else {
            print("[Murmur] Memory warning received but recording/transcribing is active — skipping model unload.")
            return
        }
        print("[Murmur] Memory warning received — unloading WhisperKit model to free memory.")
        SharedDefaults.setModelReady(false, progressText: nil)
        Task {
            await transcriptionService.unloadModel()
        }
    }

    private func signalKeyboardDictationAbandoned(reason: String) {
        SharedDefaults.abandonDictationSession(reason: reason)
        SharedDefaults.setDictationRequested(false)
        keyboardCompletionMessage = nil
        isDictationFromKeyboard = false
        keyboardDictationSessionID = nil
    }
}

// MARK: - ShareableString (Identifiable wrapper for sheet)

private struct ShareableString: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (System)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var transcriptionService: TranscriptionService
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue
    @AppStorage("cloudDictationEnabled") private var cloudDictationEnabled = false
    @AppStorage("cloudProvider") private var cloudProviderRaw: String = CloudProvider.groq.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Cloud dictation UI state
    @State private var apiKeyInput: String = ""
    @State private var cloudStatus: CloudConnectionStatus = .notConfigured
    @State private var showPrivacyDisclosure = false
    @State private var pendingCloudEnable = false
    @State private var pendingProviderChange: CloudProvider?
    @State private var testTask: Task<Void, Never>?
    @State private var availableModels: [CloudModel] = []
    @State private var selectedCloudModelID: String = ""

    private var selectedProvider: CloudProvider {
        CloudProvider(rawValue: cloudProviderRaw) ?? .groq
    }

    private var selectedMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceMode) ?? .auto },
            set: { appearanceMode = $0.rawValue }
        )
    }

    var body: some View {
        List {
            Section {
                Picker(selection: selectedMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Choose how Murmur looks. Auto follows your system setting.")
            }

            Section {
                Picker(selection: $transcriptionService.selectedModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } header: {
                Text("On-Device Model")
            } footer: {
                Text("Tiny is fastest with slightly lower accuracy. Base is more accurate but uses more memory.")
            }

            Section {
                Button("Reload Model") {
                    Task {
                        await transcriptionService.unloadModel()
                        await transcriptionService.loadModel()
                    }
                }
                .disabled(transcriptionService.modelState == .loading || transcriptionService.isTranscribing)
            }

            // MARK: - Cloud Dictation Section

            Section {
                Toggle("Use Cloud Dictation", isOn: Binding(
                    get: { cloudDictationEnabled },
                    set: { newValue in
                        if newValue {
                            // Check if disclosure has been accepted for current provider
                            if CloudTranscriptionService.isDisclosureAccepted(for: selectedProvider) {
                                cloudDictationEnabled = true
                            } else {
                                pendingCloudEnable = true
                                pendingProviderChange = nil
                                showPrivacyDisclosure = true
                            }
                        } else {
                            cloudDictationEnabled = false
                        }
                    }
                ))

                if cloudDictationEnabled {
                    Picker("Provider", selection: Binding(
                        get: { selectedProvider },
                        set: { newProvider in
                            if CloudTranscriptionService.isDisclosureAccepted(for: newProvider) {
                                cloudProviderRaw = newProvider.rawValue
                                loadStateForCurrentProvider()
                                refreshStatus()
                            } else {
                                pendingProviderChange = newProvider
                                pendingCloudEnable = false
                                showPrivacyDisclosure = true
                            }
                        }
                    )) {
                        ForEach(CloudProvider.allCases) { provider in
                            HStack(spacing: 6) {
                                Text(provider.displayName)
                                if provider.isRecommended {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(murmurAccent, in: Capsule())
                                }
                            }
                            .tag(provider)
                        }
                    }

                    // API key helper link
                    Button {
                        openURL(selectedProvider.apiKeyURL)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedProvider.isRecommended ? murmurAccent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedProvider.apiKeyCTA)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(murmurAccent)
                                Text(selectedProvider.apiKeyHelperText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    SecureField("API Key", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: apiKeyInput) {
                            CloudTranscriptionService.setAPIKey(apiKeyInput, for: selectedProvider)
                            refreshStatus()
                        }

                    if !availableModels.isEmpty {
                        Picker("Model", selection: $selectedCloudModelID) {
                            ForEach(availableModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .onChange(of: selectedCloudModelID) {
                            CloudTranscriptionService.setSelectedModel(selectedCloudModelID, for: selectedProvider)
                        }
                    }

                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if cloudStatus == .testing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(apiKeyInput.isEmpty || cloudStatus == .testing)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: cloudStatus.symbolName)
                                .foregroundStyle(colorForStatus(cloudStatus))
                            Text(cloudStatus.displayText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Cloud Dictation")
            } footer: {
                if cloudDictationEnabled {
                    Text("Audio is sent to \(selectedProvider.displayName) for transcription. Falls back to on-device if cloud fails.")
                } else {
                    Text("Send audio to a cloud provider for faster, more accurate transcription. Your API key is stored securely on-device.")
                }
            }

            Section {
                Button {
                    if let url = URL(string: "https://buymeacoffee.com/tgn5dq5j8xs") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Buy Me a Coffee")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Support Murmur's development")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Support")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Murmur v2.4")
                        .font(.headline)
                    Text(cloudDictationEnabled
                         ? "Speech-to-text via \(selectedProvider.displayName). On-device fallback always available."
                         : "On-device speech-to-text powered by WhisperKit.\nNo data leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
        .onAppear {
            loadStateForCurrentProvider()
            refreshStatus()
        }
        .onDisappear {
            testTask?.cancel()
        }
        .sheet(isPresented: $showPrivacyDisclosure) {
            // On dismiss without accepting, revert
            if pendingCloudEnable {
                pendingCloudEnable = false
            }
            if pendingProviderChange != nil {
                pendingProviderChange = nil
            }
        } content: {
            CloudPrivacyDisclosureSheet(
                provider: pendingProviderChange ?? selectedProvider,
                onAccept: {
                    let targetProvider = pendingProviderChange ?? selectedProvider
                    CloudTranscriptionService.acceptDisclosure(for: targetProvider)
                    if pendingCloudEnable {
                        cloudDictationEnabled = true
                        pendingCloudEnable = false
                    }
                    if let newProvider = pendingProviderChange {
                        cloudProviderRaw = newProvider.rawValue
                        loadStateForCurrentProvider()
                        refreshStatus()
                        pendingProviderChange = nil
                    }
                    showPrivacyDisclosure = false
                },
                onCancel: {
                    pendingCloudEnable = false
                    pendingProviderChange = nil
                    showPrivacyDisclosure = false
                }
            )
        }
    }

    // MARK: - Cloud Dictation Helpers

    private func loadStateForCurrentProvider() {
        apiKeyInput = CloudTranscriptionService.apiKey(for: selectedProvider) ?? ""
        selectedCloudModelID = CloudTranscriptionService.selectedModel(for: selectedProvider)
        loadCachedModels()
    }

    /// Kept as a convenience alias used by provider-change callsites.
    private func loadAPIKeyForCurrentProvider() {
        loadStateForCurrentProvider()
    }

    private func loadCachedModels() {
        if let cached = CloudTranscriptionService.cachedModels(for: selectedProvider) {
            availableModels = cached
            // Ensure selectedCloudModelID is still valid
            if !cached.contains(where: { $0.id == selectedCloudModelID }) {
                selectedCloudModelID = cached.first?.id ?? selectedProvider.defaultModelID
                CloudTranscriptionService.setSelectedModel(selectedCloudModelID, for: selectedProvider)
            }
        } else {
            availableModels = []
        }
    }

    private func refreshStatus() {
        if apiKeyInput.isEmpty {
            cloudStatus = .notConfigured
            availableModels = []
        } else {
            // Don't reset to notConfigured if we already have a known status
            // — let the user tap Test Connection to re-verify.
            if cloudStatus == .notConfigured {
                cloudStatus = .notConfigured
            }
        }
    }

    private func testConnection() {
        testTask?.cancel()
        cloudStatus = .testing
        let provider = selectedProvider
        testTask = Task {
            let (status, models) = await CloudTranscriptionService.testConnection(for: provider)
            guard !Task.isCancelled else { return }
            cloudStatus = status

            if let models, !models.isEmpty {
                availableModels = models
                // If current selection isn't in the fetched list, pick the best default
                if !models.contains(where: { $0.id == selectedCloudModelID }) {
                    selectedCloudModelID = models.first?.id ?? provider.defaultModelID
                    CloudTranscriptionService.setSelectedModel(selectedCloudModelID, for: provider)
                }
            }
        }
    }

    private func colorForStatus(_ status: CloudConnectionStatus) -> Color {
        switch status {
        case .notConfigured: return .secondary
        case .connected: return .green
        case .invalidKey: return .red
        case .testing: return murmurAccent
        case .error: return .orange
        }
    }
}

// MARK: - Privacy Disclosure Sheet

struct CloudPrivacyDisclosureSheet: View {
    let provider: CloudProvider
    let onAccept: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Icon
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 72, height: 72)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)

                    Text("Cloud Dictation Privacy Notice")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Text("When you enable Cloud Dictation, your voice recordings will be sent to \(provider.displayName) for transcription. This means your audio data will leave your device and be processed on external servers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    Text("Murmur does not store or have access to your API key or audio data on our servers. Your API key is stored only on your device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("By continuing, you acknowledge that:")
                            .font(.subheadline.weight(.semibold))

                        BulletPoint("Your voice recordings will be transmitted over the internet")
                        BulletPoint("\(provider.displayName)'s privacy policy applies to your data")
                        BulletPoint("You are responsible for your own API key and usage")
                    }

                    Text("This feature is optional. On-device transcription remains available at all times.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .padding(.top, 4)

                    Spacer(minLength: 20)

                    VStack(spacing: 12) {
                        Button(action: onAccept) {
                            Text("I Understand & Agree")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(murmurAccent)

                        Button("Cancel", role: .cancel, action: onCancel)
                            .font(.subheadline)
                    }
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}

private struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
