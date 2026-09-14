require "test_helper"

class BlobTest < ActiveSupport::TestCase
  def build(**overrides)
    Blob.new({ identifier: "hello", size: 27, storage_backend: "local",
               storage_key: Storage::Backend.generate_key }.merge(overrides))
  end

  test "is valid with an identifier, size, backend and key" do
    assert_predicate build, :valid?
  end

  test "requires an identifier" do
    blob = build(identifier: "")

    assert_not blob.valid?
    assert_includes blob.errors.full_messages, "id can't be blank"
  end

  test "limits the identifier to 1024 bytes, however many characters that is" do
    assert_predicate build(identifier: "a" * 1024), :valid?
    assert_predicate build(identifier: "€" * 341), :valid?

    [ "a" * 1025, "€" * 342, "😀" * 257 ].each do |identifier|
      blob = build(identifier: identifier)

      assert_not blob.valid?, "expected #{identifier.bytesize} bytes to be rejected"
      assert_includes blob.errors.full_messages, "id is too long (maximum is 1024 bytes)"
    end
  end

  test "rejects control characters in the identifier" do
    [ "null\u0000byte", "line\nbreak", "tab\there", "del\u007F" ].each do |identifier|
      blob = build(identifier: identifier)

      assert_not blob.valid?, "expected #{identifier.inspect} to be rejected"
      assert_includes blob.errors.full_messages, "id must not contain control characters"
    end
  end

  test "accepts path-like, spaced and non-ASCII identifiers" do
    [ "photos/2024/01/sunrise.jpg", "with spaces", "../../etc/passwd", "مرحبا", "a" ].each do |identifier|
      assert_predicate build(identifier: identifier), :valid?, "expected #{identifier.inspect} to be accepted"
    end
  end

  test "requires a non-negative integer size" do
    assert_not build(size: -1).valid?
    assert_not build(size: 1.5).valid?
    assert_not build(size: nil).valid?
    assert_predicate build(size: 0), :valid?
  end

  test "requires the backend name and storage key" do
    assert_not build(storage_backend: nil).valid?
    assert_not build(storage_key: "").valid?
  end

  test "the database rejects duplicate identifiers" do
    build.save!

    assert_raises(ActiveRecord::RecordNotUnique) { build.save!(validate: false) }
  end

  test "the database rejects duplicate storage keys" do
    key = Storage::Backend.generate_key
    build(identifier: "one", storage_key: key).save!

    assert_raises(ActiveRecord::RecordNotUnique) { build(identifier: "two", storage_key: key).save!(validate: false) }
  end

  test "the database rejects negative sizes" do
    assert_raises(ActiveRecord::StatementInvalid) { build(size: -1).save!(validate: false) }
  end

  test "identifiers are matched exactly" do
    build(identifier: "Hello").save!

    assert_nil Blob.find_by(identifier: "hello")
    assert_not_nil Blob.find_by(identifier: "Hello")
  end
end
