# frozen_string_literal: true

module SuperPdp
  module Models
    # The OAuth2 session bound to the current access token.
    #
    # IMPORTANT: when `company_verification_status` is anything other than "verified",
    # the API returns 403 on most routes. `#ready?` is a quick precondition check.
    class Session < Base
      def client_id
        self["client_id"]
      end

      def company_verification_status
        self["company_verification_status"]
      end

      def user_identity_verification_status
        self["user_identity_verification_status"]
      end

      def company_verified?
        company_verification_status.to_s == "verified"
      end

      # True when the session can call business routes without hitting a 403.
      def ready?
        company_verified?
      end
    end
  end
end
