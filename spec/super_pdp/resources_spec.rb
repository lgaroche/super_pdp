# frozen_string_literal: true

require "tempfile"

# Exercises the resource surfaces the higher-level specs don't: raw/file convert,
# validation reports, the directory resource and e-reporting.
RSpec.describe "SuperPdp resources" do
  subject(:client) { SuperPdp::Client.new }

  before { stub_token }

  describe "#invoices.convert" do
    it "POSTs raw content with the right content type and from/to" do
      stub = stub_request(:post, "#{API}/invoices/convert")
             .with(query: { "from" => "ubl", "to" => "cii" },
                   headers: { "Content-Type" => "application/xml" }, body: "<Invoice/>")
             .to_return(status: 200, headers: { "Content-Type" => "application/xml" }, body: "<CII/>")

      result = client.invoices.convert(content: "<Invoice/>", content_type: :xml, from: :ubl, to: :cii)
      expect(stub).to have_been_requested
      expect(result).to eq("<CII/>")
    end

    it "uploads a file as multipart and returns the converted bytes" do
      file = Tempfile.new(["invoice", ".xml"])
      file.write("<Invoice/>")
      file.flush

      stub = stub_request(:post, "#{API}/invoices/convert")
             .with(query: { "from" => "ubl", "to" => "factur-x" })
             .to_return(status: 200, headers: { "Content-Type" => "application/pdf" }, body: "%PDF-X")

      result = client.invoices.convert(file: file.path, from: :ubl, to: :"factur-x")
      expect(stub).to have_been_requested
      expect(result).to eq("%PDF-X")
    ensure
      file&.close!
    end
  end

  describe "#invoices.validate" do
    it "POSTs the file to validation_reports as multipart" do
      file = Tempfile.new(["invoice", ".xml"])
      file.write("<Invoice/>")
      file.flush

      stub = stub_request(:post, "#{API}/validation_reports")
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(valid: true))

      report = client.invoices.validate(file.path)
      expect(stub).to have_been_requested
      expect(report).to eq("valid" => true)
    ensure
      file&.close!
    end
  end

  describe "#directory" do
    it "searches the French directory and builds a Collection of companies" do
      stub_request(:get, "#{API}/french_directory/companies")
        .with(query: hash_including("formal_name_starts_with" => "Bur", "limit" => "5"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(data: [{ id: 1, formal_name: "Burger Queen" }], has_more: false))

      companies = client.directory.search_companies(formal_name_starts_with: "Bur", limit: 5)
      expect(companies).to be_a(SuperPdp::Collection)
      expect(companies.first).to be_a(SuperPdp::Models::Company)
      expect(companies.first.formal_name).to eq("Burger Queen")
    end

    it "creates a routing entry and deletes it" do
      stub_request(:post, "#{API}/directory_entries")
        .with(body: JSON.generate(directory: "PPF", identifier: "732829320"))
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(id: "de_1", directory: "PPF"))
      del = stub_request(:delete, "#{API}/directory_entries/de_1").to_return(status: 204, body: "")

      entry = client.directory.create(directory: "PPF", identifier: "732829320")
      expect(entry).to be_a(SuperPdp::Models::DirectoryEntry)
      expect(client.directory.delete("de_1")).to be(true)
      expect(del).to have_been_requested
    end
  end

  describe "#ereporting" do
    it "wraps an Array of transactions in a { data: } envelope" do
      stub = stub_request(:post, "#{API}/b2c_transactions")
             .with(body: JSON.generate(data: [{ amount: "10.00" }]))
             .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(data: [{ id: 1 }]))

      client.ereporting.create_transactions([{ amount: "10.00" }])
      expect(stub).to have_been_requested
    end

    it "forwards a Hash body as-is" do
      stub = stub_request(:post, "#{API}/b2c_payments")
             .with(body: JSON.generate(data: [{ amount: "5.00" }], note: "batch"))
             .to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: "{}")

      client.ereporting.create_payments({ data: [{ amount: "5.00" }], note: "batch" })
      expect(stub).to have_been_requested
    end

    it "lists B2C transactions as a Collection of typed models" do
      stub_request(:get, "#{API}/b2c_transactions")
        .with(query: hash_including("limit" => "10"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(data: [{ id: 1, amount: "10.00" }], has_more: false))

      txns = client.ereporting.transactions(limit: 10)
      expect(txns.first).to be_a(SuperPdp::Models::B2cTransaction)
    end
  end
end
