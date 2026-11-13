# Dictation features: build and device test handoff

Implementation is complete in source. No build, simulator launch, automated test run, or physical-device test was performed in this session. `git diff --check` was used only to review patch formatting.

## Build elsewhere

- Build the Murmur scheme, including MurmurKeyboard and MurmurWidget, with the project's supported Xcode toolchain. New source files are registered in the checked-in Xcode project; `project.yml` also includes them through its source directories.
- Run the existing SwiftPM text-processing suite. Two new Verbatim regressions check fillers/repetitions/self-corrections and dictionary bypass.
- Use a physical iPhone for microphone routing, interruption, background capture, keyboard handoff, Shortcuts, and Action Button checks. Simulator behavior is not sufficient for those paths.
- Install over an existing build first to check migration. Keep a copy of important existing history before testing.

## Recoverable recordings

- [ ] Record a note and finish. A history entry appears and the recovery draft disappears only after history is written.
- [ ] Choose **Keep recording for later**. Relaunch the app and retry the saved recording without speaking again.
- [ ] Interrupt recording with a phone call or disconnect the active input device. Check that the partial recording remains available for retry/export/discard.
- [ ] Force-quit while recording, then relaunch. Check whether iOS finalized enough of the WAV to retry; even unreadable audio must remain visible for export or discard rather than be silently deleted.
- [ ] Cause transcription to fail, then retry after restoring the model/network. Retry must use saved audio and create one history entry, not duplicates.
- [ ] Verify a failed cloud request falls back locally, including when the local model is still loading.
- [ ] Retry a draft originally started from the keyboard while another app has a text field open. It must save in Murmur without inserting into the old field.
- [ ] Discard a saved recording and confirm it stays gone after relaunch. Verify **Delete all history** removes text history but leaves explicitly saved recording drafts available for separate discard.

## History editor and original words

- [ ] Open older history. Text must remain unchanged and the editor must explain when no original was saved.
- [ ] Tap a new entry, edit it, save, and relaunch. The edit and updated word count should persist.
- [ ] Restore the original words, save, and relaunch. Fillers and repetitions must survive history loading.
- [ ] Restore polished text. Copy/share must use the text currently shown in the editor.
- [ ] Use **Verbatim** with “um I I meant Tuesday no sorry Thursday.” Confirm no cleanup, alias replacement, or snippet expansion changes the recognized words. ASR accuracy itself can still vary.

## Remember corrections

- [ ] Fix a misheard name in the editor and choose **Use my edit as a correction**.
- [ ] Check the proposed wrong/right phrases, then choose **Remember this correction**.
- [ ] Dictate the phrase again in a normal formatting mode. The existing dictionary/alias pipeline should apply it.
- [ ] Check the vocabulary screen for the saved alias. Test an existing disabled word, duplicate alias, five-alias limit, and long phrase; the UI should give a clear result.

## Pause, silence modes, and preview

- [ ] Pause, speak words that should not be recorded, resume, and finish. Only speech from before/after the pause should be transcribed.
- [ ] Finish while paused. Keep a paused recording for later and retry it.
- [ ] Test **Quick message** (2 seconds of silence), **Thinking time** (10 seconds), and **Stop manually**. These affect the next recording and are separate from warm-session duration.
- [ ] Pause close to an automatic silence stop. A queued VAD callback must not finish an already paused recording.
- [ ] Check that the Lock Screen/Dynamic Island labels change to paused and return to listening.
- [ ] Enable live preview with each supported local engine. Provisional recent speech should appear in the app and keyboard, without being inserted into the host field.
- [ ] Continue for over 20 seconds. Preview should show a rolling recent window, while the final transcript includes the complete recording.
- [ ] Disable preview. Final transcription must still work. Check battery, heat, responsiveness, and memory on the intended phone; preview currently refreshes after a four-second interval plus decoding time.
- [ ] Finish/cancel during preview decoding, then start another recording. Check for overlapping recognizer calls, stale preview text, and unexpected insertions.

## Keyboard controls and final review

- [ ] Use the sliders menu to choose a formatting style and preferred language, then restart both app and keyboard. Settings must agree.
- [ ] Dictate in the selected language through local and configured cloud engines. Language support still depends on the chosen engine/provider/model.
- [ ] Turn **Review before keyboard insertion** off. Existing automatic insertion should work once per matching session.
- [ ] Turn it on. Finished text should stay in the review panel until you tap the checkmark to insert.
- [ ] Choose **Edit** in that panel, save a correction in Murmur, return to the host app, and insert. The revised text should appear once.
- [ ] Leave review open for several minutes, then insert. Review handoff expires after 15 minutes; the history copy remains available afterward.
- [ ] Pause from the keyboard, wait long enough for possible app suspension, then resume/finish. Murmur may open visibly to resume a suspended engine.
- [ ] Cancel during startup, recording, pause, preview, and final processing. No canceled result should insert into another field/session.
- [ ] Switch fields/apps/keyboards while recording. Confirm expected spacing, session isolation, and no duplicate insertion.

## Shortcuts and Action Button

- [ ] Find **Dictate to Clipboard**, **Capture a Voice Note**, and **Finish Dictation** under Murmur in Shortcuts.
- [ ] Run clipboard capture from both a cold launch and a running app. Finish and verify the final text is copied and also saved to history.
- [ ] Assign clipboard capture to the Action Button. Run again while recording to finish the current session.
- [ ] Capture a note and verify it saves a text entry without replacing the clipboard.
- [ ] Run Finish Dictation while a keyboard-origin recording is active, including while paused.
- [ ] Test first launch/onboarding, denied microphone permission, and a model that has not finished downloading. Confirm requests are handled after setup or fail clearly.
- [ ] If clipboard transcription finishes while Murmur is backgrounded, foreground it to complete clipboard delivery. History remains the fallback if the process is terminated.

## Implementation limits to assess

- Preview is periodic local recognition of roughly the latest 20 seconds, not word-by-word streaming. It never uses a cloud provider.
- Shortcuts open Murmur and start/finish its capture workflow. They return after requesting the action; they do not return the later transcript as a synchronous Shortcuts output.
- Pause uses the existing audio engine/file. Background resumption may require opening the app.
- Original text is recognizer output, not a guarantee of word-for-word recognition. Older entries cannot recover originals that were never stored.
- Draft audio stays local and is excluded from backups. It remains until successfully transcribed or explicitly discarded. Text-history retention applies to all stored versions of a history entry.
