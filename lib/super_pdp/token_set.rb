# frozen_string_literal: true

require "time"

module SuperPdp
  # An OAuth2 token set obtained via the authorization_code (or refresh_token) flow.
  #
  # Value object: immutable, framework-agnostic. Persistence is the caller's concern
  # (e.g. an encrypted ActiveRecord row). `#to_h` gives a serializable snapshot.
  class TokenSet
    EXPIRY_SKEW = 30 # seconds

    attr_reader :access_token, :refresh_token, :expires_at, :scope, :token_type

    def initialize(access_token:, refresh_token: nil, expires_at: nil, scope: nil, token_type: "bearer")
      @access_token  = access_token
      @refresh_token = refresh_token
      @expires_at    = normalize_time(expires_at)
      @scope         = scope
      @token_type    = token_type
    end

    # Build from a parsed /oauth2/token response body.
    # `fallback_refresh_token` keeps the previous refresh token if the server omits one
    # (some servers only return a rotated refresh token, others return none on refresh).
    def self.from_response(body, fallback_refresh_token: nil)
      access_token = body["access_token"]
      raise AuthenticationError, "Token endpoint did not return an access_token" if access_token.to_s.empty?

      expires_in = body["expires_in"]
      new(
        access_token:  access_token,
        refresh_token: body["refresh_token"] || fallback_refresh_token,
        expires_at:    (expires_in ? Time.now + expires_in.to_i : nil),
        scope:         body["scope"],
        token_type:    body["token_type"] || "bearer"
      )
    end

    def expired?(skew = EXPIRY_SKEW)
      return true if access_token.nil?
      return false if expires_at.nil? # unknown expiry: assume valid, rely on 401 refresh

      Time.now >= (expires_at - skew)
    end

    def refreshable?
      !refresh_token.to_s.empty?
    end

    # Serializable snapshot for persistence. `expires_at` is an epoch integer.
    def to_h
      {
        access_token:  access_token,
        refresh_token: refresh_token,
        expires_at:    expires_at&.to_i,
        scope:         scope,
        token_type:    token_type
      }
    end

    private

    def normalize_time(value)
      case value
      when Integer then Time.at(value)
      when String then Time.parse(value)
      else value # nil, Time, or an already-suitable value: pass through
      end
    end
  end
end
