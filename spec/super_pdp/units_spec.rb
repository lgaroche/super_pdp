# frozen_string_literal: true

RSpec.describe SuperPdp::Collection do
  let(:records) do
    [SuperPdp::Models::Invoice.new(id: 1, direction: "out"),
     SuperPdp::Models::Invoice.new(id: 2, direction: "in")]
  end

  it "honours a block passed to #count (Enumerable, not #size)" do
    collection = described_class.new(data: records)
    expect(collection.count).to eq(2)
    expect(collection.count { |i| i.direction == "in" }).to eq(1)
  end
end

RSpec.describe SuperPdp::Models::Base do
  it "#to_h returns a copy that cannot mutate the model" do
    model = described_class.new(id: 1, name: "ACME")
    snapshot = model.to_h
    snapshot["name"] = "MUTATED"
    expect(model["name"]).to eq("ACME")
  end
end
