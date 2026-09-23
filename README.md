# super_pdp

Ruby client for the [SUPER PDP](https://www.superpdp.tech) e-invoicing API — a French
*Plateforme Agréée* (formerly PDP) for the 2026 e-invoicing reform.

Targets API **`v1.beta`**. Built on Faraday.

> Status: **v0.1 — validated end-to-end against the sandbox.** Covers both OAuth2 flows —
> machine-to-machine (`client_credentials`) and `authorization_code` (acting on behalf of
> clients, with rotating refresh tokens) — plus the core business surface: issuing/receiving
> invoices, lifecycle events, directory lookups and e-reporting. Third-party company enrollment
> via the accountant API (`POST /companies`) is not yet covered.

## Installation

```ruby
# Gemfile
gem "super_pdp", git: "https://github.com/lgaroche/super_pdp"
```

```sh
bundle install
```

Requires Ruby >= 3.1.

## Configuration

```ruby
SuperPdp.configure do |c|
  c.client_id     = ENV["SUPER_PDP_CLIENT_ID"]
  c.client_secret = ENV["SUPER_PDP_CLIENT_SECRET"]
  c.environment   = :sandbox        # or :production
end

client = SuperPdp::Client.new
```

In Rails: `rails generate super_pdp:install` writes `config/initializers/super_pdp.rb`.

Authentication uses the OAuth2 **client_credentials** grant. The token is fetched and cached
automatically, refreshed before expiry, and re-fetched once transparently on a 401.

### Acting on behalf of a client (authorization_code)

To onboard third-party companies (grey-label), use the OAuth 2.1 `authorization_code` flow.
The gem provides the building blocks; your app owns the callback route and token storage.

```ruby
# 1. Redirect the user (store pkce.verifier + state in the session)
pkce = SuperPdp::OAuth::AuthorizationCode.pkce_pair
url  = SuperPdp::OAuth::AuthorizationCode.authorize_url(
  redirect_uri: "https://yourapp.example/pdp/callback",
  code_challenge: pkce.challenge, state: state,
  superpdp_company_number: "732829320", superpdp_company_number_scheme: "fr_siren"
)
# ... user completes SUPER PDP's hosted KYC/KYB tunnel + consent ...

# 2. In your callback: exchange the code, then persist the TokenSet (encrypted)
tokens = SuperPdp::OAuth::AuthorizationCode.exchange_code(
  code: params[:code], code_verifier: session[:verifier],
  redirect_uri: "https://yourapp.example/pdp/callback"
)
PdpCredential.create!(company: current_company, **tokens.to_h)

# 3. Later, build a client from the stored tokens — refresh is automatic (rotating).
client = SuperPdp::Client.from_tokens(
  access_token:  cred.access_token,
  refresh_token: cred.refresh_token,
  expires_at:    cred.expires_at,
  on_refresh:    ->(set) { cred.update!(set.to_h) } # persist the rotated tokens!
)
client.invoices.received(limit: 50)
```

A single OAuth app onboards many client companies. `expires_in` is the **access** token TTL
(~30 min); the refresh token is long-lived and **rotates** on every refresh — always persist
the new one via `on_refresh`.

## Usage

### Preflight

```ruby
session = client.sessions.me
session.ready?  # => false until company_verification_status == "verified" (otherwise 403 elsewhere)
```

### Issue an invoice

If you already have a finished document, send it directly:

```ruby
client.invoices.create(file: "invoice.pdf", external_id: "INV-2026-001")          # Factur-X
client.invoices.create(content: ubl_xml, content_type: :xml, external_id: "X1")   # UBL/CII
```

Or build it from structured data — `SuperPdp::Invoice` assembles the EN 16931 model
(`en_invoice`), computes line nets / VAT breakdown / totals, runs cheap structural
pre-validation, then `issue` converts it to XML and sends it in one call:

```ruby
invoice = SuperPdp::Invoice.new(
  number: "INV-2026-001", issue_date: Date.today, currency_code: "EUR",
  seller: { name: "Burger Queen", vat_identifier: "FR44732829320",
            postal_address: { country_code: "FR", city: "Paris", post_code: "75001" },
            electronic_address: { scheme: "0009", value: "73282932000074" } },
  buyer:  { name: "Tricatel",
            postal_address: { country_code: "FR", city: "Lyon", post_code: "69002" } }
)
invoice.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20)
invoice.add_line(name: "Coffee",     quantity: 2,  unit_price: 5,   vat_rate: 5.5)

invoice.validate                       # => [] (structural checks; [] means OK)
client.invoices.issue(invoice, external_id: "INV-2026-001")
```

**Discounts and credit notes.** A line discount is an allowance (BG-27), not a lowered
net — BT-131 is `quantity × unit price − allowances`, and the builder derives it for you.
A remise globale is a document-level allowance (BG-20); because a VAT category is
mandatory on each entry, one spanning several rates is split into one entry per rate:

```ruby
invoice.add_line(name: "Consulting", quantity: 10, unit_price: 100, vat_rate: 20,
                 allowances: [{ amount: 150, percent: 15, base_amount: 1000, reason: "Remise" }])

invoice.add_document_level_discount(amount: 30, reason: "Remise globale")  # split across rates
invoice.add_document_level_allowance(amount: 30, vat_rate: 20)             # or one rate, explicit
```

`add_document_level_discount` allocates the split for you, in whole cents that sum back
to the discount exactly. If you already compute per-rate shares yourself — especially if
you store them and have shown the customer a VAT breakdown derived from them — emit each
with `add_document_level_allowance` rather than letting the gem re-derive: proportional
allocation depends on the rounding rule, and two defensible rules put the leftover cent
on different rates.

**French mandatory mentions.** Several are carried as invoice notes (BG-1) rather than in
dedicated fields. `BR-FR-05` wants three, and `BT-30` must identify the seller as a legal
entity — together they are the difference between a document the validator flags and one
it passes cleanly:

```ruby
invoice.add_note(note: "Frais de recouvrement pour retard de paiement : 40 €", subject_code: "PMT")
invoice.add_note(note: "Pénalités de retard : 3 × le taux d'intérêt légal",    subject_code: "PMD")
invoice.add_note(note: "Escompte pour paiement anticipé : néant",              subject_code: "AAB")

seller: { name: "Burger Queen", vat_identifier: "FR44732829320",
          legal_registration_identifier: { scheme: "0002", value: "732829320" }, ... }
```

**Bank details.** Where the buyer pays goes in the payment instructions (BG-16), one
BG-17 entry per account. Adding one defaults the means code (BT-81) to 58, SEPA credit
transfer; the invoice number is the usual transfer reference (BT-83):

```ruby
invoice = SuperPdp::Invoice.new(..., remittance_information: "INV-2026-001")
invoice.add_credit_transfer(account_identifier: "FR7630006000011234567890189",
                            account_name: "Burger Queen", service_provider_identifier: "AGRIFRPPXXX")
```

Leave `scheme:` at its empty default for an IBAN — any other value also lands in the CII
as a ProprietaryID.

A credit note (avoir) is `type_code: 381` referencing the invoice it corrects (BG-3):

```ruby
credit = SuperPdp::Invoice.new(number: "AV-2026-001", type_code: 381, ...)
credit.add_preceding_invoice_reference(reference: "INV-2026-001", type_code: 380)
```

`issue` raises `SuperPdp::InvalidInvoiceError` (carrying `#errors`) if the local
structural checks fail, before any HTTP call. Those checks are deliberately shallow
(required fields present, line nets and totals reconcile) — full EN 16931 conformance is
left to the server (`disable_pre_check:` on `create`/`issue`, and `invoices.validate`).

By default `issue` converts to UBL XML. To send a **Factur-X** PDF instead, pass a base
PDF (your visual layout) — the structured invoice is embedded into it as the machine-readable
XML:

```ruby
client.invoices.issue(invoice, pdf: "letterhead.pdf", external_id: "INV-2026-001")
```

### Receive invoices (polling)

There are no webhooks in the API contract yet, so reception is by polling:

```ruby
inbox = client.invoices.received(limit: 50)
inbox.each { |inv| puts "#{inv.id} #{inv.external_id}" }
inbox.next_cursor    # pass as starting_after_id: for the next page

# Acknowledge a received invoice (emittable codes: fr:204..fr:212; fr:204 = "Prise en charge")
client.invoice_events.create(invoice_id: inv.id, status_code: "fr:204")
```

### Directory

```ruby
client.directory.search_companies(number: "732829320")     # official French directory
client.directory.create(directory: "...", identifier: "...") # register a routing entry
```

### E-reporting

```ruby
# VAT regime drives the PPF schedule. One of: monthly, quarterly, simplified, vat_exemption.
client.companies.update_vat_regime("vat_exemption")

client.ereporting.create_transactions([{
  category_code: "TPS1", role_code: "SE", date: "2026-06-01", currency: "EUR",
  tax_exclusive_amount: "100.00", tax_total: "20.00",
  tax_subtotals: [{ tax_percent: "20", taxable_amount: "100.00", tax_total: "20.00" }]
}])
client.ereporting.create_payments([{ date: "2026-06-01",
                                     subtotals: [{ amount: "120.00", tax_percent: "20" }] }])

client.ereporting.preview(date: "2026-06-30", kind: "transaction", role_code: "SE")
client.ereporting.list      # declarations actually transmitted to the PPF, with status
```

## Errors

All raise subclasses of `SuperPdp::Error`. API errors (`SuperPdp::APIError`) carry `#status`,
`#body` and `#errors`. Notable: `ForbiddenError` (403) typically means the company is not yet
verified — check `client.sessions.me.ready?` first.

## Development

```sh
bin/setup
bundle exec rspec
cp .env.example .env   # then fill in SUPER_PDP_* credentials
bin/console            # loads .env; exposes `bq` and `tricatel` client helpers
```

The upstream OpenAPI specs are not vendored; see [docs/openapi/README.md](docs/openapi/README.md)
for where to download them (they are gitignored under `docs/openapi/`).

## Roadmap

- Webhooks, once exposed by SUPER PDP (reception is polling-only today)
- Optional `super_pdp-rails` companion (token model, callback controller, refresh job)

## License

MIT © Louis Garoche
