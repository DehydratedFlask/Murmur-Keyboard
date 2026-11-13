import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var capture = CaptureCoordinator()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SharedDefaults.migrateDictationPreferences()
        SharedDefaults.languageNames = Dictionary(uniqueKeysWithValues: DictationLanguage.all.map { ($0.code, $0.name) })
        let previous = SharedDefaults.dictationState()
        if previous.phase == .recording || previous.phase == .paused || previous.phase == .processing {
            SharedDefaults.abandonDictationSession(reason: "The previous recording was interrupted. Open Murmur to recover it.")
        }
        SharedDefaults.setModelReady(false, progressText: nil)
    }
    var body: some Scene {
        WindowGroup {
            ZStack {
                if hasCompletedOnboarding {
                    ContentView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    OnboardingView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
            .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
            .environmentObject(appState)
            .environmentObject(capture)
            .environmentObject(capture.recorder)
            .environmentObject(capture.transcriptionService)
            .onOpenURL { url in
                guard url.scheme == "murmur" else { return }
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                switch url.host {
                case "dictate":
                    if let target = query.first(where: { $0.name == "destination" })?.value,
                       let destination = CaptureDestination(rawValue: target), destination != .keyboard {
                        appState.captureRequest = CaptureRequest(destination: destination)
                    } else {
                        appState.shouldStartDictation = true
                    }
                case "note": appState.captureRequest = CaptureRequest(destination: .note)
                case "resume": appState.pauseRequest = false
                case "finish": appState.finishCapture()
                case "edit":
                    if let value = query.first(where: { $0.name == "id" })?.value {
                        appState.editEntryID = UUID(uuidString: value)
                    }
                default: break
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // ContentView's onBecomeActive handler restores the flag
                    // if the model is loaded. Nothing extra needed here.
                    break
                case .background:
                    // Keep modelReady true — the model stays loaded in memory
                    // until iOS kills the process or a memory warning triggers unload.
                    // Clearing it here causes the keyboard to show "Loading" unnecessarily.
                    break
                case .inactive:
                    // Don't clear model-ready on inactive — the app transitions
                    // through inactive briefly during normal operations
                    // (e.g., opening Settings, Control Center, notification banners).
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

/// Shared app state for URL-scheme and cross-process keyboard handling.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var shouldStartDictation = false
    @Published var shouldStopDictation = false
    @Published var captureRequest: CaptureRequest?
    @Published var editEntryID: UUID?
    @Published var pauseRequest: Bool?
    @Published var pauseRequestSequence: UInt = 0
    var isCapturing = false

    func finishCapture() {
        if let sessionID = SharedDefaults.currentDictationSessionID() {
            SharedDefaults.requestDictationStop(sessionID: sessionID)
        }
        shouldStopDictation = true
    }

    init() {
        DarwinNotificationCenter.observe(.dictationPauseRequested) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pauseRequestSequence &+= 1
            }
        }
        DarwinNotificationCenter.observe(.dictationStopRequested) { [weak self] in
            Task { @MainActor in
                self?.shouldStopDictation = true
            }
        }
        // Warm dictation: the keyboard can ask for a recording without opening
        // the app, as long as this process is alive.
        DarwinNotificationCenter.observe(.dictationRequested) { [weak self] in
            Task { @MainActor in
                SharedDefaults.markAppAlive()
                self?.shouldStartDictation = true
            }
        }
    }
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    let destination: CaptureDestination
}
