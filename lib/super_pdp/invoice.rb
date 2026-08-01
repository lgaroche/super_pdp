# frozen_string_literal: true

require "bigdecimal"
require "date"

module SuperPdp
  # Ergonomic builder for a structured EN 16931 invoice (the API's `en_invoice` model).
  #
  # Covers the common required path — seller / buyer / lines / totals / VAT — and does
  # the tedious arithmetic (line nets, VAT breakdown, header totals) for you. Build it,
  # add lines, then hand it to the API:
  #
  #   invoice = SuperPdp::Invoice.new(
  #     number: "INV-2026-001", issue_date: Date.today, currency_code: "EUR",
  #     seller: { name: "Burger Queen", vat_identifier: "FR44732829320",
  #               postal_address: { country_code: "FR", city: "Paris", post_code: "75001" },
  #               electronic_address: { scheme: "0009", value: "73282932000074" } },
  #     buyer:  { name: "Tricatel",
  #               postal_address: { country_code: "FR", city: "Lyon", post_code: "69002" } }
  #   )
  #   invoice.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
  #   client.invoices.issue(invoice)            # -> convert to UBL, then send
  #
  # `#validate` runs only cheap, deterministic structural checks (required fields present,
  # line nets and header totals reconcile) for fast feedback. Full EN 16931 conformance is
  # the server's job — see `disable_pre_check` on issue/create and `invoices.validate`.
  class Invoice
    DEFAULT_TYPE_CODE = 380                                # commercial invoice (BT-3)
    DEFAULT_SPECIFICATION_IDENTIFIER = "urn:cen.eu:en16931:2017"
    DEFAULT_CURRENCY = "EUR"
    DEFAULT_UNIT_CODE = "C62"                              # UN/ECE Rec 20: one (piece)
    DEFAULT_VAT_CATEGORY = "S"                             # standard rate

    Line = Struct.new(:identifier, :name, :quantity, :unit_price, :net_amount,
                      :vat_rate, :vat_category, :unit_code, keyword_init: true)

    attr_accessor :number, :issue_date, :currency_code, :type_code,
                  :specification_identifier, :business_process_type,
                  :seller, :buyer, :payment_due_date, :payment_terms,
                  :buyer_reference, :purchase_order_reference
    attr_reader :lines

    def initialize(number:, issue_date:, seller:, buyer:,
                   currency_code: DEFAULT_CURRENCY, type_code: DEFAULT_TYPE_CODE,
                   specification_identifier: DEFAULT_SPECIFICATION_IDENTIFIER,
                   business_process_type: nil, payment_due_date: nil, payment_terms: nil,
                   buyer_reference: nil, purchase_order_reference: nil)
      @number = number
      @issue_date = issue_date
      @seller = seller || {}
      @buyer = buyer || {}
      @currency_code = currency_code
      @type_code = type_code
      @specification_identifier = specification_identifier
      @business_process_type = business_process_type
      @payment_due_date = payment_due_date
      @payment_terms = payment_terms
      @buyer_reference = buyer_reference
      @purchase_order_reference = purchase_order_reference
      @lines = []
    end

    # Add an invoice line. `net_amount` defaults to quantity * unit_price.
    # Returns self so calls can be chained.
    def add_line(name:, quantity:, unit_price:, vat_rate:, identifier: nil,
                 vat_category: DEFAULT_VAT_CATEGORY, unit_code: DEFAULT_UNIT_CODE,
                 net_amount: nil)
      q = dec(quantity)
      price = dec(unit_price)
      @lines << Line.new(
        identifier:   identifier || (@lines.size + 1).to_s,
        name:         name,
        quantity:     q,
        unit_price:   price,
        net_amount:   net_amount ? dec(net_amount) : (q * price),
        vat_rate:     dec(vat_rate),
        vat_category: vat_category,
        unit_code:    unit_code
      )
      self
    end

    # VAT breakdown grouped by (category, rate): one entry per group with its
    # taxable base and tax amount. (EN 16931 BG-23.)
    def vat_breakdown
      lines.group_by { |l| [l.vat_category, l.vat_rate] }.map do |(category, rate), group|
        taxable = group.sum(&:net_amount)
        {
          category: category,
          rate:     rate,
          taxable:  taxable,
          tax:      (taxable * rate / 100).round(2)
        }
      end
    end

    # Derived header totals from the current lines (all BigDecimal).
    def totals
      lines_sum = lines.sum(BigDecimal(0), &:net_amount)
      vat_total = vat_breakdown.sum(BigDecimal(0)) { |b| b[:tax] }
      {
        sum_invoice_lines_amount: lines_sum,
        total_without_vat:        lines_sum,
        total_vat_amount:         vat_total,
        total_with_vat:           lines_sum + vat_total,
        amount_due_for_payment:   lines_sum + vat_total
      }
    end

    # Cheap, deterministic structural checks. Returns an array of message strings
    # ([] when ok). NOT EN 16931 conformance — that stays with the server.
    def validate
      errors = []
      errors << "number is required"     if blank?(number)
      errors << "issue_date is required" if blank?(issue_date)
      errors << "seller name is required" if blank?(@seller[:name] || @seller["name"])
      errors << "buyer name is required"  if blank?(@buyer[:name]  || @buyer["name"])
      errors << "at least one line is required" if lines.empty?

      lines.each_with_index do |line, i|
        n = i + 1
        errors << "line #{n}: name is required" if blank?(line.name)
        expected = line.quantity * line.unit_price
        if (line.net_amount - expected).abs > BigDecimal("0.005")
          errors << "line #{n}: net_amount #{money(line.net_amount)} != quantity*unit_price #{money(expected)}"
        end
      end
      errors
    end

    def valid?
      validate.empty?
    end

    # Serialize to the `en_invoice` JSON model the API's /invoices/convert endpoint expects.
    def to_en_invoice
      t = totals
      {
        "number"          => number,
        "issue_date"      => iso_date(issue_date),
        "type_code"       => type_code,
        "currency_code"   => currency_code,
        "process_control" => {
          "specification_identifier" => specification_identifier,
          "business_process_type"    => business_process_type
        }.compact,
        "seller"          => stringify(@seller),
        "buyer"           => stringify(@buyer),
        "lines"           => lines.map { |l| line_json(l) },
        "vat_break_down"  => vat_breakdown.map { |b| vat_json(b) },
        "totals"          => totals_json(t),
        "payment_due_date"         => (iso_date(payment_due_date) if payment_due_date),
        "payment_terms"            => payment_terms,
        "buyer_reference"          => buyer_reference,
        "purchase_order_reference" => purchase_order_reference
      }.compact
    end
    alias to_h to_en_invoice

    private

    def line_json(line)
      {
        "identifier"            => line.identifier,
        "invoiced_quantity"     => num(line.quantity),
        "invoiced_quantity_code" => line.unit_code,
        "net_amount"            => money(line.net_amount),
        "item_information"      => { "name" => line.name },
        "price_details"         => { "item_net_price" => num(line.unit_price) },
        "vat_information"       => {
          "invoiced_item_vat_category_code" => line.vat_category,
          "invoiced_item_vat_rate"          => num(line.vat_rate)
        }
      }
    end

    def vat_json(entry)
      {
        "vat_category_code"        => entry[:category],
        "vat_category_rate"        => num(entry[:rate]),
        "vat_category_taxable_amount" => money(entry[:taxable]),
        "vat_category_tax_amount"  => money(entry[:tax])
      }
    end

    def totals_json(amounts)
      {
        "sum_invoice_lines_amount" => money(amounts[:sum_invoice_lines_amount]),
        "total_without_vat"        => money(amounts[:total_without_vat]),
        "total_vat_amount"         => { "value" => money(amounts[:total_vat_amount]),
"currency_code" => currency_code },
        "total_with_vat"           => money(amounts[:total_with_vat]),
        "amount_due_for_payment"   => money(amounts[:amount_due_for_payment])
      }
    end

    def dec(value)
      case value
      when BigDecimal then value
      when Integer    then BigDecimal(value)
      else BigDecimal(value.to_s) # Float (via String to stay exact), String, etc.
      end
    end

    # Monetary amounts: fixed 2 decimals.
    def money(value)
      format("%.2f", dec(value).round(2))
    end

    # Quantities / rates / unit prices: trim trailing zeros (keep up to 4 decimals).
    def num(value)
      dec(value).round(4).to_s("F").sub(/(\.\d*?)0+\z/, '\1').sub(/\.\z/, "")
    end

    def iso_date(value)
      case value
      when nil then nil
      when String then value
      else value.strftime("%Y-%m-%d")
      end
    end

    def stringify(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      else obj
      end
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
