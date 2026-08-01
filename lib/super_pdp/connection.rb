# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"

module SuperPdp
  # Thin HTTP layer over Faraday. Injects the OAuth2 bearer token on every request,
  # parses JSON responses, maps errors and supports raw-body (PDF/XML) + multipart uploads.
  class Connection
    JSON_CONTENT_TYPE = "application/json"

    def initialize(configuration: SuperPdp.configuration, oauth: nil)
      @configuration = configuration
      @oauth = oauth || OAuth.new(configuration)
    end

    def get(path, params = {}, headers = {})
      request(:get, path, params: params, headers: headers)
    end

    def delete(path, params = {}, headers = {})
      request(:delete, path, params: params, headers: headers)
    end

    def post_json(path, body = {}, params: {}, headers: {})
      request(:post, path, params: params, json: body, headers: headers)
    end

    def patch_json(path, body = {}, params: {}, headers: {})
      request(:patch, path, params: params, json: body, headers: headers)
    end

    # POST raw bytes with an explicit content type (e.g. application/pdf, application/xml).
    def post_raw(path, raw_body, content_type:, params: {}, headers: {})
      request(:post, path, params: params, raw: raw_body,
                           headers: headers.merge("Content-Type" => content_type))
    end

    # POST a single file as multipart/form-data.
    #
    # The file is passed down as a {path:, mime:} descriptor (not a live FilePart) so the
    # multipart body can be rebuilt from scratch on a 401 retry — a FilePart's IO is read
    # to EOF on the first attempt and would otherwise re-send an empty file.
    def post_file(path, file_path, content_type: nil, field: "file", params: {}, headers: {})
      mime = content_type || mime_for(file_path)
      request(:post, path, params: params,
                           multipart: { field => { path: file_path, mime: mime } }, headers: headers)
    end

    # POST several multipart/form-data parts in one request. Each part is a descriptor:
    #   { path: "...", mime: "..." }  -> a file read from disk (FilePart)
    #   { data: "...", mime: "..." }  -> an in-memory string, e.g. JSON (ParamPart)
    # Like post_file, descriptors are rebuilt per attempt so a 401 retry is safe.
    def post_multipart(path, parts, params: {}, headers: {})
      request(:post, path, params: params, multipart: parts, headers: headers)
    end

    private

    # Performs the request, retrying once on a 401 (expired/revoked token).
    def request(method, path, params: {}, json: nil, raw: nil, multipart: nil, headers: {}, retried: false)
      response = connection.public_send(method) do |req|
        req.url(full_path(path))
        req.params.update(stringify(params)) unless params.nil? || params.empty?
        apply_headers(req, headers)

        if multipart
          req.headers["Content-Type"] = "multipart/form-data"
          # Build fresh parts per attempt so a retry doesn't re-send a consumed IO.
          req.body = multipart.transform_values { |part| multipart_part(part) }
        elsif !raw.nil?
          req.body = raw
        elsif !json.nil?
          req.headers["Content-Type"] = JSON_CONTENT_TYPE
          req.body = JSON.generate(json)
        end
      end

      handle(response)
    rescue UnauthorizedError
      raise if retried

      @oauth.invalidate!
      request(method, path, params: params, json: json, raw: raw,
                           multipart: multipart, headers: headers, retried: true)
    end

    # Turn a part descriptor into the right Faraday multipart object. Files stream from
    # disk (FilePart); in-memory data (e.g. a JSON invoice) goes as a ParamPart.
    def multipart_part(part)
      if part[:path]
        Faraday::Multipart::FilePart.new(part[:path], part[:mime])
      else
        Faraday::Multipart::ParamPart.new(part[:data], part[:mime])
      end
    end

    def handle(response)
      body = parse_body(response)

      return body if response.success?

      raise ErrorFactory.from_response(
        status: response.status,
        body: body,
        headers: response.headers
      )
    end

    def parse_body(response)
      raw = response.body
      return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

      content_type = response.headers["content-type"].to_s

      # Binary download (PDF/XML/zip): hand back the raw bytes untouched.
      return raw if binary?(content_type)

      if content_type.include?("json")
        JSON.parse(raw)
      elsif looks_like_html?(raw)
        raise InvalidResponseError.new(
          "Expected JSON but received an HTML response",
          status: response.status, body: nil, headers: response.headers
        )
      else
        raw
      end
    rescue JSON::ParserError
      raise InvalidResponseError.new(
        "Failed to parse JSON response",
        status: response.status, body: raw, headers: response.headers
      )
    end

    def apply_headers(req, headers)
      req.headers["Authorization"] = "Bearer #{@oauth.access_token}"
      req.headers["Accept"] = JSON_CONTENT_TYPE
      req.headers["User-Agent"] = @configuration.user_agent
      if (company = @configuration.impersonate_company)
        req.headers["X-Impersonate-Company"] = company.to_s
      end
      headers.each { |k, v| req.headers[k.to_s] = v }
    end

    def full_path(path)
      return path if path.start_with?("/#{SuperPdp::API_VERSION}/") || path.match?(%r{\Ahttps?://})

      "#{@configuration.api_prefix}/#{path.sub(%r{\A/}, '')}"
    end

    def connection
      @connection ||= Faraday.new(url: @configuration.base_url) do |f|
        f.request :multipart
        f.options.timeout = @configuration.timeout
        f.options.open_timeout = @configuration.open_timeout
        f.response(:logger, @configuration.logger, bodies: @configuration.debug) if @configuration.logger
        f.adapter Faraday.default_adapter
      end
    end

    def stringify(params)
      params.compact.transform_keys(&:to_s)
    end

    def binary?(content_type)
      content_type.include?("pdf") ||
        content_type.include?("octet-stream") ||
        content_type.include?("zip") ||
        content_type.include?("xml")
    end

    def looks_like_html?(raw)
      raw.is_a?(String) && raw.lstrip.start_with?("<!", "<html", "<HTML")
    end

    def mime_for(file_path)
      case File.extname(file_path).downcase
      when ".pdf" then "application/pdf"
      when ".xml" then "application/xml"
      when ".json" then "application/json"
      else "application/octet-stream"
      end
    end
  end
end
