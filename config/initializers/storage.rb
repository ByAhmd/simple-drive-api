# Build the configured storage backend once while booting so that a missing
# or invalid backend setting stops the process instead of failing the first
# request. Backends are cheap to construct and nothing is cached here.
Rails.application.config.after_initialize do
  Storage.backend
end
