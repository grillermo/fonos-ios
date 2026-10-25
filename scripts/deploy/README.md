# OTA release

    ./deploy [patch|minor|major|X.Y.Z] [--yes] [--summary ...] [--note ...]

Builds an ad-hoc `.ipa` signed by team Q3WS4MWCW3 as `me.chiq.fonos`, publishes it with
its manifest, icon and install page into `../../file_server/files` (served at
`files.chiq.me`), then commits the version bump, tags `fonos-ota-vX.Y.Z` and pushes to the
`github` remote (grillermo/fonos-ios).

Install page (stable URL, open in Safari): https://files.chiq.me/files/fonos-install.html

Fork changes that make this possible:

- `DEVELOPMENT_TEAM` and bundle IDs switched to the personal team / `me.chiq.fonos*`.
- App Group `group.com.fonos.ios` renamed to `group.me.chiq.fonos` (entitlements and
  `FonosKeyboard/KeyboardIPC.swift`), so it can be registered on this team.
- `TARGETED_DEVICE_FAMILY` is `1,2`, so it runs as an iPad app instead of in iPhone mode.
- `icon.png` is upstream's `release/app-store/icon/fonos-icon-final-1024.png`.

A device must be registered on the developer portal before a build is made.
`ruby scripts/deploy/versioning_test.rb` tests the pbxproj version bump.

To use it with the mema server on the PC: Settings > Models, add an OpenAI-compatible
speech model with base URL `http://192.168.1.3:8787`, the server's `WHISKER_AUTH_TOKEN` as
the API key, and model `balanced` (Parakeet) or any other mema profile id.
