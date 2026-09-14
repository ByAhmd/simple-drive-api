# Bearer token authentication (RFC 6750) for every API request. The token is
# a single shared secret from configuration; it is compared in constant time
# and never logged or echoed.
module BearerAuthentication
  extend ActiveSupport::Concern

  BEARER_SCHEME = %r{\ABearer\s+(?<token>[A-Za-z0-9\-._~+/]+=*)\z}i

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
    match = BEARER_SCHEME.match(request.authorization.to_s)
    return false if match.nil?

    ActiveSupport::SecurityUtils.secure_compare(match[:token], Rails.configuration.x.simple_drive.api_token)
  end
end
