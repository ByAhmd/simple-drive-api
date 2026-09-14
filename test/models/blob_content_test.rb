require "test_helper"

class BlobContentTest < ActiveSupport::TestCase
  test "requires a storage key" do
    assert_not BlobContent.new(storage_key: nil, data: "x").valid?
  end

  test "stores and reloads binary data unchanged" do
    bytes = (0..255).map(&:chr).join.b
    content = BlobContent.create!(storage_key: Storage::Backend.generate_key, data: bytes)

    reloaded = BlobContent.find(content.id).data
    assert_equal bytes, reloaded
    assert_equal Encoding::BINARY, reloaded.encoding
  end

  test "the database rejects duplicate storage keys" do
    key = Storage::Backend.generate_key
    BlobContent.create!(storage_key: key, data: "one")

    assert_raises(ActiveRecord::RecordNotUnique) { BlobContent.create!(storage_key: key, data: "two") }
  end

  test "the database rejects missing data" do
    assert_raises(ActiveRecord::NotNullViolation) do
      BlobContent.new(storage_key: Storage::Backend.generate_key, data: nil).save!(validate: false)
    end
  end
end
