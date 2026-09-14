require "test_helper"

class Blobs::RetrieveTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("simple_drive_retrieve"))
    @backend = Storage::LocalBackend.new(root: @root)
    @retrieve = Blobs::Retrieve.new(backend: @backend)
  end

  teardown { FileUtils.rm_rf(@root) }

  test "returns the metadata together with the stored bytes" do
    stored = Blobs::Store.new(backend: @backend, max_bytes: 64).call(identifier: "photo", data: "AQID")

    result = @retrieve.call("photo")

    assert_equal stored, result.blob
    assert_equal "\x01\x02\x03".b, result.data
  end

  test "raises not found for an unknown identifier" do
    error = assert_raises(Blobs::NotFound) { @retrieve.call("missing") }
    assert_equal "No blob with this id exists", error.message
  end

  test "refuses to serve a blob stored by another backend" do
    Blob.create!(identifier: "elsewhere", size: 1, storage_backend: "database",
                 storage_key: Storage::Backend.generate_key)

    error = assert_raises(Blobs::BackendMismatch) { @retrieve.call("elsewhere") }
    assert_match(/stored by the database backend but local is configured/, error.message)
  end

  test "surfaces a backend that lost the object as a storage error" do
    blob = Blobs::Store.new(backend: @backend, max_bytes: 64).call(identifier: "lost", data: "AQID")
    @backend.delete(blob.storage_key)

    assert_raises(Storage::NotFound) { @retrieve.call("lost") }
  end
end
