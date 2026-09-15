require "test_helper"
require "rake"

class BlobsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("blobs:sweep_orphans")
    @task = Rake::Task["blobs:sweep_orphans"]
    @task.reenable
  end

  test "sweep_orphans removes stale orphans of the configured backend and reports what it did" do
    backend = Storage.backend
    stale, fresh = Storage::Backend.generate_key, Storage::Backend.generate_key
    [ stale, fresh ].each { |key| backend.write(key, "bytes".b) }
    PendingUpload.create!(storage_key: stale, storage_backend: "local", created_at: 45.minutes.ago)
    PendingUpload.create!(storage_key: fresh, storage_backend: "local", created_at: 5.minutes.ago)
    PendingUpload.create!(storage_key: Storage::Backend.generate_key, storage_backend: "s3", created_at: 2.hours.ago)

    output = with_env("OLDER_THAN_MINUTES" => "30") { capture_io { @task.invoke }.first }

    assert_includes output, "Removed 1 orphaned object(s) older than 30 minute(s) from the local backend."
    assert_includes output, "1 pending upload(s) belong to other backends"
    assert_raises(Storage::NotFound) { backend.read(stale) }
    assert_equal "bytes", backend.read(fresh)
  end

  test "sweep_orphans exits with an error when objects could not be removed" do
    key = Storage::Backend.generate_key
    PendingUpload.create!(storage_key: key, storage_backend: "local", created_at: 2.hours.ago)
    failing = Storage.backend
    failing.define_singleton_method(:delete) { |_key| raise Storage::Error, "disk unavailable" }

    _, stderr = capture_io do
      error = Storage.stub(:backend, failing) { assert_raises(SystemExit) { @task.invoke } }
      assert_not error.success?
    end

    assert_includes stderr, "1 object(s) could not be removed and will be retried on the next run"
    assert_equal [ key ], PendingUpload.pluck(:storage_key)
  end

  test "sweep_orphans rejects a malformed grace period" do
    error = with_env("OLDER_THAN_MINUTES" => "soon") do
      assert_raises(SimpleDrive::ConfigurationError) { @task.invoke }
    end

    assert_equal "OLDER_THAN_MINUTES must be a positive integer", error.message
  end

  private

  def with_env(values)
    saved = values.keys.to_h { |name| [ name, ENV[name] ] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end
end
