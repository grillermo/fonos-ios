# frozen_string_literal: true

# Builds an ad-hoc-signed Fonos .ipa (app + keyboard + widget) from
# FonosApp.xcodeproj, together with the OTA manifest.plist an `itms-services://`
# link points at. Signed with the paid team Q3WS4MWCW3, so it installs from
# Safari with no cable, but only on devices registered on the portal, and only
# once these exist there (automatic signing creates profiles, not App IDs):
#   me.chiq.fonos            (App Groups: group.me.chiq.fonos)
#   me.chiq.fonos.keyboard   (App Groups: group.me.chiq.fonos)
#   me.chiq.fonos.widget

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

  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  def xml_escape(str) = str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

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
  def build(manifest:)
    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")

    step "Archiving (xcodebuild)"
    run(
      "xcodebuild -project #{PROJECT} -scheme #{SCHEME} -configuration Release " \
      "-destination 'generic/platform=iOS' -archivePath #{Shellwords.escape(archive)} " \
      "DEVELOPMENT_TEAM=#{TEAM_ID} -allowProvisioningUpdates archive",
      chdir: REPO_ROOT
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)

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
        "scripts/deploy/ipa_builder.rb) and make sure this device's UDID is registered.") unless File.exist?(ipa)
    ipa
  end
end
