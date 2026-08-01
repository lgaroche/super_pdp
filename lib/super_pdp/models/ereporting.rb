# frozen_string_literal: true

module SuperPdp
  module Models
    # An e-reporting declaration aggregated and transmitted to the French tax
    # administration (PPF). kind: "transaction" | "payment". role_code: "BY" | "SE".
    class Ereporting < Base
      def kind
        self["kind"]
      end

      def role_code
        self["role_code"]
      end

      def company_id
        self["company_id"]
      end

      def start_period
        self["start_period"]
      end

      def end_period
        self["end_period"]
      end

      def events
        Array(self["events"])
      end

      def transaction?
        kind.to_s == "transaction"
      end

      def payment?
        kind.to_s == "payment"
      end

      # Latest known PPF status code across events, if any.
      def latest_status_code
        events.filter_map { |e| e.is_a?(Hash) ? e["status_code"] : nil }.last
      end
    end

    # A B2C transaction reported for e-reporting.
    # category_code: TLB1 | TPS1 | TNT1 | TMA1. role_code: BY | SE.
    class B2cTransaction < Base
      def category_code
        self["category_code"]
      end

      def role_code
        self["role_code"]
      end

      def date
        self["date"]
      end

      def currency
        self["currency"]
      end

      def tax_total
        self["tax_total"]
      end
    end

    # A B2C payment (encaissement) reported for e-reporting.
    class B2cPayment < Base
      def date
        self["date"]
      end

      def subtotals
        Array(self["subtotals"])
      end
    end
  end
end
