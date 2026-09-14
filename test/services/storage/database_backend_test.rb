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

  test "translates database errors on write into storage errors" do
    key = Storage::Backend.generate_key
    backend.write(key, "first".b)

    assert_raises(Storage::Error) { backend.write(key, "second".b) }
  end

  test "translates database errors on read and delete into storage errors" do
    failing = ->(*) { raise ActiveRecord::StatementInvalid, "database is locked" }

    BlobContent.stub(:find_by, failing) do
      error = assert_raises(Storage::Error) { backend.read(Storage::Backend.generate_key) }
      assert_not_kind_of Storage::NotFound, error
    end
    BlobContent.stub(:where, failing) do
      assert_raises(Storage::Error) { backend.delete(Storage::Backend.generate_key) }
    end
  end
end
