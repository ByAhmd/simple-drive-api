require "test_helper"

class SimpleDrive::ExceptionsAppTest < ActiveSupport::TestCase
  def call(status, exception = nil)
    env = Rack::MockRequest.env_for("/#{status}")
    env["action_dispatch.exception"] = exception
    code, headers, body = SimpleDrive::ExceptionsApp.new.call(env)
    [ code, headers["content-type"], JSON.parse(body.join)["error"] ]
  end

  test "describes malformed JSON bodies" do
    exception = ActionDispatch::Http::Parameters::ParseError.new("unexpected token")

    assert_equal [ 400, "application/json; charset=utf-8",
                   { "code" => "invalid_json", "message" => "Request body is not valid JSON" } ], call(400, exception)
  end

  test "describes other bad requests generically" do
    assert_equal({ "code" => "bad_request", "message" => "The request could not be understood" }, call(400).last)
  end

  test "answers an unparsable Content-Type with the documented 415" do
    exception = ActionDispatch::Http::MimeNegotiation::InvalidType.new("invalid")

    assert_equal [ 415, "application/json; charset=utf-8",
                   { "code" => "unsupported_media_type", "message" => "Content-Type must be application/json" } ],
                 call(406, exception)
  end

  test "describes unknown routes" do
    assert_equal({ "code" => "not_found", "message" => "No route matches this path" }, call(404).last)
  end

  test "never leaks details of server errors" do
    status, _, error = call(500, RuntimeError.new("secret database path"))

    assert_equal 500, status
    assert_equal({ "code" => "internal_error", "message" => "An unexpected error occurred" }, error)
  end

  test "falls back to the status phrase for other statuses" do
    assert_equal({ "code" => "not_acceptable", "message" => "Not Acceptable" }, call(406).last)
  end

  test "treats an unknown status as a server error" do
    assert_equal 500, call(999).first
  end
end
