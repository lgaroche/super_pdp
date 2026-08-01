# frozen_string_literal: true

require "date"

RSpec.describe SuperPdp::Invoice do
  def build(**overrides)
    described_class.new(
      number: "INV-001", issue_date: Date.new(2026, 6, 22), currency_code: "EUR",
      seller: { name: "Burger Queen", vat_identifier: "FR44732829320",
                postal_address: { country_code: "FR", city: "Paris" },
                electronic_address: { scheme: "0009", value: "73282932000074" } },
      buyer:  { name: "Tricatel", postal_address: { country_code: "FR", city: "Lyon" } },
      **overrides
    )
  end

  describe "#add_line / #totals" do
    it "derives line nets, VAT breakdown and header totals" do
      invoice = build
      invoice.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
      invoice.add_line(name: "Coffee", quantity: 2, unit_price: 5, vat_rate: 20)

      totals = invoice.totals
      expect(totals[:sum_invoice_lines_amount]).to eq(BigDecimal("1010"))
      expect(totals[:total_vat_amount]).to eq(BigDecimal("202"))
      expect(totals[:total_with_vat]).to eq(BigDecimal("1212"))
    end

    it "groups the VAT breakdown by category and rate" do
      invoice = build
      invoice.add_line(name: "Standard", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_line(name: "Reduced", quantity: 1, unit_price: 100, vat_rate: 5.5)

      breakdown = invoice.vat_breakdown
      expect(breakdown.size).to eq(2)
      rates = breakdown.map { |b| b[:rate] }
      expect(rates).to contain_exactly(BigDecimal("20"), BigDecimal("5.5"))
    end
  end

  describe "#validate" do
    it "is empty for a well-formed invoice" do
      invoice = build.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
      expect(invoice.validate).to eq([])
      expect(invoice).to be_valid
    end

    it "flags a missing line and a net_amount that does not reconcile" do
      empty = build
      expect(empty.validate).to include(a_string_matching(/at least one line/))

      bad = build.add_line(name: "X", quantity: 2, unit_price: 50, vat_rate: 20, net_amount: 999)
      expect(bad.validate).to include(a_string_matching(/net_amount .* != quantity\*unit_price/))
    end
  end

  describe "#to_en_invoice" do
    subject(:json) do
      build.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20).to_en_invoice
    end

    it "includes every required top-level field with sane defaults" do
      expect(json).to include(
        "number" => "INV-001", "issue_date" => "2026-06-22",
        "type_code" => 380, "currency_code" => "EUR"
      )
      expect(json["process_control"]["specification_identifier"]).to eq("urn:cen.eu:en16931:2017")
      expect(json).to include("seller", "buyer", "lines", "vat_break_down", "totals")
    end

    it "serializes amounts as 2-decimal strings" do
      line = json["lines"].first
      expect(line["net_amount"]).to eq("1000.00")
      expect(json["totals"]["total_with_vat"]).to eq("1200.00")
      expect(json["totals"]["total_vat_amount"]).to eq("value" => "200.00", "currency_code" => "EUR")
    end
  end
end
