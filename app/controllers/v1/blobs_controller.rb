module V1
  class BlobsController < ApplicationController
    # The JSON body is read field by field; wrapping it under a "blob" key
    # would only duplicate it in params and in the logs.
    wrap_parameters false

    before_action :require_json, only: :create

    def create
      # Only the body is the request: query-string values must not be able to
      # override the JSON fields, so params (which merges them) is not used.
      body = request.request_parameters
      blob = Blobs::Store.new.call(identifier: body["id"], data: body["data"])
      render json: blob_json(blob), status: :created
    end

    def show
      stored = Blobs::Retrieve.new.call(params[:id])
      render json: blob_json(stored.blob, data: stored.data)
    end

    private

    def require_json
      return if request.content_mime_type == Mime[:json]

      render_error :unsupported_media_type, "unsupported_media_type", "Content-Type must be application/json"
    end

    # The specification renders size as a string, so it is returned as one.
    def blob_json(blob, data: nil)
      json = { id: blob.identifier }
      json[:data] = Base64.strict_encode64(data) unless data.nil?
      json.merge(size: blob.size.to_s, created_at: blob.created_at.utc.iso8601)
    end
  end
end
