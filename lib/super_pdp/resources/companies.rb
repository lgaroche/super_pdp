# frozen_string_literal: true

module SuperPdp
  module Resources
    # Company endpoints.
    #
    # v0.1 covers the self-service surface usable with client_credentials:
    #   - GET   /v1.beta/companies/me
    #   - PATCH /v1.beta/companies   (update VAT regime — drives the e-reporting schedule)
    #
    # Enrolling third-party companies (POST /v1.beta/companies, accountant model with
    # X-Impersonate-Company) is intentionally deferred to a later version.
    class Companies < Base
      # The company associated with the current access token.
      def me
        build(connection.get("companies/me"), Models::Company)
      end

      # Update the company VAT regime. The e-reporting declaration schedule to the PPF
      # depends on this value.
      #
      #   client.companies.update_vat_regime("franchise_en_base")
      def update_vat_regime(vat_regime)
        build(connection.patch_json("companies", { vat_regime: vat_regime }), Models::Company)
      end
    end
  end
end
