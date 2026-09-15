namespace :blobs do
  desc "Delete objects left behind by uploads that never finished (OLDER_THAN_MINUTES, default 60)"
  task sweep_orphans: :environment do
    minutes = SimpleDrive::Settings.positive_integer(ENV["OLDER_THAN_MINUTES"], "OLDER_THAN_MINUTES", default: 60)
    backend = Storage.backend
    result = Blobs::SweepOrphans.new(backend: backend, older_than: minutes.minutes).call

    puts "Removed #{result.removed} orphaned object(s) older than #{minutes} minute(s) from the #{backend.name} backend."
    puts "#{result.failed} could not be removed and will be retried on the next run." if result.failed.positive?
    if result.other_backends.positive?
      puts "#{result.other_backends} pending upload(s) belong to other backends; run the sweep with those configured."
    end
  end
end
