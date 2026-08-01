# frozen_string_literal: true

module SuperPdp
  module Models
    # A company enrolled on SUPER PDP.
    # number_scheme: "fr_siren" | "be_numero_entreprise" | "sandbox".
    class Company < Base
      def formal_name
        self["formal_name"]
      end

      def trade_name
        self["trade_name"]
      end

      def number
        self["number"]
      end

      def number_scheme
        self["number_scheme"]
      end

      def vat_regime
        self["vat_regime"]
      end

      def env
        self["env"]
      end

      def sandbox?
        env.to_s == "sandbox"
      end

      def production?
        env.to_s == "production"
      end

      # Billing mandates attached to the company.
      def mandates
        Array(self["mandates"])
      end
    end
  end
end
