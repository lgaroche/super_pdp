# frozen_string_literal: true

require "securerandom"
require "digest"
require "uri"
require "faraday"
require "json"

module SuperPdp
  class OAuth
    # Stateless helpers for the OAuth 2.1 authorization_code flow (third-party onboarding).
    #
    # Typical app wiring:
    #   pkce = SuperPdp::OAuth::AuthorizationCode.pkce_pair          # store verifier in session
    #   url  = SuperPdp::OAuth::AuthorizationCode.authorize_url(
    #            redirect_uri: cb, code_challenge: pkce.challenge, state: state,
    #            superpdp_company_number: siren, superpdp_company_number_scheme: "fr_siren")
    #   # ... redirect the user, they complete the KYC/KYB tunnel + consent ...
    #   tokens = SuperPdp::OAuth::AuthorizationCode.exchange_code(
    #              code: params[:code], code_verifier: session[:verifier], redirect_uri: cb)
    #   # persist `tokens` (encrypted), then build a client with SuperPdp::Client.from_tokens(...)
    #
    # PKCE is mandatory (OAuth 2.1): a fresh verifier/challenge per authorization request.
    module AuthorizationCode
      PkcePair = Struct.new(:verifier, :challenge)

      # Prefill params accepted by SUPER PDP's authorize endpoint.
      PREFILL_KEYS = %i[login_hint superpdp_company_number superpdp_company_number_scheme].freeze

      module_function

      # Generate a PKCE verifier (43-128 url-safe chars) and its S256 challenge.
      def pkce_pair
        verifier = SecureRandom.urlsafe_base64(64).tr("=", "")
        challenge = base64url(Digest::SHA256.digest(verifier))
        PkcePair.new(verifier, challenge)
      end

      # Build the URL to redirect the user to.
      def authorize_url(redirect_uri:, code_challenge:, state: nil, client_id: nil,
                        configuration: SuperPdp.configuration, **prefill)
        params = {
          response_type: "code",
          client_id: client_id || configuration.client_id,
          redirect_uri: redirect_uri,
          code_challenge: code_challenge,
          code_challenge_method: "S256"
        }
        params[:state] = state if state
        PREFILL_KEYS.each { |k| params[k] = prefill[k] unless prefill[k].nil? }

        "#{configuration.authorize_url}?#{URI.encode_www_form(params)}"
      end

      # Exchange an authorization code for a TokenSet.
      def exchange_code(code:, code_verifier:, redirect_uri:, client_id: nil, client_secret: nil,
                        configuration: SuperPdp.configuration)
        body = token_request(configuration,
                             grant_type: "authorization_code",
                             code: code,
                             redirect_uri: redirect_uri,
                             code_verifier: code_verifier,
                             client_id: client_id || configuration.client_id,
                             client_secret: client_secret || configuration.client_secret)
        TokenSet.from_response(body)
      end

      # Exchange a refresh token for a new TokenSet (handles rotation: the previous
      # refresh token is kept only if the server returns none).
      def refresh(refresh_token:, client_id: nil, client_secret: nil,
                  configuration: SuperPdp.configuration)
        body = token_request(configuration,
                             grant_type: "refresh_token",
                             refresh_token: refresh_token,
                             client_id: client_id || configuration.client_id,
                             client_secret: client_secret || configuration.client_secret)
        TokenSet.from_response(body, fallback_refresh_token: refresh_token)
      end

      # --- internals ---------------------------------------------------------

      def base64url(bytes)
        # base64 is no longer a default gem on Ruby 3.4; pack avoids the dependency.
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      def token_request(configuration, **form)
        conn = Faraday.new(url: configuration.token_url) do |f|
          f.options.timeout = configuration.timeout
          f.options.open_timeout = configuration.open_timeout
          f.headers["User-Agent"] = configuration.user_agent
          f.adapter Faraday.default_adapter
        end

        response = conn.post do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.headers["Accept"] = "application/json"
          req.body = URI.encode_www_form(form)
        end

        body = parse(response.body)
        unless response.success?
          desc = body.is_a?(Hash) ? (body["error_description"] || body["error"]) : nil
          raise AuthenticationError,
                "OAuth #{form[:grant_type]} failed (HTTP #{response.status})#{": #{desc}" if desc}"
        end
        body
      rescue Faraday::Error => e
        raise AuthenticationError, "Failed to reach token endpoint: #{e.message}"
      end

      def parse(raw)
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
