# Phone dictation feature plan

Requested scope: implement all seven recommendations, without building or running tests here. Existing working-tree edits must be preserved.

## Implementation order

1. **Recoverable recordings** — record into Application Support with an atomic draft manifest. Keep audio after interruptions and transcription errors. Offer retry, keep, and explicit discard. Retry runs against the saved recording, never starts the microphone or inserts into a stale keyboard session.
2. **Editable history and original text** — preserve raw and polished versions, edit saved entries, restore either version, and support optional keyboard review before insertion. Decode older history without changing its text.
3. **Remember corrections** — let the editor save a confirmed wrong/right phrase pair into the existing personal dictionary. Do not infer corrections from text in other apps.
4. **Recording controls** — pause/resume the same audio file and expose quick-message, thinking-time, and manual-stop silence modes. Keep the existing warm-session duration separate.
5. **Live preview** — periodically transcribe a bounded window of recent audio using the existing local recognizer. Preview is provisional, never sent to cloud, and never inserted automatically. Stop preview work before final transcription.
6. **Keyboard controls** — share formatting/language preferences between app and keyboard, with session-scoped partial text, pause/resume, and optional final review. Preserve session-ID checks and deliberate cancellation behavior.
7. **System entry points** — native App Intents/App Shortcuts open a capture session for clipboard or saved-note output. Reuse the app's microphone and transcription pipeline; expose matching URL routes. Finish copies to clipboard only when the app is foregrounded.

## Guardrails

- No new third-party dependencies or model downloads beyond existing engines.
- Raw text means recognition output, not the recording or a promise of perfect word-for-word recognition.
- True Verbatim skips filler removal, dictionary replacement, and snippets.
- Recovery audio is local and excluded from backup. Delete it after successful transcription or explicit discard; interrupted drafts remain visible until resolved.
- Existing history remains readable. Editing never runs a destructive cleanup migration.
- Live preview shows recent speech rather than repeatedly transcribing an unbounded recording.
- iOS microphone and keyboard restrictions still apply. Shortcuts open Murmur; they do not promise invisible background capture or return a transcript synchronously.

## Verification handoff

Do source/diff review only in this session. Do not run xcodebuild, swift build, swift test, simulator launches, or runtime tests. Supply a device checklist covering legacy history, retries, interruptions, cancellation, preview, pause/resume, keyboard isolation, formatting/language persistence, and Shortcuts.

## Implementation status

- [x] Durable recording drafts, retry/export/keep/discard, and interruption preservation.
- [x] Editable history, raw/polished versions, and true Verbatim behavior.
- [x] Confirmed correction suggestions saved to the existing dictionary.
- [x] Pause/resume, silence modes, and paused Live Activity labels.
- [x] Bounded local preview in the app and keyboard, joined before final decoding.
- [x] Shared keyboard style/language controls and optional editable final review.
- [x] Foreground App Shortcuts and matching URL routes for clipboard/note capture.
- [x] Source review, project registration, privacy copy, and device checklist.
- [ ] Build and runtime verification, deferred to the user as requested.

See `DICTATION_TEST_CHECKLIST.md` for the full handoff and implementation limits.
