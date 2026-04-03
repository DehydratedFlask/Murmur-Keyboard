import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
            .onOpenURL { url in
                if url.scheme == "murmur" && url.host == "dictate" {
                    appState.shouldStartDictation = true
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

/// Shared app state for URL scheme handling
class AppState: ObservableObject {
    @Published var shouldStartDictation = false
}
