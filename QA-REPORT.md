# Murmur QA Report

**Date:** July 24, 2026
**Toolchain:** Xcode 27 beta, iOS 27 Simulator (iPhone 17 Pro)

## Current result

- Murmur and MurmurKeyboard build successfully against the iOS 27 SDK.
- Xcode static analysis succeeds.
- The unsigned Release device build succeeds.
- The app installs and launches in the iOS 27 Simulator.
- The personal dictionary screen passes dark-mode visual and accessibility
  inspection.
- Sixteen text-processing test groups cover punctuation, questions,
  contractions, fillers, repetitions, explicit corrections, ASR artifacts,
  dictionary normalization, dictionary aliases, prompt-injection resistance,
  and semantic formatting.

## Release artifact

The v3 IPA is an unsigned device build because this Mac has no configured Apple
Developer account or provisioning profiles. The app and embedded keyboard must
be signed with the Murmur App Group entitlements before device installation or
App Store distribution.

## Known environment limitation

The simulator integration is configured to use stable Xcode, whose license is
not accepted. Verification therefore uses
`/Applications/Xcode-beta.app/Contents/Developer` directly. This does not block
beta builds, installation, launch, screenshots, or UI inspection.

## Durable regression command

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --parallel
```

If the repository is stored in a File Provider folder and macOS attaches
Finder metadata to SwiftPM's generated test bundle, copy the working tree to a
temporary local directory before running the command. This is a code-signing
artifact of the folder provider, not a test failure.

## Device-only checks still required before release

- Microphone capture quality in quiet, noisy, and echo-heavy rooms.
- Memory pressure while WhisperKit is loaded.
- Real keyboard-extension enablement and app-to-keyboard handoff in third-party
  host apps.
- Background/interruption behavior during longer recordings.
