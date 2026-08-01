# frozen_string_literal: true

module SuperPdp
  module Models
    # Lightweight, hash-backed model. The SUPER PDP API is still tagged `v1.beta`,
    # so models stay deliberately permissive: every attribute of the underlying
    # payload is reachable, and unknown fields never raise. Typed subclasses add
    # convenience accessors and predicates on top.
    class Base
      attr_reader :attributes

      def initialize(attributes = {})
        @attributes = (attributes || {}).transform_keys(&:to_s)
      end

      def [](key)
        @attributes[key.to_s]
      end

      def id
        self["id"]
      end

      def key?(key)
        @attributes.key?(key.to_s)
      end

      def to_h
        @attributes.dup
      end
      alias to_hash to_h

      def ==(other)
        other.is_a?(self.class) && other.attributes == attributes
      end

      def inspect
        "#<#{self.class.name} #{@attributes.inspect}>"
      end

      # Read arbitrary attributes as methods: invoice.external_id, company.formal_name, ...
      def method_missing(name, *args)
        key = name.to_s
        return @attributes[key] if @attributes.key?(key)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @attributes.key?(name.to_s) || super
      end
    end
  end
end
