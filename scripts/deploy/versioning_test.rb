# frozen_string_literal: true

require "minitest/autorun"
require_relative "versioning"

class VersioningTest < Minitest::Test
  APP = "me.chiq.fonos"

  PBX = <<~PBX.gsub("  ", "\t")
    \t\tA /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCURRENT_PROJECT_VERSION = 7;
    \t\t\t\tMARKETING_VERSION = 2.1.1;
    \t\t\t\t"MARKETING_VERSION[sdk=macosx*]" = 2.1.1;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = me.chiq.fonos;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tB /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCURRENT_PROJECT_VERSION = 7;
    \t\t\t\tMARKETING_VERSION = 2.1.1;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = me.chiq.fonos.keyboard;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tC /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCURRENT_PROJECT_VERSION = 1;
    \t\t\t\tMARKETING_VERSION = 1.0;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = me.chiq.fonosother;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
  PBX

  def test_read
    assert_equal({ marketing: "2.1.1", build: 7 }, Versioning.read(PBX, bundle_id: APP))
  end

  def test_bump_keywords
    assert_equal "2.1.2", Versioning.bump("2.1.1", "patch")
    assert_equal "2.1.2", Versioning.bump("2.1.1", nil)
    assert_equal "2.2.0", Versioning.bump("2.1.1", "minor")
    assert_equal "3.0.0", Versioning.bump("2.1.1", "major")
    assert_equal "3.1", Versioning.bump("2.1.1", "3.1")
    assert_raises(ArgumentError) { Versioning.bump("2.1.1", "banana") }
  end

  def test_write_touches_the_app_and_its_extensions_only
    out = Versioning.write(PBX, bundle_id: APP, version: "2.1.2", build: 8)
    assert_equal({ marketing: "2.1.2", build: 8 }, Versioning.read(out, bundle_id: APP))
    assert_equal({ marketing: "2.1.2", build: 8 }, Versioning.read(out, bundle_id: "#{APP}.keyboard"))
    assert_includes out, %("MARKETING_VERSION[sdk=macosx*]" = 2.1.2;)
    assert_includes out, "MARKETING_VERSION = 1.0;"
    assert_includes out, "CURRENT_PROJECT_VERSION = 1;"
  end

  def test_read_raises_without_the_app_target
    assert_raises(ArgumentError) { Versioning.read(PBX, bundle_id: "nope") }
  end
end
