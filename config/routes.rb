Rails.application.routes.draw do
  namespace :v1 do
    post "blobs", to: "blobs#create"
    # Identifiers are opaque and may contain "/" or ".", so the id segment is
    # a glob and no format suffix is split off it.
    get "blobs/*id", to: "blobs#show", format: false, as: :blob
  end
end
