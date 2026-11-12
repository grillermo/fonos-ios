# frozen_string_literal: true

# uploader.rb
#
# Publishes release artifacts to the file_server service behind
# FONOS_UPLOAD_BASE (files.chiq.me), from whichever Mac runs ../../deploy.
#
# file_server runs on the macmini and serves ~/c/file_server/files there. A
# release gets into that directory by one of three routes, picked once per run:
#
#   local  On the macmini itself: copy straight into the directory.
#   scp    On the home LAN: scp to the macmini, then rename into place over ssh.
#          "On the LAN" is decided by ~/c/agents-configs/lib/server-probe.sh
#          (the same probe the other skill scripts use) answering for the
#          file_server's LAN address, and then by ssh logging in: on another
#          network that address is someone else's device, and ssh's host key
#          check refuses it before anything is sent.
#   api    Anywhere else: POST to FONOS_UPLOAD_BASE/upload?name=<name> with
#          the token the file_server MCP saved on this Mac
#          (~/.config/file_server/token; log in once per machine with the MCP's
#          file_server_login).
#
# The api route goes through the Cloudflare tunnel, where request bodies past
# roughly 12 MB can stall and come back as 524s, and past ~25 MB are refused.
# So it is the last resort: at home the bytes never leave the LAN.
#
# Every publish is *pinned*: the artifact lands at exactly the name given and
# overwrites whatever was there. That is what gives the install page and the OTA
# manifest URLs that never move, so one Home Screen bookmark keeps installing the
# newest release forever. The local and scp routes write `<name>.publishing-<pid>`
# beside the target and rename it over, so a device never downloads half a file.
#
# Overrides (.env): FONOS_PUBLISH_ROUTE=local|scp|api forces a route,
# FONOS_PUBLISH_DIR a local directory (implies local), FONOS_PUBLISH_HOST
# and FONOS_PUBLISH_REMOTE_DIR the scp target, FONOS_UPLOAD_TOKEN the token,
# FONOS_PUBLISH_VERIFY=0 skips the check through the public URL.
#
# Plain Ruby 2.6 (the macmini's system Ruby): no endless defs, no pattern matching.

require "fileutils"
require "json"
require "open3"
require "socket"
require "uri"

require_relative "ipa_builder"

module Uploader
  ENV_PREFIX = "FONOS"
  DEFAULT_BASE_URL = "https://files.chiq.me"
  # The machine file_server runs on, by `hostname -s`, and its files/ dir there.
  SERVER_HOSTNAME = "macmini"
  SERVER_DIR = File.expand_path("~/c/file_server/files")
  # How this Mac reaches it on the LAN (the my-machines rule's table).
  DEFAULT_PUBLISH_HOST = "grillermo@192.168.1.1"
  DEFAULT_REMOTE_DIR = "c/file_server/files" # relative to the remote home
  LAN_URL = "http://192.168.1.1:33333"       # ~/c/file_server/bin/rackup
  SERVER_PROBE = File.expand_path("~/c/agents-configs/lib/server-probe.sh")
  DEFAULT_TOKEN_FILE = File.expand_path("~/.config/file_server/token")
  SERVICE_ID = "chiq-file-server"
  TUNNEL_SOFT_LIMIT = 12 * 1024 * 1024
  TUNNEL_HARD_LIMIT = 25 * 1024 * 1024
  SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"].freeze

  module_function

  def env(name)
    value = ENV["#{ENV_PREFIX}_#{name}"].to_s.strip
    value.empty? ? nil : value
  end

  def die(message)
    if IpaBuilder.respond_to?(:die)
      IpaBuilder.die(message)
    else
      raise message
    end
  end

  def base_url
    (env("UPLOAD_BASE") || DEFAULT_BASE_URL).sub(%r{/+\z}, "")
  end

  def publish_host
    env("PUBLISH_HOST") || DEFAULT_PUBLISH_HOST
  end

  def remote_dir
    env("PUBLISH_REMOTE_DIR") || DEFAULT_REMOTE_DIR
  end

  def publish_dir
    dir = env("PUBLISH_DIR")
    dir ? File.expand_path(dir) : SERVER_DIR
  end

  # :local, :scp or :api. Decided once per run.
  def route
    @route ||= pick_route
  end

  # Forgets the route and token, for tests that change the environment.
  def reset!
    @route = nil
    @token = nil
  end

  def pick_route
    forced = env("PUBLISH_ROUTE")
    if forced
      return forced.to_sym if %w[local scp api].include?(forced)

      die("#{ENV_PREFIX}_PUBLISH_ROUTE must be local, scp or api (got #{forced.inspect})")
    end
    return :local if env("PUBLISH_DIR") || on_server?
    return :scp if on_lan? && remote_dir_ok?

    :api
  end

  def on_server?
    Socket.gethostname.split(".").first.to_s.downcase == SERVER_HOSTNAME
  end

  # server-probe.sh's first_reachable: does anything answer HTTP at the
  # file_server's LAN address within a second? Without the helper, assume not.
  def on_lan?
    return false unless File.file?(SERVER_PROBE)

    _out, status = Open3.capture2("sh", "-c", '. "$1" && first_reachable "$2" >/dev/null', "sh", SERVER_PROBE, LAN_URL)
    status.success?
  end

  def remote_dir_ok?
    system("ssh", *SSH_OPTS, publish_host, "test -d #{remote_dir}", out: File::NULL, err: File::NULL)
  end

  def token
    @token ||= begin
      value = env("UPLOAD_TOKEN")
      value ||= File.read(DEFAULT_TOKEN_FILE).strip if File.file?(DEFAULT_TOKEN_FILE)
      value.to_s.empty? ? nil : value
    end
  end

  # ../../deploy calls this in preflight, so a route that can't work fails
  # before a build rather than after one. Returns where the files will go.
  def check!
    unless base_url.start_with?("https://")
      die("#{ENV_PREFIX}_UPLOAD_BASE must be https:// (got #{base_url}); iOS refuses OTA installs over http")
    end

    case route
    when :local
      die("the file_server files/ directory was not found at #{publish_dir}") unless File.directory?(publish_dir)
      die("the file_server files/ directory is not writable: #{publish_dir}") unless File.writable?(publish_dir)
      "#{publish_dir} (local copy)"
    when :scp
      die("cannot reach #{publish_host}:#{remote_dir} over ssh") unless remote_dir_ok?
      "#{publish_host}:#{remote_dir} (scp over the LAN)"
    when :api
      unless token
        die("off the home LAN, publishing needs the file_server token: log in once with the file_server " \
            "MCP (file_server_login), which saves it to #{DEFAULT_TOKEN_FILE}, or set #{ENV_PREFIX}_UPLOAD_TOKEN")
      end
      die("file_server is not answering at #{base_url}/health") unless service_up?
      "#{base_url} (file_server API, through the tunnel)"
    end
  end
  # Older ./deploy scripts call it by this name.
  def check_publish_dir!
    check!
  end

  # Publishes `path` under exactly `name`, returning its public URL.
  def upload(path, name:)
    die("file to publish not found: #{path}") unless File.file?(path)
    die("unsafe publish name: #{name.inspect}") unless name == File.basename(name) && name =~ /\A[\w.\-]+\z/

    case route
    when :local then copy_into_dir(path, name)
    when :scp then scp_into_dir(path, name)
    when :api then post_file(path, name)
    end
    url = "#{base_url}/files/#{name}"
    verify_public!(url, File.size(path))
    url
  end

  def copy_into_dir(path, name)
    target = File.join(publish_dir, name)
    staged = "#{target}.publishing-#{Process.pid}"
    begin
      FileUtils.cp(path, staged)
      File.chmod(0o644, staged)
      File.rename(staged, target)
    ensure
      FileUtils.rm_f(staged)
    end
  end

  # `name` is checked against [\w.-] above, so it is safe in the remote shell.
  def scp_into_dir(path, name)
    target = "#{remote_dir}/#{name}"
    staged = "#{target}.publishing-#{Process.pid}"
    unless system("scp", "-q", *SSH_OPTS, path, "#{publish_host}:#{staged}")
      system("ssh", *SSH_OPTS, publish_host, "rm -f #{staged}", err: File::NULL)
      die("scp of #{name} to #{publish_host} failed")
    end
    return if system("ssh", *SSH_OPTS, publish_host, "chmod 644 #{staged} && mv -f #{staged} #{target}")

    system("ssh", *SSH_OPTS, publish_host, "rm -f #{staged}", err: File::NULL)
    die("could not move #{name} into place on #{publish_host}")
  end

  def post_file(path, name)
    size = File.size(path)
    mb = (size / 1_048_576.0).round(1)
    if size > TUNNEL_HARD_LIMIT
      die("#{name} is #{mb} MB, over the tunnel's ~25 MB cap; publish from the home network")
    elsif size > TUNNEL_SOFT_LIMIT
      warn "    warning: #{name} is #{mb} MB through the tunnel; bodies over ~12 MB can stall (524)"
    end

    url = "#{base_url}/upload?#{URI.encode_www_form(name: name)}"
    code, body = curl(url, "-X", "POST", "-F", "file=@#{path};filename=#{name}", "--max-time", "600",
                      headers: "Authorization: Bearer #{token}")
    case code
    when "200" then nil
    when "401" then die("file_server rejected the token (401); log in again with the file_server MCP")
    else die("upload of #{name} to #{base_url} failed (#{code}): #{body.to_s[0, 300]}")
    end
  end

  # Fetches the published file's headers through the public URL (the one the
  # phone uses), so a publish that landed somewhere unserved fails here.
  # FONOS_PUBLISH_VERIFY=0 skips it (tests publishing into a temp dir).
  def verify_public!(url, size)
    return if env("PUBLISH_VERIFY") == "0"

    code, head = curl(url, "--head", "-H", "Cache-Control: no-cache", "--max-time", "30")
    length = head[/^content-length:\s*(\d+)/i, 1].to_i
    return if code == "200" && (length.zero? || length == size)

    die("#{url} answers #{code} with #{length} bytes after publishing (expected #{size})")
  end

  def service_up?
    code, body = curl("#{base_url}/health", "--max-time", "10")
    code == "200" && JSON.parse(body)["service"] == SERVICE_ID
  rescue JSON::ParserError
    false
  end

  # HTTP goes through curl, not Net::HTTP: macOS's Local Network privacy can
  # block a non-Apple Ruby (rbenv, Homebrew) with "No route to host", while curl
  # is allowed. `headers:` go in through stdin (-H @-), so the token never shows
  # up in `ps`. Returns [status, body].
  def curl(url, *args, headers: nil)
    cmd = ["curl", "-sS", "-o", "-", "-w", "\n%{http_code}", *args]
    cmd += ["-H", "@-"] if headers
    cmd << url
    out, err, status = Open3.capture3(*cmd, stdin_data: headers.to_s)
    die("curl #{url} failed: #{err.strip}") unless status.success?

    body, _, code = out.rpartition("\n")
    [code, body]
  end
end
