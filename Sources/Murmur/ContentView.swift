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
    @StateObject private var snippetStore = SnippetStore()

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

                if isDictationFromKeyboard {
                    keyboardDictationScreen
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        statusBar
                        transcriptionList
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
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [murmurAccent, murmurAccentSecondary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("Murmur")
                            .font(.system(.body, design: .rounded).weight(.bold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(isDictationFromKeyboard ? .hidden : .visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(transcriptionService: transcriptionService, store: store)
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
            MurmurDictationLiveActivity.endAllImmediately()
            SharedDefaults.setDictationSessionDurationMinutes(
                max(1, MurmurPreferences.sessionDuration.minutes)
            )
            await recorder.requestPermission()
            await transcriptionService.loadModel()
            checkKeyboardEnabled()
        }
        .onDisappear {
            // The keyboard handoff intentionally backgrounds Murmur while it
            // records. Do not abandon that session here: with the audio
            // background mode, recording continues while the user returns to
            // their original app. Actual audio interruptions are reported by
            // AudioRecorder and handled through `lastInterruptionError`.
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
        .onChange(of: appState.shouldStopDictation) {
            guard appState.shouldStopDictation else { return }
            appState.shouldStopDictation = false
            handleKeyboardStopRequest()
        }
        .onChange(of: recorder.vadDidAutoStop) {
            if recorder.vadDidAutoStop && recorder.isRecording {
                // VAD detected silence after speech — auto-stop and transcribe
                stopAndTranscribe()
            }
        }
        .onChange(of: recorder.lastInterruptionError) {
            if let error = recorder.lastInterruptionError {
                MurmurDictationLiveActivity.end()
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityHint("Tap to retry model loading")

            default:
                EmptyView()
            }
        }
    }

    // MARK: - Keyboard Dictation Screen

    /// Apple only lets the app — never the keyboard extension — use the
    /// microphone, so Murmur has to be on screen while it records. This is the
    /// single instruction that matters while that happens.
    private var keyboardDictationScreen: some View {
        GeometryReader { geo in
            let illustrationHeight = min(300, max(150, geo.size.height * 0.34))

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        cancelKeyboardDictationFromScreen()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel dictation")
                    .accessibilityHint("Stops recording and inserts nothing.")
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                Spacer(minLength: 12)

                Text("Swipe back to your app")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                swipeBackIllustration(height: illustrationHeight)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                Text(swipeBackCaption)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 36)
                    .padding(.top, 20)

                Spacer(minLength: 16)

                swipeBackHint
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// The "device" drawing: a white bracket that reads as the app you are
    /// heading back to, with the home bar and a finger glow.
    private func swipeBackIllustration(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(white: 0.17))

            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white, lineWidth: 7)
                    .frame(width: width * 0.78, height: height * 1.1)
                    .position(x: width / 2, y: height * 0.68)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: 150, height: 4)
                .offset(y: height * 0.22)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [murmurAccent.opacity(0.55), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: 46
                    )
                )
                .frame(width: 92, height: 92)
                .offset(x: height * 0.33, y: height * 0.23)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var swipeBackHint: some View {
        VStack(spacing: 8) {
            Text("Swipe right on the bar below")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.black)

            HStack(spacing: 10) {
                Capsule()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 96, height: 5)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swipe right on the bar at the bottom of the screen to go back to your app")
    }

    private var swipeBackCaption: String {
        let minutes = MurmurPreferences.sessionDuration.minutes
        if minutes <= 1 {
            return "Apple only lets the Murmur app use the microphone. Swipe right on the bar below to head back — the mic releases the moment you finish."
        }
        let durationText = minutes >= 60 ? "hour" : "\(minutes) minutes"
        return "Apple only lets the Murmur app use the microphone. Swipe right on the bar below to head back — the mic stays live for the next \(durationText)."
    }

    private func cancelKeyboardDictationFromScreen() {
        MurmurDictationLiveActivity.end()
        if recorder.isRecording {
            _ = recorder.stopRecording()
            recorder.cleanupRecording()
        }
        transcriptionTask?.cancel()
        SharedDefaults.clearPendingText()
        SharedDefaults.setDictationRequested(false)
        SharedDefaults.clearDictationSession()
        keyboardCompletionMessage = nil
        keyboardDictationSessionID = nil
        isDictationFromKeyboard = false
    }

    private func swipeBackStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(murmurAccent))

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        .background(murmurAccent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                if !allAccessGranted {
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
                        .background(murmurSurfaceElevated(colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
        .background(murmurSurface(colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(murmurBorder(colorScheme, opacity: 0.09), lineWidth: 1)
        )
        .shadow(color: murmurCardShadow.opacity(colorScheme == .dark ? 0.72 : 1), radius: 16, y: 8)
        .padding(.horizontal, 20)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            UIPasteboard.general.string = entry.text
            showCopiedToast = true
            toastDismissTask?.cancel()
            toastDismissTask = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    showCopiedToast = false
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Copy transcription")
        .accessibilityHint("Copies this transcription to the clipboard")
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
        let localModelUnavailable =
            !CloudTranscriptionService.isReady &&
            (transcriptionService.modelState == .loading ||
             transcriptionService.modelState.isError)
        let disabled =
            !recorder.hasPermission ||
            (!CloudTranscriptionService.isReady &&
             transcriptionService.modelState == .loading) ||
            isProcessing

        return RecordingFAB(
            isRecording: recorder.isRecording,
            isDisabled: disabled,
            isDimmed: !recorder.hasPermission || localModelUnavailable || isProcessing,
            reduceMotion: reduceMotion
        ) {
            recordHaptic.prepare()
            handleRecordingTap()
        }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(murmurAccent)
                Text("Allow Murmur to Access")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                accessRow(icon: "mic.fill", tint: .orange, title: "Microphone", isGranted: recorder.hasPermission)
                Divider().opacity(0.4).padding(.leading, 52)
                accessRow(icon: "keyboard", tint: .blue, title: "Murmur Keyboard", isGranted: keyboardIsEnabled)
                Divider().opacity(0.4).padding(.leading, 52)
                accessRow(icon: "lock.shield", tint: murmurAccent, title: "Full Access", isGranted: fullAccessGranted)
            }
            .background(
                murmurSurface(colorScheme).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 8) {
                swipeBackStep(1, "Open Settings → General → Keyboard → Keyboards")
                swipeBackStep(2, "Turn on Murmur, then turn on Allow Full Access")
                swipeBackStep(3, "Tap Allow on the popup")
                swipeBackStep(4, "Come back to Murmur")
            }

            Button {
                openKeyboardSettings()
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(murmurAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            murmurSurfaceElevated(colorScheme),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(murmurBorder(colorScheme, opacity: 0.12), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }

    private var allAccessGranted: Bool {
        recorder.hasPermission && keyboardIsEnabled && fullAccessGranted
    }

    private func accessRow(
        icon: String,
        tint: Color,
        title: String,
        isGranted: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Set up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(isGranted ? "allowed" : "not set up")")
    }

    // MARK: - Helpers

    private func checkKeyboardEnabled() {
        // iOS 27 exposes third-party modes only by primary language (for Murmur,
        // simply "en-US"), so activeInputModes cannot reliably identify the
        // extension. Use the extension's App Group handshake, which is set only
        // after iOS has actually loaded Murmur as a keyboard.
        // This state can change twice during foreground activation while iOS
        // refreshes input modes. Animating the LazyVStack insertion/removal
        // briefly overlaps the banner, stats card, and first section header.
        keyboardIsEnabled = SharedDefaults.isKeyboardActive()
        fullAccessGranted = SharedDefaults.isFullAccessGranted()
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
        guard !recorder.isStarting else { return }
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
                        await startRecording()
                    }
                }
            } else {
                // Also kick off model load in the background for fallback
                if transcriptionService.modelState == .unloaded {
                    Task { await transcriptionService.loadModel() }
                }
                Task { await startRecording() }
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
            await startRecording()
        }
    }

    private func startRecording() async {
        clearErrorMessage()
        do {
            try await recorder.startRecording()
            MurmurDictationLiveActivity.start()
            if isDictationFromKeyboard, let keyboardDictationSessionID {
                SharedDefaults.setDictationPhase(
                    .recording,
                    sessionID: keyboardDictationSessionID
                )
                keyboardCompletionMessage =
                    "Recording started. Swipe back to your app, then tap the checkmark on Murmur’s keyboard."

                // The request flag is persistent, so this also catches a stop
                // signal delivered while the app was finishing startup.
                if SharedDefaults.consumeDictationStopRequest(
                    matching: keyboardDictationSessionID
                ) {
                    stopAndTranscribe()
                }
            }
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
        MurmurDictationLiveActivity.end()
        if isDictationFromKeyboard {
            SharedDefaults.setDictationPhase(
                .processing,
                sessionID: keyboardDictationSessionID
            )
        }

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

                let polished = await TranscriptCleanupService.process(rawText)
                let cleanedText = SnippetStore.apply(snippetStore.snippets, to: polished)

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
                        keyboardCompletionMessage = "Transcription ready. Murmur will insert it when the keyboard is visible."
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

    private func handleKeyboardStopRequest() {
        guard isDictationFromKeyboard,
              SharedDefaults.consumeDictationStopRequest(
                matching: keyboardDictationSessionID
              )
        else {
            return
        }

        if recorder.isRecording {
            stopAndTranscribe()
        }
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
        MurmurDictationLiveActivity.end()
        SharedDefaults.abandonDictationSession(reason: reason)
        SharedDefaults.setDictationRequested(false)
        keyboardCompletionMessage = nil
        isDictationFromKeyboard = false
        keyboardDictationSessionID = nil
    }
}

/// Owns the repeating pulse state so animation frames do not invalidate the
/// entire transcription list and all of its derived sections.
private struct RecordingFAB: View {
    let isRecording: Bool
    let isDisabled: Bool
    let isDimmed: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(murmurAccent.opacity(0.18))
                        .frame(width: 102, height: 102)
                        .scaleEffect(pulseScale)
                        .blur(radius: 2)
                        .animation(
                            reduceMotion
                                ? .linear(duration: 0.01)
                                : .easeInOut(duration: 1.05)
                                    .repeatForever(autoreverses: true),
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
                            colors: isRecording
                                ? [Color.red, Color.red.opacity(0.84)]
                                : [murmurAccentSecondary, murmurAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)
                    .shadow(
                        color: (isRecording ? Color.red : murmurAccent)
                            .opacity(0.38),
                        radius: isRecording ? 24 : 18,
                        y: 10
                    )

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .disabled(isDisabled)
        .opacity(isDimmed ? 0.55 : 1)
        .onAppear {
            pulseScale = isRecording && !reduceMotion ? 1.18 : 1
        }
        .onChange(of: isRecording) {
            pulseScale = isRecording && !reduceMotion ? 1.18 : 1
        }
        .accessibilityLabel(
            NSLocalizedString(
                isRecording ? "Stop recording" : "Start recording",
                comment: "Record button accessibility label"
            )
        )
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
    @ObservedObject var store: TranscriptionStore
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue
    @AppStorage("cloudDictationEnabled") private var cloudDictationEnabled = false
    @AppStorage("cloudProvider") private var cloudProviderRaw: String = CloudProvider.groq.rawValue
    @AppStorage("dictationAutoDetectLanguage") private var autoDetectLanguage = true
    @AppStorage("dictationSessionDuration") private var sessionDurationRaw = DictationSessionDuration.fiveMinutes.rawValue
    @AppStorage("historyRetentionDays") private var historyRetentionRaw = 14
    @StateObject private var snippetStore = SnippetStore()
    @State private var selectedLanguageCodes: [String] = MurmurPreferences.selectedLanguageCodes
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

    private var footerTextForEngine: String {
        switch transcriptionService.selectedEngine {
        case .whisper:
            return "Tiny is fastest with slightly lower accuracy. Base is more accurate but uses more memory. This model is also used as fallback when cloud dictation is unavailable."
        case .parakeet:
            return "Runs on the Neural Engine and downloads about 600 MB on first use. Parakeet has no prompt support, so personal-dictionary spellings aren't used as recognition hints with this engine."
        }
    }

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }

    private var settingsSessionDuration: DictationSessionDuration {
        DictationSessionDuration(rawValue: sessionDurationRaw) ?? .fiveMinutes
    }

    private var historyRetention: HistoryRetention {
        HistoryRetention(rawValue: historyRetentionRaw) ?? .fourteenDays
    }

    private var appearanceModeDisplay: String {
        (AppearanceMode(rawValue: appearanceMode) ?? .auto).displayName
    }

    private var snippetCountText: String {
        let count = snippetStore.snippets.count
        return count == 0 ? "None" : "\(count)"
    }

    private var languageSummary: String {
        if autoDetectLanguage { return "Auto detect" }
        let names = selectedLanguageCodes.compactMap { DictationLanguage.named($0)?.name }
        if names.isEmpty { return "English" }
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    private func settingsRow(
        icon: String,
        color: Color,
        title: String,
        value: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PersonalDictionaryView()
                } label: {
                    settingsRow(
                        icon: "book.closed.fill",
                        color: .green,
                        title: "Vocabulary",
                        value: "\(PersonalDictionary.enabledEntries.count)"
                    )
                }

                NavigationLink {
                    SnippetsView(store: snippetStore)
                } label: {
                    settingsRow(
                        icon: "textformat",
                        color: .indigo,
                        title: "Snippets",
                        value: snippetCountText
                    )
                }

                NavigationLink {
                    LanguageView()
                } label: {
                    settingsRow(
                        icon: "globe",
                        color: .orange,
                        title: "Language",
                        value: languageSummary
                    )
                }

                NavigationLink {
                    SessionDurationView()
                } label: {
                    settingsRow(
                        icon: "clock.fill",
                        color: .blue,
                        title: "Session duration",
                        value: settingsSessionDuration.title
                    )
                }
            } header: {
                Text("Dictation")
            }

            Section {
                NavigationLink {
                    ThemeView()
                } label: {
                    settingsRow(
                        icon: "paintpalette.fill",
                        color: .purple,
                        title: "Theme",
                        value: appearanceModeDisplay
                    )
                }
            } header: {
                Text("Appearance")
            }

            Section {
                NavigationLink {
                    HistoryRetentionView(store: store)
                } label: {
                    settingsRow(
                        icon: "clock.arrow.circlepath",
                        color: .blue,
                        title: "Dictation history",
                        value: historyRetention.title
                    )
                }
            } header: {
                Text("History")
            }

            Section {
                Picker(selection: Binding(
                    get: { transcriptionService.selectedEngine },
                    set: { transcriptionService.setEngine($0) }
                )) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                            Text(engine.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(engine)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)

                if transcriptionService.selectedEngine == .whisper {
                    Picker(selection: $transcriptionService.selectedModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
            } header: {
                Text("Transcription Engine")
            } footer: {
                Text(footerTextForEngine)
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
                    Text("Murmur v\(appVersion)")
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
            selectedLanguageCodes = MurmurPreferences.selectedLanguageCodes
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

// MARK: - Personal Dictionary

struct PersonalDictionaryView: View {
    @State private var entries = PersonalDictionary.entries
    @State private var preferredSpelling = ""
    @State private var spokenAliases = ""
    @State private var editingEntry: PersonalDictionaryEntry?

    private var canAdd: Bool {
        !preferredSpelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                TextField("Preferred spelling", text: $preferredSpelling)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                TextField("Sounds like (optional)", text: $spokenAliases)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    addEntry()
                } label: {
                    Label("Add to Dictionary", systemImage: "plus.circle.fill")
                }
                .disabled(!canAdd)
            } header: {
                Text("New Entry")
            } footer: {
                Text("Add comma-separated pronunciations or common mishearings, such as “shiv on” for “Siobhan.”")
            }

            Section {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Dictionary Entries",
                        systemImage: "text.book.closed",
                        description: Text("Add words Murmur should recognize and spell consistently.")
                    )
                } else {
                    ForEach(entries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.phrase)
                                        .foregroundStyle(.primary)
                                    if !entry.spokenAliases.isEmpty {
                                        Text(entry.spokenAliases.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Toggle(
                                    "Enabled",
                                    isOn: Binding(
                                        get: { entry.isEnabled },
                                        set: { setEnabled(entry.id, $0) }
                                    )
                                )
                                .labelsHidden()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteEntries)
                }
            } header: {
                Text("Words & Phrases")
            } footer: {
                if !entries.isEmpty {
                    Text("Tap an entry to edit it. Swipe left to delete.")
                }
            }
        }
        .navigationTitle("Personal Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                PersonalDictionaryEntryEditor(entry: entry) { updatedEntry in
                    guard let index = entries.firstIndex(where: { $0.id == updatedEntry.id }) else {
                        return
                    }
                    entries[index] = updatedEntry
                    save()
                }
            }
        }
    }

    private func addEntry() {
        let aliases = spokenAliases
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        entries.append(
            PersonalDictionaryEntry(
                phrase: preferredSpelling,
                spokenAliases: aliases
            )
        )
        save()
        preferredSpelling = ""
        spokenAliases = ""
    }

    private func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isEnabled = enabled
        save()
    }

    private func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        PersonalDictionary.save(entries)
        entries = PersonalDictionary.entries
    }
}

struct PersonalDictionaryEntryEditor: View {
    @State private var phrase: String
    @State private var aliases: String
    @State private var isEnabled: Bool

    let entry: PersonalDictionaryEntry
    let onSave: (PersonalDictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    init(entry: PersonalDictionaryEntry, onSave: @escaping (PersonalDictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _phrase = State(initialValue: entry.phrase)
        _aliases = State(initialValue: entry.spokenAliases.joined(separator: ", "))
        _isEnabled = State(initialValue: entry.isEnabled)
    }

    var body: some View {
        Form {
            Section {
                TextField("Preferred spelling", text: $phrase)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                TextField("Sounds like", text: $aliases)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Enabled", isOn: $isEnabled)
            } footer: {
                Text("Use comma-separated pronunciations or common mishearings.")
            }
        }
        .navigationTitle("Edit Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = entry
                    updated.phrase = phrase
                    updated.spokenAliases = aliases
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    updated.isEnabled = isEnabled
                    onSave(updated)
                    dismiss()
                }
                .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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



// MARK: - Theme

private struct ThemeView: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue

    private var current: AppearanceMode {
        AppearanceMode(rawValue: appearanceMode) ?? .auto
    }

    var body: some View {
        List {
            Section {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        appearanceMode = mode.rawValue
                    } label: {
                        HStack {
                            Text(mode.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if current == mode {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(murmurAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Auto follows your system setting. Murmur's keyboard matches the app you're typing in.")
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
    }
}

// MARK: - Snippets

private struct SnippetsView: View {
    @ObservedObject var store: SnippetStore
    @State private var searchText = ""
    @State private var trigger = ""
    @State private var expansion = ""

    private var filtered: [Snippet] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(query)
                || $0.expansion.localizedCaseInsensitiveContains(query)
        }
    }

    private var canAdd: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                Text("Snippets expand a short trigger into longer text while you dictate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Trigger (e.g. omw)…", text: $trigger)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Expansion text…", text: $expansion)
                Button {
                    store.add(trigger: trigger, expansion: expansion)
                    trigger = ""
                    expansion = ""
                } label: {
                    Label("Add snippet", systemImage: "plus.circle.fill")
                }
                .disabled(!canAdd)
            }

            Section {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Text("Aa")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(searchText.isEmpty ? "No snippets yet" : "No matches")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { snippet in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(snippet.trigger)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(murmurAccent)
                            Text(snippet.expansion)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }
                    .onDelete { offsets in
                        let targets = filtered
                        for index in offsets where targets.indices.contains(index) {
                            store.delete(targets[index])
                        }
                    }
                }
            } header: {
                Text("\(filtered.count) Snippet\(filtered.count == 1 ? "" : "s")")
            }
        }
        .searchable(text: $searchText, prompt: "Search snippets")
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
    }
}

// MARK: - Language

private struct LanguageView: View {
    @AppStorage("dictationAutoDetectLanguage") private var autoDetect = true
    @State private var selected: [String] = MurmurPreferences.selectedLanguageCodes
    @State private var search = ""

    private var filtered: [DictationLanguage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return DictationLanguage.all }
        return DictationLanguage.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Auto-detect language", isOn: $autoDetect)
            } footer: {
                Text("Selecting specific languages increases transcription accuracy. Parakeet covers 25 European languages; Whisper covers the full list.")
            }

            Section {
                ForEach(filtered) { language in
                    Button {
                        toggle(language)
                    } label: {
                        HStack(spacing: 10) {
                            Text(language.flag)
                            Text(language.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(language.code) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(murmurAccent)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("All Languages")
            } footer: {
                if autoDetect {
                    Text("Murmur picks the language automatically. Turn auto-detect off to prefer the languages selected here.")
                }
            }
        }
        .searchable(text: $search, prompt: "Search languages")
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
        .onChange(of: selected) {
            MurmurPreferences.selectedLanguageCodes = selected
        }
    }

    private func toggle(_ language: DictationLanguage) {
        if let index = selected.firstIndex(of: language.code) {
            // Keep at least one language so the pipeline always has a hint.
            guard selected.count > 1 else { return }
            selected.remove(at: index)
        } else {
            selected.append(language.code)
        }
    }
}

// MARK: - Session Duration

private struct SessionDurationView: View {
    @AppStorage("dictationSessionDuration") private var durationRaw = DictationSessionDuration.fiveMinutes.rawValue

    private var selected: DictationSessionDuration {
        DictationSessionDuration(rawValue: durationRaw) ?? .fiveMinutes
    }

    var body: some View {
        List {
            Section {
                ForEach(DictationSessionDuration.allCases) { option in
                    Button {
                        durationRaw = option.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(selected == option ? murmurAccent : .secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            if selected == option {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(murmurAccent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("How long dictation stays ready to resume after you finish speaking. A longer duration resumes instantly; a shorter one releases the microphone sooner.")
            }
        }
        .navigationTitle("Session duration")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
        .onChange(of: durationRaw) {
            SharedDefaults.setDictationSessionDurationMinutes(max(1, selected.minutes))
        }
        .onAppear {
            SharedDefaults.setDictationSessionDurationMinutes(max(1, selected.minutes))
        }
    }
}

// MARK: - History Retention

private struct HistoryRetentionView: View {
    @ObservedObject var store: TranscriptionStore
    @AppStorage("historyRetentionDays") private var retentionRaw = 14
    @State private var showDeleteConfirmation = false

    private var selected: HistoryRetention {
        HistoryRetention(rawValue: retentionRaw) ?? .fourteenDays
    }

    var body: some View {
        List {
            Section {
                ForEach(HistoryRetention.allCases) { option in
                    Button {
                        retentionRaw = option.rawValue
                    } label: {
                        HStack {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected == option {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(murmurAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Keep history for")
            } footer: {
                Text("Older transcriptions are automatically deleted after this window. Lifetime word totals are unaffected.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text("Delete all history")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Dictation history")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
        .onChange(of: retentionRaw) {
            MurmurPreferences.historyRetention = selected
            store.applyRetentionPolicy()
        }
        .alert("Delete all history?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every transcription and resets your lifetime word total.")
        }
    }
}
