module SimpleDrive
  # Refuses request bodies whose Content-Length is above the limit before
  # Rails reads them. Rails parses JSON parameters while it logs the request,
  # ahead of any controller callback, so this middleware is the only place an
  # oversized body can be rejected without decoding it first. Puma de-chunks
  # chunked uploads and sets Content-Length before the app runs, so they are
  # covered too; the decoded-size check in Blobs::Store applies regardless.
  class RequestBodyLimit
    def initialize(app, max_bytes:)
      @app = app
      @max_bytes = max_bytes
    end

    def call(env)
      if env["CONTENT_LENGTH"].to_i > @max_bytes
        return JsonError.rack_response(413, "payload_too_large", "Request body exceeds the #{@max_bytes} byte limit")
      end

      @app.call(env)
    end
  end
end
