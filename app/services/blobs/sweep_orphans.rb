module Blobs
  # Removes objects whose upload never finished. Blobs::Store leaves a
  # PendingUpload row behind when the process stopped between writing the
  # bytes and recording the blob, or when a failed store could not delete what
  # it wrote. Rows older than the grace period belong to requests that can no
  # longer be running, so their objects are deleted and the rows with them.
  class SweepOrphans
    Result = Data.define(:removed, :failed, :other_backends)

    def initialize(backend: Storage.backend, older_than: 1.hour)
      @backend = backend
      @older_than = older_than
    end

    def call
      removed = failed = 0
      stale_uploads.find_each do |pending|
        # Never delete bytes a blob points to, whatever the row says.
        backend.delete(pending.storage_key) unless Blob.exists?(storage_key: pending.storage_key)
        pending.delete
        removed += 1
      rescue Storage::Error => e
        failed += 1
        Rails.logger.warn("Could not remove orphaned object #{pending.storage_key}: #{e.message}")
      end

      Result.new(removed:, failed:, other_backends: PendingUpload.where.not(storage_backend: backend.name).count)
    end

    private

    attr_reader :backend, :older_than

    def stale_uploads
      PendingUpload.where(storage_backend: backend.name, created_at: ...older_than.ago)
    end
  end
end
