# Murmur Release Notes

## Highlights

This release makes Murmur feel much more like a real keyboard product instead of an app handoff demo.

### New: Smarter keyboard dictation flow
- Added warm/cold dictation session handling
- Keyboard and app now coordinate using shared session state
- Warm launches feel faster and smoother
- Failed or abandoned sessions no longer leave the keyboard polling forever
- Keyboard only inserts text for the active dictation session

### Better reliability
- Added safer transcription file validation before processing
- Improved interruption/abandonment handling for keyboard-triggered dictation
- Fixed long-press backspace behavior in the keyboard
- Cleaned up task lifecycle handling around transcription store loading

### UI and UX polish
- Cleaner app header
- Better settings sheet presentation
- Improved onboarding finish flow
- Better predictive text empty state
- Reduced keyboard banner crowding
- Improved spacing for smaller iPhones
- More consistent loading and readiness copy

### Dark mode improvements
- Refined app surfaces, cards, borders, and shadows for dark mode
- Improved onboarding gradients, hero treatments, and CTA styling
- Better keyboard contrast and separation in dark mode
- Preserved Murmur’s visual identity while making the darker theme feel intentional

## Summary
Murmur now has a more production-ready keyboard dictation flow, improved polish in both light and dark mode, and better reliability around session handoff between the keyboard extension and the main app.
