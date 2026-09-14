require "test_helper"

class SimpleDrive::SettingsTest < ActiveSupport::TestCase
  VALID = { api_token: "secret", storage_backend: "local", max_blob_bytes: 300, local: { root: "x" } }.freeze

  test "exposes the validated values" do
    settings = SimpleDrive::Settings.new(VALID)

    assert_equal "secret", settings.api_token
    assert_equal "local", settings.storage_backend
    assert_equal 300, settings.max_blob_bytes
    assert_equal({ root: "x" }, settings.backend_settings(:local))
    assert_equal({}, settings.backend_settings(:s3))
    assert_predicate settings, :frozen?
  end

  test "accepts string keys as produced by config_for" do
    settings = SimpleDrive::Settings.new("api_token" => "t", "storage_backend" => "database",
                                         "max_blob_bytes" => "5", "s3" => { "bucket" => "b" })

    assert_equal 5, settings.max_blob_bytes
    assert_equal({ bucket: "b" }, settings.backend_settings("s3"))
  end

  test "requires the API token" do
    [ nil, "", "   " ].each do |token|
      error = assert_raises(SimpleDrive::ConfigurationError) { SimpleDrive::Settings.new(VALID.merge(api_token: token)) }
      assert_equal "SIMPLE_DRIVE_API_TOKEN must be set", error.message
    end
  end

  test "requires the backend name" do
    error = assert_raises(SimpleDrive::ConfigurationError) { SimpleDrive::Settings.new(VALID.merge(storage_backend: nil)) }
    assert_equal "STORAGE_BACKEND must be set", error.message
  end

  test "requires a positive integer blob size limit" do
    [ nil, "big", 0, -5, 1.5 ].each do |limit|
      error = assert_raises(SimpleDrive::ConfigurationError) { SimpleDrive::Settings.new(VALID.merge(max_blob_bytes: limit)) }
      assert_equal "SIMPLE_DRIVE_MAX_BLOB_BYTES must be a positive integer", error.message
    end
  end

  test "sizes the request body limit for the largest blob in any common Base64 form" do
    settings = SimpleDrive::Settings.new(VALID.merge(max_blob_bytes: 3000))
    largest = "x" * 3000

    assert_equal settings.max_request_body_bytes, SimpleDrive::Settings.max_request_body_bytes(3000)
    [ Base64.strict_encode64(largest), Base64.encode64(largest), Base64.encode64(largest).gsub("\n", "\r\n") ].each do |encoded|
      body = { id: "a" * Blob::IDENTIFIER_MAX_LENGTH, data: encoded }.to_json
      assert_operator body.bytesize, :<=, settings.max_request_body_bytes
    end
  end
end
