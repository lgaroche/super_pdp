# frozen_string_literal: true

require "rails/generators"

module SuperPdp
  module Generators
    # rails generate super_pdp:install
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a SUPER PDP initializer at config/initializers/super_pdp.rb"

      def copy_initializer
        template "super_pdp.rb", "config/initializers/super_pdp.rb"
      end
    end
  end
end
