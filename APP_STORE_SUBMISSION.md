# App Store submission

Status: ready to archive as 3.1 (build 11). This environment cannot upload — it
only issues development-signed install links and has no App Store Connect
access or distribution profile — so the upload happens in Xcode on your Mac.

## Identifiers

Switched back to the live App Store record so an upload updates "Murmur
Keyboard - AI Powered" (App Store ID 6761157714) instead of creating a new app:

| Target | Bundle identifier |
| --- | --- |
| Murmur | `com.murmurkeyboard.app` |
| MurmurKeyboard | `com.murmurkeyboard.app.keyboard` |
| MurmurWidget | `com.murmurkeyboard.app.widget` |
| App Group (all three) | `group.com.murmur.dictation` |

Things this changes:

- **Development install links no longer work.** The signing service reports
  `com.murmurkeyboard.app` as belonging to the App Store record, so it will not
  issue a development build for it. Test through TestFlight instead.
- **The extension identifiers must stay prefixed by the app identifier**, which
  they are. Check the identifier the 2.3 build actually shipped: if it differed
  from `com.murmurkeyboard.app.keyboard`, keep the shipped one so the update
  does not leave an orphaned keyboard in Settings.
- **The App Group is unchanged** (`group.com.murmur.dictation`, already
  registered on the account). Users updating from 2.3 keep a working app and
  keyboard, but transcripts and snippets stored under the 2.3 group are not
  migrated. To carry them over, change the group in both entitlement files and
  in `SharedDefaults.appGroupID` to the one 2.3 used.

## Uploading

1. Open `Murmur.xcodeproj` in Xcode, select the Murmur target → Signing &
   Capabilities, choose John Wang's team, and let Xcode create the distribution
   profile. Repeat for MurmurKeyboard and MurmurWidget if signing is reported
   there.
2. Choose "Any iOS Device (arm64)" and Product → Archive.
3. In the Organizer: Validate App, then Distribute App → App Store Connect →
   Upload.
4. App Store Connect → My Apps → Murmur Keyboard - AI Powered → **+ Version or
   Platform** → iOS 3.1, and select the uploaded build.
5. Paste `RELEASE_NOTES_V3.1.md` into "What's New".
6. Submit for review.

## Submission checklist

- [x] Version 3.1, build 11 (bumped; raise it again if Apple reports a duplicate)
- [x] `ITSAppUsesNonExemptEncryption` = false (standard HTTPS only)
- [x] Privacy manifest (`PrivacyInfo.xcprivacy`) in app and keyboard
- [x] Microphone usage description
- [x] App Group entitlement on app, keyboard and widget
- [x] Keyboard extension declares `RequestsOpenAccess`
- [x] Bundle identifiers match the live record
- [ ] Screenshots for the 6.9" iPhone (1320 × 2868) — recheck
      `screenshots/appstore-*.png` against the current size requirements
- [ ] Privacy answers: transcripts stay on device unless cloud dictation is on
- [ ] Review notes: the keyboard records through the container app (iOS forbids
      audio capture inside an extension) and needs Full Access for the handoff

## Known review risk

App Review sometimes pushes back on keyboards that require Full Access. The notes
above explain why it is needed here, and the keyboard still types with it off.
