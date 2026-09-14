require "openssl"
require "digest"

module Storage
  module S3
    # AWS Signature Version 4 for S3 (header-based authentication), written
    # from the protocol description in the S3 API reference. Given the request
    # line, the headers to sign and the payload hash it produces the value of
    # the Authorization header. The caller must send exactly the headers it
    # signed, because every one of them is part of the signature.
    class Signer
      ALGORITHM = "AWS4-HMAC-SHA256".freeze
      SERVICE = "s3".freeze
      TERMINATOR = "aws4_request".freeze

      # URI-encodes per the SigV4 rules: every byte except the unreserved
      # characters is percent-encoded with uppercase hex, and "/" is kept only
      # inside object keys.
      def self.uri_encode(value, encode_slash: true)
        pattern = encode_slash ? %r{[^A-Za-z0-9\-._~]} : %r{[^A-Za-z0-9\-._~/]}
        value.to_s.gsub(pattern) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
      end

      def initialize(access_key_id:, secret_access_key:, region:)
        @access_key_id = access_key_id
        @secret_access_key = secret_access_key
        @region = region
      end

      # +path+ is the already URI-encoded absolute path that goes on the wire;
      # +headers+ must include "host" and "x-amz-date" (names are matched
      # case-insensitively); +payload_hash+ is the hex SHA-256 of the body.
      def authorization(method:, path:, headers:, payload_hash:, query: {})
        canonical_headers = canonicalize_headers(headers)
        amz_date = canonical_headers.fetch("x-amz-date")
        date = amz_date[0, 8]
        scope = "#{date}/#{@region}/#{SERVICE}/#{TERMINATOR}"
        signed_headers = canonical_headers.keys.join(";")

        canonical_request = [
          method.to_s.upcase,
          path,
          canonical_query(query),
          canonical_headers.map { |name, value| "#{name}:#{value}\n" }.join,
          signed_headers,
          payload_hash
        ].join("\n")

        string_to_sign = [ ALGORITHM, amz_date, scope, Digest::SHA256.hexdigest(canonical_request) ].join("\n")
        signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key(date), string_to_sign)

        "#{ALGORITHM} Credential=#{@access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
      end

      private

      # Lowercase names, trimmed values with runs of whitespace collapsed,
      # sorted by name.
      def canonicalize_headers(headers)
        headers.to_h { |name, value| [ name.to_s.downcase, value.to_s.strip.gsub(/\s+/, " ") ] }.sort.to_h
      end

      def canonical_query(query)
        query.map { |name, value| [ self.class.uri_encode(name), self.class.uri_encode(value) ] }
             .sort
             .map { |name, value| "#{name}=#{value}" }
             .join("&")
      end

      def signing_key(date)
        [ date, @region, SERVICE, TERMINATOR ].reduce("AWS4#{@secret_access_key}") do |key, data|
          OpenSSL::HMAC.digest("SHA256", key, data)
        end
      end
    end
  end
end
