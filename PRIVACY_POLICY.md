# Murmur - Privacy Policy

**Last updated:** March 29, 2026

## Overview

Murmur is a voice-to-text iPhone app with a custom keyboard extension. Murmur transcribes speech on-device using Apple's Core ML and the WhisperKit framework. We designed Murmur so your audio and text stay on your device.

## Data Collection

**Murmur does not collect, store, sell, transmit, or share personal data.** Specifically:

- **No accounts.** Murmur does not require sign-up, login, or account creation.
- **No analytics or tracking.** Murmur does not use analytics SDKs, advertising SDKs, trackers, or third-party crash reporting services.
- **No server-side transcription.** Your speech is processed locally on your device using an on-device Whisper model.
- **No cloud storage.** Your audio recordings and transcriptions are not uploaded to Murmur servers because Murmur has no servers for your content.
- **No third-party sharing.** Murmur does not sell, rent, or disclose your audio or transcribed text to third parties.

## Microphone Access

Murmur requests microphone permission so you can record speech for transcription inside the app. Audio is used only while you are actively dictating. Audio is processed locally for transcription and is discarded after processing.

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

Murmur keeps recent transcription history on-device so you can view your past dictations in the app. This history stays on your device unless you choose to copy or share text yourself. Murmur does not maintain a remote database of your content.

## Children's Privacy

Murmur does not knowingly collect personal information from anyone, including children under 13.

## Changes to This Policy

If this policy changes, the updated version will be posted here with a new "Last updated" date.

## Contact

If you have questions about this privacy policy, please contact the developer through the support channel listed on the App Store product page.
