ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"

Dir[Rails.root.join("test/support/**/*.rb")].each { |file| require file }

module ActiveSupport
  class TestCase
    # Several tests stub the process-wide Storage.backend and all of them
    # share one storage directory, so the suite runs serially.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup { FileUtils.rm_rf(Rails.root.join("tmp/test_storage")) }

    def api_token
      Rails.configuration.x.simple_drive.api_token
    end
  end
end

class ActionDispatch::IntegrationTest
  def auth_headers(token: api_token)
    { "Authorization" => "Bearer #{token}" }
  end

  def json_headers(token: api_token)
    auth_headers(token: token).merge("Content-Type" => "application/json")
  end

  def post_blob(id:, data:, token: api_token)
    post "/v1/blobs", params: { id: id, data: data }.to_json, headers: json_headers(token: token)
  end

  def get_blob(id, token: api_token)
    get "/v1/blobs/#{id}", headers: auth_headers(token: token)
  end
end
