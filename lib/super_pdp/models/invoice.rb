# frozen_string_literal: true

module SuperPdp
  module Models
    # An invoice issued or received through SUPER PDP.
    # direction: "in" (received) | "out" (issued).
    class Invoice < Base
      def direction
        self["direction"]
      end

      def incoming?
        direction.to_s == "in"
      end

      def outgoing?
        direction.to_s == "out"
      end

      def external_id
        self["external_id"]
      end

      def company_id
        self["company_id"]
      end

      # Lifecycle events embedded on the invoice (when present).
      def events
        Array(self["events"]).map { |e| e.is_a?(Hash) ? InvoiceEvent.new(e) : e }
      end

      # The structured EN16931 representation, when expanded.
      def en_invoice
        self["en_invoice"]
      end
    end
  end
end
