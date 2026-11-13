# frozen_string_literal: true

# Builds an ad-hoc-signed Fonos .ipa (app + keyboard + widget) from
# FonosApp.xcodeproj, together with the OTA manifest.plist an `itms-services://`
# link points at. Signed with the paid team Q3WS4MWCW3, so it installs from
# Safari with no cable, but only on devices registered on the portal, and only
# once these exist there (automatic signing creates profiles, not App IDs):
#   me.chiq.fonos            (App Groups: group.me.chiq.fonos;
#                             iCloud Documents: iCloud.me.chiq.fonos)
#   me.chiq.fonos.keyboard   (App Groups: group.me.chiq.fonos)
#   me.chiq.fonos.widget
#
# FONOS_UNSIGNED=1 builds an unsigned Payload/ zip instead. It cannot be
# installed from Safari, and ../../deploy stops before publishing it; it exists
# so broken signing does not block producing a binary.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  APP_NAME  = "FonosApp"
  SCHEME    = "FonosApp"
  REPO_ROOT = File.expand_path(File.join(__dir__, "..", ".."))
  PROJECT   = "FonosApp.xcodeproj"
  PBXPROJ   = File.join(REPO_ROOT, PROJECT, "project.pbxproj")
  BUNDLE_ID = "me.chiq.fonos"
  TEAM_ID   = "Q3WS4MWCW3"

  # Unlocks the keychain with the login password stored on this Mac, so an agent
  # can deploy over SSH without anyone typing it. Shared by every app.
  UNLOCK_SCRIPT = File.expand_path("~/c/agents-configs/bin/unlock-codesign-keychain.sh")

  module_function

  # Plain `def ... end` throughout (no endless methods): over a non-interactive
  # SSH session the macmini's `ruby` is the system Ruby 2.6.
  def bold(str)
    "\e[1m#{str}\e[0m"
  end

  def green(str)
    "\e[32m#{str}\e[0m"
  end

  def red(str)
    "\e[31m#{str}\e[0m"
  end

  def step(msg)
    puts "\n#{bold("==> #{msg}")}"
  end

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}")
  end

  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  def unsigned?
    ENV["FONOS_UNSIGNED"] == "1"
  end

  # Over SSH (or after the Mac sleeps) the login keychain is locked, and
  # codesign cannot use the signing key: the archive then dies at its first
  # CodeSign step with errSecInternalComponent, after minutes of compiling.
  # Probe by signing a throwaway binary. If that fails, unlock with
  # UNLOCK_SCRIPT, and only without it (or when it fails) fall back to
  # `security unlock-keychain`, which prompts for the login password.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{Shellwords.escape(probe)} >/dev/null 2>&1"
    return if system(sign)
    return if File.executable?(UNLOCK_SCRIPT) && system(UNLOCK_SCRIPT)

    puts red("    codesign cannot use your signing key -- the login keychain is locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{Shellwords.escape(keychain)}") or
      die("could not unlock the login keychain")
    system(sign) or
      die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /some/file")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def xml_escape(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # `release-testing` is Xcode 15.3+'s name for ad-hoc. The `manifest` dict makes
  # xcodebuild emit manifest.plist so it can never drift from the binary; appURL
  # must be the .ipa's final public URL, known before the build.
  def export_options_plist(path, manifest:)
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>method</key><string>release-testing</string>
        <key>teamID</key><string>#{TEAM_ID}</string>
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

  # Returns the .ipa path. The caller owns (and removes) File.dirname(ipa), where
  # manifest.plist is also written.
  #
  # `ota_manifest_url:` goes in as a command-line build setting, which Info.plist
  # expands for the Install Latest quick action. An xcconfig file cannot carry
  # it: it reads the `//` in a URL as the start of a comment.
  def build(manifest:, ota_manifest_url:)
    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")

    signing = unsigned? ? "CODE_SIGNING_ALLOWED=NO" : "DEVELOPMENT_TEAM=#{TEAM_ID}"

    step "Archiving (xcodebuild)#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild -project #{PROJECT} -scheme #{SCHEME} -configuration Release " \
      "-destination 'generic/platform=iOS' -archivePath #{Shellwords.escape(archive)} " \
      "#{signing} FONOS_OTA_MANIFEST_URL=#{Shellwords.escape(ota_manifest_url)} " \
      "-allowProvisioningUpdates archive",
      chdir: REPO_ROOT
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)

    return package_unsigned(archive, work) if unsigned?

    step "Exporting signed .ipa (ad hoc)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), manifest: manifest)
    run(
      "xcodebuild -exportArchive -archivePath #{Shellwords.escape(archive)} " \
      "-exportPath #{Shellwords.escape(work)} -exportOptionsPlist #{Shellwords.escape(options)} " \
      "-allowProvisioningUpdates",
      chdir: REPO_ROOT
    )

    ipa = File.join(work, "#{APP_NAME}.ipa")
    die("export produced no .ipa in #{work} (see the xcodebuild output above). If it says " \
        "\"no profiles found\", register the App IDs on the developer portal (see the header of " \
        "scripts/deploy/ipa_builder.rb) and make sure this device's UDID is registered. For other " \
        "signing failures, check that the Apple ID for team #{TEAM_ID} is in " \
        "Xcode -> Settings -> Accounts.") unless File.exist?(ipa)
    ipa
  end

  # The pre-signing packaging path, kept for FONOS_UNSIGNED=1: zip the .app into
  # a Payload/ by hand so a resigning tool can sign it.
  def package_unsigned(archive, work)
    app_path = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

    step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app_path, payload)

    ipa = File.join(work, "#{APP_NAME}.ipa")
    # ditto --keepParent keeps the Payload/ dir at the archive root and preserves
    # the symlinks inside embedded frameworks (plain zip can mangle them).
    run(
      "ditto -c -k --sequesterRsrc --keepParent " \
      "#{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}",
      chdir: work
    )
    ipa
  end
end
