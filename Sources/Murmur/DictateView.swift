import SwiftUI

/// Focused capture surface; the coordinator owns work independently of navigation.
struct DictateView: View {
    @ObservedObject var capture: CaptureCoordinator
    let showHistory: () -> Void
    let showSettings: () -> Void
    @AppStorage("formattingSurface", store: SharedDefaults.suite) private var formatting = DictationSurface.automatic.rawValue
    @AppStorage("dictationAutoDetectLanguage", store: SharedDefaults.suite) private var automaticLanguage = true
    @State private var selectedLanguageCode = SharedDefaults.selectedLanguages.first ?? "en"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(capture.recorder.isRecording ? "Take your time." : "A thought, ready to write.")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(CloudTranscriptionService.isReady
                         ? "Dictation uses your configured cloud provider, with a local fallback."
                         : "Speak naturally. Recognition and formatting run on this iPhone.")
                        .font(.body).foregroundStyle(.secondary)
                }

                ModelStatusView(service: capture.transcriptionService)
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                if capture.recorder.isRecording {
                    CaptureControlsView(capture: capture)
                } else if capture.isProcessing {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Turning your recording into text…").font(.headline)
                        }
                        Text("Your recording is saved. You can visit History while it finishes.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(capture.processingCancellationRequested ? "Stopping safely…" : "Stop processing and keep recording") { capture.cancelProcessing() }
                            .disabled(capture.processingCancellationRequested)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    captureOptions
                    Button(action: capture.handleRecordingTap) {
                        VStack(spacing: 12) {
                            Image(systemName: capture.captureStartPending ? "ellipsis" : "mic.fill")
                                .font(.largeTitle)
                            Text(capture.captureStartPending ? "Starting microphone…" : "Start recording")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 132)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(capture.captureStartPending || capture.recorder.isStarting)
                    .accessibilityHint("Starts saving audio immediately, even while the speech model prepares.")
                    Text("Recording can begin before the model is ready. Your audio stays available if preparation fails.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let latest = capture.store.entries.first {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Latest dictation").font(.headline)
                            Spacer()
                            Button("History", action: showHistory)
                        }
                        Text(latest.text).lineLimit(5).textSelection(.enabled)
                        HStack {
                            ShareLink(item: latest.text) { Label("Share", systemImage: "square.and.arrow.up") }
                            Spacer()
                            Button("Copy", systemImage: "doc.on.doc") { capture.copyText(latest.text) }
                        }
                        .font(.subheadline)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                if !capture.draftStore.drafts.isEmpty {
                    Button(action: showHistory) {
                        Label("View saved recordings (\(capture.draftStore.drafts.count))", systemImage: "waveform.badge.exclamationmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Keyboard setup and dictation preferences", systemImage: "slider.horizontal.3", action: showSettings)
                    .font(.subheadline)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { selectedLanguageCode = SharedDefaults.selectedLanguages.first ?? "en" }
    }

    private var captureOptions: some View {
        VStack(spacing: 12) {
            Picker("Save text to", selection: $capture.captureDestination) {
                Text("History").tag(CaptureDestination.note)
                Text("Clipboard").tag(CaptureDestination.clipboard)
            }
            .pickerStyle(.segmented)
            HStack {
                Menu {
                    Button("Detect automatically") { automaticLanguage = true }
                    ForEach(DictationLanguage.all) { language in
                        Button(language.name) {
                            SharedDefaults.selectedLanguages = [language.code]
                            selectedLanguageCode = language.code
                            automaticLanguage = false
                        }
                    }
                } label: {
                    Label(languageTitle, systemImage: "globe")
                }
                Spacer()
                Menu {
                    ForEach(DictationSurface.allCases) { surface in
                        Button(surface.title) { formatting = surface.rawValue }
                    }
                } label: {
                    Label(DictationSurface(rawValue: formatting)?.title ?? "Automatic", systemImage: "text.alignleft")
                }
            }
            .font(.subheadline)
        }
    }

    private var languageTitle: String {
        if automaticLanguage { return "Auto language" }
        return DictationLanguage.named(selectedLanguageCode)?.name ?? "English"
    }
}

struct CaptureControlsView: View {
    @ObservedObject var capture: CaptureCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(capture.recorder.isPaused ? "Paused" : "Recording", systemImage: capture.recorder.isPaused ? "pause.circle" : "mic.fill")
                    .font(.headline)
                Spacer()
                if let start = capture.recordingStartedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .accessibilityLabel("Session elapsed time")
                }
            }
            Text(capture.transcriptionService.modelState == .loaded
                 ? "Your audio is being saved on this iPhone."
                 : "Recording is saved while the speech model prepares.")
                .font(.subheadline).foregroundStyle(.secondary)
            if MurmurPreferences.livePreviewEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent speech · provisional").font(.caption).foregroundStyle(.secondary)
                    Text(capture.livePreview.isEmpty ? "Your recent words will appear here. Final text may change." : capture.livePreview)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Provisional transcript: \(capture.livePreview)")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { pauseButton; finishButton }
                VStack(alignment: .leading, spacing: 12) { pauseButton; finishButton }
            }
            Button("Keep recording for later", systemImage: "tray.and.arrow.down", action: capture.keepActiveDraft)
                .font(.subheadline)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var pauseButton: some View {
        Button(capture.recorder.isPaused ? "Resume" : "Pause", systemImage: capture.recorder.isPaused ? "play.fill" : "pause.fill") {
            capture.setRecordingPaused(!capture.recorder.isPaused)
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    private var finishButton: some View {
        Button("Finish", systemImage: "checkmark", action: capture.stopAndTranscribe)
            .buttonStyle(.borderedProminent).controlSize(.large)
    }
}
