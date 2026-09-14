require "test_helper"

# Runs the backend contract against a real S3-compatible server. Skipped
# unless S3_TEST_ENDPOINT is set; see README "Running the S3 integration
# tests" for the MinIO setup (compose.yaml) and the variables.
class Storage::S3BackendIntegrationTest < ActiveSupport::TestCase
  include StorageBackendContract

  setup do
    skip "S3_TEST_ENDPOINT is not set; skipping S3 integration tests" if ENV["S3_TEST_ENDPOINT"].blank?

    endpoint = URI(ENV.fetch("S3_TEST_ENDPOINT"))
    WebMock.disable_net_connect!(allow: "#{endpoint.host}:#{endpoint.port}")
    @backend = Storage::S3Backend.new(
      endpoint: endpoint.to_s,
      bucket: ENV.fetch("S3_TEST_BUCKET"),
      region: ENV.fetch("S3_TEST_REGION", "us-east-1"),
      access_key_id: ENV.fetch("S3_TEST_ACCESS_KEY_ID"),
      secret_access_key: ENV.fetch("S3_TEST_SECRET_ACCESS_KEY"),
      path_style: ENV.fetch("S3_TEST_PATH_STYLE", "true") == "true",
      key_prefix: "integration-tests"
    )
  end

  teardown { WebMock.disable_net_connect! }

  attr_reader :backend

  test "an overwritten key returns the latest bytes" do
    key = Storage::Backend.generate_key
    backend.write(key, "first".b)
    backend.write(key, "second".b)

    assert_equal "second", backend.read(key)
  end
end
