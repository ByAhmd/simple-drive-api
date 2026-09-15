require "test_helper"
require "pp"

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

  test "printing the settings or a backend never shows a credential, in any common format" do
    s3 = { endpoint: "http://localhost:9000", bucket: "bucket", region: "us-east-1",
           access_key_id: "k", secret_access_key: "s3-secret-value" }
    ftp = { host: "ftp.example.test", username: "u", password: "ftp-password-value" }
    configured = settings("s3", api_token: "api-token-value", s3: s3, ftp: ftp)

    # The console echoes results with pp and its y command prints YAML; JSON
    # covers anything that serialises these objects.
    [ configured, Storage.backend(configured), Storage.backend(settings("ftp", ftp: ftp)) ].each do |object|
      { pp: object.pretty_inspect, yaml: object.to_yaml, json: object.to_json }.each do |format, output|
        assert_includes output, "[FILTERED]", "#{object.class} as #{format}"
        [ "api-token-value", "s3-secret-value", "ftp-password-value" ].each do |secret|
          assert_not_includes output, secret, "#{object.class} printed a credential as #{format}"
        end
      end
    end
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
