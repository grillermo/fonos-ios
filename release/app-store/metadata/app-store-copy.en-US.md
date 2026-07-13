# Fonos App Store Copy (en-US)

## Where To Fill This In App Store Connect

- App Information: name, subtitle, categories, localizations
- App Store > iOS App 1.0: promotional text, description, keywords, screenshots, version release notes, build selection
- App Review Information: contact info, sign-in info, review notes
- Pricing and Availability: price and countries/regions
- App Privacy: privacy labels and privacy policy URL
- Age Rating: age-rating questionnaire
- Export Compliance: encryption questionnaire

## App Information

- App Name: Fonos
- Subtitle: Voice Dictation & Notes
- Primary Category: Productivity
- Secondary Category: Utilities
- Price Recommendation: Free for the initial release. Revisit subscriptions or in-app purchases later if cloud quotas or premium model features are added.

## Promotional Text

Dictate, polish, translate, and organize text with voice. Use Apple Speech or configure OpenAI-compatible STT and LLM services.

## Description

Fonos is a voice dictation app designed for iPhone. Open the app, start speaking, and turn your voice into text you can copy, share, refine, formalize, or translate. You can also use the Fonos keyboard extension to bring dictation into other apps.

Key features:

- One-tap dictation for quick text capture
- Raw, Polish, Formal, and Translate processing modes
- Dictation history for reviewing and reusing previous results
- Notes workflow for organizing spoken ideas into notebooks
- Keyboard extension for voice input in other apps
- Apple Speech support, with optional OpenAI-compatible STT and LLM configuration
- API keys are stored in Keychain, not in plain app settings

Fonos is useful for capturing ideas, replying to messages, drafting notes, summarizing meeting fragments, translating short phrases, and turning spoken thoughts into clearer written text.

## Keywords

dictation,voice,transcription,translate,polish,productivity,keyboard,notes,Whisper,STT

## Version Release Notes

Fonos 1.0 is the first iOS release, with dictation, history, notes, model settings, and a keyboard extension for voice input.

## App Review Notes

Fonos does not require account sign-in.

The main app can use Apple Speech for dictation. Users may also manually configure network STT or LLM services in Settings by adding an endpoint and API key. Fonos identifies the provider, destination, and data types and requires explicit permission before sending audio or text. Permissions can be withdrawn in Settings; API keys remain in Apple Keychain.

The keyboard extension requires Full Access and communicates with the main app through an App Group because iOS custom keyboards cannot access the microphone directly. To test it, open Fonos → Settings → General and explicitly start the 15-minute Keyboard Ready session, then switch to the Fonos keyboard in another app. iOS keeps its microphone indicator visible during that bounded session. Fonos discards idle audio buffers; after the keyboard microphone is tapped, it keeps only that bounded utterance in memory and releases it when the selected recipe finishes, fails, or is cancelled.

## Still Required From You

- Support URL: `https://github.com/ethannortharc/fonos/issues`
- Marketing URL, optional
- Privacy Policy URL: a public HTTPS URL is still required before submitting the App Store version to App Review
- Copyright
- Age Rating answers
- App Privacy labels: confirm whether audio, transcripts, notes, or diagnostics leave the device and remain accessible to the developer or a service provider after the real-time request finishes
- Export Compliance: confirm the processed build does not show Missing Compliance; answer only if App Store Connect still prompts after reading `ITSAppUsesNonExemptEncryption = NO`
