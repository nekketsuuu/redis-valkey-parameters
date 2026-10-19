#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   ruby collect.rb                          # collect all TARGETS not yet collected
#   ruby collect.rb redis-7.4.11 valkey-9.0.6  # (re)collect the given versions

require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'socket'

TARGETS = {
  'redis' => %w[3.2.12 4.0.14 5.0.14 6.0.20 6.2.24 7.0.15 7.2.16 7.4.11 8.0.6 8.2.10 8.4.7 8.6.7 8.8.3 8.10.2],
  'valkey' => %w[7.2.14 8.0.11 8.1.10 9.0.6 9.1.2],
}

PRODUCTS = {
  'redis' => { image: 'redis', server: 'redis-server', repo: 'redis/redis', confs: %w[redis.conf redis-full.conf] },
  'valkey' => { image: 'valkey/valkey', server: 'valkey-server', repo: 'valkey-io/valkey', confs: %w[valkey.conf redis.conf] },
}

MODULES_DIR = '/usr/local/lib/redis/modules'
JSON_DIR = File.join(__dir__, 'docs', 'json')

module RESP
  module_function

  def call(io, *args)
    io.write("*#{args.size}\r\n" + args.map { "$#{it.bytesize}\r\n#{it}\r\n" }.join)
    read(io)
  end

  def read(io)
    line = io.gets("\r\n") or raise EOFError
    type, body = line[0], line[1..].chomp("\r\n")
    case type
    when '+' then body
    when '-' then raise body
    when ':' then body.to_i
    when '$'
      len = body.to_i
      len.negative? ? nil : io.read(len + 2)[0, len].force_encoding(Encoding::UTF_8)
    when '*'
      len = body.to_i
      len.negative? ? nil : Array.new(len) { read(io) }
    else
      raise "unexpected RESP type: #{line.inspect}"
    end
  end
end

def docker(*args)
  out, err, status = Open3.capture3('docker', *args)
  raise "docker #{args.join(' ')} failed: #{err}" unless status.success?
  out
end

def connect(port)
  60.times do
    sock = TCPSocket.new('127.0.0.1', port)
    return sock if RESP.call(sock, 'PING') == 'PONG'
  rescue SystemCallError, EOFError, RuntimeError
    sock&.close
    sleep 0.5
  end
  raise "server on port #{port} did not become ready"
end

def with_server(product, version, args = [])
  spec = PRODUCTS.fetch(product)
  id = docker('run', '-d', '-p', '127.0.0.1::6379', '--entrypoint', spec[:server], "#{spec[:image]}:#{version}", *args).strip
  port = docker('port', id, '6379/tcp').lines.first.split(':').last.to_i
  sock = connect(port)
  yield sock, id
ensure
  sock&.close
  docker('rm', '-f', id) if id
end

def config_get_all(sock, protected_mode)
  config = RESP.call(sock, 'CONFIG', 'GET', '*').each_slice(2).to_h
  # Official Docker images patch the protected-mode default to "no" at build time; restore the upstream default.
  config['protected-mode'] = protected_mode if config.key?('protected-mode')
  config.sort.to_h
end

def server_version(sock, product)
  RESP.call(sock, 'INFO', 'server')[/^#{product}_version:(\S+)/, 1]
end

def module_list(sock)
  RESP.call(sock, 'MODULE', 'LIST').map { it.each_slice(2).to_h.slice('name', 'ver') }.sort_by { it['name'] }
rescue RuntimeError
  []
end

def fetch_source(repo, version, path)
  res = Net::HTTP.get_response(URI("https://raw.githubusercontent.com/#{repo}/#{version}/#{path}"))
  res.is_a?(Net::HTTPSuccess) ? res.body.force_encoding(Encoding::UTF_8) : nil
end

# Redis 6.0+ and Valkey define the default in config.c; older Redis defines it in server.h.
def upstream_protected_mode(product, version)
  repo = PRODUCTS.fetch(product)[:repo]
  default = fetch_source(repo, version, 'src/config.c')&.[](/createBoolConfig\("protected-mode",(?:[^,]*,){3}\s*([01])\s*,/, 1) ||
            fetch_source(repo, version, 'src/server.h')&.[](/^#define CONFIG_DEFAULT_PROTECTED_MODE ([01])$/, 1)
  raise "protected-mode default of #{product}-#{version} not found" unless default

  default == '1' ? 'yes' : 'no'
end

def github_get(path)
  uri = URI("https://api.github.com/#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Accept'] = 'application/vnd.github+json'
  req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}" if ENV['GITHUB_TOKEN']
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { it.request(req) }
  res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
end

# Old Redis tags have no GitHub release, so fall back to the tagged commit date.
def release_date(product, version)
  repo = PRODUCTS.fetch(product)[:repo]
  time = github_get("repos/#{repo}/releases/tags/#{version}")&.fetch('published_at') ||
         github_get("repos/#{repo}/commits/#{version}")&.dig('commit', 'committer', 'date')
  raise "release date of #{product}-#{version} not found" unless time

  time[0, 10]
end

def doc_links(product, version, names)
  spec = PRODUCTS.fetch(product)
  confs = spec[:confs].filter_map { |file| (body = fetch_source(spec[:repo], version, file)) && [file, body.lines] }
  names.filter_map { |name|
    patterns = [/\A#{Regexp.escape(name)}(\s|\z)/, /\A#\s*#{Regexp.escape(name)}(\s|\z)/]
    found = patterns.lazy.flat_map { |pattern|
      confs.lazy.filter_map { |file, lines|
        index = lines.index { pattern.match?(it) }
        index && "https://github.com/#{spec[:repo]}/blob/#{version}/#{file}#L#{index + 1}"
      }
    }.first
    found && [name, found]
  }.to_h
end

def collect(product, version)
  warn "collecting #{product}-#{version}"
  result = { 'product' => product, 'version' => version, 'released_at' => release_date(product, version) }
  protected_mode = upstream_protected_mode(product, version)

  module_paths = []
  with_server(product, version) do |sock, id|
    reported = server_version(sock, product)
    raise "version mismatch: #{reported}" unless reported == version

    result['base'] = config_get_all(sock, protected_mode)
    result['builtin_modules'] = module_list(sock)
    module_paths = docker('exec', id, 'sh', '-c', "ls #{MODULES_DIR}/*.so 2>/dev/null || true").split
  end

  unless module_paths.empty?
    with_server(product, version, module_paths.flat_map { ['--loadmodule', it] }) do |sock|
      result['modules'] = module_list(sock)
      result['with_modules'] = config_get_all(sock, protected_mode)
    end
  end

  names = (result['base'].keys + result.fetch('with_modules', {}).keys).uniq
  result['docs'] = doc_links(product, version, names)

  dir = File.join(JSON_DIR, "#{product}-#{version}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'config.json'), JSON.pretty_generate(result) + "\n")
end

def write_versions
  entries = Dir.glob(File.join(JSON_DIR, '*', 'config.json')).map { JSON.parse(File.read(it)) }
  entries.sort_by! { [it['released_at'], Gem::Version.new(it['version'])] }.reverse!
  versions = entries.map {
    {
      'id' => "#{it['product']}-#{it['version']}",
      'released_at' => it['released_at'],
      'modules' => it.key?('with_modules'),
    }
  }
  File.write(File.join(JSON_DIR, 'versions.json'), JSON.pretty_generate(versions) + "\n")
end

targets =
  if ARGV.empty?
    TARGETS.flat_map { |product, versions| versions.map { [product, it] } }
           .reject { |product, version| File.exist?(File.join(JSON_DIR, "#{product}-#{version}", 'config.json')) }
  else
    ARGV.map { it.split('-', 2) }
  end

targets.each { |product, version| collect(product, version) }
write_versions
