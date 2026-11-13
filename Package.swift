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
                "TranscriptionService.swift",
                "TranscriptionStore.swift",
                "en.lproj",
            ],
            sources: ["TextProcessor.swift"]
        ),
        .testTarget(
            name: "MurmurTextProcessingTests",
            dependencies: ["MurmurTextProcessing"]
        ),
    ]
)
