# frozen_string_literal: true

module SuperPdp
  # A token source backed by a TokenSet (authorization_code flow), with transparent
  # refresh. Drop-in for OAuth (client_credentials): responds to #access_token and
  # #invalidate!, so Connection treats both uniformly.
  #
  # On refresh, the (possibly rotated) TokenSet is handed to the `on_refresh` callback
  # so the caller can persist it. Refreshes are serialized via a mutex; do NOT share a
  # single instance across processes refreshing the same rotating token concurrently.
  class RefreshableToken
    def initialize(token_set:, configuration: SuperPdp.configuration, on_refresh: nil,
                   client_id: nil, client_secret: nil)
      @token_set     = token_set
      @configuration = configuration
      @on_refresh    = on_refresh
      @client_id     = client_id
      @client_secret = client_secret
      @force         = false
      @mutex         = Mutex.new
    end

    attr_reader :token_set

    def access_token
      @mutex.synchronize do
        refresh! if @force || @token_set.access_token.nil? || @token_set.expired?
        @token_set.access_token
      end
    end

    # Force a refresh on the next access (called by Connection after a 401).
    def invalidate!
      @mutex.synchronize { @force = true }
    end

    private

    def refresh!
      unless @token_set.refreshable?
        raise AuthenticationError, "access token expired and no refresh_token available; re-consent required"
      end

      client_id     = @client_id     || @configuration.client_id
      client_secret = @client_secret || @configuration.client_secret
      if client_id.to_s.empty? || client_secret.to_s.empty?
        raise ConfigurationError, "client_id and client_secret are required to refresh the access token"
      end

      new_set = OAuth::AuthorizationCode.refresh(
        refresh_token: @token_set.refresh_token,
        client_id: client_id,
        client_secret: client_secret,
        configuration: @configuration
      )
      @token_set = new_set
      @force = false
      @on_refresh&.call(new_set)
      new_set
    end
  end
end
