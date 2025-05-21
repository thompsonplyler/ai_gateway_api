require 'sidekiq/web'

Rails.application.routes.draw do
  mount Sidekiq::Web => '/sidekiq'
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  namespace :api do
    namespace :v1 do
      # AI Tasks: Add index and show
      resources :ai_tasks, only: [:create, :index, :show]

      # User Registration
      resources :users, only: [:create]

      # Session/Token Management (Login/Logout)
      resource :session, only: [:create, :destroy] # Use singular resource for non-ID-based session
      # Alternatively: post '/login', to: 'sessions#create'
      #              delete '/logout', to: 'sessions#destroy'

      # Multi-step Video Evaluation Jobs
      resources :evaluation_jobs, only: [:create, :show, :index] do
        member do
          post :retry_failed # Add route for retrying failed evaluations
          get :status # Existing route
          get :test_combine_videos # New route for testing video combination
        end
      end

      # Simple Text Evaluation Jobs
      resources :text_evaluation_jobs, only: [:create, :show]

      resources :quest_candidates, only: [:index, :show] do
        collection do
          post :generate # To trigger a new quest generation
        end
      end
    end
  end

  # Optional: Health check endpoint for Render
  get "/health", to: "health#show"
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # Point root to the rails health check endpoint
  root "rails/health#show"
end
