module Blobs
  # Loads a blob's metadata and reads its bytes back from the backend that
  # stored it.
  class Retrieve
    def initialize(backend: Storage.backend)
      @backend = backend
    end

    def call(identifier)
      blob = Blob.find_by(identifier: identifier)
      raise NotFound, "No blob with this id exists" if blob.nil?

      unless blob.storage_backend == backend.name
        raise BackendMismatch,
              "blob #{blob.id} was stored by the #{blob.storage_backend} backend but #{backend.name} is configured"
      end

      StoredBlob.new(blob: blob, data: backend.read(blob.storage_key))
    end

    private

    attr_reader :backend
  end
end
