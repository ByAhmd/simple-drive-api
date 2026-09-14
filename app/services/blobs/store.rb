require "base64"

module Blobs
  # Stores a new blob: validates the request, writes the bytes to the backend
  # and only then records the metadata row.
  #
  # Writing before claiming the identifier guarantees that a metadata row
  # never points at bytes that were not stored. The unique index on
  # blobs.identifier decides between concurrent requests for the same id: the
  # loser deletes the object it wrote and reports a conflict. No database
  # transaction is held across the backend write, so a slow upload never
  # blocks other writers; the price is that a crash between the two steps can
  # leave an orphaned object behind (never a dangling metadata row).
  class Store
    BASE64_WHITESPACE = " \t\r\n".freeze

    def initialize(backend: Storage.backend, max_bytes: Rails.configuration.x.simple_drive.max_blob_bytes)
      @backend = backend
      @max_bytes = max_bytes
    end

    def call(identifier:, data:)
      validate_types!(identifier, data)
      bytes = decode(data)

      blob = Blob.new(identifier: identifier, size: bytes.bytesize,
                      storage_backend: backend.name, storage_key: Storage::Backend.generate_key)
      raise ValidationError, blob.errors.full_messages.to_sentence unless blob.valid?
      raise DuplicateIdentifier, "A blob with this id already exists" if Blob.exists?(identifier: identifier)

      backend.write(blob.storage_key, bytes)
      claim(blob)
    end

    private

    attr_reader :backend, :max_bytes

    def validate_types!(identifier, data)
      raise ValidationError, "id is required" if identifier.nil?
      raise ValidationError, "id must be a string" unless identifier.is_a?(String)
      raise ValidationError, "data is required" if data.nil?
      raise ValidationError, "data must be a string" unless data.is_a?(String)
    end

    # Strict RFC 4648 decoding (standard alphabet, correct padding, nothing
    # else), except that line breaks and spaces are ignored first: MIME-style
    # encoders such as Ruby's Base64.encode64 and base64(1) wrap their
    # output, and whitespace carries no data so accepting it is unambiguous.
    def decode(data)
      compact = data.delete(BASE64_WHITESPACE)
      # Four Base64 characters carry three bytes, so the encoded length bounds
      # the decoded size before anything is decoded.
      raise PayloadTooLarge, too_large_message if compact.bytesize > max_encoded_bytes

      bytes = begin
        Base64.strict_decode64(compact)
      rescue ArgumentError
        raise InvalidBase64, "data is not valid Base64"
      end
      raise PayloadTooLarge, too_large_message if bytes.bytesize > max_bytes

      bytes
    end

    def max_encoded_bytes
      (max_bytes + 2) / 3 * 4
    end

    def too_large_message
      "data exceeds the maximum blob size of #{max_bytes} bytes"
    end

    # Inserts the metadata row. The unique index is the arbiter under
    # concurrency; whatever goes wrong here, the object written above is
    # removed again so that a failed request leaves nothing behind.
    def claim(blob)
      blob.save!
      blob
    rescue ActiveRecord::RecordNotUnique
      discard(blob.storage_key)
      raise DuplicateIdentifier, "A blob with this id already exists"
    rescue StandardError
      discard(blob.storage_key)
      raise
    end

    def discard(key)
      backend.delete(key)
    rescue Storage::Error => e
      Rails.logger.warn("Could not remove object #{key} after a failed store: #{e.message}")
    end
  end
end
