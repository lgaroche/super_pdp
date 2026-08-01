# frozen_string_literal: true

module SuperPdp
  module Rails
    # Minimal Railtie. Configuration is expected via an initializer
    # (see `rails generate super_pdp:install`) reading ENV variables.
    class Railtie < ::Rails::Railtie
      config.super_pdp = ActiveSupport::OrderedOptions.new if defined?(ActiveSupport::OrderedOptions)

      initializer "super_pdp.configure" do |app|
        opts = app.config.respond_to?(:super_pdp) ? app.config.super_pdp : nil
        next if opts.nil?

        SuperPdp.configure do |c|
          c.client_id     = opts.client_id     if opts.client_id
          c.client_secret = opts.client_secret if opts.client_secret
          c.environment   = opts.environment   if opts.environment
          # Logger is opt-in: only wire one up if the host app explicitly sets it.
          # Defaulting to Rails.logger would enable Faraday request logging (URLs +
          # params) for every API call in production.
          c.logger        = opts.logger        if opts.logger
        end
      end
    end
  end
end
