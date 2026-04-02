import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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
            .environmentObject(appState)
            .onOpenURL { url in
                if url.scheme == "murmur" && url.host == "dictate" {
                    appState.shouldStartDictation = true
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    break
                case .inactive, .background:
                    SharedDefaults.setModelReady(false, progressText: nil)
                @unknown default:
                    SharedDefaults.setModelReady(false, progressText: nil)
                }
            }
        }
    }
}

/// Shared app state for URL scheme handling
class AppState: ObservableObject {
    @Published var shouldStartDictation = false
}
