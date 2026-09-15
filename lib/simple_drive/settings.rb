module SimpleDrive
  # Raised while booting when a required setting is missing or malformed.
  # Defined here because config/puma.rb loads this file on its own.
  class ConfigurationError < StandardError; end

  # Typed view of config/simple_drive.yml, built once in config/application.rb.
  # Values are checked here so that a misconfigured deployment fails while
  # booting rather than on its first request.
  class Settings
    DEFAULT_MAX_BLOB_BYTES = 10 * 1024 * 1024
    TOP_LEVEL_KEYS = %i[api_token storage_backend max_blob_bytes].freeze

    # The b64token grammar of RFC 6750: what BearerAuthentication accepts from
    # clients, and therefore the only tokens that can ever match.
    TOKEN_FORMAT = %r{\A[A-Za-z0-9\-._~+/]+=*\z}

    # Largest request body worth reading for a given blob size limit: the
    # Base64 form of the largest accepted blob (4 bytes per 3, rounded up),
    # room for MIME-style line breaks (a CRLF every 60 characters, the densest
    # common wrapping, is four bytes once JSON-escaped), and room for the
    # identifier and the JSON syntax. Shared with config/puma.rb, which
    # enforces a hard cap at the server.
    def self.max_request_body_bytes(max_blob_bytes)
      encoded = (max_blob_bytes + 2) / 3 * 4
      encoded + encoded / 15 + 16 * 1024
    end

    # Settings reach the application as strings from the environment. Blank
    # means "use the default" (pass default: nil to require a value), and
    # anything unparsable stops the boot. Plain Ruby, because config/puma.rb
    # calls these before Rails is loaded.
    def self.boolean(value, env_name, default:)
      return default if value.to_s.strip.empty?

      case value.to_s.strip.downcase
      when "true", "1" then true
      when "false", "0" then false
      else raise ConfigurationError, "#{env_name} must be true or false"
      end
    end

    def self.positive_integer(value, env_name, default:)
      return default if value.to_s.strip.empty? && default

      # Base 10 explicitly: Integer() alone would read "021" as octal 17.
      parsed = Integer(value.to_s.strip, 10, exception: false)
      raise ConfigurationError, "#{env_name} must be a positive integer" unless parsed&.positive?

      parsed
    end

    attr_reader :api_token, :storage_backend, :max_blob_bytes

    def initialize(options)
      options = options.to_h.symbolize_keys
      @api_token = required_string(options, :api_token, "SIMPLE_DRIVE_API_TOKEN",
                                   hint: "for local use, run bin/setup or copy .env.example to .env")
      unless TOKEN_FORMAT.match?(@api_token)
        raise ConfigurationError, "SIMPLE_DRIVE_API_TOKEN may only contain letters, digits, - . _ ~ + / and trailing ="
      end

      @storage_backend = required_string(options, :storage_backend, "STORAGE_BACKEND")
      @max_blob_bytes = self.class.positive_integer(options[:max_blob_bytes], "SIMPLE_DRIVE_MAX_BLOB_BYTES", default: nil)
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

    def required_string(options, key, env_name, hint: nil)
      value = options[key].to_s.strip
      raise ConfigurationError, [ "#{env_name} must be set", hint ].compact.join("; ") if value.empty?

      value
    end
  end
end
