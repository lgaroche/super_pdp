# frozen_string_literal: true

module SuperPdp
  # Top-level entry point.
  #
  # Machine-to-machine (client_credentials) — act on your own company:
  #   SuperPdp.configure do |c|
  #     c.client_id     = ENV["SUPER_PDP_CLIENT_ID"]
  #     c.client_secret = ENV["SUPER_PDP_CLIENT_SECRET"]
  #   end
  #   client = SuperPdp::Client.new
  #
  # On behalf of a client (authorization_code) — using a stored, refreshable TokenSet:
  #   client = SuperPdp::Client.from_tokens(
  #     access_token:  cred.access_token,
  #     refresh_token: cred.refresh_token,
  #     expires_at:    cred.expires_at,
  #     on_refresh:    ->(set) { cred.update!(set.to_h) } # persist rotated tokens
  #   )
  #
  # Per-instance overrides take precedence over the global config:
  #   SuperPdp::Client.new(client_id: "...", client_secret: "...", environment: :production)
  class Client
    attr_reader :configuration

    def initialize(client_id: nil, client_secret: nil, environment: nil,
                   base_url: nil, token_url: nil, impersonate_company: nil,
                   timeout: nil, open_timeout: nil, logger: nil, debug: nil,
                   configuration: nil, token_provider: nil)
      @configuration =
        configuration || Configuration.build_from(
          SuperPdp.configuration,
          client_id: client_id, client_secret: client_secret, environment: environment,
          base_url: base_url, token_url: token_url, impersonate_company: impersonate_company,
          timeout: timeout, open_timeout: open_timeout, logger: logger, debug: debug
        )
      @token_provider = token_provider || OAuth.new(@configuration)
      @connection = Connection.new(configuration: @configuration, oauth: @token_provider)
    end

    # Build a client acting on behalf of a company via a stored authorization_code TokenSet.
    # Tokens are refreshed transparently; `on_refresh` receives each new (rotated) TokenSet.
    def self.from_tokens(access_token:, refresh_token: nil, expires_at: nil, scope: nil,
                         on_refresh: nil, **config_overrides)
      config = Configuration.build_from(SuperPdp.configuration, **config_overrides)
      token_set = TokenSet.new(access_token: access_token, refresh_token: refresh_token,
                               expires_at: expires_at, scope: scope)
      provider = RefreshableToken.new(token_set: token_set, configuration: config, on_refresh: on_refresh)
      new(configuration: config, token_provider: provider)
    end

    # Return a new client that impersonates the given company id (accountant model).
    # Sends X-Impersonate-Company on every request.
    def impersonating(company_id)
      dup_config = Configuration.build_from(@configuration, impersonate_company: company_id)
      self.class.new(configuration: dup_config, token_provider: @token_provider)
    end

    # The active token source (OAuth client_credentials or RefreshableToken).
    attr_reader :token_provider

    # Resources
    def sessions       = (@sessions ||= Resources::Sessions.new(@connection))
    def companies      = (@companies ||= Resources::Companies.new(@connection))
    def invoices       = (@invoices ||= Resources::Invoices.new(@connection))
    def invoice_events = (@invoice_events ||= Resources::InvoiceEvents.new(@connection))
    def directory      = (@directory ||= Resources::Directory.new(@connection))
    def ereporting     = (@ereporting ||= Resources::Ereporting.new(@connection))
  end
end
