module Storage
  # Stores objects in an S3-compatible bucket (AWS S3, MinIO, DigitalOcean
  # Spaces, ...) using nothing but signed HTTP requests; see S3::Client and
  # S3::Signer. Object names are the application-generated keys, optionally
  # below a configured prefix.
  class S3Backend < Backend
    REQUIRED_SETTINGS = {
      endpoint: "S3_ENDPOINT",
      bucket: "S3_BUCKET",
      region: "S3_REGION",
      access_key_id: "S3_ACCESS_KEY_ID",
      secret_access_key: "S3_SECRET_ACCESS_KEY"
    }.freeze

    # Prefix segments are limited to characters that need no URI encoding (so
    # the object name on the wire is the prefix plus the key verbatim) and may
    # not start with a dot, which rules out "." and ".." segments.
    KEY_PREFIX_FORMAT = %r{\A[A-Za-z0-9_\-][A-Za-z0-9._\-]*(/[A-Za-z0-9_\-][A-Za-z0-9._\-]*)*\z}

    def self.from_settings(settings)
      new(
        **settings.slice(*REQUIRED_SETTINGS.keys),
        path_style: ActiveModel::Type::Boolean.new.cast(settings.fetch(:path_style, true)),
        key_prefix: settings[:key_prefix],
        timeout: Integer(settings.fetch(:timeout_seconds, 30))
      )
    end

    def initialize(endpoint: nil, bucket: nil, region: nil, access_key_id: nil, secret_access_key: nil,
                   path_style: true, key_prefix: nil, timeout: 30)
      settings = { endpoint:, bucket:, region:, access_key_id:, secret_access_key: }
      REQUIRED_SETTINGS.each do |setting, env_name|
        raise SimpleDrive::ConfigurationError, "#{env_name} must be set" if settings[setting].blank?
      end

      @client = S3::Client.new(**settings, path_style: path_style, timeout: timeout)
      @key_prefix = normalize_prefix(key_prefix)
    end

    def name
      "s3"
    end

    def write(key, data)
      response = client.put_object(object_key(key), data)
      raise Error, failure_message("upload", response) unless response.is_a?(Net::HTTPSuccess)
    end

    def read(key)
      response = client.get_object(object_key(key))
      case response
      when Net::HTTPSuccess
        response.body.to_s
      when Net::HTTPNotFound
        raise NotFound, "no object stored under key #{key}" if error_code(response) == "NoSuchKey"

        raise Error, failure_message("download", response)
      else
        raise Error, failure_message("download", response)
      end
    end

    def delete(key)
      response = client.delete_object(object_key(key))
      return if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNotFound)

      raise Error, failure_message("delete", response)
    end

    private

    attr_reader :client, :key_prefix

    def normalize_prefix(key_prefix)
      prefix = key_prefix.to_s.delete_prefix("/").delete_suffix("/")
      return prefix if prefix.empty? || KEY_PREFIX_FORMAT.match?(prefix)

      raise SimpleDrive::ConfigurationError,
            "S3_KEY_PREFIX segments may only contain letters, digits, '.', '_' and '-', and may not start with a dot"
    end

    def object_key(key)
      validate_key!(key)
      key_prefix.empty? ? key : "#{key_prefix}/#{key}"
    end

    # S3 error bodies are small XML documents; the error code and request id
    # are all that is worth surfacing in logs.
    def failure_message(operation, response)
      code = error_code(response) || "no error code"
      request_id = response["x-amz-request-id"] || "no request id"
      "S3 #{operation} failed with HTTP #{response.code} (#{code}, request id #{request_id})"
    end

    def error_code(response)
      response.body.to_s[%r{<Code>([^<]+)</Code>}, 1]
    end
  end
end
