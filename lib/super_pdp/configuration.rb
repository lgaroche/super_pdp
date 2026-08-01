# frozen_string_literal: true

module SuperPdp
  # Global configuration for the SUPER PDP client.
  #
  #   SuperPdp.configure do |c|
  #     c.client_id     = ENV["SUPER_PDP_CLIENT_ID"]
  #     c.client_secret = ENV["SUPER_PDP_CLIENT_SECRET"]
  #     c.environment   = :sandbox        # :sandbox or :production
  #   end
  class Configuration
    # OAuth2 client_credentials grant
    attr_accessor :client_id, :client_secret

    # API + OAuth endpoints
    attr_accessor :base_url, :token_url

    # :sandbox or :production. Informational; SUPER PDP uses the same host for both,
    # the active environment is determined by the credentials / enrolled company.
    attr_accessor :environment

    # HTTP behaviour
    attr_accessor :timeout, :open_timeout, :user_agent

    # Optional company impersonation (accountant model). Sent as X-Impersonate-Company.
    attr_accessor :impersonate_company

    # Logging
    attr_accessor :logger, :debug

    DEFAULT_BASE_URL  = "https://api.superpdp.tech"
    DEFAULT_TOKEN_URL = "https://api.superpdp.tech/oauth2/token"

    # Attributes copied when cloning a configuration (per-client overrides).
    COPYABLE = %i[
      client_id client_secret environment base_url token_url impersonate_company
      timeout open_timeout user_agent logger debug
    ].freeze

    # Build a new configuration from a base one, applying non-nil overrides.
    def self.build_from(base, **overrides)
      cfg = new
      COPYABLE.each { |attr| cfg.public_send("#{attr}=", base.public_send(attr)) }
      overrides.each { |key, value| cfg.public_send("#{key}=", value) unless value.nil? }
      cfg
    end

    def initialize
      @base_url     = DEFAULT_BASE_URL
      @token_url    = DEFAULT_TOKEN_URL
      @environment  = :sandbox
      @timeout      = 30
      @open_timeout = 10
      @user_agent   = "super_pdp-ruby/#{SuperPdp::VERSION}"
      @debug        = false
    end

    def production?
      environment.to_sym == :production
    end

    # Path prefix for the versioned API (e.g. "/v1.beta").
    def api_prefix
      "/#{SuperPdp::API_VERSION}"
    end

    # OAuth2 authorization endpoint (interactive, for the authorization_code flow).
    def authorize_url
      "#{base_url}/oauth2/authorize"
    end

    def validate!
      raise ConfigurationError, "client_id is required"     if client_id.to_s.empty?
      raise ConfigurationError, "client_secret is required" if client_secret.to_s.empty?

      true
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Reset configuration (mostly useful in tests).
    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
