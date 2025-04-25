module Api
  module V1
    class UsersController < ApplicationController
      # POST /api/v1/users
      def create
        user = User.new(user_params)

        if user.save
          # Exclude password_digest from the response for security
          render json: user.as_json(except: :password_digest), status: :created # 201
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity # 422
        end
      end

      private

      # Strong parameters: only allow email, password, and password_confirmation
      def user_params
        params.require(:user).permit(:email, :password, :password_confirmation)
      end
    end
  end
end
