import SwiftUI

enum MenuDestination {
    case home
    case history
    case settings
}

struct MenuView: View {

    @Binding var isOpen: Bool
    var onSelect: (MenuDestination) -> Void

    private let menuWidth: CGFloat = 260

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim overlay
            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isOpen = false
                        }
                    }
                    .transition(.opacity)
            }

            // Slide-in panel
            if isOpen {
                HStack(spacing: 0) {
                    menuPanel
                        .frame(width: menuWidth)
                        .transition(.move(edge: .leading))

                    Spacer()
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isOpen)
    }

    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App branding at top
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.49, green: 0.36, blue: 0.89))
                Text("Murmur")
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .padding(.bottom, 32)

            Divider()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            // Nav items
            menuItem(icon: "house.fill", label: "Home", dest: .home)
            menuItem(icon: "clock.arrow.circlepath", label: "History", dest: .history)

            Spacer()

            Divider()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Settings at the bottom
            menuItem(icon: "gearshape.fill", label: "Settings", dest: .settings)
                .padding(.bottom, 32)
        }
        .frame(maxHeight: .infinity)
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.12), radius: 16, x: 4, y: 0)
        )
        .ignoresSafeArea()
    }

    private func menuItem(icon: String, label: LocalizedStringKey, dest: MenuDestination) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isOpen = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onSelect(dest)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(Color(red: 0.49, green: 0.36, blue: 0.89))
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}
