# frozen_string_literal: true

require_relative "lib/super_pdp/version"

Gem::Specification.new do |spec|
  spec.name        = "super_pdp"
  spec.version     = SuperPdp::VERSION
  spec.authors     = ["Louis Garoche"]
  spec.email       = ["louis@garoche.me"]

  spec.summary     = "Ruby client for the SUPER PDP e-invoicing API (French Plateforme Agréée)."
  spec.description = "A Faraday-based Ruby/Rails client for the SUPER PDP API (v1.beta): " \
                     "OAuth2 authentication, invoice issuing/receiving, lifecycle events, " \
                     "directory lookups and e-reporting (B2C transactions & payments)."
  spec.homepage    = "https://github.com/lgaroche/super_pdp"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "webmock", "~> 3.19"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "pry", "~> 0.14"
  spec.add_development_dependency "dotenv", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.60"
end
