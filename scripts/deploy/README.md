# OTA release

    ./deploy [patch|minor|major|X.Y.Z] [--yes] [--summary ...] [--note ...]

Run it on any Mac that can sign the app. Preflight stops it before anything is touched on
no working publish route, a locked keychain it cannot unlock, a missing
icon, a branch other than `main`, a dirty tree or an existing tag. A failed run restores
`project.pbxproj`.

Publishing picks one route per run (see `scripts/deploy/uploader.rb`):

- `local`: on the macmini, copy into `~/c/file_server/files`.
- `scp`: on the home LAN, scp to the macmini and rename into place over ssh.
- `api`: anywhere else, POST to `FONOS_UPLOAD_BASE/upload` with the token saved by the
  file_server MCP login (`~/.config/file_server/token`). Large files go in slices the
  file_server joins, because the Cloudflare tunnel stalls on big request bodies.

Optional settings, in the gitignored dotenv file or the shell: `FONOS_UPLOAD_BASE`,
`FONOS_PUBLISH_DIR` (a local files/ directory; forces the local route),
`FONOS_PUBLISH_ROUTE=local|scp|api`, `FONOS_PUBLISH_HOST`, `FONOS_PUBLISH_REMOTE_DIR`,
`FONOS_UPLOAD_TOKEN` and `FONOS_PUBLISH_VERIFY=0`.

`FONOS_UNSIGNED=1` builds an unsigned `Payload/` zip and stops before publishing, for when signing is broken and you still need a binary.

Deployed builds carry the manifest URL as `FonosOTAManifestURL`, which adds an Install Latest
item to the app icon's long-press menu. The app closes itself after starting that install.
Builds made outside `./deploy` have no manifest URL and offer no such item.

Builds an ad-hoc `.ipa` signed by team Q3WS4MWCW3 as `me.chiq.fonos`, publishes it with
its manifest, icon and install page to the file_server (served at `files.chiq.me`), then commits the version bump, tags
`fonos-ota-vX.Y.Z` and pushes to the `github` remote (grillermo/fonos-ios).

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
the API key, and model `parakeet`, `qwen` or `whisper` (mema's profile ids; Probe lists them).

Or open a model link on the phone, which adds the profile, makes it the default speech
model and asks for remote-processing consent on one confirmation sheet:

    fonos://model?name=mema&base_url=http://192.168.1.3:8787&model=parakeet&api_key=<WHISKER_AUTH_TOKEN>

Optional parameters: `id`, `provider` (default `custom`), `capabilities` (`stt`, `llm` or
`stt,llm`; default `stt`), `stt_api` (`whisper` or `chat`) and `default` (which
capabilities to assign; default all of them).
