module Storage
  # Stores object bytes in the blob_contents table.
  #
  # That table is separate from the metadata table on purpose: blobs holds
  # what the API serves about every blob regardless of backend, while
  # blob_contents is merely one of the interchangeable places bytes can live.
  class DatabaseBackend < Backend
    def self.from_settings(_settings)
      new
    end

    def name
      "database"
    end

    def write(key, data)
      BlobContent.create!(storage_key: key, data: data)
    rescue ActiveRecord::ActiveRecordError => e
      raise Error, "database storage write failed: #{e.message}"
    end

    def read(key)
      content = BlobContent.find_by(storage_key: key)
      raise NotFound, "no object stored under key #{key}" if content.nil?

      content.data
    rescue ActiveRecord::ActiveRecordError => e
      raise Error, "database storage read failed: #{e.message}"
    end

    def delete(key)
      BlobContent.where(storage_key: key).delete_all
    rescue ActiveRecord::ActiveRecordError => e
      raise Error, "database storage delete failed: #{e.message}"
    end
  end
end
