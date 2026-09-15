require "test_helper"

class Blobs::StoreTest < ActiveSupport::TestCase
  HELLO = "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh".freeze # "Hello Simple Storage World!"

  setup do
    @root = Pathname(Dir.mktmpdir("simple_drive_store"))
    @backend = Storage::LocalBackend.new(root: @root)
    @store = Blobs::Store.new(backend: @backend, max_bytes: 64)
  end

  teardown { FileUtils.rm_rf(@root) }

  test "writes the bytes to the backend and records the metadata" do
    blob = @store.call(identifier: "hello", data: HELLO)

    assert_predicate blob, :persisted?
    assert_equal "hello", blob.identifier
    assert_equal 27, blob.size
    assert_equal "local", blob.storage_backend
    assert_match Storage::Backend::KEY_FORMAT, blob.storage_key
    assert_equal "Hello Simple Storage World!", @backend.read(blob.storage_key)
    assert_equal 0, PendingUpload.count
  end

  test "preserves binary data exactly" do
    bytes = (0..255).map(&:chr).join.b
    store = Blobs::Store.new(backend: @backend, max_bytes: 1024)

    blob = store.call(identifier: "bin", data: Base64.strict_encode64(bytes))

    assert_equal 256, blob.size
    assert_equal bytes, @backend.read(blob.storage_key)
  end

  test "accepts empty data as a zero-byte blob" do
    blob = @store.call(identifier: "empty", data: "")

    assert_equal 0, blob.size
    assert_equal "", @backend.read(blob.storage_key)
  end

  test "ignores line breaks and spaces as MIME-style encoders produce them" do
    bytes = "x" * 61
    store = Blobs::Store.new(backend: @backend, max_bytes: 64)

    wrapped = store.call(identifier: "wrapped", data: Base64.encode64(bytes))
    crlf = store.call(identifier: "crlf", data: Base64.encode64(bytes).gsub("\n", "\r\n"))
    spaced = store.call(identifier: "spaced", data: "SGVs bG8=\t")

    assert_equal 61, wrapped.size
    assert_equal bytes, @backend.read(crlf.storage_key)
    assert_equal "Hello", @backend.read(spaced.storage_key)
  end

  test "rejects Base64 that is not strict" do
    [ "not base64!", "SGVsbG8", "SGVsbG8=====", "SGVsbG8=!", "-_-_", "====", "SGVsbG8\u00A0=" ].each do |data|
      error = assert_raises(Blobs::InvalidBase64, "expected #{data.inspect} to be rejected") do
        @store.call(identifier: "bad-#{data.hash}", data: data)
      end
      assert_kind_of Blobs::ValidationError, error
      assert_equal "data is not valid Base64", error.message
    end
    assert_equal 0, Blob.count
    assert_empty Dir.glob(@root.join("**/*")).select { |path| File.file?(path) }
  end

  test "rejects missing or non-string fields before touching storage" do
    { [ nil, HELLO ] => "id is required", [ 42, HELLO ] => "id must be a string",
      [ "x", nil ] => "data is required", [ "x", [ HELLO ] ] => "data must be a string" }.each do |(id, data), message|
      error = assert_raises(Blobs::ValidationError) { @store.call(identifier: id, data: data) }
      assert_equal message, error.message
    end
    assert_empty Dir.glob(@root.join("**/*"))
  end

  test "rejects invalid identifiers with the model's message" do
    error = assert_raises(Blobs::ValidationError) { @store.call(identifier: "", data: HELLO) }
    assert_equal "id can't be blank", error.message

    error = assert_raises(Blobs::ValidationError) { @store.call(identifier: "a\u0000b", data: HELLO) }
    assert_equal "id must not contain control characters", error.message
    assert_empty Dir.glob(@root.join("**/*"))
  end

  test "rejects data above the size limit after decoding" do
    data = Base64.strict_encode64("x" * 65)

    error = assert_raises(Blobs::PayloadTooLarge) { @store.call(identifier: "big", data: data) }
    assert_equal "data exceeds the maximum blob size of 64 bytes", error.message
    assert_empty Dir.glob(@root.join("**/*"))
  end

  test "rejects oversized data from its encoded length without decoding it" do
    Base64.stub(:strict_decode64, ->(_) { flunk "should not decode" }) do
      assert_raises(Blobs::PayloadTooLarge) { @store.call(identifier: "big", data: "A" * 200) }
    end
  end

  test "accepts data exactly at the size limit" do
    blob = @store.call(identifier: "max", data: Base64.strict_encode64("x" * 64))

    assert_equal 64, blob.size
  end

  test "reports a duplicate identifier without writing to the backend" do
    @store.call(identifier: "dup", data: HELLO)
    files_before = Dir.glob(@root.join("**/*"))

    error = assert_raises(Blobs::DuplicateIdentifier) { @store.call(identifier: "dup", data: HELLO) }
    assert_equal "A blob with this id already exists", error.message
    assert_equal files_before, Dir.glob(@root.join("**/*"))
    assert_equal 1, Blob.count
  end

  test "resolves a race on the same identifier through the unique index and cleans up" do
    @store.call(identifier: "race", data: HELLO)

    # Pretend the existence check ran before the other request committed.
    Blob.stub(:exists?, false) do
      assert_raises(Blobs::DuplicateIdentifier) { @store.call(identifier: "race", data: "b3RoZXI=") }
    end

    assert_equal 1, Blob.count
    assert_equal 1, Dir.glob(@root.join("**/*")).count { |path| File.file?(path) }
    assert_equal "Hello Simple Storage World!", @backend.read(Blob.find_by!(identifier: "race").storage_key)
    assert_equal 0, PendingUpload.count
  end

  test "leaves no metadata behind when the backend write fails" do
    failing = Class.new(Storage::Backend) do
      def name = "failing"
      def write(_key, _data) = raise(Storage::Error, "disk on fire")
      def delete(_key) = nil
    end.new

    assert_raises(Storage::Error) { Blobs::Store.new(backend: failing, max_bytes: 64).call(identifier: "x", data: HELLO) }
    assert_equal 0, Blob.count
    assert_equal 0, PendingUpload.count
  end

  test "removes the bytes of a write that failed after the backend had stored them" do
    # An S3 PUT can time out on the client after the server stored the object.
    @backend.define_singleton_method(:write) { |key, data| super(key, data); raise Storage::Error, "read timeout" }

    assert_raises(Storage::Error) { @store.call(identifier: "late", data: HELLO) }

    assert_empty Dir.glob(@root.join("**/*")).select { |path| File.file?(path) }
    assert_equal 0, Blob.count
    assert_equal 0, PendingUpload.count
  end

  test "a process that dies between writing and recording leaves a pending upload the sweep removes" do
    Blob.stub(:transaction, ->(*) { raise Interrupt }) do
      assert_raises(Interrupt) { @store.call(identifier: "crash", data: HELLO) }
    end

    pending = PendingUpload.sole
    assert_equal "Hello Simple Storage World!", @backend.read(pending.storage_key)
    assert_equal 0, Blob.count

    travel 2.hours do
      assert_equal 1, Blobs::SweepOrphans.new(backend: @backend).call.removed
    end

    assert_raises(Storage::NotFound) { @backend.read(pending.storage_key) }
    assert_equal 0, PendingUpload.count
  end

  test "removes the written object when recording the metadata fails" do
    record = Blob.new
    record.define_singleton_method(:save!) { raise ActiveRecord::StatementInvalid, "database gone" }

    Blob.stub(:new, ->(**attributes) { record.assign_attributes(attributes); record }) do
      assert_raises(ActiveRecord::StatementInvalid) { @store.call(identifier: "x", data: HELLO) }
    end

    assert_empty Dir.glob(@root.join("**/*")).select { |path| File.file?(path) }
    assert_equal 0, Blob.count
    assert_equal 0, PendingUpload.count
  end

  test "a failed cleanup is logged, keeps the pending upload for the sweep and does not mask the original error" do
    @store.call(identifier: "race", data: HELLO)
    @backend.define_singleton_method(:delete) { |_key| raise Storage::Error, "cannot delete" }
    log = StringIO.new

    Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
      Blob.stub(:exists?, false) do
        assert_raises(Blobs::DuplicateIdentifier) { @store.call(identifier: "race", data: HELLO) }
      end
    end

    assert_match(/Could not remove object \h{8}-[\h-]+ after a failed store; the orphan sweep will retry: cannot delete/,
                 log.string)
    assert_equal 1, PendingUpload.count
    assert_equal 1, Blob.count
  end
end
