// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MurmurTextProcessing",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "MurmurTextProcessing",
            targets: ["MurmurTextProcessing"]
        ),
    ],
    targets: [
        .target(
            name: "MurmurTextProcessing",
            path: "Sources/Murmur",
            exclude: [
                "Assets.xcassets",
                "AudioRecorder.swift",
                "AppearanceMode.swift",
                "CaptureCoordinator.swift",
                "DictateView.swift",
                "ModelRuntime.swift",
                "ModelStatusView.swift",
                "MurmurLiveActivity.swift",
                "SpeechSegmenter.swift",
                "CloudTranscriptionService.swift",
                "ContentView.swift",
                "DictationIntents.swift",
                "RecordingDraftStore.swift",
                "TranscriptEditorView.swift",
                "Info.plist",
                "KeychainHelper.swift",
                "Murmur.entitlements",
                "MurmurApp.swift",
                "OnboardingView.swift",
                "PrivacyInfo.xcprivacy",
                "TranscriptionStore.swift",
                "en.lproj",
            ],
            sources: ["TextProcessor.swift", "ModelSchedulingPolicy.swift", "CaptureLifecycle.swift", "TranscriptionService.swift", "ModelRuntimeTypes.swift"]
        ),
        .target(
            name: "MurmurKeyboardTyping",
            path: "Sources/Shared",
            exclude: ["SharedDefaults.swift", "DarwinNotificationCenter.swift"],
            sources: ["KeyboardTypingPolicy.swift"]
        ),
        .testTarget(
            name: "MurmurRuntimeTests",
            dependencies: ["MurmurTextProcessing"]
        ),
        .testTarget(
            name: "MurmurTextProcessingTests",
            dependencies: ["MurmurTextProcessing", "MurmurKeyboardTyping"]
        ),
    ]
)
