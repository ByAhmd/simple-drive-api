require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
# require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Settings, the JSON error helper and the Rack middleware are needed while the
# application is being configured, before the autoloader exists, so lib/ is
# required explicitly instead of being autoloaded.
require_relative "../lib/simple_drive"

module SimpleDrive
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # All application settings come from the environment via
    # config/simple_drive.yml; SimpleDrive::Settings validates them at boot.
    config.x.simple_drive = SimpleDrive::Settings.new(config_for(:simple_drive))

    # Refuse oversized bodies before Rails parses them, and answer every error
    # that escapes the controllers with JSON instead of an HTML page.
    config.middleware.use SimpleDrive::RequestBodyLimit, max_bytes: config.x.simple_drive.max_request_body_bytes
    config.exceptions_app = SimpleDrive::ExceptionsApp.new
  end
end
