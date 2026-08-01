# frozen_string_literal: true

module SuperPdp
  module Resources
    # Lifecycle events on invoices.
    #   - GET  /v1.beta/invoice_events
    #   - POST /v1.beta/invoice_events  (emit a status, e.g. accept/reject a received invoice)
    class InvoiceEvents < Base
      # GET /v1.beta/invoice_events
      def list(invoice_id: nil, starting_after_id: nil, limit: nil)
        body = connection.get("invoice_events",
                              { invoice_id: invoice_id,
                                starting_after_id: starting_after_id,
                                limit: limit })
        build_collection(body, Models::InvoiceEvent)
      end

      # POST /v1.beta/invoice_events — create an event for an invoice.
      #
      # `payload` is passed through to the API. Typical use is to acknowledge a received
      # invoice with a status code, e.g.:
      #   invoice_events.create(invoice_id: 42, status_code: "ppf:approved")
      def create(invoice_id: nil, status_code: nil, **extra)
        body = { invoice_id: invoice_id, status_code: status_code }.merge(extra).compact
        build(connection.post_json("invoice_events", body), Models::InvoiceEvent)
      end
    end
  end
end
