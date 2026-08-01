# frozen_string_literal: true

RSpec.describe SuperPdp::Collection do
  describe ".from" do
    it "reads the { data:, has_more: } envelope" do
      body = { "data" => [{ "id" => 1 }, { "id" => 2 }], "has_more" => true }
      collection = described_class.from(body) { |h| SuperPdp::Models::Invoice.new(h) }

      expect(collection.size).to eq(2)
      expect(collection).to all(be_a(SuperPdp::Models::Invoice))
      expect(collection.has_more?).to be(true)
    end

    it "accepts a bare array body (no envelope) as a single, final page" do
      collection = described_class.from([{ "id" => 1 }, { "id" => 2 }]) { |h| h }

      expect(collection.size).to eq(2)
      expect(collection.has_more?).to be(false)
      expect(collection.next_cursor).to be_nil
    end

    it "treats a non-paginated Hash without data as an empty collection" do
      collection = described_class.from({ "error" => "x" }) { |h| h }
      expect(collection).to be_empty
    end
  end

  describe "#next_cursor" do
    it "is nil when there is no next page" do
      expect(described_class.new(data: [{ "id" => 9 }], has_more: false).next_cursor).to be_nil
    end

    it "reads id from a model record" do
      records = [SuperPdp::Models::Invoice.new(id: 7)]
      expect(described_class.new(data: records, has_more: true).next_cursor).to eq(7)
    end

    it "reads \"id\" from a raw Hash record" do
      expect(described_class.new(data: [{ "id" => 42 }], has_more: true).next_cursor).to eq(42)
    end

    it "is nil when the last record has no id" do
      expect(described_class.new(data: [{ "name" => "x" }], has_more: true).next_cursor).to be_nil
    end
  end
end
