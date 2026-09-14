# The storage layer. Everything above it deals in opaque storage keys and the
# Storage::Backend interface; which backend is in use is decided here, from
# configuration alone.
module Storage
  # Any failure to store, read or delete an object.
  class Error < StandardError; end

  # The backend holds nothing under the requested key.
  class NotFound < Error; end

  BACKENDS = {
    "local" => LocalBackend,
    "database" => DatabaseBackend,
    "s3" => S3Backend
  }.freeze

  # Builds the backend named by +settings.storage_backend+ from that backend's
  # own settings section. Raises SimpleDrive::ConfigurationError when the
  # name is unknown or the section is incomplete.
  def self.backend(settings = Rails.configuration.x.simple_drive)
    name = settings.storage_backend
    backend_class = BACKENDS.fetch(name) do
      raise SimpleDrive::ConfigurationError,
            "STORAGE_BACKEND is #{name.inspect}; expected one of: #{BACKENDS.keys.join(', ')}"
    end
    backend_class.from_settings(settings.backend_settings(name))
  end
end
