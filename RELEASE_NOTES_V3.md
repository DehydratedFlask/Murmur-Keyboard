# Murmur 3.0

Murmur 3 turns raw dictation into clean, ready-to-use writing while keeping the
default workflow on-device.

## Highlights

- New Amical-style local transcript formatter restores punctuation, sentence
  boundaries, capitalization, questions, contractions, and paragraphs without
  rewriting the speaker's meaning.
- Removes filled pauses, repetitions, false starts, explicit corrections, and
  leaked ASR/model artifacts.
- Adds a faithfulness guard that rejects invented content and safely falls back
  on devices where the local language model is unavailable.
- Adds a personal dictionary with preferred spellings, “sounds like” aliases,
  editing, enable switches, and deletion.
- Applies dictionary context to WhisperKit, OpenAI/Groq prompts, Deepgram
  keyterms, and local cleanup.
- Adds durable punctuation and cleanup regression tests.
- Fixes a currency correction edge case and a transient setup-banner overlap.
- Refreshes privacy documentation and removes obsolete project files.

Built and analyzed with Xcode 27 beta against the iOS 27 SDK.

## Download note

The attached IPA is an unsigned arm64 device build for downstream signing and
verification. It cannot be installed directly until the app and embedded
keyboard are signed with an Apple Developer profile that includes Murmur's App
Group entitlement.
