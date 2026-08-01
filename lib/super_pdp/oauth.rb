# frozen_string_literal: true

require "faraday"
require "json"

module SuperPdp
  # OAuth2 token manager for the `client_credentials` grant.
  #
  # Fetches an access token from SUPER PDP's token endpoint and caches it in memory,
  # transparently refetching when it is expired or about to expire. This is the
  # machine-to-machine flow ("access your own data, similar to an API key") and never
  # requires user interaction.
  #
  # NOTE: the authorization_code flow (acting on behalf of a client, with refresh tokens)
  # is intentionally out of scope for v0.1 and will live in a separate strategy.
  class OAuth
    # Refetch a bit before actual expiry to avoid races on near-expired tokens.
    EXPIRY_SKEW = 30 # seconds

    def initialize(configuration = SuperPdp.configuration)
      @configuration = configuration
      @mutex = Mutex.new
      @access_token = nil
      @expires_at = nil
    end

    # Returns a valid bearer token, fetching/refreshing as needed.
    def access_token
      @mutex.synchronize do
        fetch! if token_expired?
        @access_token
      end
    end

    # Force a refresh on the next call.
    def invalidate!
      @mutex.synchronize do
        @access_token = nil
        @expires_at = nil
      end
    end

    def token_expired?
      return true if @access_token.nil? || @expires_at.nil?

      Time.now >= (@expires_at - EXPIRY_SKEW)
    end

    private

    def fetch!
      @configuration.validate!
      response = token_connection.post do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = URI.encode_www_form(
          grant_type: "client_credentials",
          client_id: @configuration.client_id,
          client_secret: @configuration.client_secret
        )
      end

      handle(response)
    rescue Faraday::Error => e
      raise AuthenticationError, "Failed to reach token endpoint: #{e.message}"
    end

    def handle(response)
      body = parse(response.body)

      unless response.success?
        desc = body.is_a?(Hash) ? (body["error_description"] || body["error"]) : nil
        raise AuthenticationError, "Token request failed (HTTP #{response.status})#{": #{desc}" if desc}"
      end

      @access_token = body["access_token"]
      raise AuthenticationError, "Token endpoint did not return an access_token" if @access_token.to_s.empty?

      expires_in = (body["expires_in"] || 3600).to_i
      @expires_at = Time.now + expires_in
      @access_token
    end

    def parse(raw)
      return {} if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def token_connection
      @token_connection ||= Faraday.new(url: @configuration.token_url) do |f|
        f.options.timeout = @configuration.timeout
        f.options.open_timeout = @configuration.open_timeout
        f.headers["User-Agent"] = @configuration.user_agent
        f.response(:logger, @configuration.logger) if @configuration.debug && @configuration.logger
        f.adapter Faraday.default_adapter
      end
    end
  end
end
