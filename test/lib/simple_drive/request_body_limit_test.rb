require "test_helper"

class SimpleDrive::RequestBodyLimitTest < ActiveSupport::TestCase
  setup do
    @downstream_calls = 0
    downstream = ->(_env) { @downstream_calls += 1; [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }
    @app = Rack::MockRequest.new(SimpleDrive::RequestBodyLimit.new(downstream, max_bytes: 100))
  end

  test "passes requests within the limit through" do
    response = @app.post("/v1/blobs", input: "x" * 100)

    assert_equal 200, response.status
    assert_equal 1, @downstream_calls
  end

  test "passes requests without a body through" do
    assert_equal 200, @app.get("/v1/blobs/x").status
  end

  test "rejects bodies above the limit with a JSON 413 before the app sees them" do
    response = @app.post("/v1/blobs", input: "x" * 101)

    assert_equal 413, response.status
    assert_equal "application/json; charset=utf-8", response.headers["content-type"]
    assert_equal({ "error" => { "code" => "payload_too_large",
                                "message" => "Request body exceeds the 100 byte limit" } }, JSON.parse(response.body))
    assert_equal 0, @downstream_calls
  end
end
