require "test_helper"
require "open3"

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
      assert_equal "SIMPLE_DRIVE_API_TOKEN must be set; for local use, run bin/setup or copy .env.example to .env",
                   error.message
    end
  end

  test "rejects tokens the bearer parser could never match" do
    [ "has space", "quote\"d", "tab\tbed", "ünïcode" ].each do |token|
      error = assert_raises(SimpleDrive::ConfigurationError, "expected #{token.inspect} to be rejected") do
        SimpleDrive::Settings.new(VALID.merge(api_token: token))
      end
      assert_match(/SIMPLE_DRIVE_API_TOKEN may only contain/, error.message)
    end
    assert_equal "a-b.c_d~e+f/g==", SimpleDrive::Settings.new(VALID.merge(api_token: "a-b.c_d~e+f/g==")).api_token
  end

  test "parses optional booleans, treating blank as the default" do
    assert_equal true, SimpleDrive::Settings.boolean("", "X", default: true)
    assert_equal false, SimpleDrive::Settings.boolean(nil, "X", default: false)
    assert_equal false, SimpleDrive::Settings.boolean("False", "X", default: true)
    assert_equal true, SimpleDrive::Settings.boolean(" 1 ", "X", default: false)

    [ "yes", "no", "maybe" ].each do |value|
      error = assert_raises(SimpleDrive::ConfigurationError) { SimpleDrive::Settings.boolean(value, "S3_PATH_STYLE", default: true) }
      assert_equal "S3_PATH_STYLE must be true or false", error.message
    end
  end

  test "parses positive base-10 integers, treating blank as the default" do
    assert_equal 21, SimpleDrive::Settings.positive_integer("", "X", default: 21)
    assert_equal 21, SimpleDrive::Settings.positive_integer(nil, "X", default: 21)
    assert_equal 2121, SimpleDrive::Settings.positive_integer(" 2121 ", "X", default: 21)
    assert_equal 21, SimpleDrive::Settings.positive_integer("021", "X", default: 30)

    [ "soon", "0", "-5", "1.5", "0x1F", "1,000" ].each do |value|
      error = assert_raises(SimpleDrive::ConfigurationError, "expected #{value.inspect} to be rejected") do
        SimpleDrive::Settings.positive_integer(value, "S3_TIMEOUT_SECONDS", default: 30)
      end
      assert_equal "S3_TIMEOUT_SECONDS must be a positive integer", error.message
    end
  end

  test "config/simple_drive.yml hands environment values over unchanged and applies defaults to blank ones" do
    with_env("SIMPLE_DRIVE_API_TOKEN" => "0123", "STORAGE_BACKEND" => "", "SIMPLE_DRIVE_MAX_BLOB_BYTES" => "",
             "LOCAL_STORAGE_PATH" => "C:\\data #1", "S3_REGION" => "", "S3_TIMEOUT_SECONDS" => "030") do
      settings = SimpleDrive::Settings.new(Rails.application.config_for(:simple_drive, env: "development"))

      assert_equal "0123", settings.api_token
      assert_equal "local", settings.storage_backend
      assert_equal SimpleDrive::Settings::DEFAULT_MAX_BLOB_BYTES, settings.max_blob_bytes
      assert_equal "C:\\data #1", settings.backend_settings(:local)[:root]
      assert_equal "us-east-1", settings.backend_settings(:s3)[:region]
      assert_equal "030", settings.backend_settings(:s3)[:timeout_seconds]
    end
  end

  test "a malformed number in the environment stops the boot with the variable's name" do
    with_env("SIMPLE_DRIVE_API_TOKEN" => "token", "SIMPLE_DRIVE_MAX_BLOB_BYTES" => "1,000") do
      error = assert_raises(SimpleDrive::ConfigurationError) do
        SimpleDrive::Settings.new(Rails.application.config_for(:simple_drive, env: "development"))
      end
      assert_equal "SIMPLE_DRIVE_MAX_BLOB_BYTES must be a positive integer", error.message
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

  test "the helpers config/puma.rb uses work without Rails loaded" do
    script = <<~RUBY
      require_relative #{Rails.root.join("lib/simple_drive/settings").to_s.dump}
      puts SimpleDrive::Settings.positive_integer("", "X", default: 7)
      SimpleDrive::Settings.positive_integer("1,000", "SIMPLE_DRIVE_MAX_BLOB_BYTES", default: 7)
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-e", script)

    assert_not status.success?
    assert_match(/^7$/, output)
    assert_match(/SIMPLE_DRIVE_MAX_BLOB_BYTES must be a positive integer \(SimpleDrive::ConfigurationError\)/, output)
  end

  test "sizes the request body limit for the largest blob in any common Base64 form" do
    settings = SimpleDrive::Settings.new(VALID.merge(max_blob_bytes: 3_000_000))
    largest = "x" * 3_000_000

    assert_equal settings.max_request_body_bytes, SimpleDrive::Settings.max_request_body_bytes(3_000_000)
    [ Base64.strict_encode64(largest), Base64.encode64(largest), Base64.encode64(largest).gsub("\n", "\r\n") ].each do |encoded|
      body = { id: "a" * Blob::IDENTIFIER_MAX_BYTES, data: encoded }.to_json
      assert_operator body.bytesize, :<=, settings.max_request_body_bytes
    end
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
