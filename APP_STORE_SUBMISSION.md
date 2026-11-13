# App Store submission

This build is prepared for submission (3.1, build 11, export compliance set),
but it cannot be uploaded from the app that produced it: that environment only
issues development-signed install links and has no App Store Connect access or
distribution profile.

Before uploading, decide one thing: the bundle identifier.

## The live App Store record

- Name: **Murmur Keyboard - AI Powered** (subtitle "Powerful Private AI Dictation")
- Seller: John Wang — [developer page](https://apps.apple.com/us/developer/john-wang/id1888061643)
- App Store ID: `6761157714`
- Bundle identifier on the record: **`com.murmurkeyboard.app`**
- Released version: **2.3** (3 April 2026)
- https://apps.apple.com/us/app/murmur-keyboard-ai-powered/id6761157714

This project now builds **`com.murmur.dictation`** (app), `com.murmur.dictation.keyboard`
and `com.murmur.dictation.widget`, with App Group `group.com.murmur.dictation`.
The identifier was changed earlier because the development signing service
reported `com.murmurkeyboard.app` as registered to another app.

**Consequence:** uploading this build as-is creates a *new* App Store record.
It does not update "Murmur Keyboard - AI Powered".

## Option A — update the existing app (recommended for an update)

Set the identifiers back so the upload matches the live record:

| Target | Identifier |
| --- | --- |
| Murmur | `com.murmurkeyboard.app` |
| MurmurKeyboard | `com.murmurkeyboard.app.keyboard` |
| MurmurWidget | `com.murmurkeyboard.app.widget` |

Notes:

- Both extension identifiers must stay prefixed by the app's identifier.
- Use one App Group for app, keyboard and widget. If the group the 2.3 release
  used is still registered on the account, prefer it so existing users keep
  their transcripts; otherwise register the one you choose under
  Certificates, Identifiers & Profiles → Identifiers → App Groups.
- The keyboard extension's identifier shipped in 2.3 may differ from the one
  above. Check the existing provisioning profile before the first upload; if it
  differs, keep the shipped one to avoid leaving an orphaned keyboard in
  Settings after the update.

Trade-off: development install links are issued for `com.murmur.dictation`, so
switching back means those stop working.

## Option B — ship as a new app

Keep `com.murmur.dictation`, create a new App Store Connect record, and both
apps coexist. The 2.3 record stays on the store untouched.

## Uploading

1. In Xcode, set the team to John Wang's team, choose "Any iOS Device (arm64)"
   and archive with Product → Archive.
2. In the Organizer, Validate App, then Distribute App → App Store Connect.
3. In App Store Connect → My Apps → Murmur Keyboard - AI Powered → **+ Version
   or Platform** → iOS 3.1, select the uploaded build.
4. Paste `RELEASE_NOTES_V3.1.md` into "What's New".
5. Submit for review.

## Submission checklist

- [x] Version 3.1, build 11 (bumped for this submission)
- [x] `ITSAppUsesNonExemptEncryption` = false (standard HTTPS only)
- [x] Privacy manifest (`PrivacyInfo.xcprivacy`) in app and keyboard
- [x] Microphone usage description
- [x] App Group entitlement shared by app, keyboard and widget
- [x] Keyboard extension declares `RequestsOpenAccess`
- [ ] Screenshots for the 6.9" iPhone (1320 × 2868) — `screenshots/appstore-*.png`
      need checking against the current size requirements
- [ ] Privacy answers: the app stores transcripts on device only; enable cloud
      dictation only if you want it declared
- [ ] Review notes: the keyboard records through the container app (iOS forbids
      audio capture in an extension), and Full Access is needed for the handoff

## Known review risk

App Review sometimes rejects keyboards that require Full Access. The notes above
explain why it is needed here (app↔keyboard handoff and shared storage), and the
keyboard still types when it is off.
