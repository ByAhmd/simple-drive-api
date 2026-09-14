require "test_helper"

# Runs the backend contract against a real FTP server. Skipped unless
# FTP_TEST_HOST is set; see README "Running the FTP integration tests" for
# the server started by compose.yaml and the variables.
class Storage::FtpBackendIntegrationTest < ActiveSupport::TestCase
  include StorageBackendContract

  setup do
    skip "FTP_TEST_HOST is not set; skipping FTP integration tests" if ENV["FTP_TEST_HOST"].blank?

    @backend = Storage::FtpBackend.new(
      host: ENV.fetch("FTP_TEST_HOST"),
      port: Integer(ENV.fetch("FTP_TEST_PORT", 21)),
      username: ENV.fetch("FTP_TEST_USERNAME"),
      password: ENV.fetch("FTP_TEST_PASSWORD"),
      root: "integration-tests"
    )
    # Remember what the contract tests write so teardown can remove it again.
    @written_keys = []
    written = @written_keys
    @backend.define_singleton_method(:write) { |key, data| written << key; super(key, data) }
  end

  teardown do
    @written_keys&.each { |key| @backend.delete(key) }
  end

  attr_reader :backend
end
