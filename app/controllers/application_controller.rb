class ApplicationController < ActionController::API
  include BearerAuthentication

  rescue_from Blobs::ValidationError, with: :render_validation_error
  rescue_from Blobs::PayloadTooLarge, with: :render_payload_too_large
  rescue_from Blobs::DuplicateIdentifier, with: :render_conflict
  rescue_from Blobs::NotFound, with: :render_not_found
  rescue_from Blobs::BackendMismatch, with: :render_backend_mismatch
  rescue_from Storage::Error, with: :render_storage_unavailable

  private

  def render_error(status, code, message)
    render json: SimpleDrive::JsonError.body(code, message), status: status
  end

  def render_validation_error(error)
    render_error :unprocessable_content, "validation_failed", error.message
  end

  def render_payload_too_large(error)
    render_error :content_too_large, "payload_too_large", error.message
  end

  def render_conflict(error)
    render_error :conflict, "conflict", error.message
  end

  def render_not_found(error)
    render_error :not_found, "not_found", error.message
  end

  def render_backend_mismatch(error)
    Rails.logger.error("Storage backend mismatch: #{error.message}")
    render_error :service_unavailable, "storage_unavailable",
                 "The blob is not reachable through the configured storage backend"
  end

  def render_storage_unavailable(error)
    Rails.logger.error("Storage failure: #{error.class}: #{error.message}")
    render_error :service_unavailable, "storage_unavailable", "The storage backend is unavailable; try again later"
  end
end
