import SwiftUI
import UIKit

private let onboardingAccent = Color(red: 0.39, green: 0.28, blue: 0.95)

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var transcription: TranscriptionService
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRequestingPermission = false
    @State private var keyboardWasOpened = false
    @State private var fullAccessWasGranted = false
    @State private var keyboardTestText = ""
    @State private var settingsError: String?

    var body: some View {
        NavigationStack {
            Form {
                introduction
                microphoneSetup
                modelSetup
                keyboardSetup
            }
            .navigationTitle("Welcome to Murmur")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    Button(action: completeOnboarding) {
                        Text("Continue to Murmur")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityHint("Opens the app. You can finish setup later.")

                    Text("You can finish any of these steps later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .tint(onboardingAccent)
        .onAppear(perform: refreshSetupStatus)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSetupStatus() }
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(onboardingAccent)
                    .accessibilityHidden(true)

                Text("Your voice.\nRoom to think.")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Record a thought, turn it into text, and use it where you need it. Start with the essentials below.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private var microphoneSetup: some View {
        Section {
            if recorder.hasPermission {
                Label("Microphone allowed", systemImage: "checkmark.circle.fill")
            } else if recorder.permissionDenied {
                Label("Microphone access is off", systemImage: "mic.slash")
                Text("Allow Microphone in iOS Settings to record your voice.")
                    .foregroundStyle(.secondary)
                Button("Open Microphone Settings", action: openSettings)
                    .frame(minHeight: 44)
            } else {
                Text("Murmur needs the microphone to record. It asks for access only when you choose to allow it.")
                    .foregroundStyle(.secondary)
                Button {
                    isRequestingPermission = true
                    Task {
                        await recorder.requestPermission()
                        isRequestingPermission = false
                    }
                } label: {
                    HStack {
                        Text(isRequestingPermission ? "Requesting access…" : "Allow Microphone")
                        if isRequestingPermission {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isRequestingPermission)
            }
        } header: {
            Text("Record your voice")
        } footer: {
            Text("Recording happens in the Murmur app. iOS keyboards cannot use the microphone directly.")
        }
    }

    private var modelSetup: some View {
        Section {
            switch transcription.modelState {
            case .unloaded:
                Text("Download a speech model once. Once it is ready, your recordings can be transcribed on this device, offline.")
                    .foregroundStyle(.secondary)
                Button("Prepare Offline Transcription", action: prepareModel)
                    .frame(minHeight: 44)
            case .loading:
                ProgressView {
                    Text("Preparing offline transcription")
                }
                Text(transcription.loadingProgress.isEmpty
                     ? "Getting the speech model ready…"
                     : transcription.loadingProgress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .loaded:
                Label("Offline transcription ready", systemImage: "checkmark.circle.fill")
                Text("The speech model is loaded. You’re ready to turn recordings into text.")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Label("Couldn’t prepare transcription", systemImage: "exclamationmark.triangle")
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try Model Setup Again", action: prepareModel)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Prepare your speech model")
        } footer: {
            Text("First-time setup needs an internet connection. You can continue and record while the model prepares; transcription waits until it is ready.")
        }
    }

    private var keyboardSetup: some View {
        Section {
            Text("Add the keyboard to send your words into other apps. This step is optional.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("1. Open iOS Settings → General → Keyboard → Keyboards → Add New Keyboard, then choose Murmur.")
                Text("2. Tap Murmur and turn on Allow Full Access so the keyboard can exchange dictation with the app.")
                Text("3. Tap the field below, then touch and hold the globe key to choose Murmur.")
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open iOS Settings", action: openSettings)
                .frame(minHeight: 44)

            if let settingsError {
                Text(settingsError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Try the Murmur keyboard here", text: $keyboardTestText, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("Keyboard test field")
                .accessibilityHint("Touch and hold the globe key on your keyboard, then select Murmur.")

            DisclosureGroup("Last keyboard report") {
                Label(keyboardWasOpened ? "Murmur has opened before" : "No keyboard opening reported yet",
                      systemImage: keyboardWasOpened ? "keyboard" : "keyboard.badge.ellipsis")
                Label(fullAccessWasGranted ? "Full Access last reported on" : "Full Access not reported on",
                      systemImage: fullAccessWasGranted ? "checkmark.circle" : "info.circle")
                Text("These are saved reports from the keyboard. They do not confirm that it is currently enabled or that Full Access is still on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh Keyboard Report", action: refreshSetupStatus)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Use Murmur in other apps")
        } footer: {
            Text("You can also record in Murmur and copy your finished text. Switch between apps using the app switcher or iOS’s return-to-app control when available.")
        }
    }

    private func prepareModel() {
        // Keep the shared service working if the user continues into the app.
        Task { await transcription.loadModel() }
    }

    private func refreshSetupStatus() {
        recorder.checkPermission()
        keyboardWasOpened = SharedDefaults.isKeyboardActive()
        fullAccessWasGranted = SharedDefaults.isFullAccessGranted()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url) { accepted in
            settingsError = accepted ? nil : "Open the Settings app, then follow the steps above."
        }
    }

    private func completeOnboarding() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            hasCompletedOnboarding = true
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AudioRecorder())
        .environmentObject(TranscriptionService())
}
