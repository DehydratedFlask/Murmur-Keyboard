import SwiftUI

enum MenuDestination {
    case home
    case history
    case settings
}

struct MenuView: View {

    @Binding var isOpen: Bool
    var onSelect: (MenuDestination) -> Void

    var body: some View {
        EmptyView()
            .onChange(of: isOpen) {
                guard isOpen else { return }
                isOpen = false
            }
            .accessibilityHidden(true)
    }
}
