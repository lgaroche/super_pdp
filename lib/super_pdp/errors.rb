# frozen_string_literal: true

module SuperPdp
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # Raised before any HTTP call when the client is misconfigured.
  class ConfigurationError < Error; end

  # Raised when an OAuth2 token could not be obtained.
  class AuthenticationError < Error; end

  # Raised by Invoice#issue when local structural pre-validation fails (before any
  # HTTP call). Carries the list of human-readable problems in #errors.
  class InvalidInvoiceError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super("invoice failed structural validation: #{@errors.join('; ')}")
    end
  end

  # Base class for errors returned by the API (carry HTTP context).
  class APIError < Error
    attr_reader :status, :body, :headers, :errors

    def initialize(message = nil, status: nil, body: nil, headers: nil, errors: nil)
      @status  = status
      @body    = body
      @headers = headers
      @errors  = errors || []
      super(build_message(message))
    end

    private

    def build_message(message)
      base = message || self.class.name
      status ? "#{base} (HTTP #{status})" : base
    end
  end

  # 4xx
  class ClientError < APIError; end
  class BadRequestError < ClientError; end # 400
  class UnauthorizedError < ClientError; end       # 401
  class ForbiddenError < ClientError; end          # 403 (e.g. company_verification_status != verified)
  class NotFoundError < ClientError; end           # 404
  class ConflictError < ClientError; end           # 409
  class UnprocessableEntityError < ClientError; end # 422
  class RateLimitError < ClientError; end # 429

  # 5xx
  class ServerError < APIError; end
  class InternalServerError < ServerError; end     # 500
  class BadGatewayError < ServerError; end         # 502
  class ServiceUnavailableError < ServerError; end # 503
  class GatewayTimeoutError < ServerError; end     # 504

  # Raised when a response is not the JSON we expect (e.g. an HTML error page).
  class InvalidResponseError < APIError; end

  module ErrorFactory
    STATUS_MAP = {
      400 => BadRequestError,
      401 => UnauthorizedError,
      403 => ForbiddenError,
      404 => NotFoundError,
      409 => ConflictError,
      422 => UnprocessableEntityError,
      429 => RateLimitError,
      500 => InternalServerError,
      502 => BadGatewayError,
      503 => ServiceUnavailableError,
      504 => GatewayTimeoutError
    }.freeze

    module_function

    # Build the right error from an HTTP status + parsed body.
    def from_response(status:, body:, headers: nil)
      klass = STATUS_MAP[status] || (status >= 500 ? ServerError : ClientError)
      message, errors = extract(body)
      klass.new(message, status: status, body: body, headers: headers, errors: errors)
    end

    def extract(body)
      return [nil, []] unless body.is_a?(Hash)

      # SUPER PDP returns problem-style payloads; be lenient about the exact shape.
      message = body["message"] || body["error_description"] || body["error"] || body["title"] || body["detail"]
      errors  = body["errors"] || body["violations"] || []
      [message, Array(errors)]
    end
  end
end
