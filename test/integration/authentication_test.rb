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
end
