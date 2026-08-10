# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Invoice notes (BG-1): `Invoice#add_note(note:, subject_code:)` fills BT-22 with an
  optional BT-21 subject code from UNTDID 4451. French invoicing carries several
  mandatory mentions this way rather than in dedicated fields — BR-FR-05 wants the frais
  de recouvrement (`PMT`), late-payment penalties (`PMD`) and early-settlement discount
  (`AAB`) mentions — so without it callers had to reach past `to_en_invoice` and mutate
  the payload to comply. Verified against the sandbox validator: adding the three
  mentions clears all three `BR-FR-05/BT-22` warnings.

## [0.2.0] - 2026-08-09

### Added
- Credit notes (avoirs): `Invoice#add_preceding_invoice_reference(reference:, issue_date:,
  type_code:)` fills BG-3, the link from a `type_code: 381` credit note to the invoice it
  corrects. `type_code` is the French extension EXT-FR-FE-02 (BR-FR-04) — the *preceding*
  document's type. BG-3 stays optional, matching the schema: a goodwill credit note with no
  parent invoice is structurally valid.
- Line-level allowances (BG-27): `add_line` takes `allowances:`, and BT-131 now defaults to
  `quantity * unit_price - allowances` instead of the bare product.
- Document-level allowances (BG-20): `add_document_level_allowance` for a single VAT rate,
  and `add_document_level_discount` for a remise globale spanning several — BT-95 is
  mandatory per BG-20 entry, so the latter splits the discount into one entry per
  `(category, rate)`, allocating each share in whole cents by largest remainder — the
  shares sum back to the discount exactly, none is more than a cent off its exact
  proportional value, and the split does not depend on the order the lines were added.
- `totals` exposes `sum_allowances_amount` (BT-107), emitted whenever document-level
  allowances are present.
- `SuperPdp::Invoice` — a structured builder for the EN 16931 `en_invoice` model:
  `add_line` helpers, automatic line-net / VAT-breakdown / totals computation, sensible
  defaults, and cheap structural pre-validation (`#validate` / `#valid?`).
- `invoices.convert` accepts a structured `invoice:` (an `Invoice` or `en_invoice` Hash)
  and sends it as JSON; `invoices.issue` pre-validates, converts and sends in one call.
- Factur-X output: `convert` / `issue` accept `pdf:` to embed a structured (or XML)
  invoice into a base PDF and send the rendered Factur-X document.
- `Connection#post_multipart` for mixed multipart bodies (in-memory + file parts).
- `SuperPdp::InvalidInvoiceError`, raised by `issue` on structural pre-validation failure.

### Fixed
- Monetary amounts are held at the 2 decimals EN 16931 allows them, rounded where they
  enter the document rather than where they are serialized. BT-106 previously summed
  unrounded line nets, so it could sit a cent away from the BT-131 figures printed on the
  lines it claims to total (BR-CO-10), and the VAT taxable base with it. Sub-cent line
  nets are routine — 1.5 units at 0.333, or any markup-derived unit price.
- Line and document discounts are no longer dropped from the submitted document. Previously
  the only way to express a line discount was to override `net_amount`, which `#validate`
  rejected because it reconciled against `quantity * unit_price`; document-level discounts
  could not be expressed at all, so invoices were submitted with pre-discount totals.
  `#validate` now reconciles against the EN 16931 formula, and `#vat_breakdown` /
  `#totals` account for document-level allowances (BT-109 = BT-106 − BT-107, and each
  rate's taxable base is net of its allocated share).
- Rails install generator is now discoverable under `lib/generators/super_pdp/install`
  (`rails generate super_pdp:install`).
- `Client#impersonating` reuses the existing token provider instead of rebuilding a
  fresh `client_credentials` OAuth, preserving the auth strategy and cached token.
- Multipart uploads no longer re-send a consumed (empty) file body on a 401 retry.
- `TokenSet.from_response` raises on a blank `access_token`; `RefreshableToken#refresh!`
  raises `ConfigurationError` up front when client credentials are missing.
- `Connection#full_path` only treats real absolute URLs (`https?://`) as pass-through.
- `Collection#count` honours a block again (dropped the `count` → `size` alias).
- `Models::Base#to_h` returns a copy, so callers can't mutate model state.
- `Collection.from` no longer coerces a lone Hash body into `[[k, v], ...]` pairs;
  non-envelope, non-array bodies now yield an empty collection.

### Changed
- The Railtie no longer defaults the logger to `Rails.logger` (avoids Faraday request
  logging in production); set `config.super_pdp.logger` explicitly to opt in.

### Removed
- Dropped the `multi_json` runtime dependency in favour of the standard-library `JSON`.

## [0.1.0]

- Initial release: Faraday-based client for the SUPER PDP e-invoicing API — OAuth2
  (`client_credentials` and `authorization_code`/PKCE with refresh rotation), invoice
  issuing/receiving, lifecycle events, directory lookups and e-reporting, models, an
  error taxonomy, and a Rails install generator.

[Unreleased]: https://github.com/lgaroche/super_pdp/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/lgaroche/super_pdp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lgaroche/super_pdp/releases/tag/v0.1.0
