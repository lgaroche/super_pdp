#!/usr/bin/env ruby
# frozen_string_literal: true
#
# THROWAWAY PROBE — not part of the super_pdp gem API. Safe to delete.
# Demonstrates SUPER PDP's OAuth 2.1 authorization_code flow against the sandbox.
#
# TWO MODES:
#   bundle exec ruby bin/try_authcode.rb            # full interactive flow (browser),
#                                                   # then SAVES the token set to .tokens.json
#   bundle exec ruby bin/try_authcode.rb refresh    # NO browser: uses the saved refresh
#                                                   # token to mint a new access token + call the API
#
# The `refresh` mode is the point: it proves that once a client has consented, you can keep
# calling the API without ever re-visiting /oauth2/authorize — as long as you persist the
# (rotating) refresh token.
#
# PREREQUISITE (full flow only): in the dev portal, add this redirect URL to your app's
# "URLs de redirection":  http://localhost:8765/callback
#
# CONFIG (env / .env): SUPER_PDP_OAUTH_CLIENT_ID/SECRET (fallback SUPER_PDP_CLIENT_ID/SECRET).
# Optional prefill: COMPANY_NUMBER, COMPANY_NUMBER_SCHEME, LOGIN_HINT.

require "securerandom"
require "digest"
require "uri"
require "socket"
require "faraday"
require "multi_json"

begin
  require "dotenv"
  Dotenv.load(File.expand_path("../.env", __dir__))
rescue LoadError
end

BASE          = ENV["SUPER_PDP_BASE_URL"] || "https://api.superpdp.tech"
CLIENT_ID     = ENV["SUPER_PDP_OAUTH_CLIENT_ID"]     || ENV["SUPER_PDP_CLIENT_ID"]
CLIENT_SECRET = ENV["SUPER_PDP_OAUTH_CLIENT_SECRET"] || ENV["SUPER_PDP_CLIENT_SECRET"]
PORT          = (ENV["PORT"] || "8765").to_i
REDIRECT      = ENV["REDIRECT_URI"] || "http://localhost:#{PORT}/callback"
TOKENS_FILE   = File.expand_path("../.tokens.json", __dir__)
MODE          = ARGV[0]

abort "Set SUPER_PDP_OAUTH_CLIENT_ID/SECRET (or SUPER_PDP_CLIENT_ID/SECRET)" unless CLIENT_ID && CLIENT_SECRET

conn = Faraday.new(url: BASE)

def b64url(bytes)
  [bytes].pack("m0").tr("+/", "-_").delete("=")
end

def post_token(conn, form)
  resp = conn.post("/oauth2/token") do |r|
    r.headers["Content-Type"] = "application/x-www-form-urlencoded"
    r.body = URI.encode_www_form(form)
  end
  body = (MultiJson.load(resp.body) rescue resp.body)
  [resp.status, body]
end

def save_tokens(file, body)
  File.write(file, MultiJson.dump(
    "access_token"  => body["access_token"],
    "refresh_token" => body["refresh_token"],
    "expires_in"    => body["expires_in"],
    "obtained_at"   => Time.now.to_i
  ))
end

def show_company(conn, access)
  me = conn.get("/v1.beta/companies/me") { |r| r.headers["Authorization"] = "Bearer #{access}" }
  cm = (MultiJson.load(me.body) rescue {})
  puts "   companies/me -> HTTP #{me.status}: id=#{cm["id"]} name=#{cm["formal_name"].inspect} number=#{cm["number"].inspect}"
end

# ---------------------------------------------------------------------------
# REFRESH MODE: no browser, just use the saved refresh token.
# ---------------------------------------------------------------------------
if MODE == "refresh"
  abort "No #{TOKENS_FILE} — run the full flow once first." unless File.exist?(TOKENS_FILE)
  saved = MultiJson.load(File.read(TOKENS_FILE))
  age = Time.now.to_i - saved["obtained_at"].to_i
  puts "Using saved refresh token (obtained #{age}s ago). NO browser, NO consent."

  status, body = post_token(conn, grant_type: "refresh_token",
                                  refresh_token: saved["refresh_token"],
                                  client_id: CLIENT_ID, client_secret: CLIENT_SECRET)
  puts "token endpoint HTTP #{status}"
  unless body.is_a?(Hash) && body["access_token"]
    abort "Refresh failed: #{body.inspect[0, 300]}\n(refresh token may be expired/rotated — re-run the full flow.)"
  end
  rotated = body["refresh_token"] && body["refresh_token"] != saved["refresh_token"]
  puts "  new access_token: yes; refresh rotated: #{rotated ? "yes (saving new one)" : "no"}; expires_in=#{body["expires_in"]}"
  save_tokens(TOKENS_FILE, "access_token" => body["access_token"],
                           "refresh_token" => (body["refresh_token"] || saved["refresh_token"]),
                           "expires_in" => body["expires_in"])
  show_company(conn, body["access_token"])
  puts "\nDone. Re-run `... refresh` as many times as you like — still no browser."
  exit 0
end

# ---------------------------------------------------------------------------
# FULL INTERACTIVE FLOW
# ---------------------------------------------------------------------------
verifier  = SecureRandom.urlsafe_base64(64).tr("=", "")
challenge = b64url(Digest::SHA256.digest(verifier))
state     = SecureRandom.hex(16)

params = {
  response_type: "code", client_id: CLIENT_ID, redirect_uri: REDIRECT,
  code_challenge: challenge, code_challenge_method: "S256", state: state
}
params[:superpdp_company_number]        = ENV["COMPANY_NUMBER"]        if ENV["COMPANY_NUMBER"]
params[:superpdp_company_number_scheme] = ENV["COMPANY_NUMBER_SCHEME"] if ENV["COMPANY_NUMBER_SCHEME"]
params[:login_hint]                     = ENV["LOGIN_HINT"]            if ENV["LOGIN_HINT"]

puts "=" * 78
puts "1) Open this URL, complete the KYC/KYB tunnel + consent:\n\n#{BASE}/oauth2/authorize?#{URI.encode_www_form(params)}\n\n"
puts "Listening on #{REDIRECT} (Ctrl-C to abort) ..."
puts "=" * 78

server = TCPServer.new("127.0.0.1", PORT)
code = nil
got_state = nil
loop do
  sock = server.accept
  line = sock.gets
  if line && line =~ %r{GET\s+(\S+)\s}
    h = URI.decode_www_form(URI(Regexp.last_match(1)).query.to_s).to_h
    code = h["code"]
    got_state = h["state"]
    msg = code ? "Auth code received — return to the terminal." : "No code: #{h.inspect}"
    sock.print "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: #{msg.bytesize}\r\nConnection: close\r\n\r\n#{msg}"
    sock.close
    break
  end
  sock.close
end
server.close

abort "STATE MISMATCH (expected #{state}, got #{got_state.inspect})" unless got_state == state
abort "No authorization code received." unless code

puts "\n2) Exchanging code at /oauth2/token ..."
status, tok = post_token(conn, grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
                               client_id: CLIENT_ID, client_secret: CLIENT_SECRET, code_verifier: verifier)
puts "   HTTP #{status}"
abort "   Unexpected token body: #{tok.inspect[0, 400]}" unless tok.is_a?(Hash) && tok["access_token"]
puts "   keys=#{tok.keys.inspect} expires_in=#{tok["expires_in"]} refresh=#{tok["refresh_token"] ? "present" : "ABSENT"}"

puts "\n3) Bound company:"
show_company(conn, tok["access_token"])

# Persist the FRESH token set (do not call refresh here, so the saved refresh stays valid).
save_tokens(TOKENS_FILE, tok)
puts "\n4) Saved token set -> #{TOKENS_FILE}"
puts "   Now run:  bundle exec ruby bin/try_authcode.rb refresh   (no browser, no consent)"
puts "\nDone."
