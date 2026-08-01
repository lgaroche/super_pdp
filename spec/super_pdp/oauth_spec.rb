# frozen_string_literal: true

RSpec.describe SuperPdp::OAuth do
  subject(:oauth) { described_class.new(SuperPdp.configuration) }

  it "fetches and caches an access token" do
    stub = stub_token(access_token: "abc", expires_in: 3600)

    expect(oauth.access_token).to eq("abc")
    expect(oauth.access_token).to eq("abc") # cached: no second HTTP call
    expect(stub).to have_been_requested.once
  end

  it "refetches once the token is expired" do
    stub_token(access_token: "first", expires_in: 1)
    expect(oauth.access_token).to eq("first")

    allow(Time).to receive(:now).and_return(Time.now + 7200)
    stub_token(access_token: "second", expires_in: 3600)
    expect(oauth.access_token).to eq("second")
  end

  it "raises AuthenticationError on a failed token request" do
    stub_token(status: 401)
    expect { oauth.access_token }.to raise_error(SuperPdp::AuthenticationError, /bad credentials/)
  end

  it "raises ConfigurationError when credentials are missing" do
    SuperPdp.configuration.client_secret = nil
    expect { oauth.access_token }.to raise_error(SuperPdp::ConfigurationError)
  end
end
