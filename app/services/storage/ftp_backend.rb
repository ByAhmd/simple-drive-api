require "net/ftp"
require "stringio"

module Storage
  # Stores objects on an FTP server, one file per key below a configured
  # directory. A connection is opened per operation and closed afterwards;
  # passive mode is the default because it works through NAT and container
  # port mappings. Uploads go to a temporary name and are renamed into place
  # so that a partial transfer never appears under the final name.
  class FtpBackend < Backend
    OPEN_TIMEOUT = 5
    TRANSPORT_ERRORS = [
      Net::FTPError, SocketError, SystemCallError, IOError, EOFError, Timeout::Error, OpenSSL::SSL::SSLError
    ].freeze

    def self.from_settings(settings)
      boolean = ActiveModel::Type::Boolean.new
      new(
        host: settings[:host],
        port: Integer(settings.fetch(:port, 21)),
        username: settings[:username],
        password: settings[:password],
        root: settings[:root],
        passive: boolean.cast(settings.fetch(:passive, true)),
        tls: boolean.cast(settings.fetch(:tls, false)),
        timeout: Integer(settings.fetch(:timeout_seconds, 30))
      )
    end

    def initialize(host:, username:, password:, root: nil, port: 21, passive: true, tls: false, timeout: 30)
      { "FTP_HOST" => host, "FTP_USERNAME" => username, "FTP_PASSWORD" => password }.each do |env_name, value|
        raise SimpleDrive::ConfigurationError, "#{env_name} must be set" if value.blank?
      end

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
        ftp.storbinary("STOR #{key}.tmp", StringIO.new(data), Net::FTP::DEFAULT_BLOCKSIZE)
        ftp.rename("#{key}.tmp", key)
      end
    end

    def read(key)
      validate_key!(key)
      session do |ftp|
        ftp.getbinaryfile(key, nil)
      rescue Net::FTPPermError
        # 550 is the server's answer both for a missing file and for one it
        # refuses to serve; either way there is no object to return.
        raise NotFound, "no object stored under key #{key}"
      end
    end

    def delete(key)
      validate_key!(key)
      session do |ftp|
        ftp.delete(key)
      rescue Net::FTPPermError
        nil
      end
    end

    private

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
      ftp.mkdir(@root)
      ftp.chdir(@root)
    end
  end
end
