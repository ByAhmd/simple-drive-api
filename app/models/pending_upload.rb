# An object write that has started but whose blob is not recorded yet.
#
# Blobs::Store creates the row before writing any bytes and deletes it in the
# same transaction that inserts the blob, so a row that outlives its request
# marks an object that may exist without metadata. Blobs::SweepOrphans removes
# those objects later.
class PendingUpload < ApplicationRecord
  validates :storage_key, :storage_backend, presence: true
end
