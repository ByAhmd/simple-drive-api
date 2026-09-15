require "test_helper"

# The same API conversation against every backend: clients must not be able
# to tell which one is configured.
class BackendCompatibilityTest < ActionDispatch::IntegrationTest
  BYTES = Random.new(11).bytes(4096).freeze

  def self.backends
    backends = {
      "local" => -> { Storage::LocalBackend.new(root: "tmp/test_storage/compat") },
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
    if ENV["FTP_TEST_HOST"].present?
      backends["ftp"] = lambda do
        Storage::FtpBackend.new(
          host: ENV.fetch("FTP_TEST_HOST"), port: Integer(ENV.fetch("FTP_TEST_PORT", 21)),
          username: ENV.fetch("FTP_TEST_USERNAME"), password: ENV.fetch("FTP_TEST_PASSWORD"),
          root: "integration-tests"
        )
      end
    end
    backends
  end

  backends.each do |name, build|
    test "stores, retrieves, deduplicates and reports missing blobs with the #{name} backend" do
      backend = build.call
      Storage.stub(:backend, backend) do
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

        orphan = Storage::Backend.generate_key
        backend.write(orphan, "left behind by a crash".b)
        PendingUpload.create!(storage_key: orphan, storage_backend: name, created_at: 2.hours.ago)
        assert_equal 1, Blobs::SweepOrphans.new(backend: backend).call.removed
        assert_raises(Storage::NotFound) { backend.read(orphan) }
      end
    ensure
      Blob.find_each { |blob| backend.delete(blob.storage_key) } if backend
      WebMock.disable_net_connect!
    end
  end
end
