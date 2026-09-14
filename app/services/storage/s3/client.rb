require "net/http"
require "uri"
require "digest"

module Storage
  module S3
    # Minimal S3 REST client on top of Net::HTTP: PUT, GET and DELETE of one
    # object, each request signed with Signature Version 4 by Signer.
    #
    # Supports path-style addressing (http://host/bucket/key, what MinIO and
    # most self-hosted services expect) and virtual-hosted-style addressing
    # (http://bucket.host/key, the AWS default). A new connection is opened
    # per request; the transport errors listed below become Storage::Error.
    class Client
      OPEN_TIMEOUT = 5
      NETWORK_ERRORS = [
        Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
        OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse
      ].freeze

      def initialize(endpoint:, bucket:, access_key_id:, secret_access_key:, region:, path_style:, timeout:)
        @endpoint = parse_endpoint(endpoint)
        @bucket = bucket
        @path_style = path_style
        @timeout = timeout
        @signer = Signer.new(access_key_id: access_key_id, secret_access_key: secret_access_key, region: region)
      end

      def put_object(key, body)
        perform(Net::HTTP::Put, key, body: body, headers: { "content-type" => "application/octet-stream" })
      end

      def get_object(key)
        perform(Net::HTTP::Get, key)
      end

      def delete_object(key)
        perform(Net::HTTP::Delete, key)
      end

      private

      def parse_endpoint(endpoint)
        uri = URI.parse(endpoint.to_s)
        unless uri.is_a?(URI::HTTP) && uri.host.present?
          raise SimpleDrive::ConfigurationError, "S3_ENDPOINT must be an http(s) URL, got #{endpoint.inspect}"
        end

        uri
      rescue URI::InvalidURIError
        raise SimpleDrive::ConfigurationError, "S3_ENDPOINT must be an http(s) URL, got #{endpoint.inspect}"
      end

      def perform(request_class, key, body: nil, headers: {})
        uri = object_uri(key)
        payload_hash = Digest::SHA256.hexdigest(body.to_s)
        signed_headers = headers.merge(
          "host" => host_header(uri),
          "x-amz-date" => Time.now.utc.strftime("%Y%m%dT%H%M%SZ"),
          "x-amz-content-sha256" => payload_hash
        )

        request = request_class.new(uri.path)
        signed_headers.each { |name, value| request[name] = value }
        request["authorization"] = @signer.authorization(
          method: request.method, path: uri.path, headers: signed_headers, payload_hash: payload_hash
        )
        request.body = body unless body.nil?

        connection(uri).start { |http| http.request(request) }
      rescue *NETWORK_ERRORS => e
        raise Error, "S3 request failed: #{e.class}: #{e.message}"
      end

      # The key is encoded once, per the S3 rules, and the encoded path is
      # both what is sent and what is signed.
      def object_uri(key)
        uri = @endpoint.dup
        encoded_key = Signer.uri_encode(key, encode_slash: false)
        if @path_style
          uri.path = "#{@endpoint.path.chomp('/')}/#{@bucket}/#{encoded_key}"
        else
          uri.host = "#{@bucket}.#{@endpoint.host}"
          uri.path = "#{@endpoint.path.chomp('/')}/#{encoded_key}"
        end
        uri
      end

      # Must match the Host header Net::HTTP sends: no port when it is the
      # scheme's default.
      def host_header(uri)
        uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      end

      def connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        http
      end
    end
  end
end
