# Murmur 3

Murmur is a privacy-first voice-to-text keyboard for iPhone. It combines local
Whisper transcription with an Eloquent-inspired polishing pass so the result
reads like text you intended to write—not a verbatim dump of every pause,
stutter, or correction.

## What Murmur does

- Transcribes speech on-device with
  [WhisperKit](https://github.com/argmaxinc/WhisperKit).
- Restores sentence boundaries, capitalization, commas, periods, question
  marks, contractions, and paragraph breaks.
- Removes filled pauses, repeated words and phrases, abandoned fragments,
  explicit self-corrections, and ASR artifacts such as `[Pause]`,
  `[BLANK_AUDIO]`, and tool tokens.
- Preserves meaning-bearing words, names, numbers, questions, negation, and the
  speaker's voice instead of paraphrasing the message.
- Provides an editable personal dictionary with preferred spellings, optional
  “sounds like” aliases, and per-entry enable switches.
- Uses dictionary entries to bias WhisperKit, supported cloud transcription
  providers, and the local cleanup model.
- Includes a custom iOS keyboard with a microphone handoff and automatic result
  insertion when you return to the original app.
- Supports iOS 17 and later while adopting Liquid Glass on newer systems.

Murmur does not provide predictive text, autocorrection, or swipe typing. Its
focus is a familiar keyboard, reliable voice handoff, and polished dictation.

## How transcript polishing works

Murmur 3 uses a guarded two-stage pipeline:

1. WhisperKit transcribes 16 kHz audio with voice-activity detection, silence
   suppression, and personal-dictionary prompt tokens.
2. On supported devices, Apple Foundation Models acts as a narrow formatter:
   punctuation and disfluency cleanup are allowed; rewriting, summarizing,
   translating, answering the transcript, and inventing facts are forbidden.
3. A faithfulness validator rejects output that adds unsupported content,
   changes protected numbers or negation, leaks model metadata, or diverges too
   far from the raw transcript.
4. If the local language model is unavailable or its result fails validation,
   Murmur returns a conservative deterministic cleanup instead.

This architecture follows the same core principle used by
[Amical](https://github.com/amicalhq/amical): the model is a formatter, not a
rewriter. Google AI Edge Eloquent also inspired the personal dictionary and the
goal of producing ready-to-use prose, but Eloquent's iOS implementation and
exact model are not public. Murmur does not bundle or claim to be Google's
model.

## Keyboard flow

1. Install Murmur and open it once so the selected Whisper model can download.
2. In iOS Settings, enable the Murmur keyboard and allow Full Access so the
   extension can exchange the dictation result with the main app.
3. Select Murmur in any text field and tap its microphone button.
4. Speak in Murmur, stop recording, and return to the original app.
5. The Murmur keyboard inserts the polished result.

iOS does not allow a third-party keyboard extension to record microphone audio
directly. The app handoff is therefore required; audio recording and local
models stay in the main app.

## Personal dictionary

Open **Settings → Personal Dictionary** to add names, jargon, product names, or
preferred capitalization. For example:

- Preferred spelling: `Siobhan`
- Sounds like: `shiv on`

Entries are stored locally. If optional cloud dictation is enabled, active
canonical spellings may be sent to the selected provider as recognition hints;
aliases and the rest of the dictionary remain under Murmur's local controls.

## Privacy

On-device dictation and cleanup remain local. Murmur has no analytics, tracking,
account requirement, or content server. Optional cloud dictation is off by
default; when enabled, audio and active dictionary spellings are sent directly
to the provider selected in Settings. See the
[Privacy Policy](PRIVACY_POLICY.md).

## Development

Requirements:

- iOS 17.0+
- Xcode 27 beta (the project retains availability fallbacks for earlier iOS
  releases)
- Swift 6

Build against the beta SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Murmur.xcodeproj \
  -scheme Murmur \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Run the transcript regression suite:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --parallel
```

The test suite exercises punctuation, sentence boundaries, questions,
contractions, contextual filler removal, stutters, repetitions, explicit
corrections, ASR artifacts, prompt-injection resistance, and dictionary aliases.

## Support

If Murmur is useful to you, you can
[buy me a coffee](https://www.buymeacoffee.com/tgn5dq5j8xs).

## License

MIT
