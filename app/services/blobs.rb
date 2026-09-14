# Application layer behind the /v1/blobs endpoints. Controllers call
# Blobs::Store and Blobs::Retrieve and map the errors below to HTTP responses;
# nothing here knows about HTTP or about any particular storage backend.
module Blobs
  class Error < StandardError; end

  # The request is well-formed but its content is not acceptable.
  class ValidationError < Error; end

  # +data+ is not strict, padded, standard-alphabet Base64.
  class InvalidBase64 < ValidationError; end

  # The decoded data is bigger than the configured maximum.
  class PayloadTooLarge < Error; end

  # A blob with the requested identifier already exists.
  class DuplicateIdentifier < Error; end

  # No blob has the requested identifier.
  class NotFound < Error; end

  # The blob was stored by a backend other than the one now configured.
  class BackendMismatch < Error; end

  # A blob's metadata together with its bytes, as returned by Retrieve.
  StoredBlob = Data.define(:blob, :data)
end
