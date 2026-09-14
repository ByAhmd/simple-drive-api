require "test_helper"

# Exercises the FTP backend against an in-memory stand-in for Net::FTP that
# answers like a real server (550 for missing files and directories).
# test/services/storage/ftp_backend_integration_test.rb runs the same backend
# against a real FTP server.
class Storage::FtpBackendTest < ActiveSupport::TestCase
  class FakeServer
    attr_reader :files, :directories, :commands

    def initialize
      @files = {}
      @directories = [ "/" ]
      @commands = []
      connect
    end

    # Every login starts in the home directory, as on a real server.
    def connect
      @cwd = "/"
      self
    end

    def chdir(dir)
      @commands << [ :chdir, dir ]
      raise Net::FTPPermError, "550 Failed to change directory." unless @directories.include?(absolute(dir))

      @cwd = absolute(dir)
    end

    def mkdir(dir)
      @commands << [ :mkdir, dir ]
      raise Net::FTPPermError, "550 Create directory operation failed." if @directories.include?(absolute(dir))

      @directories << absolute(dir)
    end

    def storbinary(command, io, _blocksize)
      name = command.delete_prefix("STOR ")
      @commands << [ :stor, name ]
      @files[absolute(name)] = io.read
    end

    def rename(from, to)
      @commands << [ :rename, from, to ]
      raise Net::FTPPermError, "550 RNFR command failed." unless @files.key?(absolute(from))

      @files[absolute(to)] = @files.delete(absolute(from))
    end

    def getbinaryfile(name, _localfile)
      @commands << [ :retr, name ]
      @files.fetch(absolute(name)) { raise Net::FTPPermError, "550 Failed to open file." }
    end

    def delete(name)
      @commands << [ :delete, name ]
      @files.delete(absolute(name)) { raise Net::FTPPermError, "550 Delete operation failed." }
    end

    private

    def absolute(name)
      name.start_with?("/") ? name : File.join(@cwd, name)
    end
  end

  SETTINGS = { host: "ftp.example.test", username: "drive", password: "s3cret-pass", root: "blobs" }.freeze

  setup do
    @server = FakeServer.new
    @sessions = []
    @backend = Storage::FtpBackend.new(**SETTINGS)
    @key = Storage::Backend.generate_key
  end

  def with_fake_server(&block)
    opener = lambda do |host, **options, &session|
      @sessions << [ host, options ]
      session.call(@server.connect)
    end
    Net::FTP.stub(:open, opener, &block)
  end

  test "reports its name" do
    assert_equal "ftp", @backend.name
  end

  test "uploads to a temporary name below the root and renames it into place" do
    data = (0..255).map(&:chr).join.b

    with_fake_server { @backend.write(@key, data) }

    assert_equal({ "/blobs/#{@key}" => data }, @server.files)
    assert_includes @server.commands, [ :stor, "#{@key}.tmp" ]
    assert_includes @server.commands, [ :rename, "#{@key}.tmp", @key ]
  end

  test "creates the root directory only when it is missing" do
    with_fake_server do
      @backend.write(@key, "one".b)
      @backend.write(Storage::Backend.generate_key, "two".b)
    end

    assert_equal 1, @server.commands.count { |command| command.first == :mkdir }
    assert_equal 2, @server.files.size
  end

  test "reads the stored bytes back" do
    with_fake_server do
      @backend.write(@key, "stored".b)

      assert_equal "stored", @backend.read(@key)
    end
  end

  test "reports a missing object as not found and a missing delete as nothing" do
    with_fake_server do
      assert_raises(Storage::NotFound) { @backend.read(@key) }
      assert_nothing_raised { @backend.delete(@key) }
    end
  end

  test "delete removes the file" do
    with_fake_server do
      @backend.write(@key, "gone".b)
      @backend.delete(@key)

      assert_empty @server.files
    end
  end

  test "opens one connection per operation with the configured options" do
    backend = Storage::FtpBackend.new(**SETTINGS, port: 2121, passive: false, tls: true, timeout: 7)

    with_fake_server do
      backend.write(@key, "x".b)
      backend.read(@key)
    end

    assert_equal 2, @sessions.size
    host, options = @sessions.first
    assert_equal "ftp.example.test", host
    assert_equal({ port: 2121, username: "drive", password: "s3cret-pass", passive: false, ssl: true,
                   open_timeout: 5, read_timeout: 7 }, options)
  end

  test "reports login failures as storage errors without the password" do
    Net::FTP.stub(:open, ->(*, **) { raise Net::FTPPermError, "530 Login incorrect." }) do
      error = assert_raises(Storage::Error) { @backend.read(@key) }

      assert_not_kind_of Storage::NotFound, error
      assert_match(/530 Login incorrect/, error.message)
      assert_no_match(/s3cret-pass/, error.message)
    end
  end

  test "reports connection failures and timeouts as storage errors" do
    [ Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::FTPConnectionError, EOFError ].each do |failure|
      Net::FTP.stub(:open, ->(*, **) { raise failure, "boom" }) do
        assert_raises(Storage::Error, "expected #{failure} to be translated") { @backend.write(@key, "x".b) }
      end
    end
  end

  test "rejects keys that are not application-generated without connecting" do
    with_fake_server do
      assert_raises(ArgumentError) { @backend.write("../etc/passwd", "x".b) }
      assert_raises(ArgumentError) { @backend.read("../other") }
    end

    assert_empty @sessions
  end

  test "requires host, username and password" do
    { host: "FTP_HOST", username: "FTP_USERNAME", password: "FTP_PASSWORD" }.each do |setting, env_name|
      error = assert_raises(SimpleDrive::ConfigurationError) { Storage::FtpBackend.new(**SETTINGS, setting => "") }
      assert_match(/#{env_name} must be set/, error.message)
    end
  end

  test "builds from settings with string values" do
    backend = Storage::FtpBackend.from_settings(host: "h", username: "u", password: "p", port: "2121",
                                                passive: "false", tls: "true", timeout_seconds: "9", root: "/data/")

    with_fake_server { backend.write(@key, "x".b) }

    assert_equal({ port: 2121, username: "u", password: "p", passive: false, ssl: true,
                   open_timeout: 5, read_timeout: 9 }, @sessions.first.last)
    assert_equal [ "/data/#{@key}" ], @server.files.keys
  end
end
