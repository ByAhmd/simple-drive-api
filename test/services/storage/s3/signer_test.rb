require "test_helper"

# The vectors come from the worked examples in the Amazon S3 API reference,
# "Signature Calculations for the Authorization Header: Transferring Payload
# in a Single Chunk", which use the well-known example credentials below.
class Storage::S3::SignerTest < ActiveSupport::TestCase
  EMPTY_PAYLOAD_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".freeze

  setup do
    @signer = Storage::S3::Signer.new(
      access_key_id: "AKIAIOSFODNN7EXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      region: "us-east-1"
    )
  end

  test "signs the GET Object example" do
    authorization = @signer.authorization(
      method: "GET", path: "/test.txt",
      headers: { "Host" => "examplebucket.s3.amazonaws.com", "Range" => "bytes=0-9",
                 "x-amz-content-sha256" => EMPTY_PAYLOAD_HASH, "x-amz-date" => "20130524T000000Z" },
      payload_hash: EMPTY_PAYLOAD_HASH
    )

    assert_equal "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " \
                 "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " \
                 "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", authorization
  end

  test "signs the PUT Object example" do
    payload_hash = Digest::SHA256.hexdigest("Welcome to Amazon S3.")
    assert_equal "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", payload_hash

    authorization = @signer.authorization(
      method: "PUT", path: "/#{Storage::S3::Signer.uri_encode('test$file.text')}",
      headers: { "Date" => "Fri, 24 May 2013 00:00:00 GMT", "Host" => "examplebucket.s3.amazonaws.com",
                 "x-amz-content-sha256" => payload_hash, "x-amz-date" => "20130524T000000Z",
                 "x-amz-storage-class" => "REDUCED_REDUNDANCY" },
      payload_hash: payload_hash
    )

    assert_match(/SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, /, authorization)
    assert_match(/Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd\z/, authorization)
  end

  test "signs the GET Bucket Lifecycle example with an empty-valued query parameter" do
    authorization = @signer.authorization(
      method: "GET", path: "/", query: { "lifecycle" => "" },
      headers: { "Host" => "examplebucket.s3.amazonaws.com",
                 "x-amz-content-sha256" => EMPTY_PAYLOAD_HASH, "x-amz-date" => "20130524T000000Z" },
      payload_hash: EMPTY_PAYLOAD_HASH
    )

    assert_match(/Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543\z/, authorization)
  end

  test "signs the List Objects example with sorted query parameters" do
    authorization = @signer.authorization(
      method: "GET", path: "/", query: { "prefix" => "J", "max-keys" => "2" },
      headers: { "Host" => "examplebucket.s3.amazonaws.com",
                 "x-amz-content-sha256" => EMPTY_PAYLOAD_HASH, "x-amz-date" => "20130524T000000Z" },
      payload_hash: EMPTY_PAYLOAD_HASH
    )

    assert_match(/Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7\z/, authorization)
  end

  test "trims and collapses whitespace in header values before signing" do
    tidy = @signer.authorization(method: "GET", path: "/", payload_hash: EMPTY_PAYLOAD_HASH,
                                 headers: { "host" => "h", "x-amz-date" => "20130524T000000Z", "x-custom" => "a b" })
    messy = @signer.authorization(method: "GET", path: "/", payload_hash: EMPTY_PAYLOAD_HASH,
                                  headers: { "Host" => " h ", "X-Amz-Date" => "20130524T000000Z", "X-Custom" => "a   b " })

    assert_equal tidy, messy
  end

  test "uri_encode follows the SigV4 rules" do
    encode = Storage::S3::Signer.method(:uri_encode)

    assert_equal "AZaz09-._~", encode.call("AZaz09-._~")
    assert_equal "a%20b", encode.call("a b")
    assert_equal "test%24file.text", encode.call("test$file.text")
    assert_equal "%2F", encode.call("/")
    assert_equal "photos/Jan/sample.jpg", encode.call("photos/Jan/sample.jpg", encode_slash: false)
    assert_equal "%C3%A9", encode.call("é")
    assert_equal "%2B%3D%26%3F%23", encode.call("+=&?#")
  end
end
