require "test_helper"

class Storage::DatabaseBackendTest < ActiveSupport::TestCase
  include StorageBackendContract

  def backend
    @backend ||= Storage::DatabaseBackend.from_settings({})
  end

  test "reports its name" do
    assert_equal "database", backend.name
  end

  test "keeps bytes in blob_contents and never touches the metadata table" do
    key = Storage::Backend.generate_key

    assert_difference("BlobContent.count", 1) do
      assert_no_difference("Blob.count") { backend.write(key, "bytes".b) }
    end
    assert_equal "bytes", BlobContent.find_by!(storage_key: key).data
  end

  test "delete removes the row" do
    key = Storage::Backend.generate_key
    backend.write(key, "bytes".b)

    assert_difference("BlobContent.count", -1) { backend.delete(key) }
  end

  test "translates database errors into storage errors" do
    key = Storage::Backend.generate_key
    backend.write(key, "first".b)

    assert_raises(Storage::Error) { backend.write(key, "second".b) }
  end
end
