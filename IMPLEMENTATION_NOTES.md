# Responsive dictation and app redesign

Implemented on `codex/murmur-responsive-dictation`. Existing work in progress was preserved. Physical-device verification remains outstanding as documented below.

## Behavior

- The app opens to **Dictate**, with separate **History** and **Settings** tabs. History includes saved recording recovery; editing, originals, corrections, snippets, cloud configuration and Shortcuts remain available.
- Capture and finalization belong to an app-lifetime `CaptureCoordinator`, rather than a screen. Recording requests microphone permission when needed and saves audio while the selected model prepares.
- A capture lifecycle token rejects duplicate starts and stale delivery. Retried saved recordings do not insert into an old keyboard session. Cancellation keeps recorded audio; successful text is saved before audio deletion.
- After Stop, the audio session is released. A bounded iOS background task covers finalization; cancellation or expiration leaves recovery audio available in History. An SDK operation that ignores cancellation retains its model lease until it actually returns.
- Models have one runtime owner. Duplicate loads join, selection changes apply automatically when idle, capture pins its model through final recognition, and superseded load completions cannot publish readiness. Final recognition takes priority over opportunistic preview.
- Model status distinguishes cache checks, downloading, preparation, loading, ready and failure. Progress uses SDK download callbacks; cached storage is measured from files. Cached Whisper startup uses an explicit model/tokenizer folder.
- New installations default to Whisper Tiny, cloud off, and preview off. Existing stored choices remain. No new recognition engine or third-party dependency was added; FluidAudio's minimum version now matches the already-resolved 0.18.3 API.
- Onboarding offers explicit microphone, offline-model and optional keyboard setup actions. Saved keyboard reports are identified as historical, rather than proof that Full Access is currently enabled.

## Keyboard

- UIKit touch-driven keys and familiar layout remain. Stale touches can recover, and accent retraction belongs to a specific press and document, protecting overlapping fingers.
- Interactive typing no longer invokes `UITextChecker` or audio clicks. Optional haptics use a cached preference. Autocorrection uses a bounded deterministic typo map and prepared supplementary vocabulary; unfamiliar words remain untouched.
- Suggestions validate the word, cursor, selection and document before publication and before application. A single delete still reverses an automatic correction.
- Fixed-name signposts cover touch delivery, feedback, proxy context/insertion/deletion, correction and key-view application. No key text, transcript, surrounding text, or field identifier is logged.

## Automated validation

- 41 SwiftPM XCTest cases passed: 18 existing text-processing tests, 7 keyboard policy tests, 4 capture lifecycle tests, 6 model scheduling tests, and 6 real-service fake-backend tests.
- The model tests use the actual `TranscriptionService`, not an alternate scheduler. They cover duplicate loads, superseded selections, offline failure and retry, cancellation while waiting, unload during an uninterruptible load, and capture/final recognition leases. They do not download models or establish recognition accuracy.
- Unsigned iOS device **build-for-testing** passed for Murmur, MurmurKeyboard, MurmurWidget and MurmurRuntimeTests against Xcode 27.2. This compiles the native SDK integration and native test bundle; it does not run the iOS test bundle.
- Validation ran from a local temporary copy because some File Provider-backed reads in this checkout blocked. The copied implementation sources were compared with the working checkout.

Run model-free tests:

```sh
swift test --parallel
```

Build all targets and the native tests:

```sh
xcodebuild -project Murmur.xcodeproj -scheme Murmur \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

## Required device and visual checks

No simulator runtime or connected iPhone was available. Keyboard freezes are not declared fixed by a build or policy test. On the affected **iPhone Air**, record the installed iOS version and:

1. In Instruments, attach to the keyboard extension and capture its `Typing` signposts. Compare rapid typing with the prior build in Notes, Messages, Safari and another affected app, with feedback on/off and before/after dictation.
2. Type repeated, alternating and overlapping two-thumb sequences, accents, punctuation, spaces, correction undo and held delete. Require no lost delivered touches; target extension-side input latency below 50 ms p95 and 100 ms p99. `TouchDelivery` includes synchronous insertion work; host-rendering delay must be assessed separately.
3. Verify capture with a missing/loading model, cached offline startup, denied microphone permission, download failure, interruption, pause/resume, Stop while paused, cancellation, app switching and background expiration. Confirm recovery audio, one history entry per draft and one insertion per matching keyboard session.
4. Test Tiny/Base and Whisper/Parakeet changes while idle, recording and processing, plus preview under memory/thermal pressure. Readiness must identify the model actually loaded.
5. Check light/dark appearance, portrait/landscape, large accessibility text, VoiceOver and Reduce Motion across onboarding, all tabs, transcript editing and keyboard handoff.
6. Check an upgrade installation: existing history, raw/polished text, drafts, vocabulary, snippets and provider credentials must remain readable. Text-history deletion and retention must not silently discard saved audio.
