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

    it "keeps BT-106 equal to the sum of the printed line nets (BR-CO-10)" do
      # Sub-cent line nets are routine — 5.5 units at 6.2683, any markup-derived price.
      # BT-131 is capped at 2 decimals, so the header has to sum the *printed* figures:
      # round(sum) and sum(round) disagree, and a reader only ever sees the latter.
      invoice = build
      [[5.5, 6.2683], [19.5, 5.9972], [10.5, 6.4193]].each_with_index do |(qty, price), i|
        invoice.add_line(name: "L#{i}", quantity: qty, unit_price: price, vat_rate: 20)
      end

      json = invoice.to_en_invoice
      printed = json["lines"].map { |l| BigDecimal(l["net_amount"]) }
      expect(printed).to eq([BigDecimal("34.48"), BigDecimal("116.95"), BigDecimal("67.40")])
      expect(json["totals"]["sum_invoice_lines_amount"]).to eq("218.83")
      expect(printed.sum).to eq(BigDecimal("218.83"))
      # and the VAT base is the same figure, so the tax charged follows the document
      expect(json["vat_break_down"].first["vat_category_taxable_amount"]).to eq("218.83")
    end

    it "omits the allowance and preceding-reference groups when there are none" do
      expect(json).not_to include("preceding_invoice_references", "document_level_allowances")
      expect(json["lines"].first).not_to include("allowances")
      expect(json["totals"]).not_to include("sum_allowances_amount")
    end
  end

  describe "#add_note" do
    it "serializes BT-22 with its BT-21 subject code" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_note(note: "Frais de recouvrement 40 EUR", subject_code: "PMT")
      invoice.add_note(note: "Escompte pour paiement anticipé: néant", subject_code: "AAB")

      expect(invoice.to_en_invoice["notes"]).to eq(
        [{ "note" => "Frais de recouvrement 40 EUR", "subject_code" => "PMT" },
         { "note" => "Escompte pour paiement anticipé: néant", "subject_code" => "AAB" }]
      )
    end

    it "keeps the subject code optional and omits the group when there are no notes" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      expect(invoice.to_en_invoice).not_to include("notes")

      invoice.add_note(note: "Livraison en deux fois")
      expect(invoice.to_en_invoice["notes"]).to eq([{ "note" => "Livraison en deux fois" }])
    end

    it "flags a note with no text — BT-22 is required" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_note(note: "", subject_code: "PMT")

      expect(invoice.validate).to include(a_string_matching(/note 1: note text is required/))
    end
  end

  describe "#add_preceding_invoice_reference" do
    it "serializes BT-25 / BT-26 and the French preceding type code" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_preceding_invoice_reference(reference: "INV-000", issue_date: Date.new(2026, 5, 1),
                                              type_code: 380)

      expect(invoice.to_en_invoice["preceding_invoice_references"]).to eq(
        [{ "reference" => "INV-000", "issue_date" => "2026-05-01", "preceding_invoice_type_code" => 380 }]
      )
    end

    it "keeps issue_date and the type code optional" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_preceding_invoice_reference(reference: "INV-000")

      expect(invoice.to_en_invoice["preceding_invoice_references"]).to eq([{ "reference" => "INV-000" }])
    end
  end

  describe "a credit note" do
    subject(:json) do
      invoice = build(type_code: 381)
      invoice.add_line(name: "Refund of consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_preceding_invoice_reference(reference: "INV-001", type_code: 380)
      invoice.to_en_invoice
    end

    it "round-trips type_code 381 with its preceding invoice" do
      expect(json["type_code"]).to eq(381)
      expect(json["preceding_invoice_references"].first["reference"]).to eq("INV-001")
      expect(json["totals"]["total_with_vat"]).to eq("120.00")
    end

    it "is valid without a preceding invoice — BG-3 is optional in the schema" do
      goodwill = build(type_code: 381).add_line(name: "Goodwill", quantity: 1, unit_price: 50, vat_rate: 20)
      expect(goodwill.validate).to eq([])
    end
  end

  describe "line-level allowances (BG-27)" do
    subject(:invoice) do
      build.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20,
                     allowances: [{ amount: 150, percent: 15, base_amount: 1000, reason: "Remise" }])
    end

    it "nets the discount out of BT-131 and still reconciles" do
      expect(invoice.lines.first.net_amount).to eq(BigDecimal("850"))
      expect(invoice.validate).to eq([])
      expect(invoice.totals[:sum_invoice_lines_amount]).to eq(BigDecimal("850"))
      expect(invoice.totals[:total_vat_amount]).to eq(BigDecimal("170"))
    end

    it "emits the allowance on the line" do
      expect(invoice.to_en_invoice["lines"].first["allowances"]).to eq(
        [{ "amount" => "150.00", "base_amount" => "1000.00", "percent" => "15", "reason" => "Remise" }]
      )
    end

    it "flags a net_amount that does not reconcile against the discounted formula" do
      bad = build.add_line(name: "X", quantity: 10, unit_price: 100, vat_rate: 20,
                           net_amount: 1000, allowances: [{ amount: 150 }])
      expect(bad.validate).to include(a_string_matching(/!= quantity\*unit_price - allowances 850\.00/))
    end
  end

  describe "document-level allowances (BG-20)" do
    it "emits BT-107, deducts it from BT-109 and shrinks the taxable base" do
      invoice = build.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
      invoice.add_document_level_allowance(amount: 100, vat_rate: 20, reason: "Remise globale")

      totals = invoice.to_en_invoice["totals"]
      expect(totals["sum_invoice_lines_amount"]).to eq("1000.00")
      expect(totals["sum_allowances_amount"]).to eq("100.00")
      expect(totals["total_without_vat"]).to eq("900.00")
      expect(totals["total_with_vat"]).to eq("1080.00")

      breakdown = invoice.to_en_invoice["vat_break_down"]
      expect(breakdown.size).to eq(1)
      expect(breakdown.first).to include("vat_category_taxable_amount" => "900.00",
                                         "vat_category_tax_amount" => "180.00")
    end

    it "serializes the mandatory VAT qualification alongside the line-variant fields" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_document_level_allowance(amount: 10, vat_rate: 20, reason: "Remise", reason_code: "95")

      expect(invoice.to_en_invoice["document_level_allowances"]).to eq(
        [{ "amount" => "10.00", "reason" => "Remise", "reason_code" => "95",
           "vat_category_code" => "S", "vat_rate" => "20" }]
      )
    end

    it "accumulates several allowances sharing a VAT rate, keeping each one's reason" do
      # One entry per (discount, rate) is how a caller keeps per-discount labels on the
      # document: two remises across two rates is four BG-20 entries, two per rate.
      invoice = build
      invoice.add_line(name: "Standard", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_line(name: "Reduced",  quantity: 1, unit_price: 100, vat_rate: 5.5)
      { "Remise fidélité" => [4, 4], "Geste commercial" => [6, 6] }.each do |reason, (std, red)|
        invoice.add_document_level_allowance(amount: std, vat_rate: 20,  reason: reason)
        invoice.add_document_level_allowance(amount: red, vat_rate: 5.5, reason: reason)
      end

      json = invoice.to_en_invoice
      expect(json["document_level_allowances"].map { |a| a["reason"] })
        .to eq(["Remise fidélité", "Remise fidélité", "Geste commercial", "Geste commercial"])
      expect(json["totals"]["sum_allowances_amount"]).to eq("20.00")
      expect(json["totals"]["total_without_vat"]).to eq("180.00")

      # each rate's base is net of *both* allowances that name it, not just the first
      taxable = json["vat_break_down"].to_h { |b| [b["vat_category_rate"], b["vat_category_taxable_amount"]] }
      expect(taxable).to eq("20" => "90.00", "5.5" => "90.00")
      expect(json["totals"]["total_vat_amount"]["value"]).to eq("22.95") # 18.00 + 4.95
    end

    it "flags an allowance with no VAT category — BT-95 is required" do
      invoice = build.add_line(name: "Consulting", quantity: 1, unit_price: 100, vat_rate: 20)
      invoice.add_document_level_allowance(amount: 10, vat_rate: 20, vat_category_code: nil)

      expect(invoice.validate).to include(a_string_matching(/vat_category_code is required/))
    end
  end

  describe "#add_document_level_discount across mixed VAT rates" do
    subject(:invoice) do
      inv = build
      inv.add_line(name: "Standard", quantity: 1, unit_price: 100, vat_rate: 20)
      inv.add_line(name: "Reduced",  quantity: 1, unit_price: 200, vat_rate: 5.5)
      inv.add_document_level_discount(amount: 30, reason: "Remise globale")
      inv
    end

    it "produces one entry per VAT rate, each carrying its proportional share" do
      allowances = invoice.document_level_allowances
      expect(allowances.size).to eq(2)
      expect(allowances.map { |a| a[:vat_rate] }).to eq([BigDecimal("20"), BigDecimal("5.5")])
      expect(allowances.map { |a| a[:amount] }).to eq([BigDecimal("10"), BigDecimal("20")])
      expect(allowances.map { |a| a[:base_amount] }).to eq([BigDecimal("100"), BigDecimal("200")])
    end

    it "reduces each rate's taxable base by that rate's share only" do
      breakdown = invoice.vat_breakdown.to_h { |b| [b[:rate], b] }
      expect(breakdown[BigDecimal("20")][:taxable]).to eq(BigDecimal("90"))
      expect(breakdown[BigDecimal("5.5")][:taxable]).to eq(BigDecimal("180"))
      expect(invoice.totals[:total_without_vat]).to eq(BigDecimal("270"))
      expect(invoice.totals[:total_vat_amount]).to eq(BigDecimal("27.90")) # 18.00 + 9.90
    end

    it "allocates in whole cents that sum back to the discount exactly" do
      inv = build
      inv.add_line(name: "A", quantity: 1, unit_price: 100, vat_rate: 20)
      inv.add_line(name: "B", quantity: 1, unit_price: 100, vat_rate: 10)
      inv.add_line(name: "C", quantity: 1, unit_price: 100, vat_rate: 5.5)
      inv.add_document_level_discount(amount: 10)

      shares = inv.document_level_allowances.map { |a| a[:amount] }
      expect(shares).to eq([BigDecimal("3.34"), BigDecimal("3.33"), BigDecimal("3.33")])
      expect(shares.sum).to eq(BigDecimal("10")) # the naive 3.33 x 3 would lose a cent
      expect(inv.totals[:sum_allowances_amount]).to eq(BigDecimal("10"))
      expect(inv.to_en_invoice["totals"]["total_without_vat"]).to eq("290.00")
    end

    it "gives the leftover cent to the same rate whatever order the lines were added in" do
      shares_by_rate = lambda do |*rates|
        inv = build
        rates.each { |r| inv.add_line(name: "L#{r}", quantity: 1, unit_price: 100, vat_rate: r) }
        inv.add_document_level_discount(amount: 10)
        inv.document_level_allowances.to_h { |a| [a[:vat_rate], a[:amount]] }
      end

      # 10.00 over three equal bases: one rate must take 3.34, and which one may not
      # depend on line order — it decides how much VAT that rate carries.
      expect(shares_by_rate.call(20, 10, 5.5)).to eq(shares_by_rate.call(5.5, 10, 20))
      expect(shares_by_rate.call(20, 10, 5.5)).to eq(shares_by_rate.call(10, 20, 5.5))
      expect(shares_by_rate.call(20, 10, 5.5)[BigDecimal("20")]).to eq(BigDecimal("3.34"))
    end

    it "keeps every share within a cent of its exact proportional value" do
      inv = build
      inv.add_line(name: "A", quantity: 1, unit_price: 380.45, vat_rate: 20)
      inv.add_line(name: "B", quantity: 1, unit_price: 25.69,  vat_rate: 10)
      inv.add_line(name: "C", quantity: 1, unit_price: 20.28,  vat_rate: 5.5)
      inv.add_document_level_discount(amount: 26.96)

      gross = BigDecimal("426.42")
      inv.document_level_allowances.each do |a|
        exact = BigDecimal("26.96") * a[:base_amount] / gross
        expect((a[:amount] - exact).abs).to be <= BigDecimal("0.01")
      end
      expect(inv.document_level_allowances.sum { |a| a[:amount] }).to eq(BigDecimal("26.96"))
    end

    it "splits on cent-rounded bases, so the shares are reproducible from the document" do
      # Line nets can carry sub-cent precision; the base amounts printed on the document
      # cannot. Allocating over the raw nets would give shares nobody could re-derive.
      inv = build
      { 20 => 32.2891, 10 => 41.6748, 5.5 => 9.8608, 2.1 => 5.0347 }.each_with_index do |(rate, net), i|
        inv.add_line(name: "L#{i}", quantity: 1, unit_price: net, vat_rate: rate)
      end
      inv.add_document_level_discount(amount: 37.08)

      allowances = inv.document_level_allowances
      expect(allowances.map { |a| a[:amount] })
        .to eq([BigDecimal("13.48"), BigDecimal("17.39"), BigDecimal("4.11"), BigDecimal("2.10")])
      expect(allowances.sum { |a| a[:amount] }).to eq(BigDecimal("37.08"))

      # Each share is the largest-remainder split of 3708 cents over the *printed* bases.
      json = inv.to_en_invoice["document_level_allowances"]
      expect(json.map { |a| a["base_amount"] }).to eq(["32.29", "41.67", "9.86", "5.03"])
    end

    it "refuses to spread a discount when there is nothing to spread it over" do
      expect { build.add_document_level_discount(amount: 30) }
        .to raise_error(ArgumentError, /lines totalling 0/)
    end
  end
end
