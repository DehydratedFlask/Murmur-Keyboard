import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

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

private struct ShareableString: Identifiable {
    let id = UUID()
    let text: String
}

private enum MurmurTab: Hashable { case dictate, history, settings }

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @EnvironmentObject private var capture: CaptureCoordinator
    @State private var editorEntry: TranscriptionEntry?
    @State private var draftToDiscard: RecordingDraft?
    @State private var keyboardIsEnabled = false
    @State private var fullAccessGranted = false
    @State private var shareItem: ShareableString?
    @State private var searchText = ""
    @State private var selectedTab = MurmurTab.dictate
    private var recorder: AudioRecorder { capture.recorder }
    private var transcriptionService: TranscriptionService { capture.transcriptionService }
    private var store: TranscriptionStore { capture.store }
    private var draftStore: RecordingDraftStore { capture.draftStore }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    DictateView(capture: capture, showHistory: { selectedTab = .history },
                                showSettings: { selectedTab = .settings })
                        .navigationTitle("Dictate")
                }
                .tabItem { Label("Dictate", systemImage: "mic") }
                .tag(MurmurTab.dictate)

                NavigationStack {
                    transcriptionList
                        .navigationTitle("History")
                        .toolbar {
                            if recorder.isRecording || capture.isProcessing {
                                Button("Current dictation", systemImage: "waveform") { selectedTab = .dictate }
                            }
                        }
                }
                .tabItem { Label("History", systemImage: "clock") }
                .tag(MurmurTab.history)

                NavigationStack {
                    SettingsView(transcriptionService: transcriptionService, store: store,
                                 snippetStore: capture.snippetStore)
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MurmurTab.settings)
            }
            .tint(murmurAccent)

            if capture.isDictationFromKeyboard {
                keyboardDictationScreen
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = capture.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if !draftStore.drafts.isEmpty {
                            Button("View saved recordings") {
                                if capture.isDictationFromKeyboard, !recorder.isRecording {
                                    capture.cancelKeyboardDictationFromScreen()
                                }
                                selectedTab = .history
                            }
                        } else if transcriptionService.modelState.isError {
                            Button("Retry model") { Task { await transcriptionService.loadModel() } }
                        } else {
                            Button("Try microphone again") { capture.retryAfterError() }
                                .disabled(recorder.isRecording || capture.isProcessing || capture.captureStartPending)
                        }
                        Spacer()
                        Button("Dismiss") { capture.clearErrorMessage() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .accessibilityElement(children: .contain)
            }
        }
        .overlay(alignment: .top) {
            if capture.showCopiedToast { copiedToast.allowsHitTesting(false) }
            if capture.showCloudFallbackToast { cloudFallbackToast.allowsHitTesting(false) }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(text: item.text)
        }
        .sheet(item: $editorEntry) { entry in
            TranscriptEditorView(entry: entry, store: store)
        }
        .confirmationDialog("Discard this recording?", isPresented: Binding(
            get: { draftToDiscard != nil },
            set: { if !$0 { draftToDiscard = nil } }
        ), titleVisibility: .visible) {
            if let draft = draftToDiscard {
                Button("Discard recording", role: .destructive) {
                    do { try draftStore.discard(draft) }
                    catch { capture.presentError(error.localizedDescription) }
                    draftToDiscard = nil
                }
            }
        } message: {
            Text("This permanently deletes the saved audio from this iPhone.")
        }
        .alert("Microphone Access Required", isPresented: $capture.showMicPermissionAlert) {
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
            capture.bootstrap()
            checkKeyboardEnabled()
            openRequestedEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            capture.handleMemoryWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            checkKeyboardEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Immediate check on activation
            checkKeyboardEnabled()
            capture.finishClipboardDeliveryIfPossible()
            openRequestedEditor()
            // Freshly used app: reopen the warm window so the keyboard can ask
            // for dictation without a redirect while this process is alive.
            SharedDefaults.extendWarmSession(
                minutes: MurmurPreferences.sessionDuration.minutes
            )
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
        .onChange(of: appState.shouldStartDictation) { capture.handleStartDictationRequest() }
        .onChange(of: appState.shouldStopDictation) {
            guard appState.shouldStopDictation else { return }
            appState.shouldStopDictation = false
            capture.handleKeyboardStopRequest()
        }
        .onChange(of: appState.captureRequest?.id) { capture.handleCaptureRequest() }
        .onChange(of: appState.editEntryID) { openRequestedEditor() }
        .onChange(of: appState.pauseRequest) {
            guard let paused = appState.pauseRequest else { return }
            appState.pauseRequest = nil
            capture.setRecordingPaused(paused)
        }
        .onChange(of: appState.pauseRequestSequence) {
            guard let paused = SharedDefaults.consumePauseRequest(sessionID: capture.keyboardDictationSessionID) else { return }
            capture.setRecordingPaused(paused)
        }
        .onChange(of: store.entries.count) { openRequestedEditor() }
        .onReceive(store.$lastError) { error in
            if let error {
                capture.presentError(error.localizedDescription)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: capture.showCopiedToast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: capture.showCloudFallbackToast)
    }

    private var keyboardDictationScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Dictation for your keyboard", systemImage: "keyboard")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(recorder.isRecording ? "Keep speaking, in any app." : "Preparing your dictation.")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use the app switcher or the iOS return link, if shown, to go back to your app. Murmur keeps recording. Finish from the keyboard when you are ready.")
                        .foregroundStyle(.secondary)
                    if recorder.isRecording {
                        CaptureControlsView(capture: capture)
                    } else {
                        ModelStatusView(service: transcriptionService)
                        ProgressView(capture.isProcessing ? "Finishing your text…" : "Starting microphone…")
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Keyboard dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel handoff") { capture.cancelKeyboardDictationFromScreen() }
                }
            }
        }
    }

    // MARK: - Search

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [TranscriptionEntry] {
        guard !searchQuery.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.text.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search transcriptions", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            murmurSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 20)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No matches")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Nothing found for “\(searchQuery)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }

    // MARK: - Transcription List

    @ViewBuilder
    private var savedDrafts: some View {
        if let message = draftStore.lastError {
            Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
        }
        ForEach(draftStore.drafts.filter { $0.id != capture.activeDraft?.id }) { draft in
            VStack(alignment: .leading, spacing: 10) {
                Label("Saved recording", systemImage: "waveform.badge.exclamationmark")
                    .font(.headline)
                Text(draft.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                Text(draft.message).font(.subheadline).foregroundStyle(.secondary)
                if let raw = draft.rawText {
                    Text(raw).font(.caption).lineLimit(3).textSelection(.enabled)
                }
                HStack {
                    Button("Retry transcription") { capture.retryDraft(draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.isProcessing || recorder.isRecording || recorder.isStarting || capture.captureStartPending)
                    Menu {
                        Button("Keep for later") {
                            do { try draftStore.update(draft, message: "Kept for later. Retry when you are ready.") }
                            catch { capture.presentError(error.localizedDescription) }
                        }
                        ShareLink(item: draftStore.audioURL(for: draft)) {
                            Label("Export recording", systemImage: "square.and.arrow.up")
                        }
                        Button("Discard", role: .destructive) { draftToDiscard = draft }
                            .disabled(capture.isProcessing)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(murmurSurface(colorScheme), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)
        }
    }

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if draftStore.drafts.contains(where: { $0.id != capture.activeDraft?.id }) {
                    sectionHeader("Saved recordings")
                    savedDrafts
                }
                if !store.entries.isEmpty { searchBar }
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Your words, kept here", systemImage: "text.bubble")
                    } description: {
                        Text("Finished dictations appear here. Saved recordings stay available until you finish or discard them.")
                    } actions: {
                        Button("Start a dictation") { selectedTab = .dictate }
                    }
                } else if filteredEntries.isEmpty {
                    noMatchesState
                } else {
                    ForEach(groupedEntries(), id: \.0) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(group.0)
                            ForEach(group.1) { entry in entryRow(entry) }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
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

        return Button { editorEntry = entry } label: {
            VStack(alignment: .leading, spacing: 12) {
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
        }
        .buttonStyle(.plain)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(murmurSurface(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityLabel("Edit transcription: \(titleText)")
        .accessibilityHint("Opens the transcript, original words, and correction tools")
        .contextMenu {
            Button { editorEntry = entry } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                capture.copyText(entry.text)
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

        for entry in filteredEntries {
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

    private func openRequestedEditor() {
        guard let id = appState.editEntryID else { return }
        if let entry = store.entries.first(where: { $0.id == id }) {
            editorEntry = entry
            appState.editEntryID = nil
        }
    }


}

struct SettingsView: View {
    @EnvironmentObject private var capture: CaptureCoordinator
    @ObservedObject var transcriptionService: TranscriptionService
    @ObservedObject var store: TranscriptionStore
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue
    @AppStorage("cloudDictationEnabled") private var cloudDictationEnabled = false
    @AppStorage("cloudProvider") private var cloudProviderRaw: String = CloudProvider.groq.rawValue
    @AppStorage("dictationAutoDetectLanguage", store: SharedDefaults.suite) private var autoDetectLanguage = true
    @AppStorage("dictationSessionDuration") private var sessionDurationRaw = DictationSessionDuration.fiveMinutes.rawValue
    @AppStorage("historyRetentionDays") private var historyRetentionRaw = 0
    @AppStorage("aiCleanupEnabled") private var aiCleanupEnabled = true
    @AppStorage("formattingSurface", store: SharedDefaults.suite) private var formattingSurfaceRaw = DictationSurface.automatic.rawValue
    @AppStorage("recordingSilenceMode") private var silenceModeRaw = RecordingSilenceMode.thinkingTime.rawValue
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled = false
    @AppStorage("reviewBeforeInsertion", store: SharedDefaults.suite) private var reviewBeforeInsertion = false
    @State private var keyHapticsEnabled = SharedDefaults.isKeyHapticsEnabled()
    @ObservedObject var snippetStore: SnippetStore
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
            return "A larger on-device model. Download progress and cached storage appear below. Parakeet does not use vocabulary recognition hints; spelling corrections still apply during formatting."
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

    private var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private var cleanupFooterText: String {
        guard appleIntelligenceAvailable else {
            return "Apple Intelligence isn't available on this device, so Murmur uses its built-in cleanup for punctuation and capitalization."
        }
        if aiCleanupEnabled {
            return "Removes filler words and restructures what you said into clean sentences on-device with Apple's model, shaped for the field you are typing in. It never adds facts, summarizes or answers — only formats what you spoke."
        }
        return "Off: Murmur uses its built-in punctuation cleanup. Turn this on to have Apple's on-device model format your dictation as written prose."
    }

    private var historyRetention: HistoryRetention {
        HistoryRetention(rawValue: historyRetentionRaw) ?? .forever
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
            Section("Vocabulary & Snippets") {
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

            }
            Section {
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

            } header: {
                Text("Dictation")
            }

            Section {
                Picker("Stop after silence", selection: $silenceModeRaw) {
                    ForEach(RecordingSilenceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle("Live transcript preview", isOn: $livePreviewEnabled)
                Toggle("Review before keyboard insertion", isOn: $reviewBeforeInsertion)
            } header: {
                Text("Recording")
            } footer: {
                Text("Quick message stops after 2 seconds of silence; Thinking time waits 10 seconds. Stop manually waits for you. Preview uses the local model and shows recent speech; final text may change.")
            }

            Section {
                Text("Add Dictate to Clipboard or Capture a Voice Note in Shortcuts, then assign it to your iPhone’s Action Button. Run the shortcut again while recording to finish. Text is saved locally; clipboard capture copies after transcription when Murmur is active.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } header: {
                Text("Action Button & Shortcuts")
            }

            Section {
                Toggle(isOn: $aiCleanupEnabled) {
                    settingsRow(
                        icon: "wand.and.stars",
                        color: .pink,
                        title: "Apple Intelligence cleanup"
                    )
                }

                NavigationLink {
                    FormattingSurfaceView()
                } label: {
                    settingsRow(
                        icon: "text.alignleft",
                        color: .purple,
                        title: "Formatting style",
                        value: DictationSurface(rawValue: formattingSurfaceRaw)?.title ?? "Automatic"
                    )
                }
            } header: {
                Text("Formatting")
            } footer: {
                Text(cleanupFooterText)
            }

            Section {
                Button("Open keyboard settings", systemImage: "keyboard") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Text("Enable Murmur in Settings → General → Keyboard → Keyboards, then allow Full Access for app-to-keyboard dictation exchange. Cloud recognition is optional.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle(isOn: $keyHapticsEnabled) {
                    settingsRow(
                        icon: "hand.tap.fill",
                        color: .teal,
                        title: "Key haptics"
                    )
                }
                .onChange(of: keyHapticsEnabled) {
                    SharedDefaults.setKeyHapticsEnabled(keyHapticsEnabled)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("A small tap for each key press. Off by default. Keyboard feedback never plays audio clicks.")
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
                Text("Privacy & Storage")
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
                    Text("Recognition engine")
                }
                .pickerStyle(.menu)

                if transcriptionService.selectedEngine == .whisper {
                    Picker(selection: $transcriptionService.selectedModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    } label: {
                        Text("Whisper model")
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Models")
            } footer: {
                Text(footerTextForEngine)
            }

            Section {
                ModelStatusView(service: transcriptionService)
                if transcriptionService.isModelSwitchDeferred {
                    Label("Your new model will be used after this dictation finishes.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Reload Model") {
                    Task {
                        await transcriptionService.unloadModel()
                        await transcriptionService.loadModel()
                    }
                }
                .disabled(transcriptionService.modelState == .loading || transcriptionService.isTranscribing || capture.recorder.isRecording || capture.captureStartPending || capture.isProcessing)
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
                         ? "Speech-to-text via \(selectedProvider.displayName). Downloaded local models provide fallback; failed recordings stay available to retry."
                         : "On-device speech-to-text with Whisper or Parakeet. Recordings and transcripts stay on this iPhone when cloud dictation is off.")
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
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
    @AppStorage("dictationAutoDetectLanguage", store: SharedDefaults.suite) private var autoDetect = true
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
        .onAppear { selected = MurmurPreferences.selectedLanguageCodes }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            selected = MurmurPreferences.selectedLanguageCodes
        }
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
    @AppStorage("historyRetentionDays") private var retentionRaw = 0
    @State private var showDeleteConfirmation = false

    private var selected: HistoryRetention {
        HistoryRetention(rawValue: retentionRaw) ?? .forever
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

// MARK: - Formatting Surface

/// Picks the shape the formatter gives dictated text. Automatic follows the
/// field the keyboard was in, which is what Amical does by reading the active
/// app; the explicit styles force one shape everywhere.
private struct FormattingSurfaceView: View {
    @AppStorage("formattingSurface", store: SharedDefaults.suite) private var surfaceRaw = DictationSurface.automatic.rawValue

    private var selected: DictationSurface {
        DictationSurface(rawValue: surfaceRaw) ?? .automatic
    }

    var body: some View {
        List {
            Section {
                ForEach(DictationSurface.allCases) { option in
                    Button {
                        surfaceRaw = option.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if option == selected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(murmurAccent)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Automatic reads the kind of field you are typing in — a message field gets a chat reply, an email field keeps its greeting. Picking a style always formats that way, including dictation started from the Murmur app.")
            }
        }
        .navigationTitle("Formatting style")
        .navigationBarTitleDisplayMode(.inline)
        .tint(murmurAccent)
    }
}
