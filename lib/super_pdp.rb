# frozen_string_literal: true

require "super_pdp/version"
require "super_pdp/errors"
require "super_pdp/configuration"
require "super_pdp/collection"
require "super_pdp/token_set"
require "super_pdp/invoice"

# Models
require "super_pdp/models/base"
require "super_pdp/models/invoice_event"
require "super_pdp/models/invoice"
require "super_pdp/models/company"
require "super_pdp/models/session"
require "super_pdp/models/directory_entry"
require "super_pdp/models/ereporting"

# HTTP / auth
require "super_pdp/oauth"
require "super_pdp/oauth/authorization_code"
require "super_pdp/refreshable_token"
require "super_pdp/connection"

# Resources
require "super_pdp/resources/base"
require "super_pdp/resources/sessions"
require "super_pdp/resources/companies"
require "super_pdp/resources/invoices"
require "super_pdp/resources/invoice_events"
require "super_pdp/resources/directory"
require "super_pdp/resources/ereporting"

require "super_pdp/client"

# Ruby client for the SUPER PDP e-invoicing API (French Plateforme Agréée).
module SuperPdp
  class << self
    # Convenience constructor: SuperPdp.new(client_id:, client_secret:)
    def new(**options)
      Client.new(**options)
    end
  end
end

require "super_pdp/rails/railtie" if defined?(Rails::Railtie)
