# Release Checklist

## Current candidate

- App: `com.fonos.ios`, version `1.0 (3)`
- Keyboard: `com.fonos.ios.keyboard`, version `1.0 (3)`
- Widget: `com.fonos.ios.widget`, version `1.0 (3)`
- Deployment target: iOS `17.0`
- Device family: iPhone (`UIDeviceFamily = [1]`)
- Team: `SBU743JJ9S`
- Localizations: English and Simplified Chinese
- Toolchain: Xcode `26.2`, iOS SDK `26.2`, Swift `6.2.3`
- Export compliance: `ITSAppUsesNonExemptEncryption = NO`; the app uses Apple-provided HTTPS and Keychain APIs and no custom cryptography

## Candidate validation — July 13, 2026

- Clean generic iOS Simulator build: passed
- Release static analysis: passed
- Unit/invariant suite: `532 / 532` passed, no failures or skips
- UI suite: `7 / 7` passed, including launch, tab navigation, Flow surfaces, recording entry, and screenshots
- Strict SwiftLint findings reduced from the main-branch baseline of `38` to `6`; the remaining findings are file/type-length warnings in four established service/settings files, with no force unwrap/try, complexity, long-function, or large-tuple findings
- Unsigned Release device archive: passed at `/tmp/FonosApp-final.xcarchive`
- Archive inspection: App, Keyboard, and Widget are all `1.0 (3)`, arm64, iPhone-only
- Privacy manifests: present in App and Keyboard bundles and pass `plutil -lint`
- String catalogs: valid JSON; English and Simplified Chinese compile
- App Store screenshot test: passed on iPhone 17 Pro Max
- Upload screenshot set: `release/app-store/screenshots/iphone-17-pro-max/`, four `1320 x 2868` portrait PNG files

Representative commands:

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

xcodebuild analyze -project FonosApp.xcodeproj -scheme FonosApp \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -project FonosApp.xcodeproj -scheme FonosAppUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild archive -project FonosApp.xcodeproj -scheme FonosApp \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/FonosApp-final.xcarchive CODE_SIGNING_ALLOWED=NO
```

## Historical artifacts — do not reuse for build 3

- `build/FonosApp.xcarchive` is historical `1.0 (2)`.
- `build/AppStore/FonosApp.ipa` is historical build `1` and does not contain the Widget.
- App Store Connect previously accepted the historical `1.0 (2)` binary upload; that does not mean it was distributed through TestFlight or approved by App Review, and it does not validate `1.0 (3)`.

## Before uploading build 3 / internal TestFlight

- Create a newly signed `1.0 (3)` archive with automatic signing.
- Confirm distribution profiles and signatures for App, Keyboard, and Widget.
- Export/upload build 3 and wait for App Store Connect processing.
- Confirm the processed build does not show Missing Compliance. Because `ITSAppUsesNonExemptEncryption = NO`, answer an export-compliance prompt only if App Store Connect still presents one.
- Assign an internal TestFlight group.
- On a physical iPhone, recheck Keyboard Ready while locked/backgrounded, phone-call interruption, Bluetooth route changes, expiry during an utterance, and repeated dictation.

Privacy Policy URL and full App Store metadata do not block binary upload or internal TestFlight.
`FONOS_PRIVACY_POLICY_URL` is compiled into the app. If build 3 will also be the App Review candidate, fill it before creating the signed archive. If build 3 is uploaded with an empty URL for internal TestFlight, use build 4 for a later review candidate that includes the in-app link.

## Before App Review

- Publish a public HTTPS privacy-policy page and put the same URL in App Store Connect and `FONOS_PRIVACY_POLICY_URL`.
- Publish a support page with a private contact email; a public GitHub Issues page alone should not be the only contact path.
- Finalize App Privacy answers against the actual remote STT/LLM providers and their retention behavior.
- Complete age rating, copyright, price/regions, App Review contact, review notes, and export compliance.
- Declare the required EU Digital Services Act trader/non-trader status.
- Select processed build `1.0 (3)` on the App Store version page.
- Run external TestFlight/Beta App Review first if desired, with beta description, feedback email, and test notes.

## Signed export / upload commands

After creating a signed build 3 archive at `build/FonosApp.xcarchive`:

```bash
xcodebuild -exportArchive \
  -archivePath build/FonosApp.xcarchive \
  -exportPath build/AppStore \
  -exportOptionsPlist release/app-store/ExportOptions.app-store-connect.plist \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/FonosApp.xcarchive \
  -exportPath build/AppStoreUpload \
  -exportOptionsPlist release/app-store/ExportOptions.app-store-upload.plist \
  -allowProvisioningUpdates
```

Do not describe build 3 as uploaded until App Store Connect confirms the upload and processing status.

## Later platforms

iPad remains a later universal-target project: it needs wide-layout work, iPad keyboard testing, and iPad screenshots. Apple Watch requires a separate watchOS app/extension and is not part of `1.0 (3)`.
