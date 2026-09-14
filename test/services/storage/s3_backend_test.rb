require "test_helper"
require "socket"

# Exercises the S3 backend against stubbed HTTP (WebMock): request shape,
# signing, and how each kind of response or transport failure is reported.
# test/services/storage/s3_backend_integration_test.rb runs the same backend
# against a real MinIO server.
class Storage::S3BackendTest < ActiveSupport::TestCase
  SETTINGS = {
    endpoint: "http://s3.example.test:9000",
    bucket: "drive",
    region: "eu-central-1",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "secretEXAMPLE",
    path_style: true
  }.freeze

  setup do
    @backend = Storage::S3Backend.new(**SETTINGS)
    @key = Storage::Backend.generate_key
    @object_url = "http://s3.example.test:9000/drive/#{@key}"
  end

  test "reports its name" do
    assert_equal "s3", @backend.name
  end

  test "uploads with a signed path-style PUT carrying the payload hash" do
    data = "hello\x00\xFFworld".b
    stub = stub_request(:put, @object_url).with(
      body: data,
      headers: { "Content-Type" => "application/octet-stream", "Host" => "s3.example.test:9000",
                 "X-Amz-Content-Sha256" => Digest::SHA256.hexdigest(data),
                 "X-Amz-Date" => /\A\d{8}T\d{6}Z\z/,
                 "Authorization" => %r{\AAWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/\d{8}/eu-central-1/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=\h{64}\z} }
    ).to_return(status: 200)

    @backend.write(@key, data)

    assert_requested stub
  end

  test "sends a signature that can be recomputed from the headers it sent" do
    sent = nil
    stub_request(:put, @object_url).with { |request| sent = request }.to_return(status: 200)

    @backend.write(@key, "verify me".b)

    signer = Storage::S3::Signer.new(**SETTINGS.slice(:access_key_id, :secret_access_key, :region))
    headers = %w[Content-Type Host X-Amz-Content-Sha256 X-Amz-Date].to_h { |name| [ name, sent.headers.fetch(name) ] }
    expected = signer.authorization(method: "PUT", path: "/drive/#{@key}", headers: headers,
                                    payload_hash: Digest::SHA256.hexdigest("verify me"))
    assert_equal expected, sent.headers["Authorization"]
  end

  test "uses virtual-hosted-style addressing when path style is off" do
    backend = Storage::S3Backend.new(**SETTINGS, path_style: false)
    stub = stub_request(:put, "http://drive.s3.example.test:9000/#{@key}")
             .with(headers: { "Host" => "drive.s3.example.test:9000" }).to_return(status: 200)

    backend.write(@key, "x".b)

    assert_requested stub
  end

  test "omits the port from the Host header when it is the scheme's default" do
    backend = Storage::S3Backend.new(**SETTINGS, endpoint: "https://s3.example.test", path_style: false)
    stub = stub_request(:put, "https://drive.s3.example.test/#{@key}")
             .with(headers: { "Host" => "drive.s3.example.test" }).to_return(status: 200)

    backend.write(@key, "x".b)

    assert_requested stub
  end

  test "places objects below the configured key prefix" do
    backend = Storage::S3Backend.new(**SETTINGS, key_prefix: "/blobs/")
    stub = stub_request(:get, "http://s3.example.test:9000/drive/blobs/#{@key}").to_return(status: 200, body: "p")

    assert_equal "p", backend.read(@key)
    assert_requested stub
  end

  test "downloads binary bodies unchanged" do
    data = (0..255).map(&:chr).join.b
    stub_request(:get, @object_url).to_return(status: 200, body: data)

    read = @backend.read(@key)

    assert_equal data, read
    assert_equal Encoding::BINARY, read.encoding
  end

  test "reports a missing object as not found" do
    stub_request(:get, @object_url).to_return(status: 404, body: s3_error("NoSuchKey"))

    assert_raises(Storage::NotFound) { @backend.read(@key) }
  end

  test "reports a missing bucket as a storage error, not as not found" do
    stub_request(:get, @object_url).to_return(status: 404, body: s3_error("NoSuchBucket"))

    error = assert_raises(Storage::Error) { @backend.read(@key) }
    assert_not_kind_of Storage::NotFound, error
    assert_match(/NoSuchBucket/, error.message)
  end

  test "reports access denied on upload with the S3 error code and request id" do
    stub_request(:put, @object_url)
      .to_return(status: 403, body: s3_error("AccessDenied"), headers: { "x-amz-request-id" => "REQ123" })

    error = assert_raises(Storage::Error) { @backend.write(@key, "x".b) }
    assert_match(/HTTP 403 \(AccessDenied, request id REQ123\)/, error.message)
    assert_no_match(/secretEXAMPLE/, error.message)
  end

  test "reports server errors as storage errors" do
    stub_request(:put, @object_url).to_return(status: 500, body: "")

    assert_raises(Storage::Error) { @backend.write(@key, "x".b) }
  end

  test "treats a redirect as a failure rather than following it" do
    stub_request(:get, @object_url).to_return(status: 301, body: s3_error("PermanentRedirect"))

    assert_raises(Storage::Error) { @backend.read(@key) }
  end

  test "delete succeeds on 204 and on 404" do
    stub_request(:delete, @object_url).to_return({ status: 204 }, { status: 404, body: s3_error("NoSuchKey") })

    assert_nothing_raised do
      @backend.delete(@key)
      @backend.delete(@key)
    end
  end

  test "delete failures are storage errors" do
    stub_request(:delete, @object_url).to_return(status: 500)

    assert_raises(Storage::Error) { @backend.delete(@key) }
  end

  test "treats a body shorter than its Content-Length as a failure, not as a short blob" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    # Net::HTTP retries an idempotent request once, so answer two connections.
    thread = Thread.new do
      2.times do
        socket = server.accept
        socket.readpartial(4096)
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort")
        socket.close
      end
    end
    WebMock.disable_net_connect!(allow: "127.0.0.1:#{port}")
    backend = Storage::S3Backend.new(**SETTINGS, endpoint: "http://127.0.0.1:#{port}")

    error = assert_raises(Storage::Error) { backend.read(@key) }
    assert_match(/EOFError/, error.message)
  ensure
    WebMock.disable_net_connect!
    server&.close
    thread&.join(5)
  end

  test "timeouts become storage errors" do
    stub_request(:put, @object_url).to_timeout

    error = assert_raises(Storage::Error) { @backend.write(@key, "x".b) }
    assert_match(/S3 request failed/, error.message)
  end

  test "connection failures become storage errors" do
    stub_request(:get, @object_url).to_raise(Errno::ECONNREFUSED)

    assert_raises(Storage::Error) { @backend.read(@key) }
  end

  test "rejects keys that are not application-generated without sending anything" do
    assert_raises(ArgumentError) { @backend.read("../other-bucket") }
    assert_raises(ArgumentError) { @backend.write("../x", "x".b) }
    assert_not_requested :any, /.*/
  end

  test "requires every connection setting" do
    Storage::S3Backend::REQUIRED_SETTINGS.each do |setting, env_name|
      error = assert_raises(SimpleDrive::ConfigurationError) { Storage::S3Backend.new(**SETTINGS, setting => "") }
      assert_match(/#{env_name}/, error.message)
    end
  end

  test "restricts the key prefix to characters that need no encoding" do
    [ "blobs", "a/b-c/d_e.f", "/lead/", "" ].each do |prefix|
      assert_nothing_raised { Storage::S3Backend.new(**SETTINGS, key_prefix: prefix) }
    end
    [ "with space", "a//b", "../up", "pre%fix", "ü" ].each do |prefix|
      assert_raises(SimpleDrive::ConfigurationError, "expected #{prefix.inspect} to be rejected") do
        Storage::S3Backend.new(**SETTINGS, key_prefix: prefix)
      end
    end
  end

  test "rejects bucket names S3 would not accept" do
    [ "b", "My-Bucket", "with space", "-leading", "a" * 64 ].each do |bucket|
      error = assert_raises(SimpleDrive::ConfigurationError, "expected #{bucket.inspect} to be rejected") do
        Storage::S3Backend.new(**SETTINGS, bucket: bucket)
      end
      assert_match(/S3_BUCKET must be/, error.message)
    end
  end

  test "treats a blank addressing style as the default and rejects junk settings" do
    backend = Storage::S3Backend.from_settings(SETTINGS.merge(path_style: "", timeout_seconds: ""))
    stub = stub_request(:get, @object_url).to_return(status: 200, body: "d")

    assert_equal "d", backend.read(@key)
    assert_requested stub
    assert_raises(SimpleDrive::ConfigurationError) { Storage::S3Backend.from_settings(SETTINGS.merge(path_style: "maybe")) }
    assert_raises(SimpleDrive::ConfigurationError) { Storage::S3Backend.from_settings(SETTINGS.merge(timeout_seconds: "soon")) }
  end

  test "requires an http(s) endpoint" do
    assert_raises(SimpleDrive::ConfigurationError) { Storage::S3Backend.new(**SETTINGS, endpoint: "minio:9000") }
    assert_raises(SimpleDrive::ConfigurationError) { Storage::S3Backend.new(**SETTINGS, endpoint: "not a url") }
  end

  test "builds from settings with string booleans and integer timeouts" do
    backend = Storage::S3Backend.from_settings(SETTINGS.merge(path_style: "false", timeout_seconds: "7"))
    stub = stub_request(:get, "http://drive.s3.example.test:9000/#{@key}").to_return(status: 200, body: "v")

    assert_equal "v", backend.read(@key)
    assert_requested stub
  end

  private

  def s3_error(code)
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>#{code}</Code><Message>msg</Message></Error>"
  end
end
