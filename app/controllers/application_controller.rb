class ApplicationController < ActionController::API
  # Expose current_user helper method to controllers
  attr_reader :current_user

  # Handle missing parameters globally with a 400 Bad Request response
  rescue_from ActionController::ParameterMissing do |exception|
    render json: { error: exception.message }, status: :bad_request
  end

  protected # Keep methods below private to controllers

  # Authenticate requests based on Authorization: Bearer <token> header
  def authenticate_user!
    token = extract_token_from_header
    unless token
      render json: { error: 'Authorization header missing or invalid' }, status: :unauthorized
      return
    end

    api_token = ApiToken.find_by(token: token)
    if api_token.nil? || api_token.expired?
      render json: { error: 'Invalid or expired token' }, status: :unauthorized
      return
    end

    # Token is valid and active, set the current user
    @current_user = api_token.user
  rescue ActiveRecord::RecordNotFound # Handle case where user associated with token is deleted
     render json: { error: 'User not found for token' }, status: :unauthorized
  end

  private

  # Extracts the token value from the Authorization header
  def extract_token_from_header
    header = request.headers['Authorization']
    header&.match(/^Bearer\s+(.*)$/)&.captures&.first
  end
end
