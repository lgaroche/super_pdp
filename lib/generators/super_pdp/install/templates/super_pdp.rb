# frozen_string_literal: true

# SUPER PDP client configuration.
# Credentials use the OAuth2 client_credentials grant (machine-to-machine).
SuperPdp.configure do |config|
  config.client_id     = ENV.fetch("SUPER_PDP_CLIENT_ID", nil)
  config.client_secret = ENV.fetch("SUPER_PDP_CLIENT_SECRET", nil)

  # :sandbox (default) or :production
  config.environment = ENV.fetch("SUPER_PDP_ENV", "sandbox").to_sym

  # Optional: HTTP tuning
  # config.timeout      = 30
  # config.open_timeout = 10

  # Optional: log requests (avoid in production; bodies may contain invoice data)
  # config.logger = Rails.logger
  # config.debug  = false
end
