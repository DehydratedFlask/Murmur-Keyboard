# Murmur Keyboard Upgrade Spec

## Goal
Make the Murmur keyboard feel like the native Apple iOS keyboard with a "Start Dictation" bar at the top.

## Issues to Fix

### 1. Key Press Pop-up Preview
The native iOS keyboard shows a magnified preview of the character above the key when you tap it. Implement this:
- When a letter/number key is tapped, show a rounded-rect popup above the key with the character in a larger font (~30pt)
- Popup should appear instantly on touch-down and dismiss on touch-up
- Use a ZStack overlay approach — the popup should extend above the keyboard bounds
- Match the native appearance: white/dark background depending on color scheme, slight shadow

### 2. Haptic Feedback
Add haptic feedback on every key press:
- Use `UIImpactFeedbackGenerator(style: .light)` for letter/number keys
- Use `UIImpactFeedbackGenerator(style: .medium)` for backspace, shift, return
- Prepare the generator on viewDidLoad for responsiveness
- NOTE: Haptic feedback requires Full Access in keyboard extensions. Only trigger if `hasFullAccess` is true.

### 3. Continuous Backspace (Hold to Delete)
Currently backspace only deletes one character per tap. Implement hold-to-delete:
- On touch-down: delete one character immediately
- After 0.5s hold: start repeating at ~10 chars/second
- After 1.5s hold: accelerate to word-at-a-time deletion (deleteBackward by word)
- On touch-up: stop deleting
- Use a Timer or GestureRecognizer approach in the ViewModel

### 4. Predictive Text / Autocomplete Bar
Add a suggestion bar above the keyboard (between the dictation bar and the keys):
- Use `UITextChecker` for basic spell-check suggestions
- Use `requestSupplementaryLexicon(completion:)` from UIInputViewController to get user's contacts/shortcuts
- Show 3 suggestion slots
- Tapping a suggestion replaces the current word being typed
- If no suggestions, show the currently typed word in the center slot (like Apple does)
- Style: same height as Apple's bar, separator lines between suggestions

### 5. "Start Dictation" Bar at Top
Replace the current mic button in the bottom row with a dictation bar at the top of the keyboard:
- Full-width bar above the predictive text area
- Shows "Start Dictation" with a mic icon
- Tapping opens the Murmur app for dictation (same `openMurmurForDictation()` logic)
- Style it similar to SwiftKey's "Start Flow" bar — subtle, not intrusive
- Keep a small mic icon in the bottom row as well for quick access

### 6. Fix Dictation Flow
Currently users get "need to open the app" error. Fix:
- Ensure the URL scheme `murmur://dictate` is properly registered
- Verify `extensionContext?.open(url)` works with Full Access enabled
- If URL scheme fails, show a more helpful error message
- The keyboard should detect when the user returns from the app and automatically insert the transcribed text (the pending text timer already handles this, but verify it works)

### 7. Pre-bundle Whisper Model
The model currently downloads on first launch. Change this:
- In the Xcode project, add the WhisperKit tiny model files to the app bundle (under a `Models/` group)
- On first launch, copy bundled models to the WhisperKit models directory instead of downloading
- If bundled models exist, skip the download entirely
- This ensures the app works offline immediately after install
- The tiny model (~40MB) is acceptable for bundle size
- NOTE: Check WhisperKit docs for `modelFolder` parameter to point to bundled models

### 8. Remove Mic Button Error in Main App
The main ContentView shows "Audio device disconnected. Partial audio was discarded." — this should be handled gracefully:
- Don't show raw error messages to users
- If audio device disconnects, show a friendly message like "Recording interrupted. Please try again."
- Clear the error after 3 seconds automatically

## Apple Keyboard Reference (Features to Match)

### Key Layout
- QWERTY layout with same key proportions ✅ (already done)
- Shift key on left, backspace on right of bottom letter row ✅
- Globe key, 123 key, space, return in bottom row ✅

### Key Behavior
- **Key pop-up:** Character magnifier appears on touch-down ❌ (missing)
- **Haptic:** Light tap feedback on every key press ❌ (missing)
- **Hold backspace:** Continuous deletion with acceleration ❌ (missing)
- **Double-space period:** Typing two spaces quickly inserts ". " ❌ (add this)
- **Auto-capitalization:** Capitalize after period/newline ❌ (add this)
- **Auto-shift on new sentence:** After ". " shift activates automatically ❌ (add this)

### Predictive Text
- Three suggestion slots above keyboard ❌ (missing)
- Tapping suggestion replaces current word ❌ (missing)
- Center slot shows current typed word ❌ (missing)

### Visual
- Key shadow/depth matching Apple style ✅ (close enough)
- Color scheme matching (light/dark mode) ✅
- Key corner radius matching ✅

## Technical Notes

- Project: /Users/jarvis/Desktop/Murmur
- Keyboard extension: Sources/MurmurKeyboard/
- Main app: Sources/Murmur/
- Shared code: Sources/Shared/
- Build with: `xcodegen generate && xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Test on simulator AND device — keyboard extensions behave differently

## Priority Order
1. Haptic feedback (quick win)
2. Continuous backspace
3. Key pop-up preview
4. Double-space period + auto-capitalization
5. Start Dictation bar
6. Predictive text bar
7. Fix dictation flow
8. Pre-bundle whisper model
9. Fix error message in main app
