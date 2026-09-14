module SimpleDrive
  # Rails hands errors that escape the controllers (malformed JSON, unknown
  # routes, unexpected exceptions) to this app instead of rendering the HTML
  # pages in public/. It answers with the shared JSON error shape and never
  # includes exception details; Rails has already logged them.
  class ExceptionsApp
    def call(env)
      request = ActionDispatch::Request.new(env)
      status = request.path_info[1..].to_i
      status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status)

      code, message = describe(status, request.get_header("action_dispatch.exception"))
      JsonError.rack_response(status, code, message)
    end

    private

    def describe(status, exception)
      case status
      when 400
        if exception.is_a?(ActionDispatch::Http::Parameters::ParseError)
          [ "invalid_json", "Request body is not valid JSON" ]
        else
          [ "bad_request", "The request could not be understood" ]
        end
      when 404
        [ "not_found", "No route matches this path" ]
      when 500..599
        [ "internal_error", "An unexpected error occurred" ]
      else
        phrase = Rack::Utils::HTTP_STATUS_CODES.fetch(status)
        [ phrase.downcase.tr(" ", "_"), phrase ]
      end
    end
  end
end
