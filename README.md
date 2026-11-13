<div align="center">

# Murmur 3.1

**The voice keyboard that speaks *your* language.**
On-device Whisper transcription, polished into the text you meant to write — never a verbatim dump of pauses and stutters.

<img src="screenshots/screenshot-promax-main.png" alt="Murmur running on iPhone" width="320" />

[![iOS](https://img.shields.io/badge/iOS-17+-0af?logo=ios&logoColor=white)](#development)
[![Swift](https://img.shields.io/badge/swift-6-F05138?logo=swift)](https://swift.org)
[![Privacy](https://img.shields.io/badge/transcription-on--device-10b981)](#privacy)
[![Analytics](https://img.shields.io/badge/tracking-none-6366f1)](#privacy)

</div>

---

## Why Murmur

Dictation apps give you a transcript. Murmur gives you a **message**:

- Transcribes speech on-device with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  or [NVIDIA Parakeet](https://github.com/FluidInference/FluidAudio) on the Neural Engine
- Restores sentence boundaries, capitalization, commas, periods, question marks, contractions, paragraph breaks
- Removes filled pauses, repeated words, abandoned fragments, self-corrections, and ASR artifacts like `[Pause]` and `[BLANK_AUDIO]` — anywhere in a sentence, not just at the start
- Voice-activity segmentation before transcription: only the stretches that contain speech reach the model, so a fan, a TV or room tone cannot turn into invented words
- Context-aware formatting: the keyboard tells the formatter which kind of field you were in (chat, email, search) and what text surrounds the cursor, so a reply stays a reply and a continuation joins the sentence it continues
- Preserves meaning-bearing words, names, numbers, negation — and your voice
- Personal dictionary with preferred spellings, "sounds like" aliases, per-entry toggles
- Snippets: expand a short trigger ("omw") into longer text while you dictate
- Language selection or auto-detect, session duration, and a configurable history window
- Custom iOS keyboard with microphone handoff and automatic result insertion
- System-style typing: character pop-ups, accented variants, and the key click
  on touch-down rather than on lift
- Autocorrection that waits until you commit the word, puts the original back
  on a single delete, and offers the fix as a tap-to-apply suggestion
- Live Activity in the Dynamic Island: a waveform icon and a running timer while you dictate
- iOS 17+ with Liquid Glass adoption on newer systems

Murmur types the way the system keyboard does — pop-ups, accents, autocorrect
and a suggestion above the keys — plus reliable voice handoff and polished
dictation. No swipe typing and no second keyboard to learn.

## The pipeline: formatter, not rewriter

Murmur runs a guarded two-stage process:

1. **Transcribe** — WhisperKit handles 16 kHz audio with VAD, silence
   suppression, and personal-dictionary prompt tokens.
2. **Polish** — on supported devices, Apple Foundation Models acts as a narrow
   formatter: punctuation and disfluency cleanup allowed; rewriting,
   summarizing, translating, or inventing facts forbidden.
3. **Validate** — a faithfulness validator rejects output that adds
   unsupported content, alters protected numbers/negation, leaks model
   metadata, or drifts too far from the raw transcript.
4. **Fall back** — if the local model is unavailable or fails validation,
   Murmur returns a conservative deterministic cleanup instead.

Architecture follows the core principle from
[Amical](https://github.com/amicalhq/amical); Google's Eloquent inspired the
personal dictionary and ready-to-use prose goal (its iOS implementation is not
public — Murmur bundles nothing of it).

## Keyboard flow

iOS doesn't let third-party keyboards record audio directly, so Murmur uses a
handoff:

1. Install Murmur and open it once so the Whisper model downloads.
2. In iOS Settings, enable the keyboard + Full Access (for app↔extension exchange).
3. Tap Murmur's microphone in any text field.
4. Speak in Murmur, then swipe back to your app — swipe right from the left
   edge, or tap the back link in the top-left corner. Murmur keeps listening in
   the background.
5. Tap the checkmark on Murmur's keyboard and the polished result appears.

## Personal dictionary

**Settings → Personal Dictionary**: add names, jargon, preferred
capitalization (`Siobhan` ← "shiv on"). Stored locally; entries bias
WhisperKit, optional cloud providers, and the local cleanup model.

## Privacy

On-device dictation and cleanup stay local. No analytics, tracking, account
requirement, or content server. Optional cloud dictation is off by default;
when enabled, audio and active dictionary spellings go only to the provider
you choose. See the [Privacy Policy](PRIVACY_POLICY.md).

## Development

Requirements: iOS 17+, Xcode 27 beta, Swift 6.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Murmur.xcodeproj \
  -scheme Murmur \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Run the transcript regression suite (punctuation, fillers, stutters,
corrections, ASR artifacts, prompt-injection resistance, dictionary aliases):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --parallel
```

## Support

If Murmur is useful to you, [buy me a coffee](https://www.buymeacoffee.com/tgn5dq5j8xs).

## License

MIT

---

<div align="center">
<sub>Speak freely. Sound sharp.</sub>
</div>
