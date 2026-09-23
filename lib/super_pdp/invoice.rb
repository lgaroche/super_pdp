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
    SEPA_CREDIT_TRANSFER = "58"                            # UNTDID 4461 (BT-81)

    Line = Struct.new(:identifier, :name, :quantity, :unit_price, :net_amount,
                      :vat_rate, :vat_category, :unit_code, :allowances, keyword_init: true)

    attr_accessor :number, :issue_date, :currency_code, :type_code,
                  :specification_identifier, :business_process_type,
                  :seller, :buyer, :payment_due_date, :payment_terms,
                  :buyer_reference, :purchase_order_reference,
                  :payment_means_type_code, :payment_means_text, :remittance_information
    attr_reader :lines, :notes, :preceding_invoice_references, :document_level_allowances,
                :credit_transfers

    def initialize(number:, issue_date:, seller:, buyer:,
                   currency_code: DEFAULT_CURRENCY, type_code: DEFAULT_TYPE_CODE,
                   specification_identifier: DEFAULT_SPECIFICATION_IDENTIFIER,
                   business_process_type: nil, payment_due_date: nil, payment_terms: nil,
                   buyer_reference: nil, purchase_order_reference: nil,
                   payment_means_type_code: nil, payment_means_text: nil,
                   remittance_information: nil)
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
      @payment_means_type_code = payment_means_type_code
      @payment_means_text = payment_means_text
      @remittance_information = remittance_information
      @lines = []
      @notes = []
      @preceding_invoice_references = []
      @document_level_allowances = []
      @credit_transfers = []
    end

    # Add a document-level note (BG-1) — free text about the invoice as a whole, with an
    # optional subject code (BT-21) from UNTDID 4451 qualifying what the note is about.
    #
    # French invoicing requires several mentions to be carried this way rather than in a
    # dedicated field: BR-FR-05 wants the frais de recouvrement mention (subject code
    # `PMT`), and the penalty and discount-terms mentions travel the same route. Without
    # this, callers have to reach past `to_en_invoice` and mutate the payload to comply.
    #
    #   invoice.add_note(note: "Frais de recouvrement 40 EUR", subject_code: "PMT")
    #
    # Returns self.
    def add_note(note:, subject_code: nil)
      @notes << { note: note, subject_code: subject_code }.compact
      self
    end

    # Add an account the buyer can pay into by transfer (BG-17), inside the payment
    # instructions (BG-16).
    #
    #   invoice.add_credit_transfer(account_identifier: "FR7630006000011234567890189",
    #                               account_name: "Burger Queen", service_provider_identifier: "AGRIFRPPXXX")
    #
    # `account_identifier` is BT-84 — an IBAN for a SEPA transfer. Leave `scheme` empty
    # for one: the API writes BT-84 to CII's IBANID either way, and any non-empty scheme is
    # *also* written out as a ProprietaryID holding that string, a second account
    # identifier nobody meant to give (observed against the sandbox converter). BT-85 is
    # the account's name, BT-86 the bank's identifier (a BIC).
    #
    # BR-49 wants a payment means code (BT-81) wherever BG-16 is present, so this sets
    # `payment_means_type_code` to 58, SEPA credit transfer, unless one was given.
    # `remittance_information` (BT-83) is the reference the buyer should quote on the
    # transfer — commonly the invoice number. Returns self.
    def add_credit_transfer(account_identifier:, account_name: nil, service_provider_identifier: nil,
                            scheme: "")
      @payment_means_type_code ||= SEPA_CREDIT_TRANSFER
      @credit_transfers << {
        account_identifier:          account_identifier,
        scheme:                      scheme.to_s,
        account_name:                account_name,
        service_provider_identifier: service_provider_identifier
      }.compact
      self
    end

    # Add an invoice line. `allowances` (BG-27) is a list of line-level discounts, each
    # `{ amount:, base_amount: nil, percent: nil, reason: nil, reason_code: nil }` —
    # amounts without VAT. `net_amount` (BT-131) defaults to the EN 16931 formula,
    # quantity * unit_price - allowances, so a discounted line still reconciles.
    # Returns self so calls can be chained.
    def add_line(name:, quantity:, unit_price:, vat_rate:, identifier: nil,
                 vat_category: DEFAULT_VAT_CATEGORY, unit_code: DEFAULT_UNIT_CODE,
                 net_amount: nil, allowances: [])
      q = dec(quantity)
      price = dec(unit_price)
      list = Array(allowances).map { |a| normalize_line_allowance(a) }
      @lines << Line.new(
        identifier:   identifier || (@lines.size + 1).to_s,
        name:         name,
        quantity:     q,
        unit_price:   price,
        net_amount:   money_value(net_amount || ((q * price) - allowance_total(list))),
        vat_rate:     dec(vat_rate),
        vat_category: vat_category,
        unit_code:    unit_code,
        allowances:   list
      )
      self
    end

    # Reference a preceding invoice (BG-3) — what a credit note (`type_code: 381`)
    # corrects, or the partial / pre-payment invoices a final invoice draws on.
    #
    # `type_code` is the French extension EXT-FR-FE-02 (BR-FR-04): the type of the
    # *preceding* document, e.g. 380 when crediting a commercial invoice.
    #
    # Leave it nil when converting to **UBL**. It maps to the BillingReference
    # DocumentTypeCode, which UBL-CR-026 says an EN 16931 UBL document should not carry —
    # the sandbox validator warns on it, and omitting it makes the credit note validate
    # as cleanly as a plain invoice. It is meaningful on the CII / Factur-X path.
    #
    # BG-3 is 0..n and absent from the schema's `required` — a goodwill credit note with
    # no parent invoice stays structurally valid. Linking is a French legal obligation
    # (CGI ann. II art. 242 nonies A) when rectifying a specific invoice, not a schema
    # constraint, so the builder does not force it. Returns self.
    def add_preceding_invoice_reference(reference:, issue_date: nil, type_code: nil)
      @preceding_invoice_references << {
        reference:  reference,
        issue_date: issue_date,
        type_code:  type_code&.to_i
      }.compact
      self
    end

    # Add a document-level allowance (BG-20) — a remise globale, applied to the invoice
    # as a whole rather than to a line.
    #
    # BT-95 (`vat_category_code`) is mandatory on every BG-20 entry, so one entry can
    # only ever carry a single VAT rate. For a discount spanning lines at several rates,
    # use `add_document_level_discount`, which does the split.
    #
    # Several entries may share a rate, and that is how to keep a per-discount label on
    # the document: allocate each discount across the rates separately, then add one entry
    # per (discount, rate) with its own `reason`. A rate's taxable base comes out net of
    # every allowance naming it. Returns self.
    def add_document_level_allowance(amount:, vat_rate:, vat_category_code: DEFAULT_VAT_CATEGORY,
                                     base_amount: nil, percent: nil, reason: nil, reason_code: nil,
                                     vat_exemption_reason: nil, vat_exemption_reason_code: nil)
      @document_level_allowances << {
        amount:                    money_value(amount),
        vat_category_code:         vat_category_code,
        vat_rate:                  dec(vat_rate),
        base_amount:               (money_value(base_amount) if base_amount),
        percent:                   (dec(percent) if percent),
        reason:                    reason,
        reason_code:               reason_code,
        vat_exemption_reason:      vat_exemption_reason,
        vat_exemption_reason_code: vat_exemption_reason_code
      }.compact
      self
    end

    # Add a remise globale spread across the VAT rates of the lines added so far.
    #
    # Because BT-95 is mandatory per BG-20 entry (see above), a discount that spans
    # several rates becomes *one entry per (category, rate)*, each carrying that group's
    # share of `amount` in proportion to its net. Shares are allocated in whole cents by
    # largest remainder, so they add back up to `amount` exactly, no share is more than a
    # cent off its exact value, and the result does not depend on the order of the lines.
    #
    # This is a convenience for callers that have no allocation of their own. If you
    # already computed per-rate shares — in particular if you *froze* them, and the
    # customer has been shown a VAT breakdown derived from them — pass them to
    # `add_document_level_allowance` instead. Proportional allocation is
    # rounding-policy-dependent: splitting 10.00 over three equal bases gives one rate a
    # cent the others don't get, and which rate that is differs between defensible rules.
    # Re-deriving here would make this a second source of truth for a number already
    # decided elsewhere.
    #
    # Call this *after* the lines it applies to. Returns self.
    def add_document_level_discount(amount:, reason: nil, reason_code: nil, percent: nil)
      groups = lines.group_by { |l| [l.vat_category, l.vat_rate] }
                    .map { |key, group| [key, group.sum(BigDecimal(0), &:net_amount)] }

      allocate(dec(amount), groups).each_with_index do |share, i|
        (category, rate), net = groups[i]
        next if share.zero?

        add_document_level_allowance(amount: share, vat_category_code: category, vat_rate: rate,
                                     base_amount: net, percent: percent,
                                     reason: reason, reason_code: reason_code)
      end
      self
    end

    # VAT breakdown grouped by (category, rate): one entry per group with its
    # taxable base and tax amount. (EN 16931 BG-23.)
    #
    # Document-level allowances reduce the taxable base of the group they name (BT-116
    # is net of BG-20), so a remise globale lowers the VAT actually charged.
    def vat_breakdown
      bases = lines.group_by { |l| [l.vat_category, l.vat_rate] }
                   .transform_values { |group| group.sum(BigDecimal(0), &:net_amount) }
      document_level_allowances.each do |allowance|
        key = [allowance[:vat_category_code], allowance[:vat_rate]]
        bases[key] = (bases[key] || BigDecimal(0)) - allowance[:amount]
      end

      bases.map do |(category, rate), taxable|
        {
          category: category,
          rate:     rate,
          taxable:  taxable,
          tax:      (taxable * rate / 100).round(2)
        }
      end
    end

    # Derived header totals from the current lines and document-level allowances
    # (all BigDecimal). BT-109 = BT-106 - BT-107; charges (BT-108/BG-21) are not
    # modelled by this builder, so they contribute nothing.
    def totals
      lines_sum      = lines.sum(BigDecimal(0), &:net_amount)
      allowances_sum = document_level_allowances.sum(BigDecimal(0)) { |a| a[:amount] }
      net_total      = lines_sum - allowances_sum
      vat_total      = vat_breakdown.sum(BigDecimal(0)) { |b| b[:tax] }
      {
        sum_invoice_lines_amount: lines_sum,
        sum_allowances_amount:    allowances_sum,
        total_without_vat:        net_total,
        total_vat_amount:         vat_total,
        total_with_vat:           net_total + vat_total,
        amount_due_for_payment:   net_total + vat_total
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
        discount = allowance_total(line.allowances)
        expected = (line.quantity * line.unit_price) - discount
        formula  = discount.zero? ? "quantity*unit_price" : "quantity*unit_price - allowances"
        if (line.net_amount - expected).abs > BigDecimal("0.005")
          errors << "line #{n}: net_amount #{money(line.net_amount)} != #{formula} #{money(expected)}"
        end
      end

      notes.each_with_index do |entry, i|
        errors << "note #{i + 1}: note text is required" if blank?(entry[:note])
      end

      preceding_invoice_references.each_with_index do |ref, i|
        errors << "preceding invoice reference #{i + 1}: reference is required" if blank?(ref[:reference])
      end

      document_level_allowances.each_with_index do |allowance, i|
        next unless blank?(allowance[:vat_category_code])

        errors << "document-level allowance #{i + 1}: vat_category_code is required"
      end

      if payment_instructions_json && blank?(payment_means_type_code)
        errors << "payment_means_type_code is required with payment instructions"
      end
      credit_transfers.each_with_index do |transfer, i|
        next unless blank?(transfer[:account_identifier])

        errors << "credit transfer #{i + 1}: account_identifier is required"
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
        "notes"           => list_json(notes) { |n| note_json(n) },
        "vat_break_down"  => vat_breakdown.map { |b| vat_json(b) },
        "totals"          => totals_json(t),
        "preceding_invoice_references" =>
          list_json(preceding_invoice_references) { |r| preceding_reference_json(r) },
        "document_level_allowances"    =>
          list_json(document_level_allowances) { |a| document_allowance_json(a) },
        "payment_due_date"         => (iso_date(payment_due_date) if payment_due_date),
        "payment_terms"            => payment_terms,
        "payment_instructions"     => payment_instructions_json,
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
        "allowances"            => list_json(line.allowances) { |a| allowance_json(a) },
        "vat_information"       => {
          "invoiced_item_vat_category_code" => line.vat_category,
          "invoiced_item_vat_rate"          => num(line.vat_rate)
        }
      }.compact
    end

    # BG-27: the line variant carries no vat_category_code — it inherits the line's.
    def allowance_json(allowance)
      {
        "amount"      => money(allowance[:amount]),
        "base_amount" => (money(allowance[:base_amount]) if allowance[:base_amount]),
        "percent"     => (num(allowance[:percent]) if allowance[:percent]),
        "reason"      => allowance[:reason],
        "reason_code" => allowance[:reason_code]
      }.compact
    end

    # BG-20: stricter than the line variant — vat_category_code is required.
    def document_allowance_json(allowance)
      allowance_json(allowance).merge(
        {
          "vat_category_code"         => allowance[:vat_category_code],
          "vat_rate"                  => (num(allowance[:vat_rate]) if allowance[:vat_rate]),
          "vat_exemption_reason"      => allowance[:vat_exemption_reason],
          "vat_exemption_reason_code" => allowance[:vat_exemption_reason_code]
        }.compact
      )
    end

    # BG-1: the note text is required, the subject code (BT-21) is not.
    def note_json(entry)
      {
        "note"         => entry[:note],
        "subject_code" => entry[:subject_code]
      }.compact
    end

    # BG-16, or nil when the invoice says nothing about how to pay — so an invoice
    # without it serializes exactly as it did before. BT-81 is a string in the schema; an
    # Integer code is accepted and converted.
    def payment_instructions_json
      json = {
        "payment_means_type_code" => payment_means_type_code&.to_s,
        "payment_means_text"      => payment_means_text,
        "remittance_information"  => remittance_information,
        "credit_transfers"        => list_json(credit_transfers) { |t| credit_transfer_json(t) }
      }.compact
      json unless json.empty?
    end

    # BG-17: BT-84 is required, and carries its scheme as the API's identifier object.
    def credit_transfer_json(transfer)
      {
        "payment_account_identifier"          => { "scheme" => transfer[:scheme],
                                                   "value"  => transfer[:account_identifier] },
        "payment_account_name"                => transfer[:account_name],
        "payment_service_provider_identifier" => transfer[:service_provider_identifier]
      }.compact
    end

    def preceding_reference_json(ref)
      {
        "reference"                   => ref[:reference],
        "issue_date"                  => iso_date(ref[:issue_date]),
        "preceding_invoice_type_code" => ref[:type_code]
      }.compact
    end

    def vat_json(entry)
      {
        "vat_category_code"        => entry[:category],
        "vat_category_rate"        => num(entry[:rate]),
        "vat_category_taxable_amount" => money(entry[:taxable]),
        "vat_category_tax_amount" => money(entry[:tax])
      }
    end

    def totals_json(amounts)
      {
        "sum_invoice_lines_amount" => money(amounts[:sum_invoice_lines_amount]),
        "sum_allowances_amount"    => (money(amounts[:sum_allowances_amount]) unless document_level_allowances.empty?),
        "total_without_vat"        => money(amounts[:total_without_vat]),
        "total_vat_amount"         => { "value" => money(amounts[:total_vat_amount]),
"currency_code" => currency_code },
        "total_with_vat"           => money(amounts[:total_with_vat]),
        "amount_due_for_payment"   => money(amounts[:amount_due_for_payment])
      }.compact
    end

    # Optional repeated groups: nil (dropped by the caller's .compact) rather than an
    # empty array, so an invoice without them serializes exactly as it did before.
    def list_json(items, &block)
      items.map(&block) unless items.empty?
    end

    def normalize_line_allowance(allowance)
      a = allowance.transform_keys(&:to_sym)
      raise ArgumentError, "a line allowance requires an amount" if a[:amount].nil?

      {
        amount:      money_value(a[:amount]),
        base_amount: (money_value(a[:base_amount]) if a[:base_amount]),
        percent:     (dec(a[:percent]) if a[:percent]),
        reason:      a[:reason],
        reason_code: a[:reason_code]
      }.compact
    end

    def allowance_total(allowances)
      Array(allowances).sum(BigDecimal(0)) { |a| a[:amount] }
    end

    # Split `total` across `groups` (`[[category, rate], net]`) in whole cents, by largest
    # remainder: floor every exact share, then hand the leftover cents to the groups that
    # were cut by the most. The shares always add back up to `total`, and none is ever
    # more than a cent off its exact value.
    #
    # Every step is integer arithmetic on cents — the group bases are rounded to the cent
    # *before* the split, not after. A line net may carry sub-cent precision (quantity
    # 1.5 at 0.333 is 0.4995), and allocating over those raw values would make the shares
    # proportional to figures that appear nowhere on the document, so a reader could not
    # reproduce them from the printed base amounts. Integer `divmod` also keeps the floor
    # and remainder exact, so the leftover count is always in 0...groups.size.
    def allocate(total, groups)
      cents = (total * 100).round
      bases = groups.map { |(_key, net)| (net * 100).round }
      base  = bases.sum
      raise ArgumentError, "cannot spread a document-level discount over lines totalling 0" if base.zero?

      split = bases.map { |b| (cents * b).divmod(base) }
      whole = split.map { |(quotient, _remainder)| quotient }
      ranked(split, bases, groups).first(cents - whole.sum).each { |i| whole[i] += 1 }
      whole.map { |c| BigDecimal(c) / 100 }
    end

    # Who gets the leftover cents: the groups cut the most, by descending remainder. Ties
    # break on the group itself — bigger base, then higher VAT rate — never on position,
    # so reordering the lines cannot move a cent from one rate to another.
    def ranked(split, bases, groups)
      groups.each_index.sort_by { |i| [-split[i].last, -bases[i], -groups[i].first.last] }
    end

    # A monetary amount, held at the precision it will be *printed* at.
    #
    # EN 16931 caps monetary business terms at 2 decimals, so a line net (BT-131) that
    # was never rounded is not a figure the document can carry. Rounding at the boundary
    # rather than at serialization is what makes BT-106 equal the sum of the printed
    # BT-131s (BR-CO-10) instead of merely landing near it: `round(SUM x)` and
    # `SUM round(x)` disagree, and sub-cent nets are routine — 1.5 units at 0.333, or any
    # markup-derived unit price.
    def money_value(value)
      dec(value).round(2)
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
