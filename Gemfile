source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]; 6.1 added the
# http_content_length_limit setting used in config/puma.rb
gem "puma", ">= 6.1"

# Ruby's FTP client, used by the FTP storage backend; a bundled gem since
# Ruby 3.1, so it has to be declared to be loadable under Bundler
gem "net-ftp"

# json 3.0 made JSON.parse's options keyword-only, which Active Support 8.1.3
# does not pass yet; every JSON request body would fail to parse.
gem "json", "< 4"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Loads .env files in development and test so local configuration stays out of the shell profile
  gem "dotenv-rails"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :test do
  # Stubs outbound HTTP so the S3 adapter can be tested without a live server
  gem "webmock"

  # Minitest 6 ships its stub/mock helpers as a separate gem
  gem "minitest-mock"
end
