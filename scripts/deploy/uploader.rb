# frozen_string_literal: true

# Publishes release artifacts into the files/ directory that the file_to_s3
# service behind files.chiq.me serves from. That service runs on this machine, so
# a release is a local file write, not an upload (request bodies past ~12 MB stall
# in the Cloudflare tunnel). Every publish is *pinned*: the artifact lands at
# exactly the name given and overwrites what was there, which is what keeps the
# install-page URL stable forever.

require "fileutils"
require_relative "ipa_builder"

module Uploader
  DEFAULT_BASE = "https://files.chiq.me"
  DEFAULT_PUBLISH_DIR = File.expand_path("../../file_server/files", IpaBuilder::REPO_ROOT)

  module_function

  def base_url = ENV.fetch("FONOS_UPLOAD_BASE", DEFAULT_BASE).sub(%r{/+\z}, "")

  def publish_dir = ENV.fetch("FONOS_PUBLISH_DIR", DEFAULT_PUBLISH_DIR)

  def check_publish_dir!
    dir = publish_dir
    return dir if File.directory?(dir)

    IpaBuilder.die(
      "the file_to_s3 files/ directory was not found at #{dir}.\n" \
      "  Set FONOS_PUBLISH_DIR if the service moved."
    )
  end

  def upload(path, name:)
    IpaBuilder.die("file to publish not found: #{path}") unless File.file?(path)
    IpaBuilder.die("unsafe publish name: #{name.inspect}") unless name == File.basename(name)

    target = File.join(check_publish_dir!, name)
    # Stage beside the target and rename so a device mid-download never sees a
    # half-written file.
    staged = "#{target}.publishing-#{Process.pid}"
    begin
      FileUtils.cp(path, staged)
      File.rename(staged, target)
    ensure
      FileUtils.rm_f(staged)
    end

    "#{base_url}/files/#{name}"
  end
end
