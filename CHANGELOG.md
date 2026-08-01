# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

[Unreleased]: https://github.com/lgaroche/super_pdp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lgaroche/super_pdp/releases/tag/v0.1.0
