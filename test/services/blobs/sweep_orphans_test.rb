require "test_helper"

class Blobs::SweepOrphansTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("simple_drive_sweep"))
    @backend = Storage::LocalBackend.new(root: @root)
  end

  teardown { FileUtils.rm_rf(@root) }

  test "deletes the objects of stale pending uploads and their rows" do
    key = orphan(age: 2.hours)

    result = Blobs::SweepOrphans.new(backend: @backend).call

    assert_equal [ 1, 0 ], [ result.removed, result.failed ]
    assert_raises(Storage::NotFound) { @backend.read(key) }
    assert_equal 0, PendingUpload.count
  end

  test "leaves uploads younger than the grace period alone, since they may still be running" do
    key = orphan(age: 10.minutes)

    result = Blobs::SweepOrphans.new(backend: @backend, older_than: 1.hour).call

    assert_equal 0, result.removed
    assert_equal "bytes", @backend.read(key)
    assert_equal 1, PendingUpload.count
  end

  test "never deletes an object that a blob points to" do
    key = orphan(age: 2.hours)
    Blob.create!(identifier: "kept", size: 5, storage_backend: "local", storage_key: key)

    Blobs::SweepOrphans.new(backend: @backend).call

    assert_equal "bytes", @backend.read(key)
    assert_equal 0, PendingUpload.count
  end

  test "keeps the row when the object cannot be deleted, so the next run retries" do
    key = orphan(age: 2.hours)
    @backend.define_singleton_method(:delete) { |_key| raise Storage::Error, "disk unavailable" }

    result = Blobs::SweepOrphans.new(backend: @backend).call

    assert_equal [ 0, 1 ], [ result.removed, result.failed ]
    assert_equal [ key ], PendingUpload.pluck(:storage_key)
  end

  test "a row whose object was never written is simply cleared" do
    PendingUpload.create!(storage_key: Storage::Backend.generate_key, storage_backend: "local", created_at: 2.hours.ago)

    assert_equal 1, Blobs::SweepOrphans.new(backend: @backend).call.removed
    assert_equal 0, PendingUpload.count
  end

  test "reports but does not touch pending uploads of other backends" do
    PendingUpload.create!(storage_key: Storage::Backend.generate_key, storage_backend: "s3", created_at: 2.hours.ago)

    result = Blobs::SweepOrphans.new(backend: @backend).call

    assert_equal [ 0, 1 ], [ result.removed, result.other_backends ]
    assert_equal 1, PendingUpload.count
  end

  private

  def orphan(age:)
    key = Storage::Backend.generate_key
    @backend.write(key, "bytes".b)
    PendingUpload.create!(storage_key: key, storage_backend: "local", created_at: age.ago)
    key
  end
end
