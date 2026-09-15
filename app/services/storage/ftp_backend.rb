require "net/ftp"
require "stringio"

module Storage
  # Stores objects on an FTP server, one file per key below a configured
  # directory. A connection is opened per operation and closed afterwards;
  # passive mode is the default because it works through NAT and container
  # port mappings. Uploads go to a temporary name and are renamed into place
  # so that a partial transfer never appears under the final name.
  class FtpBackend < Backend
    include SimpleDrive::FilteredOutput

    OPEN_TIMEOUT = 5
    TRANSPORT_ERRORS = [
      Net::FTPError, SocketError, SystemCallError, IOError, EOFError, Timeout::Error, OpenSSL::SSL::SSLError
    ].freeze

    def self.from_settings(settings)
      new(
        host: settings[:host],
        port: SimpleDrive::Settings.positive_integer(settings[:port], "FTP_PORT", default: 21),
        username: settings[:username],
        password: settings[:password],
        root: settings[:root],
        passive: SimpleDrive::Settings.boolean(settings[:passive], "FTP_PASSIVE", default: true),
        tls: SimpleDrive::Settings.boolean(settings[:tls], "FTP_TLS", default: false),
        timeout: SimpleDrive::Settings.positive_integer(settings[:timeout_seconds], "FTP_TIMEOUT_SECONDS", default: 30)
      )
    end

    def initialize(host:, username:, password:, root: nil, port: 21, passive: true, tls: false, timeout: 30)
      { "FTP_HOST" => host, "FTP_USERNAME" => username, "FTP_PASSWORD" => password }.each do |env_name, value|
        raise SimpleDrive::ConfigurationError, "#{env_name} must be set" if value.blank?
      end
      raise SimpleDrive::ConfigurationError, "FTP_PORT must be between 1 and 65535" unless (1..65_535).cover?(port)

      @host = host
      @root = root.to_s.delete_suffix("/")
      @options = { port: port, username: username, password: password, passive: passive, ssl: tls || nil,
                   open_timeout: OPEN_TIMEOUT, read_timeout: timeout }
    end

    def name
      "ftp"
    end

    def write(key, data)
      validate_key!(key)
      session do |ftp|
        ftp.storbinary("STOR #{temporary_name(key)}", StringIO.new(data), Net::FTP::DEFAULT_BLOCKSIZE)
        ftp.rename(temporary_name(key), key)
      end
    end

    def read(key)
      validate_key!(key)
      session do |ftp|
        ftp.getbinaryfile(key, nil)
      rescue Net::FTPPermError => e
        # 550 is the server's answer both for a missing file and for one it
        # refuses to serve; either way there is no object to return. Any other
        # permanent error is a real failure and is reported as one.
        raise unless file_unavailable?(e)

        raise NotFound, "no object stored under key #{key}"
      end
    end

    # Also removes the temporary file an interrupted upload may have left.
    def delete(key)
      validate_key!(key)
      session do |ftp|
        [ temporary_name(key), key ].each do |name|
          ftp.delete(name)
        rescue Net::FTPPermError => e
          raise unless file_unavailable?(e)
        end
      end
    end

    private

    def filtered_attributes
      { host: @host, root: @root, options: @options.merge(password: filtered(@options[:password])) }
    end

    def session
      Net::FTP.open(@host, **@options) do |ftp|
        enter_root(ftp)
        yield ftp
      end
    rescue *TRANSPORT_ERRORS => e
      raise Error, "FTP request failed: #{e.class}: #{e.message.strip}"
    end

    # The configured directory is created on first use when it is missing
    # (one level only; deeper paths must exist).
    def enter_root(ftp)
      return if @root.empty?

      ftp.chdir(@root)
    rescue Net::FTPPermError
      create_root(ftp)
      ftp.chdir(@root)
    end

    # A concurrent first upload can create the directory between the failed
    # chdir and this mkdir; the chdir that follows decides whether it exists.
    def create_root(ftp)
      ftp.mkdir(@root)
    rescue Net::FTPPermError => e
      raise unless file_unavailable?(e)
    end

    def file_unavailable?(error)
      error.message.start_with?("550")
    end

    def temporary_name(key)
      "#{key}.tmp"
    end
  end
end
