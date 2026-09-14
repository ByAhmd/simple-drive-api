# Metadata for one stored blob. The bytes themselves live in the configured
# storage backend under +storage_key+; this table only tracks them.
class Blob < ApplicationRecord
  # Counted in bytes, not characters: GET carries the id percent-encoded in the
  # path, where each byte can take three characters, and Puma refuses request
  # paths over 8192 bytes.
  IDENTIFIER_MAX_BYTES = 1024
  CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/

  validates :identifier, presence: true
  validates :identifier, format: { without: CONTROL_CHARACTERS, message: "must not contain control characters" },
                         allow_blank: true
  validate :identifier_fits_in_a_request_path
  validates :size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :storage_backend, :storage_key, presence: true

  private

  def identifier_fits_in_a_request_path
    return if identifier.nil? || identifier.bytesize <= IDENTIFIER_MAX_BYTES

    errors.add(:identifier, "is too long (maximum is #{IDENTIFIER_MAX_BYTES} bytes)")
  end
end
