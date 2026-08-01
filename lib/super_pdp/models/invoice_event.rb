# frozen_string_literal: true

module SuperPdp
  module Models
    # A lifecycle event on an invoice (e.g. submission, acceptance, rejection, payment).
    class InvoiceEvent < Base
      def invoice_id
        self["invoice_id"]
      end

      # PPF/AFNOR status code carried by the event (e.g. "ppf:received", "ppf:approved").
      def status_code
        self["status_code"] || self["code"]
      end

      def created_at
        self["created_at"]
      end
    end
  end
end
