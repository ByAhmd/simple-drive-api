# Bearer token authentication (RFC 6750) for every API request. The token is
# a single shared secret from configuration; it is compared in constant time
# and never logged or echoed.
module BearerAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate
  end

  private

  def authenticate
    return if authenticated?

    headers["WWW-Authenticate"] = 'Bearer realm="Simple Drive"'
    render_error :unauthorized, "unauthorized", "A valid bearer token is required"
  end

  def authenticated?
    scheme, token = request.authorization.to_s.split(" ", 2)
    return false unless scheme&.casecmp?("Bearer") && SimpleDrive::Settings::TOKEN_FORMAT.match?(token.to_s)

    ActiveSupport::SecurityUtils.secure_compare(token, Rails.configuration.x.simple_drive.api_token)
  end
end
