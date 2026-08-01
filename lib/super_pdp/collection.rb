# frozen_string_literal: true

module SuperPdp
  # Wraps a cursor-paginated list response of the shape:
  #   { "data" => [ ... ], "has_more" => true|false }
  #
  # SUPER PDP uses cursor pagination via `starting_after_id` / `ending_before_id`.
  # This object is Enumerable over the current page's records and exposes the cursor
  # needed to fetch the next page.
  class Collection
    include Enumerable

    attr_reader :data, :has_more

    def initialize(data:, has_more: false)
      @data = Array(data)
      @has_more = has_more ? true : false
    end

    def each(&block)
      @data.each(&block)
    end

    def empty?
      @data.empty?
    end

    def size
      @data.size
    end
    alias length size
    # NOTE: no `count` alias — Enumerable#count already handles the no-arg, argument,
    # and block forms (e.g. `collection.count { |i| i.outgoing? }`). Aliasing it to
    # #size would silently ignore the block.

    def has_more?
      @has_more
    end

    # Id to pass as `starting_after_id` to fetch the next page (nil if no next page).
    def next_cursor
      return nil unless has_more?

      last = @data.last
      if last.respond_to?(:id)
        last.id
      else
        (last.is_a?(Hash) ? last["id"] : nil)
      end
    end

    def to_a
      @data
    end

    # Build a Collection from a raw API body + a record builder block.
    # The body is either the { "data" => [...], "has_more" => bool } envelope or a
    # bare array; anything else (e.g. a lone object) yields an empty collection rather
    # than coercing a Hash into [[k, v], ...] pairs via Array().
    def self.from(body, &builder)
      if body.is_a?(Hash) && body.key?("data")
        new(data: Array(body["data"]).map(&builder), has_more: body["has_more"])
      elsif body.is_a?(Array)
        new(data: body.map(&builder), has_more: false)
      else
        new(data: [], has_more: false)
      end
    end
  end
end
