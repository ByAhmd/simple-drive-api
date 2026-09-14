require "test_helper"

# The same API conversation against every backend: clients must not be able
# to tell which one is configured.
class BackendCompatibilityTest < ActionDispatch::IntegrationTest
  BYTES = Random.new(11).bytes(4096).freeze

  def self.backends
    backends = {
      "local" => -> { Storage::LocalBackend.new(root: Dir.mktmpdir("simple_drive_compat")) },
      "database" => -> { Storage::DatabaseBackend.new }
    }
    if ENV["S3_TEST_ENDPOINT"].present?
      backends["s3"] = lambda do
        endpoint = URI(ENV.fetch("S3_TEST_ENDPOINT"))
        WebMock.disable_net_connect!(allow: "#{endpoint.host}:#{endpoint.port}")
        Storage::S3Backend.new(
          endpoint: endpoint.to_s, bucket: ENV.fetch("S3_TEST_BUCKET"),
          region: ENV.fetch("S3_TEST_REGION", "us-east-1"),
          access_key_id: ENV.fetch("S3_TEST_ACCESS_KEY_ID"),
          secret_access_key: ENV.fetch("S3_TEST_SECRET_ACCESS_KEY"),
          path_style: ENV.fetch("S3_TEST_PATH_STYLE", "true") == "true", key_prefix: "integration-tests"
        )
      end
    end
    backends
  end

  backends.each do |name, build|
    test "stores, retrieves, deduplicates and reports missing blobs with the #{name} backend" do
      Storage.stub(:backend, build.call) do
        post_blob id: "compat/#{name}.bin", data: Base64.strict_encode64(BYTES)
        assert_response :created
        assert_equal BYTES.bytesize.to_s, response.parsed_body["size"]
        assert_equal name, Blob.find_by!(identifier: "compat/#{name}.bin").storage_backend

        get_blob "compat/#{name}.bin"
        assert_response :ok
        assert_equal BYTES, Base64.strict_decode64(response.parsed_body["data"])

        post_blob id: "compat/#{name}.bin", data: "AQID"
        assert_response :conflict

        get_blob "compat/#{name}.missing"
        assert_response :not_found
      end
    end
  end
end
