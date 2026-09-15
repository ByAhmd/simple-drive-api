module Storage
  # Stores each object as a file below a configured root directory.
  #
  # File names are the application-generated keys, never client identifiers,
  # so nothing a client sends can influence a path. Objects are spread over
  # two levels of prefix directories to keep any single directory small.
  class LocalBackend < Backend
    def self.from_settings(settings)
      new(root: settings[:root])
    end

    def initialize(root:)
      raise SimpleDrive::ConfigurationError, "LOCAL_STORAGE_PATH must be set" if root.blank?

      @root = Rails.root.join(root).expand_path
    end

    def name
      "local"
    end

    def write(key, data)
      path = path_for(key)
      path.dirname.mkpath
      write_atomically(path, data)
    rescue SystemCallError, IOError => e
      raise Error, "local storage write failed: #{e.message}"
    end

    def read(key)
      path_for(key).binread
    rescue Errno::ENOENT
      raise NotFound, "no object stored under key #{key}"
    rescue SystemCallError, IOError => e
      raise Error, "local storage read failed: #{e.message}"
    end

    # Also removes the temporary file an interrupted write may have left.
    def delete(key)
      path = path_for(key)
      FileUtils.rm_f(temporary_path(path))
      path.delete
    rescue Errno::ENOENT
      nil
    rescue SystemCallError, IOError => e
      raise Error, "local storage delete failed: #{e.message}"
    end

    private

    attr_reader :root

    def path_for(key)
      validate_key!(key)
      root.join(key[0, 2], key[2, 2], key)
    end

    # Writes a sibling temporary file and renames it into place, so that a
    # crash mid-write cannot leave a truncated object behind.
    def write_atomically(path, data)
      temporary = temporary_path(path)
      temporary.binwrite(data)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def temporary_path(path)
      path.sub_ext(".tmp")
    end
  end
end
