require "test_helper"

class Storage::LocalBackendTest < ActiveSupport::TestCase
  include StorageBackendContract

  setup do
    @root = Pathname(Dir.mktmpdir("simple_drive_test"))
    @backend = Storage::LocalBackend.new(root: @root)
  end

  teardown { FileUtils.rm_rf(@root) }

  attr_reader :backend

  test "reports its name" do
    assert_equal "local", backend.name
  end

  test "requires a root directory" do
    error = assert_raises(SimpleDrive::ConfigurationError) { Storage::LocalBackend.from_settings({ root: "" }) }
    assert_match(/LOCAL_STORAGE_PATH/, error.message)
  end

  test "resolves a relative root from the application root" do
    backend = Storage::LocalBackend.new(root: "tmp/test_storage")
    key = Storage::Backend.generate_key
    backend.write(key, "relative".b)

    assert_predicate Rails.root.join("tmp/test_storage", key[0, 2], key[2, 2], key), :file?
  end

  test "keeps files below the root in two levels of prefix directories" do
    key = Storage::Backend.generate_key
    backend.write(key, "layout".b)

    files = Dir.glob(@root.join("**/*")).select { |path| File.file?(path) }
    assert_equal [ @root.join(key[0, 2], key[2, 2], key).to_s ], files
  end

  test "creates the root directory on first write" do
    FileUtils.rm_rf(@root)

    backend.write(Storage::Backend.generate_key, "created".b)

    assert_predicate @root, :directory?
  end

  test "leaves no temporary file behind" do
    backend.write(Storage::Backend.generate_key, "clean".b)

    assert_empty Dir.glob(@root.join("**/*.tmp"))
  end

  test "rejects keys that are not application-generated" do
    [ "../../etc/passwd", "..\\..\\secret", "/etc/passwd", "plain-name", "", nil,
      "#{Storage::Backend.generate_key}/../x" ].each do |key|
      assert_raises(ArgumentError, "expected #{key.inspect} to be rejected") { backend.write(key, "x".b) }
      assert_raises(ArgumentError) { backend.read(key) }
      assert_raises(ArgumentError) { backend.delete(key) }
    end
    assert_empty Dir.glob(@root.join("**/*"))
  end

  test "translates filesystem errors on write into storage errors" do
    key = Storage::Backend.generate_key
    @root.join(key[0, 2]).dirname.mkpath
    File.write(@root.join(key[0, 2]), "a file where a directory is needed")

    assert_raises(Storage::Error) { backend.write(key, "blocked".b) }
  end

  test "translates filesystem errors on read into storage errors" do
    key = Storage::Backend.generate_key
    @root.join(key[0, 2], key[2, 2], key).mkpath

    error = assert_raises(Storage::Error) { backend.read(key) }
    assert_not_kind_of Storage::NotFound, error
  end
end
