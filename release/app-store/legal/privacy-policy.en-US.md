# Fonos Privacy Policy

Last updated: July 13, 2026

Fonos is a voice dictation app for iPhone. This policy explains how Fonos handles voice, text, notes, and configuration data.

## Data You Create

Fonos can process audio recordings, transcripts, edited text, translations, dictation history, and notes. Dictation history and notes are stored on your device unless you delete them.

## Microphone And Speech Recognition

Fonos asks for microphone access so it can record your voice for dictation. Fonos may also ask for speech recognition access to use Apple Speech.

For no-jump dictation from the Fonos custom keyboard, you may explicitly start a time-limited Keyboard Ready session in the main app. During that session iOS keeps microphone input active and shows its microphone indicator. Before you tap the microphone in the Fonos keyboard, incoming audio buffers are discarded and are not stored, recognized, or uploaded. After you tap, Fonos keeps only the bounded in-memory audio for that utterance and releases it after the selected recipe finishes, fails, or is cancelled. Keyboard Ready ends automatically unless you stop it sooner.

## Optional Third-Party Services

Fonos can use Apple Speech by default. You may also configure speech-to-text or language model services by entering your own endpoint and API key. Before Fonos sends content, the app identifies the provider and network destination, explains whether voice recordings, transcripts, or text prompts will be sent, and asks for your explicit permission. Voice recordings, transcripts, notes, and prompts are sent only when you initiate a configured feature that uses that remote model, such as a voice recipe or voice-note processing. A manual connectivity or model-discovery test may contact the configured endpoint and use its credential, but it does not send those contents.

Your use of a third-party service is subject to that provider's privacy policy and terms.

Public AI endpoints must use HTTPS. Clear-text HTTP is accepted only for an explicitly configured localhost or local-network server.

## API Keys

API keys entered in Fonos are stored in Keychain. They are not stored in plain app settings. Deleting a model profile removes its credential from Keychain. Because iOS may preserve Keychain items independently of an app's local sandbox, delete model profiles before uninstalling Fonos if you want to explicitly remove their credentials.

## Analytics And Advertising

Fonos does not include third-party advertising SDKs. Fonos does not use your data to track you across other companies' apps or websites.

## Local Data

History, notes, configuration, and remote-AI permission choices remain on your device until you delete them or iOS removes the app's local sandbox. You can remove local history, notes, and model profiles from the app. You can withdraw all remote-AI permissions at any time under Settings → General → Privacy & Data Sharing. After withdrawal, Fonos blocks future network STT and LLM requests until you explicitly allow that endpoint again.

Fonos does not operate an account or cloud-storage service. Withdrawing permission in Fonos does not delete content that a model provider already received. That provider controls its own retention and deletion; consult its privacy policy and use its privacy controls to request deletion.

## Contact

Support: https://github.com/ethannortharc/fonos/issues

Do not include API keys, transcripts, recordings, or other personal information in a public support issue.

A private support or privacy-contact email must be added to the published support page before App Review.
