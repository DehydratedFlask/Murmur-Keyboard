import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
                .environmentObject(appState)
                .onOpenURL { url in
                    if url.scheme == "murmur" && url.host == "dictate" {
                        appState.shouldStartDictation = true
                    }
                }
        }
    }
}

/// Shared app state for URL scheme handling
class AppState: ObservableObject {
    @Published var shouldStartDictation = false
}
