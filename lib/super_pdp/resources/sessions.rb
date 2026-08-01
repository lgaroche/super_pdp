# frozen_string_literal: true

module SuperPdp
  module Resources
    # GET /v1.beta/oauth2_sessions/me
    class Sessions < Base
      # Returns the OAuth2 session bound to the current access token.
      # Use Session#ready? to confirm the company is verified before other calls.
      def me
        build(connection.get("oauth2_sessions/me"), Models::Session)
      end
    end
  end
end
