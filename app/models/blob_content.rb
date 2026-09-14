# Row format of the database storage backend. It holds nothing but the bytes
# and the storage key that the metadata table (Blob) points at; the two tables
# are deliberately independent so that the backend stays interchangeable.
class BlobContent < ApplicationRecord
  validates :storage_key, presence: true
end
