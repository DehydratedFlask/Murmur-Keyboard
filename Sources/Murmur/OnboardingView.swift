import SwiftUI

private let onboardingAccent = Color(red: 0.39, green: 0.28, blue: 0.95)
private let onboardingAccentSecondary = Color(red: 0.53, green: 0.44, blue: 1.0)

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentPage = 0

    private let pages = OnboardingPage.allCases

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.08, blue: 0.10), Color(red: 0.11, green: 0.10, blue: 0.15), Color(red: 0.08, green: 0.08, blue: 0.10)]
                    : [Color(.systemBackground), onboardingAccent.opacity(0.08), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $currentPage) {
                    ForEach(pages) { page in
                        pageView(for: page)
                            .tag(page.rawValue)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .animation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.4, dampingFraction: 0.88), value: currentPage)

                bottomCTA
            }
        }
        .tint(onboardingAccent)
    }

    private var topBar: some View {
        HStack {
            Spacer()

            if currentPage < pages.count - 1 {
                Button("Skip") {
                    completeOnboarding()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemBackground).opacity(colorScheme == .dark ? 0.52 : 0.72), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                Spacer(minLength: page.hasCard ? 8 : 24)

                pageHero(icon: page.icon, compact: page.hasCard)

                VStack(spacing: 10) {
                    if page == .welcome {
                        Text("Murmur")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text(page.title)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(page.title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                    }

                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }

                if page == .howItWorks {
                    howItWorksCard
                }

                if page == .enableKeyboard {
                    setupCard
                }

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pageHero(icon: String, compact: Bool = false) -> some View {
        let size: CGFloat = compact ? 120 : 152
        let iconSize: CGFloat = compact ? 48 : 60
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [onboardingAccent.opacity(0.16), onboardingAccentSecondary.opacity(0.08)]
                            : [onboardingAccent.opacity(0.18), onboardingAccentSecondary.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Circle()
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.7), lineWidth: 1)
                .frame(width: size, height: size)

            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [onboardingAccentSecondary, onboardingAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .shadow(color: onboardingAccent.opacity(colorScheme == .dark ? 0.10 : 0.16), radius: 20, y: 10)
    }

    private var howItWorksCard: some View {
        VStack(spacing: 16) {
            OnboardingStepView(icon: "mic.fill", title: "Tap to speak")
            OnboardingStepView(icon: "waveform", title: "Murmur transcribes on-device")
            OnboardingStepView(icon: "doc.on.clipboard", title: "Text appears instantly")
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.92 : 1.0), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 18, y: 8)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use Murmur in any app — Messages, Notes, Mail, and more.", systemImage: "apps.iphone")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Label("Open Settings and enable the Murmur keyboard.", systemImage: "gearshape.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label("Switch to Murmur whenever you want private voice-to-text.", systemImage: "hand.tap.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.92 : 1.0), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(onboardingAccent.opacity(colorScheme == .dark ? 0.20 : 0.12), lineWidth: 1)
        )
        .shadow(color: onboardingAccent.opacity(colorScheme == .dark ? 0.12 : 0.08), radius: 20, y: 10)
    }

    private var bottomCTA: some View {
        VStack(spacing: 14) {
            Button {
                primaryAction()
            } label: {
                Text(currentPage == pages.count - 1 ? "Set Up" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [onboardingAccentSecondary.opacity(0.92), onboardingAccent.opacity(0.90)]
                                : [onboardingAccentSecondary, onboardingAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: onboardingAccent.opacity(0.24), radius: 16, y: 8)
            }
            .buttonStyle(.plain)

            if currentPage == pages.count - 1 {
                Button("Skip for now") {
                    completeOnboarding()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 34)
        .background(
            (colorScheme == .dark
                ? Color(.systemBackground).opacity(0.88)
                : Color(.systemBackground).opacity(0.96))
            .blur(radius: 10)
        )
    }

    private func primaryAction() {
        if currentPage == pages.count - 1 {
            // Complete onboarding first so the main UI appears cleanly.
            // The main view's keyboard setup banner guides the user to Settings
            // without the jarring jump-away that openSettingsURLString causes.
            completeOnboarding()
        } else {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.42, dampingFraction: 0.86)) {
                currentPage += 1
            }
        }
    }

    private func completeOnboarding() {
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.35)) {
            hasCompletedOnboarding = true
        }
    }
}

private struct OnboardingStepView: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(onboardingAccent.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 54, height: 54)

                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(onboardingAccent)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(.tertiarySystemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case howItWorks
    case privacy
    case enableKeyboard

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .welcome:
            return "waveform"
        case .howItWorks:
            return "sparkles"
        case .privacy:
            return "lock.shield.fill"
        case .enableKeyboard:
            return "keyboard.badge.ellipsis"
        }
    }

    var title: String {
        switch self {
        case .welcome:
            return "Your voice, your words, your device."
        case .howItWorks:
            return "How It Works"
        case .privacy:
            return "100% Private"
        case .enableKeyboard:
            return "Set Up Murmur Keyboard"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "On-device speech-to-text that never leaves your phone."
        case .howItWorks:
            return "Speak naturally, let Murmur handle the transcription, and watch your text appear instantly."
        case .privacy:
            return "No internet required. No accounts. No data collection. Everything stays on your iPhone."
        case .enableKeyboard:
            return "Use Murmur in any app — Messages, Notes, Mail, and more."
        }
    }

    var hasCard: Bool {
        self == .howItWorks || self == .enableKeyboard
    }
}

#Preview {
    OnboardingView()
}
