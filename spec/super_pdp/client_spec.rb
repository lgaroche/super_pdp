# frozen_string_literal: true

require "tempfile"

RSpec.describe SuperPdp::Client do
  subject(:client) { described_class.new }

  before { stub_token }

  describe "#sessions.me" do
    it "returns the session and exposes verification status" do
      stub_request(:get, "#{API}/oauth2_sessions/me")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(client_id: "c1", company_verification_status: "verified"))

      session = client.sessions.me
      expect(session).to be_a(SuperPdp::Models::Session)
      expect(session).to be_ready
      expect(session.company_verified?).to be(true)
    end
  end

  describe "#invoices.received" do
    it "lists received invoices as a paginated Collection" do
      stub_request(:get, "#{API}/invoices")
        .with(query: hash_including("direction" => "in", "limit" => "2"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(
                     data: [
                       { id: 1, direction: "in", external_id: "A" },
                       { id: 2, direction: "in", external_id: "B" }
                     ],
                     has_more: true
                   ))

      invoices = client.invoices.received(limit: 2)
      expect(invoices).to be_a(SuperPdp::Collection)
      expect(invoices.size).to eq(2)
      expect(invoices.first).to be_incoming
      expect(invoices.has_more?).to be(true)
      expect(invoices.next_cursor).to eq(2)
    end
  end

  describe "#invoices.create" do
    it "POSTs raw XML with the right content type and external_id" do
      stub = stub_request(:post, "#{API}/invoices")
             .with(query: { "external_id" => "INV-1" },
                   headers: { "Content-Type" => "application/xml" },
                   body: "<Invoice/>")
             .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(id: 99, direction: "out", external_id: "INV-1"))

      invoice = client.invoices.create(content: "<Invoice/>", content_type: :xml, external_id: "INV-1")
      expect(stub).to have_been_requested
      expect(invoice.id).to eq(99)
      expect(invoice).to be_outgoing
    end

    it "passes the processing_rule assertion in the query" do
      stub = stub_request(:post, "#{API}/invoices")
             .with(query: { "external_id" => "INV-2", "processing_rule" => "B2C" },
                   body: "<Invoice/>")
             .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(id: 100, direction: "out", processing_rule: "B2C"))

      client.invoices.create(content: "<Invoice/>", content_type: :xml,
                             external_id: "INV-2", processing_rule: "B2C")
      expect(stub).to have_been_requested
    end
  end

  describe "#invoices.generate_test" do
    it "requests a B2C sample when b2c: true" do
      stub = stub_request(:get, "#{API}/invoices/generate_test_invoice")
             .with(query: { "format" => "ubl", "b2c" => "true" })
             .to_return(status: 200, headers: { "Content-Type" => "application/xml" },
                        body: "<Invoice>B2C</Invoice>")

      expect(client.invoices.generate_test(b2c: true)).to eq("<Invoice>B2C</Invoice>")
      expect(stub).to have_been_requested
    end
  end

  describe "#invoices.create multipart upload" do
    it "re-sends the file content (not an empty body) on a 401 retry" do
      file = Tempfile.new(["invoice", ".pdf"])
      file.write("HELLOPDFBYTES")
      file.flush

      bodies = []
      stub_request(:post, "#{API}/invoices")
        .with { |req|
          bodies << req.body.to_s
          true
        }
        .to_return({ status: 401, body: "" },
                   { status: 201, headers: { "Content-Type" => "application/json" },
                     body: JSON.generate(id: 7, direction: "out") })

      invoice = client.invoices.create(file: file.path, content_type: :pdf, multipart: true)

      expect(invoice.id).to eq(7)
      expect(bodies.size).to eq(2)
      expect(bodies).to all(include("HELLOPDFBYTES"))
    ensure
      file&.close!
    end
  end

  describe "#invoices.issue (structured)" do
    def sample_invoice
      inv = SuperPdp::Invoice.new(
        number: "INV-001", issue_date: "2026-06-22", currency_code: "EUR",
        seller: { name: "Burger Queen", postal_address: { country_code: "FR" },
                  electronic_address: { scheme: "0009", value: "552" } },
        buyer:  { name: "Tricatel", postal_address: { country_code: "FR" } }
      )
      inv.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
    end

    it "converts the en_invoice JSON to UBL then sends it via create" do
      convert = stub_request(:post, "#{API}/invoices/convert")
                .with(query: { "from" => "en16931", "to" => "ubl" },
                      headers: { "Content-Type" => "application/json" }) { |req|
        JSON.parse(req.body)["number"] == "INV-001"
      }
                .to_return(status: 200, headers: { "Content-Type" => "application/xml" },
                           body: "<Invoice>UBL</Invoice>")

      create = stub_request(:post, "#{API}/invoices")
               .with(query: { "external_id" => "INV-001" },
                     headers: { "Content-Type" => "application/xml" }, body: "<Invoice>UBL</Invoice>")
               .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate(id: 5, direction: "out", external_id: "INV-001"))

      invoice = client.invoices.issue(sample_invoice, external_id: "INV-001")
      expect(convert).to have_been_requested
      expect(create).to have_been_requested
      expect(invoice.id).to eq(5)
    end

    it "forwards processing_rule to the create call" do
      stub_request(:post, "#{API}/invoices/convert")
        .with(query: { "from" => "en16931", "to" => "ubl" })
        .to_return(status: 200, headers: { "Content-Type" => "application/xml" },
                   body: "<Invoice>UBL</Invoice>")

      create = stub_request(:post, "#{API}/invoices")
               .with(query: { "external_id" => "INV-001", "processing_rule" => "B2C" },
                     body: "<Invoice>UBL</Invoice>")
               .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate(id: 6, direction: "out"))

      client.invoices.issue(sample_invoice, external_id: "INV-001", processing_rule: "B2C")
      expect(create).to have_been_requested
    end

    it "embeds the invoice into a base PDF to produce Factur-X when pdf: is given" do
      pdf = Tempfile.new(["base", ".pdf"])
      pdf.write("%PDF-1.4 base")
      pdf.flush

      convert = stub_request(:post, "#{API}/invoices/convert")
                .with(query: { "to" => "factur-x" }) { |req|
                  req.body.include?("INV-001") && req.body.include?("%PDF-1.4 base")
                }
                .to_return(status: 200, headers: { "Content-Type" => "application/pdf" }, body: "%PDF-FACTURX")

      create = stub_request(:post, "#{API}/invoices")
               .with(headers: { "Content-Type" => "application/pdf" }, body: "%PDF-FACTURX")
               .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate(id: 9, direction: "out"))

      invoice = client.invoices.issue(sample_invoice, pdf: pdf.path)
      expect(convert).to have_been_requested
      expect(create).to have_been_requested
      expect(invoice.id).to eq(9)
    ensure
      pdf&.close!
    end

    it "raises InvalidInvoiceError before any HTTP call when structurally invalid" do
      bad = SuperPdp::Invoice.new(number: nil, issue_date: nil, seller: {}, buyer: {})
      expect { client.invoices.issue(bad) }.to raise_error(SuperPdp::InvalidInvoiceError) do |e|
        expect(e.errors).to include(a_string_matching(/number is required/))
      end
      expect(a_request(:post, "#{API}/invoices/convert")).not_to have_been_made
    end
  end

  describe "#companies.update_vat_regime" do
    it "PATCHes the VAT regime" do
      stub_request(:patch, "#{API}/companies")
        .with(body: JSON.generate(vat_regime: "franchise_en_base"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(id: 1, vat_regime: "franchise_en_base"))

      company = client.companies.update_vat_regime("franchise_en_base")
      expect(company.vat_regime).to eq("franchise_en_base")
    end
  end

  describe "error mapping" do
    it "raises ForbiddenError when the company is not verified (403)" do
      stub_request(:get, "#{API}/invoices")
        .to_return(status: 403, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(message: "company not verified"))

      expect { client.invoices.list }.to raise_error(SuperPdp::ForbiddenError) do |e|
        expect(e.status).to eq(403)
        expect(e.message).to include("company not verified")
      end
    end

    it "retries once after a 401 by refreshing the token" do
      auth = stub_request(:get, "#{API}/oauth2_sessions/me")
             .to_return({ status: 401, body: "" },
                        { status: 200, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate(client_id: "c1", company_verification_status: "verified") })

      expect(client.sessions.me.client_id).to eq("c1")
      expect(auth).to have_been_requested.twice
    end
  end

  describe "#impersonating" do
    it "sends X-Impersonate-Company" do
      stub = stub_request(:get, "#{API}/companies/me")
             .with(headers: { "X-Impersonate-Company" => "42" })
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(id: 42, formal_name: "ACME"))

      client.impersonating(42).companies.me
      expect(stub).to have_been_requested
    end

    it "reuses the original token provider instead of building a fresh one" do
      provider = SuperPdp::Client.from_tokens(access_token: "stored-token").token_provider
      impersonated = SuperPdp::Client.new(token_provider: provider).impersonating(42)
      expect(impersonated.token_provider).to be(provider)
    end
  end
end
