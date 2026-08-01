# frozen_string_literal: true

module SuperPdp
  module Resources
    class Base
      def initialize(connection)
        @connection = connection
      end

      private

      attr_reader :connection

      def build(data, model_class)
        return nil if data.nil?

        model_class.new(data)
      end

      def build_collection(body, model_class)
        Collection.from(body) { |item| model_class.new(item) }
      end
    end
  end
end
