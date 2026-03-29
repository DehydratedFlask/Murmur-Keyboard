import SwiftUI

// MARK: - Accent colour

private let murmurAccent = Color(red: 0.39, green: 0.28, blue: 0.95)
private let murmurAccentSecondary = Color(red: 0.53, green: 0.44, blue: 1.0)
private let murmurCardShadow = Color.black.opacity(0.08)

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriptionService = TranscriptionService()
    @StateObject private var store = TranscriptionStore()

    // UI state
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showMenu = false
    @State private var showCopiedToast = false
    @State private var keyboardIsEnabled = false
    @State private var shareItem: ShareableString?
    @State private var isDictationFromKeyboard = false
    @State private var dictationTask: Task<Void, Never>?
    @State private var showMicPermissionAlert = false
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionTaskID: UInt = 0
    @State private var toastDismissTask: Task<Void, Never>?

    // Pulse animation for recording button
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                statusBar

                transcriptionList
            }

            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    recordFAB
                        .padding(.trailing, 24)
                        .padding(.bottom, 34)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(transcriptionService: transcriptionService)
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
            await recorder.requestPermission()
            await transcriptionService.loadModel()
            checkKeyboardEnabled()
        }
        .onDisappear {
            dictationTask?.cancel()
            transcriptionTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            checkKeyboardEnabled()
        }
        .onChange(of: appState.shouldStartDictation) {
            if appState.shouldStartDictation {
                appState.shouldStartDictation = false
                isDictationFromKeyboard = SharedDefaults.consumeDictationRequested()
                dictationTask?.cancel()
                dictationTask = handleDictationRequest()
            }
        }
        .onChange(of: recorder.lastInterruptionError) {
            if let error = recorder.lastInterruptionError {
                errorMessage = error
            }
        }
        .onReceive(store.$lastError) { error in
            if let error {
                errorMessage = error.localizedDescription
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
        .animation(.spring(response: 0.3), value: showMenu)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [murmurAccent, murmurAccentSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Murmur")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                if let url = URL(string: "https://buymeacoffee.com/tgn5dq5j8xs") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Color.yellow.gradient, in: Circle())
                    .shadow(color: Color.yellow.opacity(0.24), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Buy me a coffee")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(Color(.systemGroupedBackground).opacity(0.94))
    }

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
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            default:
                EmptyView()
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation at a glance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Text("\(formatNumber(store.totalWordCount)) words")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Average \(store.avgWordsPerDictation) words per dictation")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [murmurAccent, murmurAccentSecondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: murmurAccent.opacity(0.22), radius: 24, y: 12)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    private func formatNumber(_ n: Int) -> String {
        cachedNumberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                if !keyboardIsEnabled {
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
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
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
            .padding(.bottom, 128)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [murmurAccent.opacity(0.16), murmurAccentSecondary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 108, height: 108)

                Circle()
                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: 108, height: 108)

                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .medium))
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
        .padding(.vertical, 44)
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
        let titleText = String(entry.text.prefix(60)).components(separatedBy: ".").first ?? String(entry.text.prefix(60))

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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: murmurCardShadow, radius: 16, y: 8)
        .padding(.horizontal, 20)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                shareItem = ShareableString(text: entry.text)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(murmurAccent)

            Button(role: .destructive) {
                withAnimation {
                    store.delete(entry)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
            .tint(.blue)
        }
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

    // MARK: - Floating Record Button

    private var recordFAB: some View {
        Button {
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
        .disabled(!recorder.hasPermission || transcriptionService.modelState != .loaded || isProcessing)
        .opacity((!recorder.hasPermission || transcriptionService.modelState != .loaded || isProcessing) ? 0.55 : 1.0)
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
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .padding(.top, 66)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Keyboard Setup Banner

    private var keyboardSetupBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(murmurAccent.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(murmurAccent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Enable Murmur Keyboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Use Murmur for fast dictation in any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Button {
                openKeyboardSettings()
            } label: {
                Text("Set Up")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(murmurAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(.secondarySystemGroupedBackground), Color(.secondarySystemGroupedBackground).opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(murmurAccent.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: murmurAccent.opacity(0.08), radius: 14, y: 8)
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

        withAnimation { keyboardIsEnabled = enabled }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Recording Actions

    private func handleRecordingTap() {
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    @discardableResult
    private func handleDictationRequest() -> Task<Void, Never> {
        Task {
            for _ in 0..<60 {
                if transcriptionService.modelState == .loaded && recorder.hasPermission { break }
                if transcriptionService.modelState.isError { break }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return // CancellationError — bail out
                }
            }
            guard !Task.isCancelled else { return }
            guard transcriptionService.modelState == .loaded else {
                errorMessage = NSLocalizedString("Cannot start dictation: model not loaded.", comment: "Error when dictation attempted before model is ready")
                isDictationFromKeyboard = false
                return
            }
            guard recorder.hasPermission else {
                errorMessage = NSLocalizedString("Cannot start dictation: no microphone permission.", comment: "Error when dictation attempted without mic permission")
                showMicPermissionAlert = true
                isDictationFromKeyboard = false
                return
            }
            startRecording()
        }
    }

    private func startRecording() {
        errorMessage = nil
        do {
            try recorder.startRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndTranscribe() {
        guard let audioURL = recorder.stopRecording() else {
            errorMessage = NSLocalizedString("No audio was recorded.", comment: "Error when recording produces no audio")
            return
        }
        isProcessing = true
        errorMessage = nil

        // Cancel any existing transcription task before starting a new one
        transcriptionTask?.cancel()
        transcriptionTaskID &+= 1
        let myTaskID = transcriptionTaskID
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
                let rawText = try await transcriptionService.transcribe(audioURL: audioURL)
                let cleanedText = TextProcessor.process(rawText)

                if !cleanedText.isEmpty {
                    let entry = TranscriptionEntry(text: cleanedText)
                    withAnimation {
                        store.save(entry)
                    }

                    if isDictationFromKeyboard {
                        SharedDefaults.setPendingText(cleanedText)
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                }
                isDictationFromKeyboard = false
            } catch is CancellationError {
                isDictationFromKeyboard = false
            } catch {
                isDictationFromKeyboard = false
                errorMessage = error.localizedDescription
            }
        }
        transcriptionTask = task
    }
}

// MARK: - ShareableString (Identifiable wrapper for sheet)

private struct ShareableString: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var transcriptionService: TranscriptionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Model", selection: $transcriptionService.selectedModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Whisper Model")
                } footer: {
                    Text("Tiny is fastest with slightly lower accuracy. Base is more accurate but uses more memory.")
                }

                Section {
                    Button("Reload Model") {
                        Task {
                            await transcriptionService.unloadModel()
                            await transcriptionService.loadModel()
                            dismiss()
                        }
                    }
                    .disabled(transcriptionService.modelState == .loading || transcriptionService.isTranscribing)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Murmur v1.0")
                            .font(.headline)
                        Text("On-device speech-to-text powered by WhisperKit.\nNo data leaves your device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(murmurAccent)
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
