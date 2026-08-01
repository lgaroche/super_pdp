# frozen_string_literal: true

require "json"

module SuperPdp
  module Resources
    # Invoice endpoints (issue / receive / fetch / convert / validate).
    class Invoices < Base
      CONTENT_TYPES = {
        pdf: "application/pdf",   # Factur-X
        xml: "application/xml"    # UBL or CII
      }.freeze

      # GET /v1.beta/invoices
      # direction: "in" (received) | "out" (issued). Cursor pagination.
      def list(direction: nil, date: nil, order: nil, starting_after_id: nil,
               ending_before_id: nil, limit: nil, expand: nil)
        params = {
          direction: direction,
          date: date,
          order: order,
          starting_after_id: starting_after_id,
          ending_before_id: ending_before_id,
          limit: limit
        }
        params["expand[]"] = expand if expand
        build_collection(connection.get("invoices", params), Models::Invoice)
      end

      # Convenience: list received invoices (direction: "in").
      def received(**opts)
        list(direction: "in", **opts)
      end

      # Convenience: list issued invoices (direction: "out").
      def issued(**opts)
        list(direction: "out", **opts)
      end

      # GET /v1.beta/invoices/{id}
      def get(id, format: nil, force_superpdp_pdf_renderer: nil)
        body = connection.get("invoices/#{id}",
                              { format: format,
                                force_superpdp_pdf_renderer: force_superpdp_pdf_renderer })
        body.is_a?(Hash) ? build(body, Models::Invoice) : body
      end

      # GET /v1.beta/invoices/{id}/download -> raw invoice bytes (PDF/XML).
      def download(id)
        connection.get("invoices/#{id}/download")
      end

      # GET /v1.beta/invoices/generate_test_invoice -> a sample invoice (raw XML).
      # Handy in sandbox to obtain a valid payload to send back via #create.
      def generate_test(format: "ubl")
        connection.get("invoices/generate_test_invoice", { format: format })
      end

      # POST /v1.beta/invoices — issue (send) an invoice.
      #
      # Provide either a file path or raw content:
      #   invoices.create(file: "invoice.pdf")
      #   invoices.create(content: xml_string, content_type: :xml)
      #
      # external_id: your own reference, echoed back on the invoice.
      # disable_pre_check: skip SUPER PDP's synchronous pre-validation.
      # multipart: send as multipart/form-data instead of a raw body.
      def create(file: nil, content: nil, content_type: nil, external_id: nil,
                 disable_pre_check: nil, multipart: false)
        params = { external_id: external_id, disable_pre_check: disable_pre_check }

        body =
          if multipart && file
            connection.post_file("invoices", file,
                                 content_type: resolve_content_type(content_type, file),
                                 params: params)
          elsif file
            connection.post_raw("invoices", File.binread(file),
                                content_type: resolve_content_type(content_type, file),
                                params: params)
          elsif content
            raise ArgumentError, "content_type is required when sending raw content" unless content_type

            connection.post_raw("invoices", content,
                                content_type: CONTENT_TYPES.fetch(content_type.to_sym, content_type.to_s),
                                params: params)
          else
            raise ArgumentError, "provide either file: or content:"
          end

        build(body, Models::Invoice)
      end
      alias send_invoice create

      # POST /v1.beta/invoices/convert — convert between formats.
      #
      # Input shapes:
      #   convert(invoice: structured, to: :ubl)            # SuperPdp::Invoice or en_invoice Hash (JSON)
      #   convert(file: "invoice.xml", to: :"factur-x")     # multipart file
      #   convert(content: xml_string, content_type: :xml, to: :cii)
      #   convert(invoice: structured, pdf: "base.pdf")     # Factur-X: embed XML into a PDF
      #
      # `from`/`to` are one of :cii, :ubl, :en16931, :"factur-x". For a structured
      # invoice the source is JSON, so `from` defaults to :en16931. When `pdf:` is given
      # the invoice (structured/JSON or CII XML) is combined with that base PDF to render a
      # Factur-X PDF, so `to` defaults to :"factur-x".
      def convert(to: nil, from: nil, invoice: nil, pdf: nil, file: nil, content: nil, content_type: nil)
        if pdf
          connection.post_multipart("invoices/convert",
                                    { "invoice" => invoice_part(invoice, content, content_type),
                                      "pdf" => { path: pdf, mime: CONTENT_TYPES[:pdf] } },
                                    params: { from: from, to: to || "factur-x" })
        elsif invoice
          payload = invoice.respond_to?(:to_en_invoice) ? invoice.to_en_invoice : invoice
          connection.post_json("invoices/convert", payload, params: { from: from || "en16931", to: to })
        elsif file
          connection.post_file("invoices/convert", file,
                               content_type: resolve_content_type(content_type, file), params: { from: from, to: to })
        elsif content
          connection.post_raw("invoices/convert", content,
                              content_type: CONTENT_TYPES.fetch((content_type || :xml).to_sym, content_type.to_s),
                              params: { from: from, to: to })
        else
          raise ArgumentError, "provide invoice:, file: or content:"
        end
      end

      # Issue a structured invoice in one call: pre-validate, convert the EN 16931
      # model, then send it via #create.
      #
      #   client.invoices.issue(invoice, external_id: "INV-001")             # UBL
      #   client.invoices.issue(invoice, pdf: "letterhead.pdf")             # Factur-X
      #
      # `validate:` runs the invoice's cheap structural checks first and raises
      # InvalidInvoiceError before any HTTP call (pass false to skip). By default the
      # invoice is converted to UBL XML; pass `pdf:` to embed it into that base PDF and
      # send a Factur-X document instead. `to:` overrides the conversion target.
      def issue(invoice, external_id: nil, disable_pre_check: nil, pdf: nil, to: nil, validate: true)
        if validate && invoice.respond_to?(:validate) && !(errors = invoice.validate).empty?
          raise InvalidInvoiceError, errors
        end

        if pdf
          rendered = convert(invoice: invoice, pdf: pdf, to: to || "factur-x")
          create(content: rendered, content_type: :pdf, external_id: external_id, disable_pre_check: disable_pre_check)
        else
          xml = convert(invoice: invoice, to: to || :ubl)
          create(content: xml, content_type: :xml, external_id: external_id, disable_pre_check: disable_pre_check)
        end
      end

      # POST /v1.beta/validation_reports — validate an invoice file (multipart).
      def validate(file)
        connection.post_file("validation_reports", file,
                             content_type: resolve_content_type(nil, file))
      end

      private

      # Build the `invoice` multipart part for a Factur-X convert: a structured invoice
      # (or en_invoice Hash) goes as JSON; raw `content` goes as XML.
      def invoice_part(invoice, content, content_type)
        if invoice
          payload = invoice.respond_to?(:to_en_invoice) ? invoice.to_en_invoice : invoice
          { data: JSON.generate(payload), mime: "application/json" }
        elsif content
          { data: content, mime: CONTENT_TYPES.fetch((content_type || :xml).to_sym, content_type.to_s) }
        else
          raise ArgumentError, "Factur-X conversion needs invoice: or content: alongside pdf:"
        end
      end

      def resolve_content_type(content_type, file)
        return CONTENT_TYPES.fetch(content_type.to_sym, content_type.to_s) if content_type

        case File.extname(file.to_s).downcase
        when ".pdf" then CONTENT_TYPES[:pdf]
        when ".xml" then CONTENT_TYPES[:xml]
        else "application/octet-stream"
        end
      end
    end
  end
end
