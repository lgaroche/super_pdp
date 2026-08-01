# frozen_string_literal: true

require "digest"

TOKEN_URL = "https://api.superpdp.tech/oauth2/token"

def stub_token_grant(grant:, response:, status: 200)
  stub_request(:post, TOKEN_URL)
    .with(body: hash_including("grant_type" => grant))
    .to_return(status: status, headers: { "Content-Type" => "application/json" },
               body: JSON.generate(response))
end

RSpec.describe SuperPdp::OAuth::AuthorizationCode do
  describe ".pkce_pair" do
    it "produces a verifier and its S256 base64url challenge" do
      pair = described_class.pkce_pair
      expect(pair.verifier.length).to be_between(43, 128)
      expected = [Digest::SHA256.digest(pair.verifier)].pack("m0").tr("+/", "-_").delete("=")
      expect(pair.challenge).to eq(expected)
      expect(pair.challenge).not_to match(%r{[+/=]})
    end
  end

  describe ".authorize_url" do
    it "builds the authorize URL with PKCE, state and prefill params" do
      url = described_class.authorize_url(
        redirect_uri: "https://example.com/pdp/callback",
        code_challenge: "CH", state: "st8",
        superpdp_company_number: "732829320", superpdp_company_number_scheme: "fr_siren"
      )
      expect(url).to start_with("https://api.superpdp.tech/oauth2/authorize?")
      q = URI.decode_www_form(URI(url).query).to_h
      expect(q).to include(
        "response_type" => "code", "client_id" => "test-client-id",
        "redirect_uri" => "https://example.com/pdp/callback",
        "code_challenge" => "CH", "code_challenge_method" => "S256", "state" => "st8",
        "superpdp_company_number" => "732829320", "superpdp_company_number_scheme" => "fr_siren"
      )
    end
  end

  describe ".exchange_code" do
    it "exchanges a code for a TokenSet" do
      stub_token_grant(grant: "authorization_code",
                       response: { access_token: "AT", refresh_token: "RT", expires_in: 1800,
                                   token_type: "bearer", scope: "" })

      set = described_class.exchange_code(code: "code-1", code_verifier: "ver", redirect_uri: "https://cb")
      expect(set).to be_a(SuperPdp::TokenSet)
      expect(set.access_token).to eq("AT")
      expect(set.refresh_token).to eq("RT")
      expect(set.expired?).to be(false)
    end

    it "raises AuthenticationError on failure" do
      stub_token_grant(grant: "authorization_code", status: 400,
                       response: { error: "invalid_grant", error_description: "bad code" })
      expect {
        described_class.exchange_code(code: "x", code_verifier: "v", redirect_uri: "https://cb")
      }.to raise_error(SuperPdp::AuthenticationError, /bad code/)
    end

    it "raises AuthenticationError when a 200 response omits the access_token" do
      stub_token_grant(grant: "authorization_code", response: { refresh_token: "RT", expires_in: 1800 })
      expect {
        described_class.exchange_code(code: "x", code_verifier: "v", redirect_uri: "https://cb")
      }.to raise_error(SuperPdp::AuthenticationError, /did not return an access_token/)
    end
  end

  describe ".refresh" do
    it "returns a new TokenSet and carries rotation" do
      stub_token_grant(grant: "refresh_token",
                       response: { access_token: "AT2", refresh_token: "RT2", expires_in: 1800 })
      set = described_class.refresh(refresh_token: "RT1")
      expect(set.access_token).to eq("AT2")
      expect(set.refresh_token).to eq("RT2")
    end

    it "keeps the previous refresh token if the server omits one" do
      stub_token_grant(grant: "refresh_token", response: { access_token: "AT2", expires_in: 1800 })
      set = described_class.refresh(refresh_token: "RT1")
      expect(set.refresh_token).to eq("RT1")
    end
  end
end

RSpec.describe SuperPdp::RefreshableToken do
  it "returns the current access token without refreshing while valid" do
    set = SuperPdp::TokenSet.new(access_token: "valid", refresh_token: "r", expires_at: Time.now + 1800)
    provider = described_class.new(token_set: set)
    expect(provider.access_token).to eq("valid")
    expect(a_request(:post, TOKEN_URL)).not_to have_been_made
  end

  it "refreshes when expired and fires on_refresh with the rotated set" do
    set = SuperPdp::TokenSet.new(access_token: "old", refresh_token: "r1", expires_at: Time.now - 5)
    captured = nil
    provider = described_class.new(token_set: set, on_refresh: ->(s) { captured = s })
    stub_token_grant(grant: "refresh_token", response: { access_token: "new", refresh_token: "r2", expires_in: 1800 })

    expect(provider.access_token).to eq("new")
    expect(captured).to be_a(SuperPdp::TokenSet)
    expect(captured.refresh_token).to eq("r2")
  end

  it "raises when expired and no refresh token is available" do
    set = SuperPdp::TokenSet.new(access_token: "old", refresh_token: nil, expires_at: Time.now - 5)
    provider = described_class.new(token_set: set)
    expect { provider.access_token }.to raise_error(SuperPdp::AuthenticationError, /re-consent/)
  end

  it "raises ConfigurationError when client credentials are missing for a refresh" do
    config = SuperPdp::Configuration.new # no client_id / client_secret
    set = SuperPdp::TokenSet.new(access_token: "old", refresh_token: "r1", expires_at: Time.now - 5)
    provider = described_class.new(token_set: set, configuration: config)
    expect { provider.access_token }.to raise_error(SuperPdp::ConfigurationError, /client_id and client_secret/)
  end
end

RSpec.describe "SuperPdp::Client.from_tokens" do
  it "uses the stored access token for API calls" do
    client = SuperPdp::Client.from_tokens(access_token: "AT", refresh_token: "RT",
                                          expires_at: Time.now + 1800)
    stub_request(:get, "#{API}/companies/me")
      .with(headers: { "Authorization" => "Bearer AT" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate(id: 12_509, formal_name: "Tricatel"))

    expect(client.companies.me.formal_name).to eq("Tricatel")
  end

  it "auto-refreshes an expired token before the call and persists via on_refresh" do
    saved = nil
    client = SuperPdp::Client.from_tokens(access_token: "old", refresh_token: "RT1",
                                          expires_at: Time.now - 5,
                                          on_refresh: ->(s) { saved = s.to_h })
    stub_token_grant(grant: "refresh_token",
                     response: { access_token: "fresh", refresh_token: "RT2", expires_in: 1800 })
    stub_request(:get, "#{API}/companies/me")
      .with(headers: { "Authorization" => "Bearer fresh" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate(id: 12_509, formal_name: "Tricatel"))

    expect(client.companies.me.formal_name).to eq("Tricatel")
    expect(saved[:access_token]).to eq("fresh")
    expect(saved[:refresh_token]).to eq("RT2")
  end
end
