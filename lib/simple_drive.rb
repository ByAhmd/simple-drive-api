# Boot-time support code: settings, the shared JSON error shape and the Rack
# pieces that must exist before the Rails autoloader is ready. It is required
# explicitly from config/application.rb rather than autoloaded.
module SimpleDrive
  # Raised while booting when a required setting is missing or malformed.
  class ConfigurationError < StandardError; end
end

require_relative "simple_drive/json_error"
require_relative "simple_drive/settings"
require_relative "simple_drive/request_body_limit"
require_relative "simple_drive/exceptions_app"
