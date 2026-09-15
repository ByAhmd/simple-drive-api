require "test_helper"

class PendingUploadTest < ActiveSupport::TestCase
  test "requires the storage key and backend" do
    assert_predicate PendingUpload.new(storage_key: Storage::Backend.generate_key, storage_backend: "local"), :valid?
    assert_not PendingUpload.new(storage_key: "", storage_backend: "local").valid?
    assert_not PendingUpload.new(storage_key: Storage::Backend.generate_key, storage_backend: nil).valid?
  end

  test "the database rejects a second row for the same storage key" do
    key = Storage::Backend.generate_key
    PendingUpload.create!(storage_key: key, storage_backend: "local")

    assert_raises(ActiveRecord::RecordNotUnique) do
      PendingUpload.new(storage_key: key, storage_backend: "local").save!(validate: false)
    end
  end
end
