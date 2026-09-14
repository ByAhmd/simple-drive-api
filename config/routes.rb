Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    post "blobs", to: "blobs#create"
    # Identifiers are opaque and may contain "/" or ".", so the id segment is
    # a glob and no format suffix is split off it.
    get "blobs/*id", to: "blobs#show", format: false, as: :blob
  end
end
