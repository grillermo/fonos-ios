# frozen_string_literal: true

# The version lives in FonosApp.xcodeproj/project.pbxproj, in the Debug and
# Release buildSettings of every target. read() takes it from the app target
# (the blocks whose PRODUCT_BUNDLE_IDENTIFIER is exactly the app's bundle ID);
# write() bumps the app and every target nested under its bundle ID (keyboard,
# widget, tests), since an extension's version must match its host app's.
module Versioning
  BLOCK     = /buildSettings = \{.*?\n\t\t\t\};/m
  MARKETING = /^(\s*"?MARKETING_VERSION(?:\[sdk=[^\]]+\])?"?\s*=\s*)([\d.]+);/
  BUILD     = /^(\s*CURRENT_PROJECT_VERSION\s*=\s*)(\d+);/

  module_function

  def app_blocks(text, bundle_id)
    marker = "PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};"
    text.scan(BLOCK).select { |b| b.include?(marker) }
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
    nested = /PRODUCT_BUNDLE_IDENTIFIER = #{Regexp.escape(bundle_id)}(\.[\w.-]+)?;/
    text.gsub(BLOCK) do |block|
      next block unless block.match?(nested)

      block.gsub(MARKETING) { "#{$1}#{version};" }.gsub(BUILD) { "#{$1}#{build};" }
    end
  end
end
