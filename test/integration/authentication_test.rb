require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  test "requests without an Authorization header are rejected" do
    get "/v1/blobs/anything"

    assert_unauthorized
  end

  test "the wrong token is rejected" do
    get_blob "anything", token: "not-the-token"

    assert_unauthorized
  end

  test "a token that merely starts with the real one is rejected" do
    get_blob "anything", token: "#{api_token}x"

    assert_unauthorized
  end

  test "other authentication schemes are rejected" do
    [ "Token #{api_token}", "Basic #{api_token}", "Token token=\"#{api_token}\"",
      "Basic #{Base64.strict_encode64("user:#{api_token}")}", api_token,
      "Bearer", "Bearer ", "Bearer #{api_token} trailing", "Bearer #{api_token}\n" ].each do |authorization|
      get "/v1/blobs/anything", headers: { "Authorization" => authorization }

      assert_unauthorized "expected #{authorization.inspect} to be rejected"
    end
  end

  test "the scheme name is case-insensitive as RFC 6750 allows" do
    get "/v1/blobs/anything", headers: { "Authorization" => "bearer #{api_token}" }

    assert_response :not_found
  end

  test "the store endpoint requires authentication too" do
    post "/v1/blobs", params: { id: "x", data: "AQID" }.to_json, headers: { "Content-Type" => "application/json" }

    assert_unauthorized
    assert_equal 0, Blob.count
  end

  test "authentication is checked before the request body is inspected" do
    post "/v1/blobs", params: +"{not json", headers: { "Content-Type" => "application/json" }

    assert_unauthorized
  end

  test "requests that cannot be parsed are refused before authentication, whatever the token" do
    body_limit = Rails.configuration.x.simple_drive.max_request_body_bytes

    post "/v1/blobs", params: "x" * (body_limit + 1), headers: { "Content-Type" => "application/json" }
    assert_refused :content_too_large, "payload_too_large"

    post "/v1/blobs", params: +"{}", headers: { "Content-Type" => "garbage" }
    assert_refused :unsupported_media_type, "unsupported_media_type"

    get "/v1/blobs/hello", headers: { "Accept" => "application" }
    assert_refused :not_acceptable, "not_acceptable"

    get "/v1/blobs/%FF"
    assert_refused :bad_request, "bad_request"

    # Set directly: the test client refuses to build a URI with a bad escape.
    [ "a=%ZZ", "a=%FF" ].each do |query|
      get "/v1/blobs/hello", env: { "QUERY_STRING" => query }
      assert_refused :bad_request, "bad_request", query
    end

    post "/v1/blobs", params: +"a=%ZZ", headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    assert_refused :bad_request, "bad_request"
  end

  test "there is no unauthenticated endpoint serving data, not even a health check" do
    [ "/up", "/" ].each do |path|
      get path

      assert_response :not_found
      assert_equal({ "error" => { "code" => "not_found", "message" => "No route matches this path" } }, response.parsed_body)
    end
  end

  private

  def assert_unauthorized(message = nil)
    assert_response :unauthorized, message
    assert_equal 'Bearer realm="Simple Drive"', response.headers["WWW-Authenticate"], message
    assert_equal({ "error" => { "code" => "unauthorized", "message" => "A valid bearer token is required" } },
                 response.parsed_body, message)
  end

  def assert_refused(status, code, message = nil)
    assert_response status, message
    assert_nil response.headers["WWW-Authenticate"], message
    assert_equal code, response.parsed_body.dig("error", "code"), message
  end
end
