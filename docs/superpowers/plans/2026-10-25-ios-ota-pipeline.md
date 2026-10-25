# iOS OTA Pipeline (full spec) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring fonos-ios's existing `./deploy` OTA release up to the full spec in `~/c/agents-configs/docs/ios-ota-rollout/pipeline-prompt.md`, porting what is missing from the reference implementation in `~/c/vvterm`.

**Architecture:** The Ruby release script stays `./deploy` at the repo root. Its pure pieces (version bump, `.env` loading, CLI options, release notes, install page, ExportOptions and build settings) move into small, unit-tested modules under `scripts/deploy/`. The signing identity moves out of `project.pbxproj` into a committed `Config/Fonos.xcconfig` with a gitignored `Config/Local.xcconfig` override. All app-side code is fork-only and lives in a new `FonosApp/Fork/` folder: an Install Latest quick action and DevLog. They are wired into the upstream SwiftUI `App` with a single `@UIApplicationDelegateAdaptor` line, so upstream merges stay easy.

**Tech Stack:** Ruby 3.2 (stdlib + minitest), Xcode 26.3 / `xcodebuild`, Swift 6 + SwiftUI + UIKit, Swift Testing, Python 3 stdlib (DevLog server).

---

## Context for the executor (read first)

- Repo: `~/c/third-parties/fonos-ios` on the macmini (this machine). Fork of `github.com/ethannortharc/fonos-ios`.
- Remotes: `github` = `git@github.com:grillermo/fonos-ios.git` (**ours, the only one we push to**). `origin` = upstream `ethannortharc` (**never push there**). `main` tracks `origin/main`, so a bare `git push` would aim at upstream. Always name `github` explicitly. `./deploy` already does.
- State this plan builds on: `main` at `37a1a83 Release Fonos OTA fonos-ota-v1.0.9`, clean tree, `github/main` == HEAD. Today's commits (2026-10-25) added the fork (`b5bbf4e fork: sign as me.chiq.fonos on team Q3WS4MWCW3, build for iPad, add OTA ./deploy`) and releases v1.0.1–v1.0.9 with feature commits in between. Run `git log --oneline -15` first. If HEAD moved, rebase your understanding on the new commits, but the plan still applies.
- **The existing pipeline already works** (9 real releases). What exists today:
  - `deploy` (Ruby): it parses `--yes/--summary/--note`, checks that the branch is main and the tree is clean, checks that the tag exists not, checks the publish dir, prompts, bumps with an `at_exit` restore, builds, publishes .ipa → icon → manifest → page with staged renames, HTML-escapes the page, commits `Release Fonos OTA <tag>`, tags, and pushes to `github`.
  - `scripts/deploy/ipa_builder.rb`: `release-testing`, `thinning <none>`, the manifest dict, newest Xcode. Team/bundle ID are hard-coded constants.
  - `scripts/deploy/uploader.rb`: copies into `../../file_server/files` with a staged rename. The base URL is hard-coded `https://files.chiq.me` with a `FONOS_UPLOAD_BASE` env override.
  - `scripts/deploy/versioning.rb` + `versioning_test.rb`: bumps the app and nested-bundle-ID targets. Tested.
  - `FonosApp/Resources/Info.plist` already has `NSAppTransportSecurity → NSAllowsLocalNetworking = true`. Keep it.
- **Real gaps against the spec** (what this plan does):
  1. No `.env` loader. The base URL is hard-coded and should come from `FONOS_UPLOAD_BASE` in a gitignored `.env`.
  2. There is no codesign probe or `security unlock-keychain` preflight.
  3. The push has no fallback for "push failed but the remote already has HEAD".
  4. The bundle ID and team are hard-coded in `project.pbxproj` and `ipa_builder.rb`, and there is no `Config/*.xcconfig`.
  5. The signing-failure hint doesn't mention Xcode → Settings → Accounts.
  6. There is no `FONOS_UNSIGNED=1` ditto fallback.
  7. The temp build dir is only removed on success, so it leaks when a build or publish fails.
  8. The install page has no "Add to Home Screen" hint.
  9. The `--note=value` form and multi-line notes are not supported (vvterm supports both).
  10. There is no `FonosOTAManifestURL` Info.plist key and no Install Latest quick action. The app has no AppDelegate (pure SwiftUI `App`).
  11. There is no ntfy project memory.
  12. There is no `--devlog`, no `DevLog.swift`, no `scripts/devlog/server.py`, and `/log/` is not gitignored.
  13. The README doesn't document the deploy setup.
  14. `.env` and `Config/Local.xcconfig` are not gitignored.
- Reference implementation: `~/c/vvterm` (`deploy`, `scripts/deploy/*.rb`, `scripts/devlog/server.py`, `Config/*.xcconfig`, `VVTerm/Core/Logging/DevLog.swift`, `VVTerm/App/iOS/Composition/AppQuickAction*.swift`, `AppDelegate+iOS.swift`, `VVTermTests/App/Lifecycle/AppQuickActionTests.swift`). The code below is already adapted. Consult vvterm only if something here is unclear.
- Project conventions:
  - `FonosApp.xcodeproj` uses **classic file references** (`objectVersion = 56`, no synchronized folders). Every new Swift file must be added to `project.pbxproj` by hand: a PBXFileReference, a PBXBuildFile, a group child, and a Sources phase entry. The project already uses hand-made object IDs (e.g. `KBIPC002AA002AA002AA01A`). This plan uses IDs starting with `F0A0` (none exist yet; check with `grep -c F0A0 FonosApp.xcodeproj/project.pbxproj` → `0`).
  - Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`, `@testable import FonosApp`) in the `FonosAppTests` target (flat folder). The swiftlint config opts into `force_unwrapping`, so new app code must not use `!`.
  - Swift 6 language mode with no default MainActor isolation.
- DevLog ports: every app has its own so the servers run side by side on the macmini. **fonos-ios uses 19487** (vvterm already has 19480). `FONOS_DEVLOG_PORT` overrides it, and both `scripts/devlog/server.py` and `./deploy --devlog` read it. The smoke tests below use 19587, a spare port no app owns.
- Simulator for tests: `iPhone 16e` (exists and is booted on the macmini; `iPhone 16` from CLAUDE.md does not exist here). Unit test command used throughout:
  ```bash
  xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/<SuiteName> 2>&1 | tail -30
  ```
- Ruby tests: `for t in scripts/deploy/*_test.rb; do ruby "$t" || break; done`
- `docs/` is gitignored (CLAUDE.md: internal planning). This plan file was added with `git add -f`. Do not commit anything else under `docs/`.
- **Do not run `./deploy` without `FONOS_UNSIGNED=1` and do not publish anything before Task 14's explicit user approval.** Between Tasks 3 and 7 `./deploy` is intentionally half-migrated. Don't run it at all until Task 13.
- A Bash hook blocks commands that print a `.env` file. Use `test -f .env` to check it, and never `cat` it.
- Every commit message ends with a blank line and then:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  Commit locally after each task. Do not push. git-sync / the user handles that, and the real `./deploy` in Task 14 pushes.

## File structure

| File | Status | Responsibility |
|---|---|---|
| `Config/Fonos.xcconfig` | create | Committed defaults: `FONOS_BUNDLE_ID`, `DEVELOPMENT_TEAM`, empty `FONOS_OTA_MANIFEST_URL` / `FONOS_DEVLOG_URL`. Optional include of Local. |
| `Config/Local.xcconfig` | create, **gitignored** | `FONOS_BUNDLE_ID = me.chiq.fonos`, `DEVELOPMENT_TEAM = Q3WS4MWCW3` |
| `.env` | create, **gitignored** | `FONOS_UPLOAD_BASE=https://files.chiq.me` |
| `.gitignore` | modify | add `.env`, `Config/Local.xcconfig`, `/log/` |
| `FonosApp.xcodeproj/project.pbxproj` | modify | bundle IDs → `$(FONOS_BUNDLE_ID)…`, drop target `DEVELOPMENT_TEAM`, xcconfig as project base config, register new files |
| `scripts/deploy/versioning.rb` (+`_test`) | modify | match `PRODUCT_BUNDLE_IDENTIFIER = "$(FONOS_BUNDLE_ID)…"` |
| `scripts/deploy/dotenv_file.rb` (+`_test`) | create | minimal dotenv that never overrides an exported var |
| `scripts/deploy/cli_options.rb` (+`_test`) | create | `--flag value` / `--flag=value` extraction |
| `scripts/deploy/release_notes.rb` (+`_test`) | create | noise filter, max 8, note cleanup, description text |
| `scripts/deploy/install_page.rb` (+`_test`) | create | escaped, self-contained install page HTML |
| `scripts/deploy/ipa_builder.rb` (+`_test`) | modify | xcconfig-based identity, codesign probe, build settings, unsigned ditto fallback, signing hints |
| `scripts/deploy/uploader.rb` | modify | base URL required from `FONOS_UPLOAD_BASE` |
| `deploy` | rewrite | orchestration, header docs, `--devlog`, push fallback, temp-dir cleanup |
| `FonosApp/Fork/AppQuickAction.swift` | create | pure URL mapping for Install Latest |
| `FonosApp/Fork/FonosAppDelegate.swift` | create | registers the shortcut item, installs scene delegate |
| `FonosApp/Fork/AppQuickActionSceneDelegate.swift` | create | handles the action (cold launch + `windowScene(_:performActionFor:)`), `exit(0)` after 1.5 s |
| `FonosApp/Fork/DevLog.swift` | create | no-op unless `FonosDevLogURL` set, batched JSON sender |
| `FonosApp/FonosApp.swift` | modify (1 line) | `@UIApplicationDelegateAdaptor(FonosAppDelegate.self)` |
| `FonosApp/Resources/Info.plist` | modify | `FonosOTAManifestURL`, `FonosDevLogURL` keys |
| `FonosAppTests/AppQuickActionTests.swift` | create | URL mapping tests |
| `FonosAppTests/DevLogSinkTests.swift` | create | DevLog on/off tests |
| `scripts/devlog/server.py` | create | stdlib receiver on :19487 |
| `README.md`, `scripts/deploy/README.md` | modify | usage docs |
| `~/.claude/projects/-Users-grillermo-c-third-parties-fonos-ios/memory/deploy-ntfy-install-link.md` + `MEMORY.md` | create (outside repo) | ntfy-after-every-deploy memory |

---

### Task 0: Baseline

**Files:** none changed.

- [ ] **Step 1: Confirm the starting state**

```bash
cd ~/c/third-parties/fonos-ios && git status --short && git log --oneline -5 && git remote -v && git tag -l 'fonos-ota-v*' | sort -V | tail -3
```
Expected: empty status, HEAD is `Release Fonos OTA fonos-ota-v1.0.9` (or newer), `github` → grillermo, latest tag `fonos-ota-v1.0.9` (or newer). If the latest tag is newer, substitute it wherever this plan says `1.0.9`/`1.0.10`.

- [ ] **Step 2: Run the existing Ruby test**

```bash
cd ~/c/third-parties/fonos-ios && ruby scripts/deploy/versioning_test.rb
```
Expected: `4 runs, ... 0 failures, 0 errors`.

- [ ] **Step 3: Run the full unit test suite once and note pre-existing failures**

```bash
cd ~/c/third-parties/fonos-ios && xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests 2>&1 | grep -E "✘|failed|TEST SUCCEEDED|TEST FAILED" | tail -40
```
Write down any failing test names. They are pre-existing and are not this plan's job, but later tasks must not add new failures.

---

### Task 1: Versioning understands `$(FONOS_BUNDLE_ID)` bundle IDs

Task 2 replaces the literal `me.chiq.fonos*` bundle IDs in `project.pbxproj` with `"$(FONOS_BUNDLE_ID)"`, `"$(FONOS_BUNDLE_ID).keyboard"` etc. `Versioning` finds the app's blocks by bundle ID, so it must accept both forms (quoted or not).

**Files:**
- Modify: `scripts/deploy/versioning.rb`
- Test: `scripts/deploy/versioning_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `class VersioningTest` (before its final `end`) in `scripts/deploy/versioning_test.rb`:

```ruby
  # project.pbxproj names the bundle IDs through the FONOS_BUNDLE_ID build
  # setting (Config/Fonos.xcconfig), quoted because of the $( ).
  PBX_VARS = PBX.gsub(/PRODUCT_BUNDLE_IDENTIFIER = me\.chiq\.fonos([\w.]*);/) do
    %(PRODUCT_BUNDLE_IDENTIFIER = "$(FONOS_BUNDLE_ID)#{Regexp.last_match(1)}";)
  end

  def test_read_with_build_setting_ids
    assert_includes PBX_VARS, %(PRODUCT_BUNDLE_IDENTIFIER = "$(FONOS_BUNDLE_ID).keyboard";)
    assert_equal({ marketing: "2.1.1", build: 7 }, Versioning.read(PBX_VARS, bundle_id: Versioning::APP_ID))
  end

  def test_write_with_build_setting_ids_touches_the_app_and_its_extensions_only
    out = Versioning.write(PBX_VARS, bundle_id: Versioning::APP_ID, version: "2.1.2", build: 8)
    assert_equal({ marketing: "2.1.2", build: 8 }, Versioning.read(out, bundle_id: Versioning::APP_ID))
    assert_equal({ marketing: "2.1.2", build: 8 }, Versioning.read(out, bundle_id: "#{Versioning::APP_ID}.keyboard"))
    # "$(FONOS_BUNDLE_ID)other" is not nested under the app.
    assert_includes out, "MARKETING_VERSION = 1.0;"
    assert_includes out, "CURRENT_PROJECT_VERSION = 1;"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby scripts/deploy/versioning_test.rb`
Expected: errors `uninitialized constant Versioning::APP_ID`.

- [ ] **Step 3: Implement**

In `scripts/deploy/versioning.rb`, update the header comment's first sentence block and replace `app_blocks` and the `nested` regex in `write`. The full new file:

```ruby
# frozen_string_literal: true

# The version lives in FonosApp.xcodeproj/project.pbxproj, in the Debug and
# Release buildSettings of every target. read() takes it from the app target
# (the blocks whose PRODUCT_BUNDLE_IDENTIFIER is exactly the app's bundle ID);
# write() bumps the app and every target nested under its bundle ID (keyboard,
# widget, tests), since an extension's version must match its host app's.
#
# Bundle IDs are written as "$(FONOS_BUNDLE_ID)", "$(FONOS_BUNDLE_ID).keyboard"
# and so on (the value lives in Config/*.xcconfig), so APP_ID is that literal
# build-setting reference. Plain IDs (me.chiq.fonos) still work too.
module Versioning
  APP_ID    = "$(FONOS_BUNDLE_ID)"
  BLOCK     = /buildSettings = \{.*?\n\t\t\t\};/m
  MARKETING = /^(\s*"?MARKETING_VERSION(?:\[sdk=[^\]]+\])?"?\s*=\s*)([\d.]+);/
  BUILD     = /^(\s*CURRENT_PROJECT_VERSION\s*=\s*)(\d+);/

  module_function

  # PRODUCT_BUNDLE_IDENTIFIER line for bundle_id, optionally quoted; nested: true
  # also matches bundle_id.<suffix>.
  def id_line(bundle_id, nested:)
    suffix = nested ? '(?:\.[\w.-]+)?' : ""
    /PRODUCT_BUNDLE_IDENTIFIER = "?#{Regexp.escape(bundle_id)}#{suffix}"?;/
  end

  def app_blocks(text, bundle_id)
    exact = id_line(bundle_id, nested: false)
    text.scan(BLOCK).select { |b| b.match?(exact) }
  end

  def read(text, bundle_id:)
    block = app_blocks(text, bundle_id).first or
      raise ArgumentError, "no buildSettings with PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id} in project.pbxproj"
    marketing = block[MARKETING, 2] or raise ArgumentError, "no MARKETING_VERSION for #{bundle_id}"
    build     = block[BUILD, 2]     or raise ArgumentError, "no CURRENT_PROJECT_VERSION for #{bundle_id}"
    { marketing: marketing, build: build.to_i }
  end

  def bump(current, arg)
    return arg if arg =~ /\A\d+\.\d+(\.\d+)?\z/

    major, minor, patch = current.split(".").map(&:to_i)
    patch ||= 0
    case arg
    when "major" then "#{major + 1}.0.0"
    when "minor" then "#{major}.#{minor + 1}.0"
    when "patch", nil then "#{major}.#{minor}.#{patch + 1}"
    else raise ArgumentError, "bad argument '#{arg}' (use patch|minor|major or an X.Y[.Z] version)"
    end
  end

  def write(text, bundle_id:, version:, build:)
    nested = id_line(bundle_id, nested: true)
    text.gsub(BLOCK) do |block|
      next block unless block.match?(nested)

      block.gsub(MARKETING) { "#{$1}#{version};" }.gsub(BUILD) { "#{$1}#{build};" }
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby scripts/deploy/versioning_test.rb`
Expected: `6 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/versioning.rb scripts/deploy/versioning_test.rb
git commit -m "$(printf 'build(deploy): versioning accepts $(FONOS_BUNDLE_ID) bundle IDs\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 2: Signing identity in `Config/Fonos.xcconfig` + gitignored `Config/Local.xcconfig`

The spec says the bundle ID and team live in a gitignored `Config/Local.xcconfig` that overrides committed defaults, so a fresh clone still builds. Target-level settings in `project.pbxproj` beat an xcconfig, so the target `DEVELOPMENT_TEAM` lines must go. Bundle IDs become `$(FONOS_BUNDLE_ID)…`, which resolves from the xcconfig attached as the **project-level** base configuration.

**Deliberately unchanged:** the App Group `group.me.chiq.fonos` (in both `.entitlements` files and the Swift constant `KeyboardIPC.appGroupID`) and the keychain group `$(AppIdentifierPrefix)me.chiq.fonos`. Parameterizing them would mean editing upstream Swift. Task 12 documents that a different bundle ID also needs those three spots changed.

**Files:**
- Create: `Config/Fonos.xcconfig`, `Config/Local.xcconfig` (gitignored)
- Modify: `.gitignore`, `FonosApp.xcodeproj/project.pbxproj`, `deploy` (2 references)

- [ ] **Step 1: Create `Config/Fonos.xcconfig`**

```text
// Fork-only (OTA releases): settings that identify whoever signs the app.
// These defaults keep a fresh clone building; put your own values in
// Config/Local.xcconfig, which is gitignored and overrides them. See README.md.
FONOS_BUNDLE_ID = com.example.fonos
DEVELOPMENT_TEAM =

// ./deploy passes the OTA manifest URL on the xcodebuild command line, because
// an xcconfig file reads the // in a URL as a comment. Builds made any other
// way leave it empty and offer no Install Latest quick action.
FONOS_OTA_MANIFEST_URL =

// ./deploy --devlog passes the DevLog server URL the same way. Empty, DevLog
// records nothing.
FONOS_DEVLOG_URL =

#include? "Local.xcconfig"
```

- [ ] **Step 2: Create `Config/Local.xcconfig`**

```text
// Personal signing values; gitignored. Overrides Config/Fonos.xcconfig.
FONOS_BUNDLE_ID = me.chiq.fonos
DEVELOPMENT_TEAM = Q3WS4MWCW3
```

- [ ] **Step 3: Gitignore it (plus `.env` and `/log/` for later tasks)**

Append to `.gitignore`:

```text

# Fork (OTA releases): personal values, never committed
.env
Config/Local.xcconfig

# DevLog server output (scripts/devlog/server.py)
/log/
```

Verify:
```bash
git check-ignore -v Config/Local.xcconfig .env log/x && git status --short
```
Expected: three ignore matches. Status shows `.gitignore` modified and `Config/` with only `Fonos.xcconfig` untracked (`git status --short -uall` lists `Config/Fonos.xcconfig` and not `Local.xcconfig`).

- [ ] **Step 4: Rewrite bundle IDs and drop target teams in `project.pbxproj`**

```bash
ruby -i -pe '
  sub(/PRODUCT_BUNDLE_IDENTIFIER = me\.chiq\.fonos([\w.]*);/) { %(PRODUCT_BUNDLE_IDENTIFIER = "$(FONOS_BUNDLE_ID)#{$1}";) }
  $_ = "" if $_.match?(/^\s*DEVELOPMENT_TEAM = Q3WS4MWCW3;$/)
' FonosApp.xcodeproj/project.pbxproj
grep -c 'PRODUCT_BUNDLE_IDENTIFIER = "$(FONOS_BUNDLE_ID)' FonosApp.xcodeproj/project.pbxproj
grep -c 'DEVELOPMENT_TEAM\|me\.chiq' FonosApp.xcodeproj/project.pbxproj
```
Expected: `10` (5 targets × Debug/Release), then `0`.

- [ ] **Step 5: Register the xcconfig as the project-level base configuration**

Make four edits in `FonosApp.xcodeproj/project.pbxproj` (tabs, not spaces):

(a) After the line `/* Begin PBXFileReference section */` insert:
```text
		F0A007000000000000000001 /* Fonos.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Fonos.xcconfig; sourceTree = "<group>"; };
```

(b) After the line `/* Begin PBXGroup section */` insert:
```text
		F0A0F1000000000000000001 /* Config */ = {
			isa = PBXGroup;
			children = (
				F0A007000000000000000001 /* Fonos.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		};
```

(c) In the main group `EB7F26921B15416BBDBF911D = {`, its `children` list starts with `771A58FA8CA147459534EE1C /* FonosApp */,`. Insert this line directly before it:
```text
				F0A0F1000000000000000001 /* Config */,
```

(d) Replace
```text
		72EEA2B9000F4EAFB67013E3 /* Debug */ = {
			isa = XCBuildConfiguration;
```
with
```text
		72EEA2B9000F4EAFB67013E3 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = F0A007000000000000000001 /* Fonos.xcconfig */;
```
and replace
```text
		7BA1B7DB38D147B0B6F9CBC1 /* Release */ = {
			isa = XCBuildConfiguration;
```
with
```text
		7BA1B7DB38D147B0B6F9CBC1 /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = F0A007000000000000000001 /* Fonos.xcconfig */;
```
(These are the two PBXProject-level configurations, listed in `756B8C3D892E4965B3541FAA /* Build configuration list for PBXProject "FonosApp" */`.)

- [ ] **Step 6: Point `deploy` at the build-setting bundle ID**

In `deploy`, replace both occurrences of `bundle_id: B::BUNDLE_ID` with `bundle_id: Versioning::APP_ID` (one in `Versioning.read`, one in `Versioning.write`). Leave the install page's `B::BUNDLE_ID` for now. Task 7 rewrites `deploy`.

- [ ] **Step 7: Verify the settings resolve**

```bash
plutil -lint FonosApp.xcodeproj/project.pbxproj
xcodebuild -project FonosApp.xcodeproj -scheme FonosApp -configuration Release -showBuildSettings 2>/dev/null | grep -E '^ *(PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|FONOS_OTA_MANIFEST_URL) ='
```
Expected: `OK`, then `DEVELOPMENT_TEAM = Q3WS4MWCW3`, `PRODUCT_BUNDLE_IDENTIFIER = me.chiq.fonos`, and `FONOS_OTA_MANIFEST_URL =` (empty).

Fresh-clone check (temporarily hide Local):
```bash
mv Config/Local.xcconfig /tmp/fonos-Local.xcconfig && xcodebuild -project FonosApp.xcodeproj -scheme FonosApp -showBuildSettings 2>/dev/null | grep -E '^ *PRODUCT_BUNDLE_IDENTIFIER ='; mv /tmp/fonos-Local.xcconfig Config/Local.xcconfig
```
Expected: `PRODUCT_BUNDLE_IDENTIFIER = com.example.fonos`, and the file is back in place (`test -f Config/Local.xcconfig && echo back`).

Keyboard extension check:
```bash
xcodebuild -project FonosApp.xcodeproj -target FonosKeyboard -showBuildSettings 2>/dev/null | grep -E '^ *PRODUCT_BUNDLE_IDENTIFIER ='
```
Expected: `me.chiq.fonos.keyboard`.

- [ ] **Step 8: Simulator build and Ruby tests**

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' 2>&1 | tail -3
ruby scripts/deploy/versioning_test.rb
ruby -r ./scripts/deploy/versioning -e 'p Versioning.read(File.read("FonosApp.xcodeproj/project.pbxproj"), bundle_id: Versioning::APP_ID)'
```
Expected: `** BUILD SUCCEEDED **`, tests pass, and `{:marketing=>"1.0.9", :build=>12}` (or the current values).

- [ ] **Step 9: Commit (Local.xcconfig must NOT be in it)**

```bash
git add .gitignore Config/Fonos.xcconfig FonosApp.xcodeproj/project.pbxproj deploy
git status --short   # Config/Local.xcconfig must not appear
git commit -m "$(printf 'build(fork): bundle ID and team from Config/Local.xcconfig\n\nConfig/Fonos.xcconfig holds committed defaults (com.example.fonos, no\nteam) so a fresh clone builds; the gitignored Config/Local.xcconfig\noverrides them. Targets name their bundle IDs through FONOS_BUNDLE_ID.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 3: `.env` loader and a required `FONOS_UPLOAD_BASE`

**Files:**
- Create: `scripts/deploy/dotenv_file.rb`, `scripts/deploy/dotenv_file_test.rb`, `.env` (gitignored)
- Modify: `scripts/deploy/uploader.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/dotenv_file_test.rb`

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "dotenv_file"

class DotEnvFileTest < Minitest::Test
  def test_parse_reads_key_value_lines
    vars = DotEnvFile.parse(<<~ENV)
      # comment

      FONOS_UPLOAD_BASE=https://files.chiq.me
      QUOTED="a b"
      SINGLE='c'
      export EXPORTED=yes
      WITH_EQUALS=a=b
      NOVALUE
    ENV
    assert_equal(
      { "FONOS_UPLOAD_BASE" => "https://files.chiq.me", "QUOTED" => "a b", "SINGLE" => "c",
        "EXPORTED" => "yes", "WITH_EQUALS" => "a=b" },
      vars
    )
  end

  def test_load_never_overrides_an_exported_variable
    file = Tempfile.new("dotenv")
    file.write("A=from-file\nB=from-file\nC=from-file\n")
    file.close
    env = { "A" => "exported", "C" => "" }
    DotEnvFile.load(file.path, env)
    assert_equal({ "A" => "exported", "B" => "from-file", "C" => "" }, env)
  ensure
    file&.unlink
  end

  def test_load_ignores_a_missing_file
    env = {}
    DotEnvFile.load("/nonexistent/dotenv", env)
    assert_empty env
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby scripts/deploy/dotenv_file_test.rb`
Expected: `cannot load such file -- .../dotenv_file`.

- [ ] **Step 3: Implement** `scripts/deploy/dotenv_file.rb`

```ruby
# frozen_string_literal: true

# Minimal dotenv for ./deploy: KEY=VALUE lines from the repo's gitignored .env.
# A variable already in the environment always wins, even when empty, so a
# one-off `FONOS_X=... ./deploy` overrides the file.
module DotEnvFile
  module_function

  def parse(text)
    text.each_line.with_object({}) do |line, vars|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next if value.nil?

      key = key.strip.delete_prefix("export ").strip
      next if key.empty?

      vars[key] = value.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  def load(path, env = ENV)
    return unless File.exist?(path)

    parse(File.read(path)).each { |key, value| env[key] = value unless env.key?(key) }
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby scripts/deploy/dotenv_file_test.rb`
Expected: `3 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Make the base URL come only from the environment**

In `scripts/deploy/uploader.rb`, delete the line `DEFAULT_BASE = "https://files.chiq.me"` and replace `def base_url = ENV.fetch("FONOS_UPLOAD_BASE", DEFAULT_BASE).sub(%r{/+\z}, "")` with:

```ruby
  # Public URL of the file server (files.chiq.me), from FONOS_UPLOAD_BASE in .env.
  def base_url
    base = ENV["FONOS_UPLOAD_BASE"].to_s
    IpaBuilder.die("set FONOS_UPLOAD_BASE (in .env) to the public URL of your file server, e.g. https://files.chiq.me") if base.empty?
    base.sub(%r{/+\z}, "")
  end
```

Also update the header comment's first paragraph to say "the file_server service behind FONOS_UPLOAD_BASE (files.chiq.me)" instead of "file_to_s3 service behind files.chiq.me", and the `check_publish_dir!` message to say `file_server` instead of `file_to_s3`.

- [ ] **Step 6: Create the local `.env` (gitignored, no secrets in it)**

```bash
test -f .env && echo "exists, leave it" || printf 'FONOS_UPLOAD_BASE=https://files.chiq.me\n' > .env
git check-ignore -q .env && echo ignored
```
Expected: `ignored`.

- [ ] **Step 7: Commit**

```bash
git add scripts/deploy/dotenv_file.rb scripts/deploy/dotenv_file_test.rb scripts/deploy/uploader.rb
git commit -m "$(printf 'build(deploy): read FONOS_UPLOAD_BASE from a gitignored .env\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 4: CLI options and release notes helpers

**Files:**
- Create: `scripts/deploy/cli_options.rb`, `scripts/deploy/cli_options_test.rb`, `scripts/deploy/release_notes.rb`, `scripts/deploy/release_notes_test.rb`

- [ ] **Step 1: Write the failing tests**

`scripts/deploy/cli_options_test.rb`:
```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "cli_options"

class CliOptionsTest < Minitest::Test
  def test_takes_separate_and_equals_forms_and_leaves_positionals
    argv = ["minor", "--note", "one", "--note=two", "-n", "three", "--summary", "S"]
    assert_equal %w[one two three], CliOptions.take(argv, "--note", "-n")
    assert_equal ["minor", "--summary", "S"], argv
  end

  def test_missing_value_raises
    assert_raises(ArgumentError) { CliOptions.take(["--note"], "--note") }
    assert_raises(ArgumentError) { CliOptions.take(["--note", "--yes"], "--note") }
  end
end
```

`scripts/deploy/release_notes_test.rb`:
```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "release_notes"

class ReleaseNotesTest < Minitest::Test
  def test_from_subjects_drops_noise_dupes_and_keeps_at_most_eight
    subjects = [
      "Release Fonos OTA fonos-ota-v1.0.9\n", "Merge branch 'x'", "Bump deps", "WIP poking",
      "wip", "feat: a", "feat: a", "", "Commit pending changes",
      *(1..10).map { |i| "fix: #{i}" }
    ]
    assert_equal ["feat: a", *(1..7).map { |i| "fix: #{i}" }], ReleaseNotes.from_subjects(subjects)
  end

  def test_clean_splits_lines_and_strips_bullets
    assert_equal %w[one two three], ReleaseNotes.clean(["- one\n• two", "  * three ", "  "])
  end

  def test_compose
    assert_equal "What's new in 1.1.0:\n\n• a\n• b", ReleaseNotes.compose(version: "1.1.0", summary: nil, bullets: %w[a b])
    assert_equal "Faster\n\n• a", ReleaseNotes.compose(version: "1.1.0", summary: "Faster", bullets: %w[a])
    assert_equal "Release 1.1.0.", ReleaseNotes.compose(version: "1.1.0", summary: nil, bullets: [])
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby scripts/deploy/cli_options_test.rb; ruby scripts/deploy/release_notes_test.rb`
Expected: both fail with `cannot load such file`.

- [ ] **Step 3: Implement**

`scripts/deploy/cli_options.rb`:
```ruby
# frozen_string_literal: true

module CliOptions
  module_function

  # Pulls every "--flag value" / "--flag=value" for any of `names` out of argv,
  # so the version argument stays positional wherever it sits, and returns the
  # values in order. Raises ArgumentError when a flag has no value.
  def take(argv, *names)
    values = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if names.include?(arg)
        value = argv[i + 1]
        raise ArgumentError, "#{arg} needs a value" if value.nil? || value.start_with?("--")

        values << value
        argv.slice!(i, 2)
      elsif (eq = arg.match(/\A(--[a-z-]+)=(.*)\z/m)) && names.include?(eq[1])
        values << eq[2]
        argv.slice!(i, 1)
      else
        i += 1
      end
    end
    values
  end
end
```

`scripts/deploy/release_notes.rb`:
```ruby
# frozen_string_literal: true

# Release notes for the install page and the confirmation prompt.
module ReleaseNotes
  # Subjects that say nothing to someone installing the app: our own release
  # commits, merges, dependency bumps and work-in-progress.
  NOISE = /\A(Release Fonos OTA |Merge |Commit pending changes|Bump |wip\b)/i
  MAX = 8

  module_function

  def from_subjects(subjects)
    subjects.map(&:strip).reject { |s| s.empty? || s.match?(NOISE) }.uniq.first(MAX)
  end

  # --note values: one bullet per line, leading "-", "*" or "•" removed.
  def clean(raw_notes)
    raw_notes.flat_map { |n| n.split("\n") }.map { |n| n.strip.sub(/\A[-*•]\s*/, "") }.reject(&:empty?)
  end

  def compose(version:, summary:, bullets:)
    headline = summary || (bullets.empty? ? "Release #{version}." : "What's new in #{version}:")
    lines = [headline]
    lines << "" unless bullets.empty?
    lines.concat(bullets.map { |b| "• #{b}" })
    lines.join("\n")
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby scripts/deploy/cli_options_test.rb && ruby scripts/deploy/release_notes_test.rb`
Expected: `2 runs ... 0 failures` and `3 runs ... 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/cli_options.rb scripts/deploy/cli_options_test.rb scripts/deploy/release_notes.rb scripts/deploy/release_notes_test.rb
git commit -m "$(printf 'build(deploy): tested CLI option and release-note helpers\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 5: Install page renderer

**Files:**
- Create: `scripts/deploy/install_page.rb`, `scripts/deploy/install_page_test.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/install_page_test.rb`

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "install_page"

class InstallPageTest < Minitest::Test
  ITMS = "itms-services://?action=download-manifest&url=https://files.chiq.me/files/fonos-manifest.plist"

  def page(notes: "What's new in 1.0.10:\n\n• <b>bold</b> & \"quoted\"")
    InstallPage.render(version: "1.0.10", build: 13, icon_url: "https://files.chiq.me/files/fonos-icon.png",
                       itms_url: ITMS, notes: notes, bundle_id: "me.chiq.fonos")
  end

  def test_install_button_links_to_the_escaped_itms_url
    assert_includes page, %(href="itms-services://?action=download-manifest&amp;url=https://files.chiq.me/files/fonos-manifest.plist")
  end

  def test_everything_inserted_is_escaped
    html = page
    refute_includes html, "<b>bold</b>"
    assert_includes html, "&lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot;"
  end

  def test_has_version_safari_home_screen_and_registration_notes
    html = page
    assert_includes html, "Version 1.0.10 (build 13)"
    assert_includes html, "Safari"
    assert_includes html, "Add to Home Screen"
    assert_includes html, "registered"
    assert_includes html, "<code>me.chiq.fonos</code>"
    assert_includes html, %(<meta name="viewport")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby scripts/deploy/install_page_test.rb`
Expected: `cannot load such file`.

- [ ] **Step 3: Implement** `scripts/deploy/install_page.rb`

```ruby
# frozen_string_literal: true

# The self-contained install page published under a fixed name
# (fonos-install.html), so one Home Screen bookmark installs the newest release.
# Everything inserted is HTML-escaped: release notes come from commit subjects.
module InstallPage
  module_function

  def h(str) = str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")

  def render(version:, build:, icon_url:, itms_url:, notes:, bundle_id:)
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <title>Install Fonos</title>
      <style>
        :root { color-scheme: dark; }
        body { margin: 0; padding: 2.5rem 1.25rem 4rem; background: #111; color: #f2f2f2;
          font: 16px/1.55 -apple-system, system-ui, sans-serif; display: flex; flex-direction: column; align-items: center; }
        main { width: 100%; max-width: 26rem; }
        img.icon { width: 88px; height: 88px; border-radius: 20px; display: block; margin: 0 auto 1.25rem; }
        h1 { font-size: 1.6rem; margin: 0 0 .25rem; text-align: center; }
        .version { text-align: center; color: #9a9a9a; margin: 0 0 2rem; font-size: .95rem; }
        a.install { display: block; background: #1E88E5; color: #fff; text-decoration: none; font-weight: 600;
          font-size: 1.05rem; text-align: center; padding: 1rem; border-radius: 14px; margin-bottom: 1.5rem; }
        a.install:active { background: #1667b0; }
        section { border-top: 1px solid #2a2a2a; padding-top: 1.25rem; margin-top: 1.25rem; }
        h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em; color: #8a8a8a; margin: 0 0 .6rem; }
        pre.notes { white-space: pre-wrap; margin: 0; font: inherit; color: #d8d8d8; }
        p { color: #b0b0b0; font-size: .9rem; }
        code { background: #1c1c1c; padding: .15em .4em; border-radius: 5px; font-size: .85em; word-break: break-all; }
      </style>
      </head>
      <body>
      <main>
        <img class="icon" src="#{h(icon_url)}" alt="">
        <h1>Fonos</h1>
        <p class="version">Version #{h(version)} (build #{h(build)})</p>
        <a class="install" href="#{h(itms_url)}">Install Fonos</a>
        <p>Open this page in <strong>Safari</strong>; other browsers cannot start an install.
        Then confirm the prompt and watch the Home Screen.</p>
        <section><h2>What&rsquo;s new</h2><pre class="notes">#{h(notes)}</pre></section>
        <section><h2>Updating later</h2>
        <p>Add this page to your Home Screen (Share &rarr; Add to Home Screen). Its Install button
        always installs the newest release, and so does the app's <strong>Install Latest</strong>
        quick action (touch and hold the app icon).</p></section>
        <section><h2>Requirements</h2>
        <p>The device must be registered on the developer account before the build is made; a device
        added afterwards needs a fresh <code>./deploy</code>. This fork is signed as
        <code>#{h(bundle_id)}</code>, so it installs beside the App Store Fonos.</p></section>
      </main>
      </body>
      </html>
    HTML
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby scripts/deploy/install_page_test.rb`
Expected: `3 runs, ... 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/install_page.rb scripts/deploy/install_page_test.rb
git commit -m "$(printf 'build(deploy): tested install page with a Home Screen hint\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 6: `ipa_builder`: xcconfig identity, codesign probe, build settings, unsigned fallback

After this task `deploy` still references the removed `B::BUNDLE_ID` in its install page. Task 7 rewrites it. Don't run `./deploy` in between.

**Files:**
- Modify (rewrite): `scripts/deploy/ipa_builder.rb`
- Create: `scripts/deploy/ipa_builder_test.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/ipa_builder_test.rb`

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "ipa_builder"

class IpaBuilderTest < Minitest::Test
  def test_export_options_make_one_universal_ad_hoc_ipa_with_a_manifest
    Dir.mktmpdir do |dir|
      path = IpaBuilder.export_options_plist(
        File.join(dir, "ExportOptions.plist"),
        team_id: "TEAM123",
        manifest: { app_url: "https://f.example/files/FonosApp-1.0.10.ipa?a=1&b=2",
                    icon_url: "https://f.example/files/fonos-icon.png" }
      )
      xml = File.read(path)
      assert_includes xml, "<key>method</key><string>release-testing</string>"
      assert_includes xml, "<key>teamID</key><string>TEAM123</string>"
      assert_includes xml, "<key>signingStyle</key><string>automatic</string>"
      assert_includes xml, "<key>thinning</key><string>&lt;none&gt;</string>"
      assert_includes xml, "<key>appURL</key><string>https://f.example/files/FonosApp-1.0.10.ipa?a=1&amp;b=2</string>"
      assert_includes xml, "<key>displayImageURL</key><string>https://f.example/files/fonos-icon.png</string>"
      assert system("plutil", "-lint", "-s", path), "ExportOptions.plist is not a valid plist"
    end
  end

  def test_local_xcconfig_wins_over_committed_defaults
    Dir.mktmpdir do |dir|
      local = File.join(dir, "Local.xcconfig")
      committed = File.join(dir, "Fonos.xcconfig")
      File.write(committed, "FONOS_BUNDLE_ID = com.example.fonos\nDEVELOPMENT_TEAM =\n")
      File.write(local, "// mine\nFONOS_BUNDLE_ID = me.chiq.fonos\n")
      assert_equal "me.chiq.fonos", IpaBuilder.xcconfig_value("FONOS_BUNDLE_ID", paths: [local, committed])
      assert_nil IpaBuilder.xcconfig_value("DEVELOPMENT_TEAM", paths: [local, committed])
      assert_equal "com.example.fonos",
                   IpaBuilder.xcconfig_value("FONOS_BUNDLE_ID", paths: [File.join(dir, "missing.xcconfig"), committed])
    end
  end

  def test_build_settings_go_on_the_command_line
    assert_equal "DEVELOPMENT_TEAM=TEAM123 FONOS_OTA_MANIFEST_URL=https://files.chiq.me/files/fonos-manifest.plist",
                 IpaBuilder.build_settings(unsigned: false, team_id: "TEAM123",
                                           ota_manifest_url: "https://files.chiq.me/files/fonos-manifest.plist",
                                           devlog_url: nil)
    assert_equal "CODE_SIGNING_ALLOWED=NO FONOS_DEVLOG_URL=http://macmini.local:19487/api/devlog",
                 IpaBuilder.build_settings(unsigned: true, team_id: nil, ota_manifest_url: nil,
                                           devlog_url: "http://macmini.local:19487/api/devlog")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby scripts/deploy/ipa_builder_test.rb`
Expected: errors such as `unknown keyword: :team_id` and `undefined method 'xcconfig_value'`.

- [ ] **Step 3: Rewrite** `scripts/deploy/ipa_builder.rb`

```ruby
# frozen_string_literal: true

# Builds an ad-hoc-signed Fonos .ipa (app + keyboard + widget) from
# FonosApp.xcodeproj, together with the OTA manifest.plist an `itms-services://`
# link points at. Used by ../../deploy.
#
# Signed with the paid team in Config/Local.xcconfig, so it installs from Safari
# with no cable, but only on devices registered on the portal before the build,
# and only once these App IDs exist there (automatic signing creates
# certificates and profiles, never App IDs):
#   <FONOS_BUNDLE_ID>            (App Groups: group.me.chiq.fonos)
#   <FONOS_BUNDLE_ID>.keyboard   (App Groups: group.me.chiq.fonos)
#   <FONOS_BUNDLE_ID>.widget
#
# FONOS_UNSIGNED=1 falls back to an unsigned Payload/ zip. Safari cannot install
# it; it exists so a broken signing setup never blocks getting a binary.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  APP_NAME  = "FonosApp"
  SCHEME    = "FonosApp"
  REPO_ROOT = File.expand_path(File.join(__dir__, "..", ".."))
  PROJECT   = "FonosApp.xcodeproj"
  PBXPROJ   = File.join(REPO_ROOT, PROJECT, "project.pbxproj")
  # Local (gitignored, personal) first: it overrides the committed defaults.
  XCCONFIGS = [
    File.join(REPO_ROOT, "Config", "Local.xcconfig"),
    File.join(REPO_ROOT, "Config", "Fonos.xcconfig"),
  ].freeze
  PLACEHOLDER_BUNDLE_ID = "com.example.fonos"

  module_function

  def bold(str) = "\e[1m#{str}\e[0m"
  def green(str) = "\e[32m#{str}\e[0m"
  def red(str) = "\e[31m#{str}\e[0m"
  def step(msg) = puts "\n#{bold("==> #{msg}")}"

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}")
  end

  def unsigned? = ENV["FONOS_UNSIGNED"] == "1"

  # A build setting as Xcode resolves it from our xcconfigs: the first file that
  # sets it to something non-empty wins.
  def xcconfig_value(key, paths: XCCONFIGS)
    paths.each do |path|
      next unless File.exist?(path)

      value = File.read(path)[/^[ \t]*#{Regexp.escape(key)}[ \t]*=[ \t]*(\S*)/, 1]
      return value unless value.nil? || value.empty?
    end
    nil
  end

  def bundle_id = xcconfig_value("FONOS_BUNDLE_ID")

  # FONOS_TEAM_ID overrides Config/Local.xcconfig for a one-off.
  def team_id
    env = ENV["FONOS_TEAM_ID"].to_s
    env.empty? ? xcconfig_value("DEVELOPMENT_TEAM") : env
  end

  # Preflight: a signed build needs a real bundle ID and a team, which only
  # Config/Local.xcconfig provides (the committed defaults are placeholders).
  def check_signing_config!
    return if unsigned?

    id = bundle_id
    if id.nil? || id == PLACEHOLDER_BUNDLE_ID
      die("FONOS_BUNDLE_ID is #{id.inspect}; create Config/Local.xcconfig with your bundle ID " \
          "and DEVELOPMENT_TEAM (see README.md), or set FONOS_UNSIGNED=1")
    end
    die("no DEVELOPMENT_TEAM in Config/Local.xcconfig and no FONOS_TEAM_ID set") if team_id.nil?
  end

  # xcodebuild needs a full Xcode, not the Command Line Tools. Honour an existing
  # DEVELOPER_DIR, otherwise use the newest /Applications/Xcode*.app.
  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  # Over SSH, or after the Mac slept, the login keychain is locked and codesign
  # cannot use the signing key: the archive then dies at its first CodeSign
  # step (errSecInternalComponent) after minutes of compiling. Probe by signing
  # a throwaway copy of /usr/bin/true; if that fails, unlock the keychain
  # (prompts for the login password) and probe again.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{Shellwords.escape(probe)} >/dev/null 2>&1"
    return if system(sign)

    puts red("    codesign cannot use your signing key -- the login keychain is locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{Shellwords.escape(keychain)}") or
      die("could not unlock the login keychain")
    system(sign) or
      die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /some/file")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def xml_escape(str) = str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  # `release-testing` is Xcode 15.3+'s name for ad hoc: the distribution
  # certificate plus an Ad Hoc profile listing the registered devices.
  # The `manifest` dict makes xcodebuild write manifest.plist, so it can never
  # drift from the binary; appURL must be the .ipa's final public URL, known
  # before the build. thinning <none> keeps one universal .ipa, because a
  # thinned export makes per-device variants that one URL cannot serve.
  def export_options_plist(path, team_id:, manifest:)
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>method</key><string>release-testing</string>
        <key>teamID</key><string>#{xml_escape(team_id)}</string>
        <key>signingStyle</key><string>automatic</string>
        <key>stripSwiftSymbols</key><true/>
        <key>thinning</key><string>&lt;none&gt;</string>
        <key>destination</key><string>export</string>
        <key>manifest</key>
        <dict>
          <key>appURL</key><string>#{xml_escape(manifest[:app_url])}</string>
          <key>displayImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
          <key>fullSizeImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
        </dict>
      </dict>
      </plist>
    PLIST
    path
  end

  # Command-line build settings for `xcodebuild archive`. The URLs go here, not
  # in an xcconfig, because an xcconfig reads the // in a URL as a comment.
  def build_settings(unsigned:, team_id:, ota_manifest_url:, devlog_url:)
    settings = unsigned ? ["CODE_SIGNING_ALLOWED=NO"] : ["DEVELOPMENT_TEAM=#{Shellwords.escape(team_id)}"]
    settings << "FONOS_OTA_MANIFEST_URL=#{Shellwords.escape(ota_manifest_url)}" if ota_manifest_url
    settings << "FONOS_DEVLOG_URL=#{Shellwords.escape(devlog_url)}" if devlog_url
    settings.join(" ")
  end

  # Builds into `work` (a temp dir the caller creates and removes, even when this
  # dies) and returns the .ipa path. A signed export also writes manifest.plist
  # next to the .ipa.
  def build(work:, manifest:, ota_manifest_url: nil, devlog_url: nil)
    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"
    archive = File.join(work, "#{APP_NAME}.xcarchive")
    settings = build_settings(unsigned: unsigned?, team_id: team_id,
                              ota_manifest_url: ota_manifest_url, devlog_url: devlog_url)

    step "Archiving (xcodebuild)#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild -project #{PROJECT} -scheme #{SCHEME} -configuration Release " \
      "-destination 'generic/platform=iOS' -archivePath #{Shellwords.escape(archive)} " \
      "#{settings} -allowProvisioningUpdates archive",
      chdir: REPO_ROOT
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)

    return package_unsigned(archive, work) if unsigned?

    step "Exporting signed .ipa (ad hoc)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), team_id: team_id, manifest: manifest)
    run(
      "xcodebuild -exportArchive -archivePath #{Shellwords.escape(archive)} " \
      "-exportPath #{Shellwords.escape(work)} -exportOptionsPlist #{Shellwords.escape(options)} " \
      "-allowProvisioningUpdates",
      chdir: REPO_ROOT
    )

    ipa = File.join(work, "#{APP_NAME}.ipa")
    unless File.exist?(ipa)
      die("export produced no .ipa in #{work} (see the xcodebuild output above). If signing failed, check:\n" \
          "  - the Apple ID for team #{team_id} is added in Xcode -> Settings -> Accounts;\n" \
          "  - the device is registered on the developer portal (ad hoc only installs on devices\n" \
          "    registered before the build);\n" \
          "  - the App IDs #{bundle_id}, #{bundle_id}.keyboard and #{bundle_id}.widget exist on the portal\n" \
          "    (\"no profiles found\": automatic signing does not create App IDs).\n" \
          "  FONOS_UNSIGNED=1 ./deploy still produces an unsigned binary.")
    end
    ipa
  end

  # FONOS_UNSIGNED=1: zip the .app into a Payload/ by hand. ditto --keepParent
  # keeps Payload/ at the archive root and preserves the symlinks inside
  # embedded frameworks, which plain zip can mangle.
  def package_unsigned(archive, work)
    app = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app}") unless Dir.exist?(app)

    step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app, payload)
    ipa = File.join(work, "#{APP_NAME}.ipa")
    run("ditto -c -k --sequesterRsrc --keepParent #{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}", chdir: work)
    ipa
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
ruby scripts/deploy/ipa_builder_test.rb
ruby -r ./scripts/deploy/ipa_builder -e 'p [IpaBuilder.bundle_id, IpaBuilder.team_id]; IpaBuilder.check_signing_config!; puts "signing config ok"'
```
Expected: `3 runs ... 0 failures`, then `["me.chiq.fonos", "Q3WS4MWCW3"]` and `signing config ok`.

- [ ] **Step 5: Exercise the codesign probe**

```bash
ruby -r ./scripts/deploy/ipa_builder -e 'IpaBuilder.ensure_codesign_can_sign!; puts "codesign ok"'
```
Expected: `codesign ok`. If it says the keychain is locked and `security unlock-keychain` fails with no TTY, **stop and ask the user** to unlock it, by running this in their own terminal (or with the `!` prefix in Claude Code):
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```
Then re-run. Never handle the password yourself.

- [ ] **Step 6: Commit**

```bash
git add scripts/deploy/ipa_builder.rb scripts/deploy/ipa_builder_test.rb
git commit -m "$(printf 'build(deploy): xcconfig signing identity, codesign probe, unsigned fallback\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 7: Rewire `./deploy`

**Files:**
- Modify (rewrite): `deploy` (keep it executable: `ls -l deploy` shows `x`)

- [ ] **Step 1: Replace the whole file with**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# deploy
#
# One-shot over-the-air release of this Fonos fork (github.com/grillermo/fonos-ios):
# no App Store, TestFlight or cable. Adapted from ~/c/vvterm/deploy.
#
#   1. preflight: on main with a clean tree, the tag is unreleased, the publish
#      dir exists, Config/Local.xcconfig names a signer, codesign can sign
#   2. bump MARKETING_VERSION / CURRENT_PROJECT_VERSION of the app and its
#      extensions in FonosApp.xcodeproj/project.pbxproj  (scripts/deploy/versioning.rb)
#   3. build an ad-hoc-signed .ipa + its OTA manifest     (scripts/deploy/ipa_builder.rb)
#   4. publish .ipa, icon, manifest and install page into file_server's files/
#   5. commit the bump as "Release Fonos OTA <tag>", tag fonos-ota-vX.Y.Z, push to `github`
#
# The install page URL never changes, so a Home Screen bookmark always installs
# the newest release; the app's Install Latest quick action does the same.
#
#   ./deploy                    # bump patch (1.0.9 -> 1.0.10)
#   ./deploy patch|minor|major
#   ./deploy 1.2.0              # explicit version
#   ./deploy --yes              # skip the confirmation prompt
#   ./deploy --devlog           # diagnostics build: DevLog -> scripts/devlog/server.py
#   ./deploy --summary "Faster dictation" --note "Return starts recording" --note "..."
#
# --summary is the headline, --note (repeatable, or one per line) a bullet. With
# neither, the notes are the commit subjects since the last fonos-ota-v* tag,
# minus noise (merges, release commits, Bump, wip), at most 8.
#
# Configuration (README.md, "Over-the-air releases"):
#   .env                   FONOS_UPLOAD_BASE=https://files.chiq.me (required)
#                          FONOS_PUBLISH_DIR (default ../../file_server/files)
#   Config/Local.xcconfig  FONOS_BUNDLE_ID, DEVELOPMENT_TEAM (gitignored)
#   FONOS_UNSIGNED=1       unsigned .ipa into build/; nothing published, committed or tagged
#   FONOS_DEVLOG_PORT      DevLog port (default 19487; also read by scripts/devlog/server.py)
#   FONOS_DEVLOG_URL       overrides the whole --devlog server URL
#   FONOS_TEAM_ID          overrides DEVELOPMENT_TEAM for one run
#
# file_server runs on this machine, so publishing is a copy into its files/
# directory: request bodies over ~12 MB stall in the Cloudflare tunnel (524s).

# .env first: everything below reads its variables. Exported ones still win.
require_relative "scripts/deploy/dotenv_file"
DotEnvFile.load(File.join(__dir__, ".env"))

require_relative "scripts/deploy/cli_options"
require_relative "scripts/deploy/install_page"
require_relative "scripts/deploy/ipa_builder"
require_relative "scripts/deploy/release_notes"
require_relative "scripts/deploy/uploader"
require_relative "scripts/deploy/versioning"
require "fileutils"
require "shellwords"
require "tmpdir"

B = IpaBuilder
REPO_ROOT   = B::REPO_ROOT
PBXPROJ     = B::PBXPROJ
PBXPROJ_REL = "FonosApp.xcodeproj/project.pbxproj"
# `github` is grillermo/fonos-ios. `origin` is upstream and is never pushed to.
REMOTE      = "github"
BRANCH      = "main"
TAG_PREFIX  = "fonos-ota-v"
# Each app has its own DevLog port so the servers run side by side (vvterm: 19480).
DEVLOG_PORT = ENV.fetch("FONOS_DEVLOG_PORT", "19487")

PINNED_MANIFEST = "fonos-manifest.plist"
PINNED_INSTALL  = "fonos-install.html"
PINNED_ICON     = "fonos-icon.png"
ICON_SOURCE     = File.join(REPO_ROOT, "scripts/deploy/icon.png") # upstream's 1024 px app icon

def git(args) = `git -C #{REPO_ROOT.shellescape} #{args}`

# --- flags -----------------------------------------------------------------------

ASSUME_YES = !ARGV.delete("--yes").nil?
DEVLOG     = !ARGV.delete("--devlog").nil?
begin
  SUMMARY = CliOptions.take(ARGV, "--summary", "-s").last
  NOTES   = ReleaseNotes.clean(CliOptions.take(ARGV, "--note", "--notes", "-n"))
rescue ArgumentError => e
  B.die(e.message)
end
unknown = ARGV.find { |a| a.start_with?("-") }
B.die("unknown option #{unknown} (see the header of ./deploy)") if unknown
B.die("expected at most one version argument, got: #{ARGV.join(' ')}") if ARGV.length > 1

# --- preflight: nothing here touches the working tree ------------------------------

branch = git("rev-parse --abbrev-ref HEAD").strip
B.die("on branch '#{branch}', not '#{BRANCH}'; releases are cut from #{BRANCH}") unless branch == BRANCH

dirty = git("status --porcelain")
B.die("working tree is dirty -- commit or stash before releasing:\n#{dirty}") unless dirty.strip.empty?

begin
  current = Versioning.read(File.read(PBXPROJ), bundle_id: Versioning::APP_ID)
  version = Versioning.bump(current[:marketing], ARGV[0])
rescue ArgumentError => e
  B.die(e.message)
end
build = current[:build] + 1
tag   = "#{TAG_PREFIX}#{version}"
asset = "#{B::APP_NAME}-#{version}.ipa"

# The .ipa name carries the version, so re-releasing one would overwrite a
# published binary; the tag is what makes a version releasable only once.
B.die("tag #{tag} already exists -- bump to a new version") if git("tag -l #{tag.shellescape}").strip == tag

BASE = Uploader.base_url # dies when FONOS_UPLOAD_BASE is not set
Uploader.check_publish_dir!
B.check_signing_config!
B.ensure_codesign_can_sign! # find a locked keychain now, not after minutes of compiling

MANIFEST_URL = "#{BASE}/files/#{PINNED_MANIFEST}"
INSTALL_URL  = "#{BASE}/files/#{PINNED_INSTALL}"
ICON_URL     = "#{BASE}/files/#{PINNED_ICON}"
ITMS_URL     = "itms-services://?action=download-manifest&url=#{MANIFEST_URL}"
DOWNLOAD_URL = "#{BASE}/files/#{asset}"

# --- release notes + confirmation --------------------------------------------------

def subjects_since_last_release
  last = git("describe --tags --abbrev=0 --match '#{TAG_PREFIX}*' 2>/dev/null").strip
  range = last.empty? ? "-n 20 HEAD" : "#{last}..HEAD"
  git("log --no-merges --pretty=%s #{range}").lines
end

bullets     = NOTES.empty? ? ReleaseNotes.from_subjects(subjects_since_last_release) : NOTES
DESCRIPTION = ReleaseNotes.compose(version: version, summary: SUMMARY, bullets: bullets)

puts B.bold("\n==> Releasing #{B::APP_NAME} (OTA) #{current[:marketing]} -> #{version} (build #{build})" \
            "#{B.unsigned? ? ' [UNSIGNED, not published]' : ''}#{DEVLOG ? ' [devlog]' : ''}")
puts DESCRIPTION.lines.map { |l| "      #{l}" }.join
puts "\n    Install page: #{INSTALL_URL}"

unless ASSUME_YES
  print "\n    Continue? [y/N] "
  B.die("aborted") unless $stdin.gets.to_s.strip.downcase.start_with?("y")
end

# --- bump; from here on every exit restores the tree ------------------------------
#
# A leftover bump is invisible in this run but fails the next run's clean-tree
# check with an error that points nowhere near this one. B.die calls exit, so
# at_exit covers every way out: failed build, failed publish, exception, Ctrl-C.
# It also removes the build's temp dir, which holds a multi-GB archive.

original  = File.read(PBXPROJ)
committed = false
work      = Dir.mktmpdir("#{B::APP_NAME}-ipa-")
at_exit do
  File.write(PBXPROJ, original) unless committed
  FileUtils.remove_entry(work) if Dir.exist?(work)
end

File.write(PBXPROJ, Versioning.write(original, bundle_id: Versioning::APP_ID, version: version, build: build))

# --- build -------------------------------------------------------------------------

devlog_url = nil
if DEVLOG
  devlog_url = ENV["FONOS_DEVLOG_URL"].to_s
  devlog_url = "http://#{`scutil --get LocalHostName`.strip}.local:#{DEVLOG_PORT}/api/devlog" if devlog_url.empty?
  puts "    DevLog: #{devlog_url} -- start scripts/devlog/server.py before installing"
end

ipa = B.build(work: work, manifest: { app_url: DOWNLOAD_URL, icon_url: ICON_URL },
              ota_manifest_url: MANIFEST_URL, devlog_url: devlog_url)
puts B.green("    #{File.basename(ipa)} — #{(File.size(ipa) / 1_048_576.0).round(1)} MB")

if B.unsigned?
  out = File.join(REPO_ROOT, "build", "#{B::APP_NAME}-#{version}-unsigned.ipa")
  FileUtils.mkdir_p(File.dirname(out))
  FileUtils.cp(ipa, out)
  puts B.green("\n✓ Unsigned build: #{out}")
  puts "    Nothing was published, committed or tagged (Safari cannot install an unsigned .ipa);"
  puts "    the version bump is reverted on exit."
  exit 0
end

built_manifest = File.join(work, "manifest.plist")
B.die("export produced no manifest.plist -- cannot publish the OTA route") unless File.exist?(built_manifest)

# Anything the build rewrote besides the bump would ride along unreleased.
leftovers = git("status --porcelain").lines.map(&:strip).reject { |l| l.end_with?(PBXPROJ_REL) }
B.die("the build left changes behind -- commit them and re-run:\n#{leftovers.join("\n")}") unless leftovers.empty?

# --- publish: each file references the one before it --------------------------------

B.step "Publishing the .ipa"
puts "    #{Uploader.upload(ipa, name: asset)}"
B.step "Publishing the icon"
puts "    #{Uploader.upload(ICON_SOURCE, name: PINNED_ICON)}"
B.step "Publishing the OTA manifest"
puts "    #{Uploader.upload(built_manifest, name: PINNED_MANIFEST)}"

B.step "Publishing the install page"
page = File.join(work, PINNED_INSTALL)
File.write(page, InstallPage.render(version: version, build: build, icon_url: ICON_URL, itms_url: ITMS_URL,
                                    notes: DESCRIPTION, bundle_id: B.bundle_id))
puts "    #{Uploader.upload(page, name: PINNED_INSTALL)}"

# --- commit, tag, push ---------------------------------------------------------------

B.step "Committing + pushing"
B.run("git add #{PBXPROJ_REL.shellescape}", chdir: REPO_ROOT)
B.run("git commit -m #{"Release Fonos OTA #{tag}\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>".shellescape}",
      chdir: REPO_ROOT)
committed = true # the bump lives in a commit now; at_exit must not undo it
B.run("git tag #{tag.shellescape}", chdir: REPO_ROOT)

# git-sync may push the same commit first and make our push fail even though the
# remote has exactly what we wanted; that counts as success.
cmd = "git push #{REMOTE} #{BRANCH} --tags"
puts "    $ #{cmd}"
unless system(cmd, chdir: REPO_ROOT)
  local  = git("rev-parse HEAD").strip
  remote = git("ls-remote #{REMOTE} refs/heads/#{BRANCH}").split.first.to_s
  unless !local.empty? && local == remote
    B.die("command failed: #{cmd} (remote is at #{remote.empty? ? 'nothing' : remote[0, 7]}, we are at #{local[0, 7]})")
  end
  puts B.green("    remote already at #{local[0, 7]} -- pushed already; continuing")
end

puts B.green("\n✓ Published #{B::APP_NAME} OTA #{version}")
puts B.bold("\n    Install from Safari on the device:\n    #{INSTALL_URL}")
puts "    Manifest: #{MANIFEST_URL}"
```

- [ ] **Step 2: Syntax check and run all Ruby tests**

```bash
ruby -c deploy && for t in scripts/deploy/*_test.rb; do ruby "$t" || break; done 2>&1 | grep -E "runs|Error|Failure"
```
Expected: `Syntax OK` and every suite shows `0 failures, 0 errors`.

- [ ] **Step 3: Quick non-publishing smoke test (dirty tree refusal)**

`deploy` is modified but not yet committed, so it must refuse to run:
```bash
./deploy --yes; echo "exit=$?"
```
Expected: `error: working tree is dirty ...` and `exit=1`. Nothing else happens.

- [ ] **Step 4: Commit**

```bash
git add deploy
git commit -m "$(printf 'build(deploy): full OTA spec -- .env, codesign preflight, unsigned, --devlog, push fallback\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 8: `AppQuickAction`, a pure URL-mapping type (TDD)

**Files:**
- Create: `FonosApp/Fork/AppQuickAction.swift`, `FonosAppTests/AppQuickActionTests.swift`
- Modify: `FonosApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test** `FonosAppTests/AppQuickActionTests.swift`

```swift
// Fork-only (OTA). Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/AppQuickActionTests

import Foundation
import Testing
@testable import FonosApp

struct AppQuickActionTests {
    private let deployedInfo: [String: Any] = [
        AppQuickAction.otaManifestURLInfoKey: "https://files.example.com/files/fonos-manifest.plist"
    ]

    @Test
    func installLatestStartsTheOTAInstallFromThePinnedManifest() {
        // ./deploy republishes the manifest under this fixed name on every
        // release, so the link always installs the newest build.
        #expect(
            AppQuickAction.installLatest.url(infoDictionary: deployedInfo)
                == URL(string: "itms-services://?action=download-manifest&url=https://files.example.com/files/fonos-manifest.plist")
        )
    }

    @Test
    func deployedBuildOffersInstallLatest() {
        #expect(AppQuickAction.available(infoDictionary: deployedInfo) == [.installLatest])
    }

    @Test
    func buildWithoutAManifestOffersNoQuickActions() {
        let localBuild: [String: Any] = [AppQuickAction.otaManifestURLInfoKey: ""]
        #expect(AppQuickAction.available(infoDictionary: localBuild).isEmpty)
        #expect(AppQuickAction.available(infoDictionary: nil).isEmpty)
        #expect(AppQuickAction.installLatest.url(infoDictionary: localBuild) == nil)
        // An unexpanded build setting is not a manifest URL.
        let unexpanded: [String: Any] = [AppQuickAction.otaManifestURLInfoKey: "$(FONOS_OTA_MANIFEST_URL)"]
        #expect(AppQuickAction.available(infoDictionary: unexpanded).isEmpty)
    }

    @Test
    func shortcutTypesRoundTripAndUnknownOnesAreIgnored() {
        #expect(AppQuickAction(shortcutType: AppQuickAction.installLatest.rawValue) == .installLatest)
        #expect(AppQuickAction(shortcutType: "com.example.unknown") == nil)
    }
}
```

- [ ] **Step 2: Register the test file in `project.pbxproj`**

(a) After `/* Begin PBXBuildFile section */` insert:
```text
		F0A005000000000000000002 /* AppQuickActionTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A005000000000000000001 /* AppQuickActionTests.swift */; };
```
(b) After `/* Begin PBXFileReference section */` insert:
```text
		F0A005000000000000000001 /* AppQuickActionTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppQuickActionTests.swift; sourceTree = "<group>"; };
```
(c) In the `3E090E64BBAA4232B8A4810E /* FonosAppTests */` group, after the line `				KBIPC002AA002AA002AA01A /* KeyboardIPCTests.swift */,` insert:
```text
				F0A005000000000000000001 /* AppQuickActionTests.swift */,
```
(d) In the tests Sources phase `598E6D93E1274503BE563840 /* Sources */`, after `				KBIPC002AA002AA002AA01B /* KeyboardIPCTests.swift in Sources */,` insert:
```text
				F0A005000000000000000002 /* AppQuickActionTests.swift in Sources */,
```

- [ ] **Step 3: Run it to verify it fails**

```bash
plutil -lint FonosApp.xcodeproj/project.pbxproj && xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/AppQuickActionTests 2>&1 | grep -E "error:|TEST" | head
```
Expected: `error: cannot find 'AppQuickAction' in scope` and `** TEST FAILED **`.

- [ ] **Step 4: Implement** `FonosApp/Fork/AppQuickAction.swift`

```swift
import Foundation

/// Fork-only (OTA releases): Home Screen quick actions, registered at launch
/// from `available(infoDictionary:)`. Each raw value is the item's
/// `UIApplicationShortcutItem.type`. Pure, so it is unit-tested without UIKit.
enum AppQuickAction: String, Equatable, Sendable {
    case installLatest = "fonos.install-latest"

    /// Info.plist key that ./deploy fills with its fixed OTA manifest URL.
    static let otaManifestURLInfoKey = "FonosOTAManifestURL"

    init?(shortcutType: String) {
        self.init(rawValue: shortcutType)
    }

    /// Builds made outside ./deploy carry no manifest URL, so they offer no
    /// Install Latest action: there is no release for them to install.
    static func available(infoDictionary: [String: Any]?) -> [AppQuickAction] {
        otaManifestURL(infoDictionary: infoDictionary) == nil ? [] : [.installLatest]
    }

    func url(infoDictionary: [String: Any]?) -> URL? {
        switch self {
        case .installLatest:
            // Same link as the install page's button: iOS offers to install
            // straight away.
            Self.otaManifestURL(infoDictionary: infoDictionary).flatMap {
                URL(string: "itms-services://?action=download-manifest&url=\($0.absoluteString)")
            }
        }
    }

    private static func otaManifestURL(infoDictionary: [String: Any]?) -> URL? {
        guard let value = infoDictionary?[otaManifestURLInfoKey] as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
```

- [ ] **Step 5: Register the app file (new `Fork` group) in `project.pbxproj`**

(a) After `/* Begin PBXBuildFile section */` insert:
```text
		F0A001000000000000000002 /* AppQuickAction.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A001000000000000000001 /* AppQuickAction.swift */; };
```
(b) After `/* Begin PBXFileReference section */` insert:
```text
		F0A001000000000000000001 /* AppQuickAction.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppQuickAction.swift; sourceTree = "<group>"; };
```
(c) After `/* Begin PBXGroup section */` insert:
```text
		F0A0F0000000000000000001 /* Fork */ = {
			isa = PBXGroup;
			children = (
				F0A001000000000000000001 /* AppQuickAction.swift */,
			);
			path = Fork;
			sourceTree = "<group>";
		};
```
(d) In the `771A58FA8CA147459534EE1C /* FonosApp */` group, after `				WP04VON002AA002AA002001A /* DeepLinkRouter.swift */,` insert:
```text
				F0A0F0000000000000000001 /* Fork */,
```
(e) In the app Sources phase `FE1967CA54134ADA979C91A6 /* Sources */`, after `				663C34A9CC884E40AD59B701 /* FonosApp.swift in Sources */,` insert:
```text
				F0A001000000000000000002 /* AppQuickAction.swift in Sources */,
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
plutil -lint FonosApp.xcodeproj/project.pbxproj && xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/AppQuickActionTests 2>&1 | grep -E "error:|✔|✘|TEST" | tail
```
Expected: 4 passing tests, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add FonosApp/Fork/AppQuickAction.swift FonosAppTests/AppQuickActionTests.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "$(printf 'feat(ota): Install Latest URL mapping (AppQuickAction)\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 9: Wire up the Install Latest quick action

The app uses the SwiftUI `App` lifecycle (`FonosApp/FonosApp.swift`, `WindowGroup`, no AppDelegate, no `UIApplicationSceneManifest`). As in vvterm, add a `UIApplicationDelegate` via `@UIApplicationDelegateAdaptor`. It sets `shortcutItems` at launch and returns a scene configuration whose `delegateClass` is a small `UIWindowSceneDelegate`, which receives the shortcut on a cold launch (`connectionOptions.shortcutItem`) and while running (`windowScene(_:performActionFor:)`). SwiftUI still owns the window.

**Files:**
- Create: `FonosApp/Fork/FonosAppDelegate.swift`, `FonosApp/Fork/AppQuickActionSceneDelegate.swift`
- Modify: `FonosApp/FonosApp.swift` (1 line), `FonosApp/Resources/Info.plist`, `FonosApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create** `FonosApp/Fork/AppQuickActionSceneDelegate.swift`

```swift
import UIKit

/// Fork-only (OTA releases): receives Home Screen quick actions for SwiftUI's
/// window scene. SwiftUI still owns the window; this only handles the item.
final class AppQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A cold launch delivers the item before the scene is active, and opening a
    /// URL then is unreliable, so it waits for the first activation.
    private var pendingAction: AppQuickAction?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        pendingAction = connectionOptions.shortcutItem.flatMap { AppQuickAction(shortcutType: $0.type) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let action = pendingAction else { return }
        pendingAction = nil
        perform(action)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = AppQuickAction(shortcutType: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        perform(action)
        completionHandler(true)
    }

    private func perform(_ action: AppQuickAction) {
        DevLog.event("quickaction.perform", ["type": action.rawValue])
        guard let url = action.url(infoDictionary: Bundle.main.infoDictionary) else { return }
        Task { @MainActor in
            let opened = await UIApplication.shared.open(url)
            guard opened, action == .installLatest else { return }
            // iOS replaces the bundle under a running process, which crashes it,
            // and only starts the install once you leave the app. Exiting after
            // the install prompt is up lets the install begin on its own.
            try? await Task.sleep(for: .milliseconds(1500))
            exit(0)
        }
    }
}
```

Note: this references `DevLog`, which Task 11 creates. To keep this task compiling on its own, **temporarily omit the `DevLog.event(...)` line here** and add it back in Task 11, Step 6. Do the same for the `DevLog.event("app.launch")` line in the next file.

- [ ] **Step 2: Create** `FonosApp/Fork/FonosAppDelegate.swift`

```swift
import UIKit

/// Fork-only (OTA releases): registers the Install Latest Home Screen quick
/// action and installs the scene delegate that handles it. Attached to the
/// SwiftUI app with @UIApplicationDelegateAdaptor in FonosApp.swift.
final class FonosAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DevLog.event("app.launch")
        application.shortcutItems = AppQuickAction.available(infoDictionary: Bundle.main.infoDictionary)
            .map(shortcutItem(for:))
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = AppQuickActionSceneDelegate.self
        }
        return configuration
    }

    private func shortcutItem(for action: AppQuickAction) -> UIApplicationShortcutItem {
        switch action {
        case .installLatest:
            UIApplicationShortcutItem(
                type: action.rawValue,
                localizedTitle: "Install Latest",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app")
            )
        }
    }
}
```
(Omit the `DevLog.event("app.launch")` line until Task 11, as noted above.)

- [ ] **Step 3: Attach it to the app** in `FonosApp/FonosApp.swift`

Replace
```swift
struct FonosApp: App {

    private static let appGroupID = KeyboardIPC.appGroupID
```
with
```swift
struct FonosApp: App {

    // Fork-only (OTA): Install Latest quick action. See FonosApp/Fork/.
    @UIApplicationDelegateAdaptor(FonosAppDelegate.self) private var appDelegate

    private static let appGroupID = KeyboardIPC.appGroupID
```

- [ ] **Step 4: Add the Info.plist keys** in `FonosApp/Resources/Info.plist`

Replace
```xml
    <key>FonosSupportURL</key>
    <string>$(FONOS_SUPPORT_URL)</string>
```
with
```xml
    <key>FonosSupportURL</key>
    <string>$(FONOS_SUPPORT_URL)</string>
    <!-- Fork (OTA): set by ./deploy; empty builds register no Install Latest quick action (AppQuickAction) -->
    <key>FonosOTAManifestURL</key>
    <string>$(FONOS_OTA_MANIFEST_URL)</string>
    <!-- Fork (OTA): set by ./deploy --devlog; empty builds send no DevLog records -->
    <key>FonosDevLogURL</key>
    <string>$(FONOS_DEVLOG_URL)</string>
```

- [ ] **Step 5: Register both files in `project.pbxproj`**

(a) After `/* Begin PBXBuildFile section */` insert:
```text
		F0A002000000000000000002 /* FonosAppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A002000000000000000001 /* FonosAppDelegate.swift */; };
		F0A003000000000000000002 /* AppQuickActionSceneDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A003000000000000000001 /* AppQuickActionSceneDelegate.swift */; };
```
(b) After `/* Begin PBXFileReference section */` insert:
```text
		F0A002000000000000000001 /* FonosAppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FonosAppDelegate.swift; sourceTree = "<group>"; };
		F0A003000000000000000001 /* AppQuickActionSceneDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppQuickActionSceneDelegate.swift; sourceTree = "<group>"; };
```
(c) In the `F0A0F0000000000000000001 /* Fork */` group, after `				F0A001000000000000000001 /* AppQuickAction.swift */,` insert:
```text
				F0A002000000000000000001 /* FonosAppDelegate.swift */,
				F0A003000000000000000001 /* AppQuickActionSceneDelegate.swift */,
```
(d) In `FE1967CA54134ADA979C91A6 /* Sources */`, after `				F0A001000000000000000002 /* AppQuickAction.swift in Sources */,` insert:
```text
				F0A002000000000000000002 /* FonosAppDelegate.swift in Sources */,
				F0A003000000000000000002 /* AppQuickActionSceneDelegate.swift in Sources */,
```

- [ ] **Step 6: Build with a manifest URL and check the baked Info.plist**

```bash
plutil -lint FonosApp.xcodeproj/project.pbxproj FonosApp/Resources/Info.plist
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build/DerivedData FONOS_OTA_MANIFEST_URL=https://files.chiq.me/files/fonos-manifest.plist 2>&1 | grep -E "error:|warning: .*Fork|BUILD" | tail
plutil -extract FonosOTAManifestURL raw build/DerivedData/Build/Products/Debug-iphonesimulator/FonosApp.app/Info.plist
```
Expected: lints OK, `** BUILD SUCCEEDED **` with no errors in Fork files, then `https://files.chiq.me/files/fonos-manifest.plist`.
If Swift 6 rejects the `completionHandler` signature of `windowScene(_:performActionFor:completionHandler:)` (Sendable/MainActor mismatch), apply the compiler's fix-it signature (e.g. `@escaping @MainActor @Sendable (Bool) -> Void`). Don't change the logic.

- [ ] **Step 7: Verify that SwiftUI still owns the scene and that deep links still work (simulator)**

The upstream app relies on `.onOpenURL` for `fonos://` links, and a custom scene `delegateClass` must not break that.
```bash
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/FonosApp.app
xcrun simctl launch booted me.chiq.fonos
xcrun simctl openurl booted 'fonos://record'
xcrun simctl io booted screenshot build/deeplink-check.png
```
Open `build/deeplink-check.png` with the Read tool. Expected: the Fonos UI is shown, not a blank window, and the record deep link took effect (dictation/recording UI or a microphone-permission prompt). If the window is blank or the deep link is ignored, **stop and report**: the fix would be to also forward `scene(_:openURLContexts:)`, and that needs a decision.

- [ ] **Step 8: Run the quick-action unit tests and the keyboard IPC tests**

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/AppQuickActionTests -only-testing:FonosAppTests/KeyboardIPCTests 2>&1 | grep -E "error:|TEST" | tail -3
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add FonosApp/Fork FonosApp/FonosApp.swift FonosApp/Resources/Info.plist FonosApp.xcodeproj/project.pbxproj
git commit -m "$(printf 'feat(ota): Install Latest Home Screen quick action\n\nRegistered only when ./deploy baked FonosOTAManifestURL into Info.plist.\nOpens the itms-services link, then exits after 1.5 s so iOS can replace\nthe bundle. Handled on cold launch and from windowScene(_:performActionFor:).\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 10: DevLog server (`scripts/devlog/server.py`)

**Files:**
- Create: `scripts/devlog/server.py` (executable)

- [ ] **Step 1: Create the server**

```python
#!/usr/bin/env python3
"""Receives the DevLog records a `./deploy --devlog` build of Fonos sends.

A phone cannot write to this machine's filesystem, so the instrumented app POSTs
batches of JSON records to /api/devlog and this server appends them, one per
line, to log/devlog.jsonl, echoing each to stdout so a run can be watched live.
Files sent with DevLog.upload (screenshots) go to /api/devlog/screen?name=...
and land in log/screens/. Both are emptied on start, so they hold one run.

    scripts/devlog/server.py              # 0.0.0.0:19487 -> log/devlog.jsonl
    FONOS_DEVLOG_PORT=19500 scripts/devlog/server.py   # ./deploy --devlog reads the same variable

Each app has its own port so the servers run side by side on the macmini
(vvterm: 19480, fonos-ios: 19487).
    curl http://$(scutil --get LocalHostName).local:${FONOS_DEVLOG_PORT:-19487}/api/devlog/health

Stdlib only. It listens on the LAN without auth, so it caps request, record
and file sizes instead of trusting the client.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("FONOS_DEVLOG_PORT", "19487"))
LOG_PATH = Path(os.getenv("FONOS_DEVLOG_FILE", Path(__file__).resolve().parents[2] / "log" / "devlog.jsonl"))
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RECORDS_PER_REQUEST = 2000
# At the cap the file becomes devlog.jsonl.1, so at most two generations exist.
MAX_LOG_BYTES = 32 * 1024 * 1024
SCREENS_DIR = LOG_PATH.parent / "screens"
MAX_SCREEN_BYTES = 8 * 1024 * 1024
MAX_SCREENS_BYTES = 512 * 1024 * 1024
SCREEN_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")

write_lock = Lock()


def append(records):
    lines = []
    for record in records:
        try:
            lines.append(json.dumps(record, ensure_ascii=True, separators=(",", ":")))
        except (TypeError, ValueError):
            continue
    if not lines:
        return 0
    with write_lock:
        if LOG_PATH.exists() and LOG_PATH.stat().st_size >= MAX_LOG_BYTES:
            os.replace(LOG_PATH, LOG_PATH.with_suffix(LOG_PATH.suffix + ".1"))
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line, flush=True)
    return len(lines)


def screens_size():
    return sum(p.stat().st_size for p in SCREENS_DIR.iterdir() if p.is_file())


def save_screen(name, data):
    if not SCREEN_NAME.match(name) or name.startswith("."):
        return False
    with write_lock:
        if screens_size() + len(data) > MAX_SCREENS_BYTES:
            return False
        (SCREENS_DIR / name).write_bytes(data)
    return True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/devlog/health":
            self._reply(200, b"ok\n")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path == "/api/devlog/screen":
            return self._screen(parse_qs(url.query).get("name", [""])[0])
        if url.path != "/api/devlog":
            return self._reply(404, b"not found\n")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            return self._reply(413, b"bad size\n")
        try:
            payload = json.loads(self.rfile.read(length))
            records = payload["records"]
            if not isinstance(records, list) or len(records) > MAX_RECORDS_PER_REQUEST:
                raise ValueError("records")
        except (ValueError, KeyError, TypeError):
            return self._reply(400, b"bad payload\n")
        append([r for r in records if isinstance(r, dict)])
        self._reply(204, b"")

    def _screen(self, name):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_SCREEN_BYTES:
            return self._reply(413, b"bad size\n")
        data = self.rfile.read(length)
        if not save_screen(name, data):
            return self._reply(400, b"bad name or screens full\n")
        print(json.dumps({"kind": "screen.file", "name": name, "bytes": length}), flush=True)
        self._reply(204, b"")

    def _reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *args):
        # Records already go to stdout; per-request access lines would bury them.
        pass


def main():
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_PATH.write_text("")
    LOG_PATH.with_suffix(LOG_PATH.suffix + ".1").unlink(missing_ok=True)
    SCREENS_DIR.mkdir(parents=True, exist_ok=True)
    for old in SCREENS_DIR.iterdir():
        if old.is_file():
            old.unlink()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"devlog: listening on :{PORT}, writing {LOG_PATH}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
```

```bash
chmod +x scripts/devlog/server.py
```

- [ ] **Step 2: Smoke test on a spare port (no LAN traffic needed)**

Start it in the background (Bash `run_in_background: true`):
```bash
cd ~/c/third-parties/fonos-ios && mkdir -p build/devlog-test && FONOS_DEVLOG_PORT=19587 FONOS_DEVLOG_FILE="$PWD/build/devlog-test/devlog.jsonl" python3 scripts/devlog/server.py
```
Then:
```bash
cd ~/c/third-parties/fonos-ios
curl -s http://127.0.0.1:19587/api/devlog/health
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' --data '{"records":[{"t":"2026-10-25T00:00:00Z","kind":"smoke","meta":{"a":"b"},"session":"s","build":"1.0.9 (12)"}]}' http://127.0.0.1:19587/api/devlog
cat build/devlog-test/devlog.jsonl
curl -s -o /dev/null -w '%{http_code}\n' --data-binary @scripts/deploy/icon.png 'http://127.0.0.1:19587/api/devlog/screen?name=probe.png'
ls build/devlog-test/screens/
curl -s -o /dev/null -w '%{http_code}\n' --data-binary @scripts/deploy/icon.png 'http://127.0.0.1:19587/api/devlog/screen?name=../evil.png'
head -c 2000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- http://127.0.0.1:19587/api/devlog
```
Expected, in order: `ok`, `204`, the smoke record as one JSON line, `204`, `probe.png`, `400`, `413`. Stop the background server afterwards (TaskStop or `pkill -f 'scripts/devlog/server.py'`).

- [ ] **Step 3: Commit**

```bash
git add scripts/devlog/server.py
git commit -m "$(printf 'feat(devlog): stdlib DevLog receiver on :19487\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 11: `DevLog.swift` (TDD) + live simulator check

**Files:**
- Create: `FonosApp/Fork/DevLog.swift`, `FonosAppTests/DevLogSinkTests.swift`
- Modify: `FonosApp/Fork/FonosAppDelegate.swift`, `FonosApp/Fork/AppQuickActionSceneDelegate.swift` (restore the DevLog lines), `FonosApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test** `FonosAppTests/DevLogSinkTests.swift`

```swift
// Fork-only (DevLog). Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/DevLogSinkTests

import Foundation
import Testing
@testable import FonosApp

struct DevLogSinkTests {
    @Test
    func staysOffWithoutDevLogURL() {
        #expect(DevLogSink(infoDictionary: nil) == nil)
        #expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: ""]) == nil)
        // An unexpanded build setting must not count as a URL.
        #expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "$(FONOS_DEVLOG_URL)"]) == nil)
        #expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "ftp://macmini.local/api/devlog"]) == nil)
    }

    @Test
    func turnsOnWithHTTPDevLogURL() {
        #expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "http://macmini.local:19487/api/devlog"]) != nil)
    }
}
```

Register it in `project.pbxproj`:
(a) After `/* Begin PBXBuildFile section */`:
```text
		F0A006000000000000000002 /* DevLogSinkTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A006000000000000000001 /* DevLogSinkTests.swift */; };
```
(b) After `/* Begin PBXFileReference section */`:
```text
		F0A006000000000000000001 /* DevLogSinkTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevLogSinkTests.swift; sourceTree = "<group>"; };
```
(c) In the `FonosAppTests` group, after `				F0A005000000000000000001 /* AppQuickActionTests.swift */,`:
```text
				F0A006000000000000000001 /* DevLogSinkTests.swift */,
```
(d) In `598E6D93E1274503BE563840 /* Sources */`, after `				F0A005000000000000000002 /* AppQuickActionTests.swift in Sources */,`:
```text
				F0A006000000000000000002 /* DevLogSinkTests.swift in Sources */,
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/DevLogSinkTests 2>&1 | grep -E "error:|TEST" | head -5
```
Expected: `error: cannot find 'DevLogSink' in scope`, `** TEST FAILED **`.

- [ ] **Step 3: Implement** `FonosApp/Fork/DevLog.swift`

```swift
import Foundation

/// Fork-only: ships diagnostic events to the developer's log server
/// (`scripts/devlog/server.py`) so a device build can be debugged without Xcode.
/// Only `./deploy --devlog` bakes the server URL into Info.plist; every other
/// build has none, and `event` then does nothing, not even build its fields.
///
/// Emitting only appends to a bounded buffer under a lock. Sending happens on a
/// utility queue once a second, and failed batches are dropped, so the code
/// being observed never waits on the network.
enum DevLog {
    static let urlInfoKey = "FonosDevLogURL"

    private static let sink = DevLogSink(infoDictionary: Bundle.main.infoDictionary)

    static var isEnabled: Bool { sink != nil }

    static func event(_ kind: String, _ fields: @autoclosure () -> [String: String] = [:]) {
        sink?.append(kind: kind, fields: fields())
    }

    /// Sends a file (e.g. a screenshot), stored by the server under
    /// `log/screens/<name>`. Uploads skip the record buffer, because one image
    /// would crowd out many records, and are dropped when too many are in flight.
    static func upload(_ name: String, _ data: Data) {
        sink?.upload(name: name, data: data)
    }
}

final class DevLogSink: @unchecked Sendable {
    private static let maxBufferedRecords = 2_000
    private static let flushInterval: DispatchTimeInterval = .seconds(1)
    private static let maxUploadsInFlight = 6

    private let endpoint: URL
    private let session = UUID().uuidString
    private let build: String
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private let queue = DispatchQueue(label: "fonos.devlog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var uploadsInFlight = 0

    init?(infoDictionary: [String: Any]?) {
        guard let value = infoDictionary?[DevLog.urlInfoKey] as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        endpoint = url
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let number = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        build = "\(version) (\(number))"
        startTimer()
    }

    func append(kind: String, fields: [String: String]) {
        let record: [String: Any] = [
            "t": ISO8601DateFormatter.devLog.string(from: Date()),
            "kind": kind,
            "meta": fields,
            "session": session,
            "build": build
        ]
        lock.lock()
        if buffer.count < Self.maxBufferedRecords {
            buffer.append(record)
        }
        lock.unlock()
    }

    func upload(name: String, data: Data) {
        guard var components = URLComponents(url: endpoint.appendingPathComponent("screen"), resolvingAgainstBaseURL: false) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return }
        lock.lock()
        guard uploadsInFlight < Self.maxUploadsInFlight else {
            lock.unlock()
            return
        }
        uploadsInFlight += 1
        lock.unlock()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: data) { [weak self] _, _, _ in
            guard let self else { return }
            self.lock.lock()
            self.uploadsInFlight -= 1
            self.lock.unlock()
        }.resume()
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
    }

    private func flush() {
        lock.lock()
        let records = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !records.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["records": records]) else {
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let devLog: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
```

Register it:
(a) After `/* Begin PBXBuildFile section */`:
```text
		F0A004000000000000000002 /* DevLog.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0A004000000000000000001 /* DevLog.swift */; };
```
(b) After `/* Begin PBXFileReference section */`:
```text
		F0A004000000000000000001 /* DevLog.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevLog.swift; sourceTree = "<group>"; };
```
(c) In the `Fork` group, after `				F0A003000000000000000001 /* AppQuickActionSceneDelegate.swift */,`:
```text
				F0A004000000000000000001 /* DevLog.swift */,
```
(d) In `FE1967CA54134ADA979C91A6 /* Sources */`, after `				F0A003000000000000000002 /* AppQuickActionSceneDelegate.swift in Sources */,`:
```text
				F0A004000000000000000002 /* DevLog.swift in Sources */,
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
plutil -lint FonosApp.xcodeproj/project.pbxproj && xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/DevLogSinkTests 2>&1 | grep -E "error:|TEST" | tail -3
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Restore the DevLog call sites omitted in Task 9**

In `FonosApp/Fork/FonosAppDelegate.swift`, make `didFinishLaunchingWithOptions` start with `DevLog.event("app.launch")` (as shown in Task 9, Step 2). In `FonosApp/Fork/AppQuickActionSceneDelegate.swift`, make `perform(_:)` start with `DevLog.event("quickaction.perform", ["type": action.rawValue])` (as shown in Task 9, Step 1).

- [ ] **Step 6: Live check: simulator build → local server**

Start the server in the background (`run_in_background: true`):
```bash
cd ~/c/third-parties/fonos-ios && mkdir -p build/devlog-sim && FONOS_DEVLOG_PORT=19587 FONOS_DEVLOG_FILE="$PWD/build/devlog-sim/devlog.jsonl" python3 scripts/devlog/server.py
```
Build, install, launch:
```bash
cd ~/c/third-parties/fonos-ios
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build/DerivedData FONOS_DEVLOG_URL=http://127.0.0.1:19587/api/devlog 2>&1 | tail -1
plutil -extract FonosDevLogURL raw build/DerivedData/Build/Products/Debug-iphonesimulator/FonosApp.app/Info.plist
xcrun simctl terminate booted me.chiq.fonos 2>/dev/null; xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/FonosApp.app && xcrun simctl launch booted me.chiq.fonos
```
Wait up to ~10 s for the record. If foreground `sleep` is blocked, use the Monitor tool with an until-loop on this grep:
```bash
grep '"kind":"app.launch"' ~/c/third-parties/fonos-ios/build/devlog-sim/devlog.jsonl
```
Expected: `** BUILD SUCCEEDED **`, `http://127.0.0.1:19587/api/devlog`, and one JSON line with `"kind":"app.launch"`, a `session` UUID and `"build":"1.0.9 (12)"`. Stop the server afterwards.

Also confirm a build without the setting has the key empty (DevLog off):
```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build/DerivedData 2>&1 | tail -1
plutil -extract FonosDevLogURL raw build/DerivedData/Build/Products/Debug-iphonesimulator/FonosApp.app/Info.plist; echo "[end]"
```
Expected: an empty line, then `[end]`.

- [ ] **Step 7: Commit**

```bash
git add FonosApp/Fork FonosAppTests/DevLogSinkTests.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "$(printf 'feat(devlog): DevLog for ./deploy --devlog builds\n\nNo-op unless FonosDevLogURL is baked in; batches JSON to\nscripts/devlog/server.py once a second and drops failures.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 12: Documentation + ntfy project memory

**Files:**
- Modify: `README.md` (append a section; upstream content untouched), `scripts/deploy/README.md`
- Create (outside the repo): `~/.claude/projects/-Users-grillermo-c-third-parties-fonos-ios/memory/deploy-ntfy-install-link.md`, `.../memory/MEMORY.md`

- [ ] **Step 1: Append to `README.md`** (after the `## Building` section, before `## License`)

````markdown
## Over-the-air releases (this fork)

This fork ([grillermo/fonos-ios](https://github.com/grillermo/fonos-ios)) installs on registered
devices with no App Store, TestFlight or cable. One command bumps the version, builds an ad hoc
signed `.ipa`, publishes it to a file server, and commits, tags and pushes the release:

```bash
./deploy                       # bump the patch version
./deploy minor                 # or major, or an explicit 1.2.0
./deploy --yes                 # skip the confirmation prompt
./deploy --summary "Headline" --note "One bullet" --note "Another"
./deploy --devlog              # diagnostics build that reports to scripts/devlog/server.py
```

Without `--summary`/`--note`, the release notes are the commit subjects since the last
`fonos-ota-v*` tag, minus merges, release commits, "Bump" and "wip" (at most 8).

The install page has a fixed URL (for example https://files.chiq.me/files/fonos-install.html).
Open it in Safari and add it to the Home Screen once: it always installs the newest release.
Builds made by `./deploy` also offer **Install Latest** when you touch and hold the app icon.

### Setup

1. `Config/Local.xcconfig` (gitignored) overrides the committed defaults in `Config/Fonos.xcconfig`:

   ```text
   FONOS_BUNDLE_ID = me.chiq.fonos
   DEVELOPMENT_TEAM = Q3WS4MWCW3
   ```

   The App Group (`group.me.chiq.fonos`, in both `.entitlements` files and
   `FonosKeyboard/KeyboardIPC.swift`) and the keychain group in `FonosApp.entitlements` are
   still fixed. A different bundle ID needs those changed too.
2. On the developer portal, register the App IDs `<bundle id>`, `<bundle id>.keyboard` (both with
   the App Group) and `<bundle id>.widget`, plus every device that should install. Automatic
   signing creates certificates and profiles, but not App IDs. Ad hoc builds only install on
   devices registered before the build. Add the team's Apple ID in Xcode → Settings → Accounts.
3. `.env` (gitignored) at the repo root:

   ```text
   FONOS_UPLOAD_BASE=https://files.chiq.me
   ```

   Releases are copied into the file server's `files/` directory (default
   `../../file_server/files`, override with `FONOS_PUBLISH_DIR`) instead of uploaded, because
   large uploads stall in the Cloudflare tunnel.

### Environment variables

| Variable | Effect |
|---|---|
| `FONOS_UPLOAD_BASE` | Public base URL of the file server (required; usually in `.env`) |
| `FONOS_PUBLISH_DIR` | Directory the file server serves |
| `FONOS_UNSIGNED=1` | Builds an unsigned `.ipa` into `build/`; publishes, commits and tags nothing |
| `FONOS_TEAM_ID` | Overrides `DEVELOPMENT_TEAM` for one run |
| `FONOS_DEVLOG_PORT` | DevLog port, default 19487 (vvterm uses 19480); read by `./deploy --devlog` and `scripts/devlog/server.py` |
| `FONOS_DEVLOG_URL` | Overrides the whole `--devlog` server URL (default `http://<LocalHostName>.local:19487/api/devlog`) |

Variables exported in the shell win over `.env`.

### DevLog

`./deploy --devlog` bakes a log server URL into the app. Before installing that build, start the
receiver on the Mac and check it:

```bash
scripts/devlog/server.py
```

```bash
curl "http://$(scutil --get LocalHostName).local:${FONOS_DEVLOG_PORT:-19487}/api/devlog/health"
```

Records land in `log/devlog.jsonl` (gitignored), and uploaded files in `log/screens/`.
````

- [ ] **Step 2: Update `scripts/deploy/README.md`**

Replace its first block (from `# OTA release` up to and including the `Install page (stable URL...` line) with:

```markdown
# OTA release

Usage, setup (`.env`, `Config/Local.xcconfig`) and flags are documented in the repo's
`README.md`, section "Over-the-air releases (this fork)", and in the header of `./deploy`.

Install page (stable URL, open in Safari): https://files.chiq.me/files/fonos-install.html

Tests for the release script: `for t in scripts/deploy/*_test.rb; do ruby "$t"; done`
```

Then in the "Fork changes" bullet list, change the first bullet to:
`- Bundle IDs come from FONOS_BUNDLE_ID (Config/Fonos.xcconfig, overridden by the gitignored Config/Local.xcconfig = me.chiq.fonos / team Q3WS4MWCW3).`
Add a bullet: `- FonosApp/Fork/ holds the fork-only app code (Install Latest quick action, DevLog), attached with one @UIApplicationDelegateAdaptor line in FonosApp.swift.`
Delete the line `` `ruby scripts/deploy/versioning_test.rb` tests the pbxproj version bump. `` (superseded). Keep the mema / `fonos://model` section as it is.

- [ ] **Step 3: Write the project memory** `~/.claude/projects/-Users-grillermo-c-third-parties-fonos-ios/memory/deploy-ntfy-install-link.md`

```markdown
---
name: deploy-ntfy-install-link
description: "After every ./deploy of fonos-ios, send an ntfy notification whose tap starts the OTA install"
metadata:
  type: feedback
---

After every `./deploy` (OTA release) of fonos-ios, send an ntfy notification (ntfy skill) with the version in the message, so tapping it starts the install.

**Why:** The iOS OTA pipeline spec (~/c/agents-configs/docs/ios-ota-rollout/pipeline-prompt.md, section 5) asks for this on every deploy.

**How to apply:** Tap target `-u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fonos-manifest.plist'`. The script's `-l` only takes http(s), so add the install page `-l https://files.chiq.me/files/fonos-install.html -L "Install page"` as a button. Example:

    sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "Fonos 1.0.10" -T rocket -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fonos-manifest.plist' -l https://files.chiq.me/files/fonos-install.html -L "Install page" "Fonos 1.0.10 is published. Tap to install."

If the deploy fails, send the failure instead with `-p high -T x` and the error line.
```

And `~/.claude/projects/-Users-grillermo-c-third-parties-fonos-ios/memory/MEMORY.md` (create it, or append the line if it exists):
```markdown
- [Deploy → ntfy install link](deploy-ntfy-install-link.md) — after every ./deploy, ntfy the itms-services install link
```

Check that the script accepts the itms tap target without sending:
```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh --dry-run -t "Fonos test" -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fonos-manifest.plist' -l https://files.chiq.me/files/fonos-install.html -L "Install page" "dry run"
```
Expected: a JSON preview with `"click":"itms-services://..."` and no error.

- [ ] **Step 4: Commit (repo files only)**

```bash
git add README.md scripts/deploy/README.md
git commit -m "$(printf 'docs: document ./deploy, .env, Local.xcconfig and DevLog\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

---

### Task 13: Verify everything that can be verified without publishing

Everything here leaves the tree clean, creates no tag and publishes nothing. After **each** command, check:
```bash
git status --porcelain; git tag -l 'fonos-ota-v1.0.10'; ls ~/c/file_server/files | grep -c 'FonosApp-1.0.10'
```
Expected each time: no status output, no tag, `0`. (Substitute the next version if HEAD's version isn't 1.0.9.)

- [ ] **Step 1: All Ruby tests**

```bash
for t in scripts/deploy/*_test.rb; do ruby "$t" || break; done 2>&1 | grep -E "runs|Failure|Error"
```
Expected: 7 suites, all `0 failures, 0 errors`.

- [ ] **Step 2: Preflight failures** (each must exit 1 with the quoted error, before any build)

```bash
./deploy banana --yes; echo "exit=$?"                      # bad argument 'banana' ...
./deploy --bogus --yes; echo "exit=$?"                     # unknown option --bogus
./deploy --note; echo "exit=$?"                            # --note needs a value
./deploy 1.0.9 --yes; echo "exit=$?"                       # tag fonos-ota-v1.0.9 already exists
FONOS_UPLOAD_BASE= ./deploy --yes; echo "exit=$?"          # set FONOS_UPLOAD_BASE (in .env) ...
FONOS_PUBLISH_DIR=/nonexistent ./deploy --yes; echo "exit=$?"   # file_server files/ directory was not found
touch preflight-probe.tmp && ./deploy --yes; echo "exit=$?"; rm -f preflight-probe.tmp   # working tree is dirty
git switch -c preflight-probe && ./deploy --yes; echo "exit=$?"; git switch main && git branch -D preflight-probe   # not 'main'
mv Config/Local.xcconfig /tmp/fonos-Local.xcconfig; ./deploy --yes; echo "exit=$?"; mv /tmp/fonos-Local.xcconfig Config/Local.xcconfig   # FONOS_BUNDLE_ID is "com.example.fonos" ...
echo n | ./deploy; echo "exit=$?"                          # prints the release plan + notes, then "aborted"
```
Confirm `Config/Local.xcconfig` is back (`test -f Config/Local.xcconfig && echo back`). The `echo n` run must print the version change `1.0.9 -> 1.0.10 (build 13)` and release notes made of feature subjects only (no `Release Fonos OTA` lines). It must leave the pbxproj untouched, since the bump comes after the prompt.

- [ ] **Step 3: Unsigned build (the full compile path, nothing published)**

Run in the background (several minutes):
```bash
cd ~/c/third-parties/fonos-ios && FONOS_UNSIGNED=1 ./deploy --yes --devlog
```
Expected tail: `✓ Unsigned build: .../build/FonosApp-1.0.10-unsigned.ipa`, `exit 0`. Then:
```bash
cd ~/c/third-parties/fonos-ios
git status --porcelain                       # empty: at_exit restored project.pbxproj
ls -d "${TMPDIR:-/tmp}"/FonosApp-ipa-* 2>/dev/null | wc -l   # 0: temp dir removed
unzip -l build/FonosApp-1.0.10-unsigned.ipa | grep -E "Payload/FonosApp.app/Info.plist|PlugIns/FonosKeyboard.appex/" | head -3
rm -rf build/ipa-check && mkdir -p build/ipa-check && unzip -q build/FonosApp-1.0.10-unsigned.ipa -d build/ipa-check
plutil -extract FonosOTAManifestURL raw build/ipa-check/Payload/FonosApp.app/Info.plist
plutil -extract FonosDevLogURL raw build/ipa-check/Payload/FonosApp.app/Info.plist
plutil -extract CFBundleShortVersionString raw build/ipa-check/Payload/FonosApp.app/Info.plist
```
Expected: the Info.plist and keyboard appex entries are listed, then `https://files.chiq.me/files/fonos-manifest.plist`, `http://macmini.local:19487/api/devlog`, and `1.0.10`. The bump was in the build, but the source is restored.

- [ ] **Step 4: Interrupted run restores the tree**

Start `FONOS_UNSIGNED=1 ./deploy --yes` in the background. Once its output shows `Archiving`, stop it (TaskStop, i.e. SIGTERM/SIGINT). Then:
```bash
git -C ~/c/third-parties/fonos-ios status --porcelain; ls -d "${TMPDIR:-/tmp}"/FonosApp-ipa-* 2>/dev/null | wc -l
```
Expected: empty, `0`. If a hard kill (SIGKILL) skipped `at_exit`, restore with `git checkout FonosApp.xcodeproj/project.pbxproj`, delete the temp dir, and note it. Only SIGKILL can bypass `at_exit`.

- [ ] **Step 5: Full unit test suite**

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests 2>&1 | grep -E "✘|TEST SUCCEEDED|TEST FAILED" | tail -20
```
Expected: the same result as the Task 0 baseline, plus the new `AppQuickActionTests` and `DevLogSinkTests` passing. No new failures.

- [ ] **Step 6: Codesign preflight**

```bash
ruby -r ./scripts/deploy/ipa_builder -e 'IpaBuilder.ensure_codesign_can_sign!; puts "codesign ok"'
```
Expected: `codesign ok` (if not, see Task 6, Step 5: ask the user to unlock the keychain).

- [ ] **Step 7: Review the branch**

```bash
git log --oneline 37a1a83..HEAD && git diff --stat 37a1a83..HEAD
```
Check that no secret or personal file was committed (`git ls-files | grep -E '\.env$|Local\.xcconfig'` prints nothing) and that `git status` is clean. Nothing is pushed yet. The real deploy pushes everything along with the release commit.

---

### Task 14: Ask the user before the one real `./deploy`

**Do not run this without an explicit "yes" from the user in this conversation.**

- [ ] **Step 1: Ask**

Tell the user what has been verified (Task 13), that the next version will be `1.0.10` (build 13), and what a real deploy does. It publishes `FonosApp-1.0.10.ipa`, the icon, `fonos-manifest.plist` and `fonos-install.html` into `~/c/file_server/files`, commits `Release Fonos OTA fonos-ota-v1.0.10`, tags it, and pushes `main` + tags to `github` (grillermo/fonos-ios, never upstream). That push also publishes all the commits from this plan. Show the auto-generated release notes (from the `echo n | ./deploy` run) and ask whether to use them or a `--summary`/`--note` they give. Suggested alternative: `--summary "Install Latest quick action" --note "Touch and hold the Fonos icon → Install Latest installs the newest release"`.

- [ ] **Step 2: After approval, deploy** (Bash `run_in_background: true`, it takes several minutes)

```bash
cd ~/c/third-parties/fonos-ios && ./deploy --yes --summary "<approved summary>" --note "<approved note>"
```
(Or plain `./deploy --yes` if they approved the automatic notes.)

- [ ] **Step 3: Verify the release**

```bash
cd ~/c/third-parties/fonos-ios
git status --porcelain; git log --oneline -1; git tag -l fonos-ota-v1.0.10
git ls-remote github refs/heads/main refs/tags/fonos-ota-v1.0.10
curl -s -o /dev/null -w '%{http_code}\n' https://files.chiq.me/files/fonos-install.html
curl -s https://files.chiq.me/files/fonos-manifest.plist | grep -A1 '<key>url</key>' | head -2
curl -s https://files.chiq.me/files/fonos-install.html | grep -o 'Version [^<]*'
```
Expected: a clean tree, HEAD `Release Fonos OTA fonos-ota-v1.0.10`, the tag exists locally and on `github`, `200`, the manifest's url ends in `FonosApp-1.0.10.ipa`, and `Version 1.0.10 (build 13)`.

- [ ] **Step 4: Notify (per the project memory)**

On success:
```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "Fonos 1.0.10" -T rocket -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fonos-manifest.plist' -l https://files.chiq.me/files/fonos-install.html -L "Install page" "Fonos 1.0.10 is published. Tap to install."
```
On failure: the same script with `-p high -T x`, the error line as the message, and no `-u`.

- [ ] **Step 5: Report to the user**

Give the install URL (https://files.chiq.me/files/fonos-install.html) and what each step printed: version change, archive/export, the four published URLs, the commit/tag/push. Then ask them to check on the device: install from the notification or page, then touch and hold the Fonos icon → **Install Latest** should appear. Tapping it should show the install prompt, and the app should close itself about 1.5 s later.
