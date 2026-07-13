# Fonos Support

Fonos is a voice dictation app for iPhone.

## Contact

https://github.com/ethannortharc/fonos/issues

Do not include API keys, transcripts, recordings, or other personal information in a public support issue.

A private support email must be added here before App Review so users can contact the developer without disclosing personal information publicly.

## Common Setup Steps

- Allow microphone access when prompted.
- Allow speech recognition access when prompted.
- For the Fonos keyboard extension, enable Full Access in iOS Settings.
- Open Fonos → Settings → General and start the 15-minute Keyboard Ready session.

## Keyboard Dictation

The Fonos keyboard extension communicates with the main Fonos app through an App Group. If keyboard dictation does not start, open Fonos → Settings → General, start Keyboard Ready, then return to the app where you want to type and switch to the Fonos keyboard. The orange iOS microphone indicator remains visible while the time-limited Ready session is active; idle audio is discarded until you tap the keyboard microphone.

## Model Configuration

Fonos can use Apple Speech for dictation. You can also configure speech-to-text and language model services in Settings by entering your own endpoint and API key. Fonos identifies the recipient and asks for permission before sending voice or text to each configured endpoint.

API keys are stored in Keychain.
