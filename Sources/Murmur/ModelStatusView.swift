import SwiftUI

/// The same readiness presentation is used on capture and model settings.
struct ModelStatusView: View {
    @ObservedObject var service: TranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: service.modelState == .loaded ? "checkmark.circle" : "cpu")
                    .font(.title3)
                    .foregroundStyle(service.modelState == .loaded ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.activeModelLabel ?? service.selectedEngine.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if service.modelState == .loading {
                if let fraction = service.downloadFraction {
                    ProgressView("Download", value: fraction, total: 1)
                        .font(.caption)
                } else {
                    ProgressView().accessibilityLabel(statusText)
                }
            }
            if service.cachedModelBytes > 0 {
                Text("Cached models: \(ByteCountFormatter.string(fromByteCount: service.cachedModelBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.modelState == .unloaded || service.modelState.isError {
                Button(service.modelState.isError ? "Retry model preparation" : "Prepare offline dictation") {
                    Task { await service.loadModel() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch service.modelState {
        case .unloaded: return "Record now. Your audio is saved while the model prepares."
        case .loading: return service.loadingProgress.isEmpty ? "Preparing offline dictation…" : service.loadingProgress
        case .loaded: return "Ready for on-device recognition"
        case .error(let message): return message
        }
    }
}
