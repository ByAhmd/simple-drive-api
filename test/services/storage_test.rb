require "test_helper"

class StorageTest < ActiveSupport::TestCase
  def settings(backend, **sections)
    SimpleDrive::Settings.new({ api_token: "t", storage_backend: backend, max_blob_bytes: 10 }.merge(sections))
  end

  test "builds the local backend from its settings section" do
    assert_instance_of Storage::LocalBackend, Storage.backend(settings("local", local: { root: "tmp/x" }))
  end

  test "builds the database backend" do
    assert_instance_of Storage::DatabaseBackend, Storage.backend(settings("database"))
  end

  test "builds the S3 backend from its settings section" do
    s3 = { endpoint: "http://localhost:9000", bucket: "bucket", region: "us-east-1",
           access_key_id: "k", secret_access_key: "s", path_style: "true", timeout_seconds: "5" }

    assert_instance_of Storage::S3Backend, Storage.backend(settings("s3", s3: s3))
  end

  test "builds the FTP backend from its settings section" do
    ftp = { host: "ftp.example.test", username: "u", password: "p", root: "blobs" }

    assert_instance_of Storage::FtpBackend, Storage.backend(settings("ftp", ftp: ftp))
  end

  test "rejects an unknown backend name" do
    error = assert_raises(SimpleDrive::ConfigurationError) { Storage.backend(settings("gcs")) }
    assert_match(/STORAGE_BACKEND is "gcs"; expected one of: local, database, s3, ftp/, error.message)
  end

  test "reports which backend setting is missing" do
    error = assert_raises(SimpleDrive::ConfigurationError) { Storage.backend(settings("s3", s3: { endpoint: "http://x" })) }
    assert_match(/S3_BUCKET must be set/, error.message)
  end

  test "uses the application settings by default" do
    assert_instance_of Storage::LocalBackend, Storage.backend
  end
end
