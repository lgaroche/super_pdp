# frozen_string_literal: true

require "super_pdp"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before do
    SuperPdp.reset_configuration!
    SuperPdp.configure do |c|
      c.client_id     = "test-client-id"
      c.client_secret = "test-client-secret"
      c.environment   = :sandbox
    end
  end
end

# Stub the OAuth token endpoint with a token valid for `expires_in` seconds.
def stub_token(access_token: "test-access-token", expires_in: 3600, status: 200)
  body = if status == 200
           { access_token: access_token, token_type: "Bearer", expires_in: expires_in }
         else
           { error: "invalid_client", error_description: "bad credentials" }
         end
  stub_request(:post, "https://api.superpdp.tech/oauth2/token")
    .to_return(status: status, headers: { "Content-Type" => "application/json" },
               body: JSON.generate(body))
end

API = "https://api.superpdp.tech/v1.beta"
