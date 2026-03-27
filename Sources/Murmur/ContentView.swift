import SwiftUI

// MARK: - Accent colour

private let murmurAccent = Color(red: 0.49, green: 0.36, blue: 0.89)
private let warmBackground = Color(red: 0.96, green: 0.96, blue: 0.94)

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

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

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

    // Pulse animation for recording button
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            warmBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                statusBar

                if !keyboardIsEnabled {
                    keyboardSetupBanner
                }

                statsSection

                transcriptionList

                Spacer(minLength: 0)
            }

            // Floating action button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    recordFAB
                        .padding(.trailing, 24)
                        .padding(.bottom, 40)
                }
            }

            // Copied toast
            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Slide-out menu (top layer)
            MenuView(isOpen: $showMenu) { dest in
                switch dest {
                case .home: break
                case .history: break
                case .settings: showSettings = true
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
        .onChange(of: appState.shouldStartDictation) { shouldStart in
            if shouldStart {
                appState.shouldStartDictation = false
                isDictationFromKeyboard = SharedDefaults.consumeDictationRequested()
                dictationTask = handleDictationRequest()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
        .animation(.spring(response: 0.3), value: showMenu)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ZStack {
            // Perfectly centered title
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(murmurAccent)
                Text("Murmur")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
            }

            // Left and right items pinned to edges
            HStack {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showMenu.toggle()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Button {
                    if let url = URL(string: "https://buymeacoffee.com/tgn5dq5j8xs") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 14, weight: .medium))
                        Text("Buy Me a Coffee")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.yellow, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        Group {
            switch transcriptionService.modelState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(transcriptionService.loadingProgress.isEmpty
                         ? NSLocalizedString("Loading model…", comment: "Status bar loading text")
                         : transcriptionService.loadingProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)

            case .error(let msg):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)

            default:
                EmptyView()
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 6) {
            Text("\(formatNumber(store.totalWordCount)) words")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(murmurAccent)

            Text("you've dictated so far.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)

            Text("Average \(store.avgWordsPerDictation) words per dictation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(murmurAccent.opacity(0.06))
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func formatNumber(_ n: Int) -> String {
        cachedNumberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    // Show error banner inline if present
                    if let error = errorMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }

                    let grouped = groupedEntries()
                    ForEach(grouped, id: \.0) { group in
                        sectionHeader(group.0)
                        ForEach(group.1) { entry in
                            entryRow(entry)
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .padding(.bottom, 120)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(murmurAccent.opacity(0.35))
            Text("No transcriptions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap the mic to start dictating")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.8)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func entryRow(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title line - first ~50 chars bold
            let titleText = String(entry.text.prefix(60)).components(separatedBy: ".").first ?? String(entry.text.prefix(60))
            Text(titleText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(timeString(entry.timestamp))
                .font(.system(size: 12))
                .foregroundStyle(murmurAccent.opacity(0.6))
                .padding(.top, 2)

            // Purple accent line
            Rectangle()
                .fill(murmurAccent.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 8)

            // Body text
            Text(entry.text)
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.text
                showCopiedToast = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    showCopiedToast = false
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

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"

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
                key = dateFormatter.string(from: entry.timestamp)
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
                        .fill(murmurAccent.opacity(0.2))
                        .frame(width: 72, height: 72)
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: pulseScale
                        )
                }

                Circle()
                    .fill(recorder.isRecording ? Color.red : murmurAccent)
                    .frame(width: 56, height: 56)
                    .shadow(
                        color: (recorder.isRecording ? Color.red : murmurAccent).opacity(0.4),
                        radius: 10, y: 4
                    )

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .disabled(!recorder.hasPermission || transcriptionService.modelState != .loaded || isProcessing)
        .opacity((!recorder.hasPermission || transcriptionService.modelState != .loaded || isProcessing) ? 0.5 : 1.0)
        .onChange(of: recorder.isRecording) { recording in
            if recording {
                pulseScale = 1.25
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Copied to clipboard")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .padding(.top, 60)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Keyboard Setup Banner

    private var keyboardSetupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.title3)
                .foregroundStyle(murmurAccent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Enable Murmur Keyboard")
                    .font(.subheadline.weight(.semibold))
                Text("Dictate in any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openKeyboardSettings()
            } label: {
                Text("Set Up")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(murmurAccent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return // CancellationError — bail out
                }
            }
            guard !Task.isCancelled else { return }
            guard transcriptionService.modelState == .loaded else {
                errorMessage = NSLocalizedString("Cannot start dictation: model not loaded.", comment: "Error when dictation attempted before model is ready")
                return
            }
            guard recorder.hasPermission else {
                errorMessage = NSLocalizedString("Cannot start dictation: no microphone permission.", comment: "Error when dictation attempted without mic permission")
                showMicPermissionAlert = true
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
                        isDictationFromKeyboard = false
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                }
            } catch is CancellationError {
                // Suppress cancellation — cleanup handled by defer
            } catch {
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
                        Text("Murmur v1.2.3")
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
