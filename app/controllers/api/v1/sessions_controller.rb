module Api
  module V1
    class SessionsController < ApplicationController
      # POST /api/v1/session
      def create
        user = User.find_by(email: session_params[:email])

        if user&.authenticate(session_params[:password])
          # Password is correct, create a new API token
          # Consider deleting old tokens if you only want one active token per user
          api_token = user.api_tokens.create! # Let the model handle token generation/expiration
          render json: { 
            message: "Login successful", 
            token: api_token.token, 
            expires_at: api_token.expires_at 
          }, status: :created # 201
        else
          # User not found or password incorrect
          render json: { error: "Invalid email or password" }, status: :unauthorized # 401
        end
      end

      # DELETE /api/v1/session (Placeholder for now)
      def destroy
        # In a real app, you would find the token based on the request header
        # and destroy it. This requires authentication first.
        # For now, just return a success message.
        render json: { message: "Logout endpoint hit (implement token deletion later)" }, status: :ok
      end

      private

      def session_params
        # First, require the top-level :session key
        permitted = params.require(:session).permit(:email, :password)
        # Then, require the specific keys within the permitted hash
        permitted.require(:email)
        permitted.require(:password)
        permitted # Return the hash if all requirements met
      end
    end
  end
end
