module SimpleDrive
  # Rails hands errors that escape the controllers (malformed JSON, unknown
  # routes, unexpected exceptions) to this app instead of rendering the HTML
  # pages in public/. It answers with the shared JSON error shape and never
  # includes exception details; Rails has already logged them.
  class ExceptionsApp
    def call(env)
      request = ActionDispatch::Request.new(env)
      exception = request.get_header("action_dispatch.exception")
      status = status_for(request.path_info, exception)
      code, message = describe(status, exception)
      JsonError.rack_response(status, code, message)
    end

    private

    # Rails reports an unparsable Content-Type header as 406; for this API
    # the accurate and documented answer is 415.
    def status_for(path_info, exception)
      return 415 if exception.is_a?(ActionDispatch::Http::MimeNegotiation::InvalidType)

      status = path_info[1..].to_i
      Rack::Utils::HTTP_STATUS_CODES.key?(status) ? status : 500
    end

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
      when 415
        [ "unsupported_media_type", "Content-Type must be application/json" ]
      when 500..599
        [ "internal_error", "An unexpected error occurred" ]
      else
        phrase = Rack::Utils::HTTP_STATUS_CODES.fetch(status)
        [ phrase.downcase.tr(" ", "_"), phrase ]
      end
    end
  end
end
