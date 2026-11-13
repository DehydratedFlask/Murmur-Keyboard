# Murmur 3.1

Murmur 3.1 makes the keyboard feel like the system one and keeps invented words
out of your dictation, while everything still runs on device.

## Highlights

- **A real key layer.** Keys are UIKit views that answer every touch: character
  pop-ups, accent palettes after a half-second hold, a press that registers on
  touch-down, and cancel-by-dragging like Apple's keyboard. Keys also accept
  touches in the gaps between caps, so fast typing no longer lands in a dead
  strip.
- **System-style autocorrection.** Words are corrected when you commit them
  (space, punctuation, return), one press of delete puts the original back, and
  a space typed before punctuation is removed. Delete repeats at a steady rate
  and never jumps to deleting whole words.
- **Speech-only transcription.** Recordings are trimmed to the stretches that
  contain a voice before the model sees them, so a fan, a TV or room tone cannot
  turn into invented text. A recording with no speech says so instead of
  guessing.
- **Context-aware formatting.** Apple's on-device model formats with Amical-style
  structure: filler removed anywhere in a sentence, then rewritten as clean
  prose. The keyboard tells it which kind of field you are in (chat, email,
  search) and what text surrounds the cursor, so a reply stays a reply and a
  continuation joins its sentence. Choose Automatic, General, Chat, Email,
  Notes, Search or Verbatim under Settings › Formatting.
- **More reliable dictation.** One dictation at a time, a single start that
  waits for the app to be active, an audio stack rebuilt across three attempts
  when iOS refuses the microphone, and no more raw `CancellationError` text.
- **Live Activity** in the Dynamic Island: a waveform and a running timer while
  you dictate.
- **Parakeet** alongside Whisper, personal dictionary, snippets, language
  selection, session duration and a configurable history window.

Built with Xcode 27 against the iOS 26 SDK.

## Download note

The attached IPA is an unsigned arm64 device build for downstream signing and
verification. It cannot be installed directly until the app and embedded
keyboard are signed with an Apple Developer profile that includes Murmur's App
Group entitlement. For a build signed for your own registered iPhone, use the
install link the app's development build produces.
