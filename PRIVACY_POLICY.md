# Murmur - Privacy Policy

**Last updated:** July 24, 2026

## Overview

Murmur is a voice-to-text iPhone app with a custom keyboard extension. By
default, Murmur transcribes speech on-device using Apple's Core ML and the
WhisperKit framework. An optional cloud dictation mode is available only when
you enable it and configure a supported provider.

## Data Collection

**Murmur does not operate a content server, sell personal data, or use audio or
transcriptions for advertising or tracking.** Specifically:

- **No accounts.** Murmur does not require sign-up, login, or account creation.
- **No analytics or tracking.** Murmur does not use analytics SDKs, advertising SDKs, trackers, or third-party crash reporting services.
- **On-device by default.** Unless you enable cloud dictation, your speech is
  processed locally using an on-device Whisper model.
- **No Murmur cloud storage.** Murmur has no server or remote database for your
  audio, transcriptions, history, or personal dictionary.
- **Optional providers.** When cloud dictation is enabled, Murmur sends the
  current audio and enabled personal-dictionary spellings directly to the
  provider you selected. That provider processes the request under its own
  terms and privacy policy.

## Microphone Access

Murmur requests microphone permission so you can record speech for
transcription inside the app. Audio is used only while you are actively
dictating and is discarded by Murmur after processing. It remains on-device
unless you have enabled cloud dictation.

## Optional Cloud Dictation

Cloud dictation is off by default and requires an API key plus acceptance of an
in-app disclosure for the selected provider. When enabled:

- The recorded audio is transmitted over HTTPS to the selected provider.
- Enabled personal-dictionary spellings may be included as recognition hints.
- Murmur stores the API key in the iOS Keychain.
- If the provider is unavailable, Murmur may fall back to on-device
  transcription.

You can disable cloud dictation at any time in Settings.

## Keyboard Extension and Full Access

Murmur includes a custom keyboard extension. The keyboard extension:

- Does **not** log keystrokes
- Does **not** transmit typed text or dictated text off-device
- Uses the App Group shared container only to pass transcribed text from the main app to the keyboard on your device
- Stores that handoff text temporarily on-device and automatically clears stale handoff data after a short period

Murmur may ask you to enable **Full Access** for the keyboard. This is required for the keyboard extension to communicate with the main app through the shared container and insert the result back into the active text field. Murmur does **not** use Full Access for advertising, analytics, remote processing, or tracking.

## Model Download

On first launch, Murmur may download the selected Whisper model over **HTTPS** so transcription can run fully on-device afterward. This is a one-time model download provided through WhisperKit's model distribution pipeline, which may use Apple-hosted or Hugging Face-hosted content delivery infrastructure. After the model is downloaded, Murmur does not require internet access for transcription.

## Data Storage

Murmur keeps recent transcription history and your personal dictionary
on-device so you can view past dictations and manage preferred spellings. This
data stays on your device unless you copy or share text yourself, or enable
cloud dictation as described above. Murmur does not maintain a remote database
of your content.

## Children's Privacy

Murmur does not knowingly collect personal information from anyone, including children under 13.

## Changes to This Policy

If this policy changes, the updated version will be posted here with a new "Last updated" date.

## Contact

If you have questions about this privacy policy, please contact the developer through the support channel listed on the App Store product page.
