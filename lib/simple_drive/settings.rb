module SimpleDrive
  # Typed view of config/simple_drive.yml, built once in config/application.rb.
  # Values are checked here so that a misconfigured deployment fails while
  # booting rather than on its first request.
  class Settings
    DEFAULT_MAX_BLOB_BYTES = 10 * 1024 * 1024
    TOP_LEVEL_KEYS = %i[api_token storage_backend max_blob_bytes].freeze

    # Largest request body worth reading for a given blob size limit: the
    # Base64 form of the largest accepted blob (4 bytes per 3, rounded up),
    # room for MIME-style line breaks (CRLF every 60 characters, the densest
    # common wrapping), and room for the identifier and the JSON syntax.
    # Shared with config/puma.rb, which enforces the same limit at the
    # server level.
    def self.max_request_body_bytes(max_blob_bytes)
      encoded = (max_blob_bytes + 2) / 3 * 4
      encoded + encoded / 30 + 16 * 1024
    end

    attr_reader :api_token, :storage_backend, :max_blob_bytes

    def initialize(options)
      options = options.to_h.symbolize_keys
      @api_token = required_string(options, :api_token, "SIMPLE_DRIVE_API_TOKEN")
      @storage_backend = required_string(options, :storage_backend, "STORAGE_BACKEND")
      @max_blob_bytes = positive_integer(options, :max_blob_bytes, "SIMPLE_DRIVE_MAX_BLOB_BYTES")
      @backend_settings = options.except(*TOP_LEVEL_KEYS).transform_values { |section| section.to_h.symbolize_keys }
      freeze
    end

    # Settings section for one backend, e.g. +backend_settings(:s3)+.
    def backend_settings(name)
      @backend_settings.fetch(name.to_sym, {})
    end

    def max_request_body_bytes
      self.class.max_request_body_bytes(max_blob_bytes)
    end

    private

    def required_string(options, key, env_name)
      value = options[key].to_s.strip
      raise ConfigurationError, "#{env_name} must be set" if value.empty?

      value
    end

    def positive_integer(options, key, env_name)
      value = Integer(options[key].to_s, exception: false)
      raise ConfigurationError, "#{env_name} must be a positive integer" unless value&.positive?

      value
    end
  end
end
