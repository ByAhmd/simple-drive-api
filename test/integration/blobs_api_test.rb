require "test_helper"

class BlobsApiTest < ActionDispatch::IntegrationTest
  HELLO = "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh".freeze # "Hello Simple Storage World!", 27 bytes
  TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  test "stores a blob and returns its metadata" do
    post_blob id: "hello", data: HELLO

    assert_response :created
    assert_equal "application/json; charset=utf-8", response.content_type
    assert_equal %w[id size created_at], response.parsed_body.keys
    assert_equal "hello", response.parsed_body["id"]
    assert_equal "27", response.parsed_body["size"]
    assert_match TIMESTAMP, response.parsed_body["created_at"]
  end

  test "retrieves a stored blob with its Base64 data, size and UTC timestamp" do
    post_blob id: "hello", data: HELLO
    blob = Blob.find_by!(identifier: "hello")

    get_blob "hello"

    assert_response :ok
    assert_equal({ "id" => "hello", "data" => HELLO, "size" => "27",
                   "created_at" => blob.created_at.utc.iso8601 }, response.parsed_body)
    assert_match TIMESTAMP, response.parsed_body["created_at"]
  end

  test "the timestamp is rendered in UTC whatever the process time zone" do
    post_blob id: "zoned", data: HELLO
    blob = Blob.find_by!(identifier: "zoned")

    Time.use_zone("Asia/Riyadh") { get_blob "zoned" }

    assert_equal blob.created_at.utc.iso8601, response.parsed_body["created_at"]
  end

  test "round-trips arbitrary binary data" do
    bytes = Random.new(7).bytes(50_000) + (0..255).map(&:chr).join.b
    post_blob id: "binary", data: Base64.strict_encode64(bytes)
    assert_response :created
    assert_equal bytes.bytesize.to_s, response.parsed_body["size"]

    get_blob "binary"

    assert_equal bytes, Base64.strict_decode64(response.parsed_body["data"])
  end

  test "accepts line-wrapped Base64 as produced by MIME-style encoders" do
    bytes = Random.new(3).bytes(200)
    post_blob id: "wrapped", data: Base64.encode64(bytes)
    assert_response :created
    assert_equal "200", response.parsed_body["size"]

    get_blob "wrapped"

    assert_equal Base64.strict_encode64(bytes), response.parsed_body["data"]
  end

  test "accepts an empty blob" do
    post_blob id: "empty", data: ""
    assert_response :created
    assert_equal "0", response.parsed_body["size"]

    get_blob "empty"
    assert_equal "", response.parsed_body["data"]
  end

  test "accepts identifiers that look like paths, contain dots, spaces or non-ASCII characters" do
    [ "photos/2024/01/sunrise.jpg", "report.final.v2.pdf", "with spaces and (parens)", "ملف/صورة.png",
      "../../etc/passwd", "a?b=c&d", "trailing.json" ].each do |id|
      post_blob id: id, data: HELLO
      assert_response :created, "storing #{id.inspect}"

      get "/v1/blobs/#{id.split('/').map { |segment| CGI.escape(segment).gsub('+', '%20') }.join('/')}", headers: auth_headers
      assert_response :ok, "retrieving #{id.inspect}"
      assert_equal id, response.parsed_body["id"]
    end
  end

  test "never lets an identifier influence where bytes are stored" do
    root = Rails.root.join("tmp/test_storage")
    post_blob id: "../../escaped.txt", data: HELLO

    assert_response :created
    assert_not Rails.root.join("tmp/escaped.txt").exist?
    assert_not Rails.root.join("escaped.txt").exist?
    stored = Dir.glob(root.join("**/*")).select { |path| File.file?(path) }
    assert_equal 1, stored.size
    assert_match Storage::Backend::KEY_FORMAT, File.basename(stored.first)
  end

  test "ignores query-string parameters when storing" do
    post "/v1/blobs?id=evil&data=QUJD", params: { id: "good", data: HELLO }.to_json, headers: json_headers

    assert_response :created
    assert_equal "good", response.parsed_body["id"]
    assert_equal "27", response.parsed_body["size"]
    assert_nil Blob.find_by(identifier: "evil")
  end

  test "rejects a duplicate identifier" do
    post_blob id: "twice", data: HELLO
    post_blob id: "twice", data: HELLO

    assert_error :conflict, "conflict", "A blob with this id already exists"
    assert_equal 1, Blob.count
  end

  test "rejects invalid Base64" do
    [ "not base64!", "SGVsbG8", "SGVsbG8=!", "-_-_" ].each do |data|
      post_blob id: "bad", data: data

      assert_error :unprocessable_content, "validation_failed", "data is not valid Base64"
    end
    assert_equal 0, Blob.count
  end

  test "rejects a missing or non-string id" do
    post "/v1/blobs", params: { data: HELLO }.to_json, headers: json_headers
    assert_error :unprocessable_content, "validation_failed", "id is required"

    post "/v1/blobs", params: { id: 123, data: HELLO }.to_json, headers: json_headers
    assert_error :unprocessable_content, "validation_failed", "id must be a string"

    post_blob id: "", data: HELLO
    assert_error :unprocessable_content, "validation_failed", "id can't be blank"
  end

  test "rejects a missing or non-string data field" do
    post "/v1/blobs", params: { id: "x" }.to_json, headers: json_headers
    assert_error :unprocessable_content, "validation_failed", "data is required"

    post "/v1/blobs", params: { id: "x", data: { nested: true } }.to_json, headers: json_headers
    assert_error :unprocessable_content, "validation_failed", "data must be a string"
  end

  test "rejects an identifier that is too long or contains control characters" do
    post_blob id: "a" * 1025, data: HELLO
    assert_error :unprocessable_content, "validation_failed", "id is too long (maximum is 1024 bytes)"

    post_blob id: "€" * 342, data: HELLO
    assert_error :unprocessable_content, "validation_failed", "id is too long (maximum is 1024 bytes)"

    post_blob id: "tab\there", data: HELLO
    assert_error :unprocessable_content, "validation_failed", "id must not contain control characters"
  end

  test "accepts the longest multi-byte identifier and serves it back through its encoded path" do
    id = "€" * 341 # 1023 bytes, 3069 once percent-encoded
    post_blob id: id, data: HELLO
    assert_response :created

    get "/v1/blobs/#{ERB::Util.url_encode(id)}", headers: auth_headers

    assert_response :ok
    assert_equal id, response.parsed_body["id"]
  end

  test "rejects a body that is not JSON" do
    post "/v1/blobs", params: +"{\"id\": \"x\", \"data\": ", headers: json_headers

    assert_error :bad_request, "invalid_json", "Request body is not valid JSON"
  end

  test "rejects a request without a JSON content type" do
    post "/v1/blobs", params: { id: "x", data: HELLO }, headers: auth_headers

    assert_error :unsupported_media_type, "unsupported_media_type", "Content-Type must be application/json"
  end

  test "rejects a malformed content type header with the same 415" do
    post "/v1/blobs", params: { id: "x", data: HELLO }.to_json,
                      headers: auth_headers.merge("Content-Type" => "garbage")

    assert_error :unsupported_media_type, "unsupported_media_type", "Content-Type must be application/json"
  end

  test "answers a malformed Accept header with 406, not with a content type error" do
    get "/v1/blobs/missing", headers: auth_headers.merge("Accept" => "application")

    assert_error :not_acceptable, "not_acceptable", "Not Acceptable"
  end

  test "rejects a blob above the configured size limit" do
    limit = Rails.configuration.x.simple_drive.max_blob_bytes
    post_blob id: "big", data: Base64.strict_encode64("x" * (limit + 1))

    assert_error :content_too_large, "payload_too_large", "data exceeds the maximum blob size of #{limit} bytes"
    assert_equal 0, Blob.count
  end

  test "rejects a request body far above the limit before parsing it" do
    body_limit = Rails.configuration.x.simple_drive.max_request_body_bytes
    post "/v1/blobs", params: "{\"id\": \"huge\", \"data\": \"#{'A' * body_limit}\"}", headers: json_headers

    assert_error :content_too_large, "payload_too_large", "Request body exceeds the #{body_limit} byte limit"
  end

  test "returns not found for an unknown blob" do
    get_blob "missing"

    assert_error :not_found, "not_found", "No blob with this id exists"
  end

  test "returns not found as JSON for unknown routes" do
    get "/v1/nothing", headers: auth_headers

    assert_error :not_found, "not_found", "No route matches this path"
  end

  test "reports a failing storage backend as unavailable without details" do
    broken = Class.new(Storage::Backend) do
      def name = "local"
      def write(_key, _data) = raise(Storage::Error, "disk /srv/secret is full")
      def read(_key) = raise(Storage::Error, "disk /srv/secret is gone")
    end.new

    Storage.stub(:backend, broken) do
      post_blob id: "x", data: HELLO
      assert_error :service_unavailable, "storage_unavailable", "The storage backend is unavailable; try again later"
      assert_equal 0, Blob.count

      Blob.create!(identifier: "y", size: 1, storage_backend: "local", storage_key: Storage::Backend.generate_key)
      get_blob "y"
      assert_error :service_unavailable, "storage_unavailable", "The storage backend is unavailable; try again later"
    end
  end

  test "reports a blob stored by another backend as unavailable" do
    Blob.create!(identifier: "elsewhere", size: 1, storage_backend: "s3", storage_key: Storage::Backend.generate_key)

    get_blob "elsewhere"

    assert_error :service_unavailable, "storage_unavailable",
                 "The blob is not reachable through the configured storage backend"
  end

  private

  def assert_error(status, code, message)
    assert_response status
    assert_equal "application/json; charset=utf-8", response.content_type
    assert_equal({ "error" => { "code" => code, "message" => message } }, response.parsed_body)
  end
end
