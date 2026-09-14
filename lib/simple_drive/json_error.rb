require "json"

module SimpleDrive
  # The single error shape every layer answers with, so clients see the same
  # JSON whether a controller, the body-size middleware or the exceptions app
  # rejected the request:
  #
  #   { "error": { "code": "not_found", "message": "No blob with this id exists" } }
  module JsonError
    CONTENT_TYPE = "application/json; charset=utf-8".freeze

    def self.body(code, message)
      { error: { code: code, message: message } }
    end

    def self.rack_response(status, code, message)
      [ status, { "content-type" => CONTENT_TYPE }, [ JSON.generate(body(code, message)) ] ]
    end
  end
end
