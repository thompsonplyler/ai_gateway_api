# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# Read more: https://github.com/cyu/rack-cors

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Allow requests from the Vite development server
    origins "http://localhost:5173"

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      credentials: false # Adjust if you need cookies/sessions across origins
  end

  # Add other origins if needed, e.g., your production frontend URL
  # allow do
  #   origins 'YOUR_PRODUCTION_FRONTEND_URL'
  #   resource "*",
  #     headers: :any,
  #     methods: [:get, :post, :options, :head]
  # end
end
