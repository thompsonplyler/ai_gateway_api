# config/initializers/sidekiq.rb

# Default Redis URL for development/test
# In production (Render), this will be overridden by the REDIS_URL env var
redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end