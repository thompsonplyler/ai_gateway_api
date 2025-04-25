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
    Rails.logger.debug("--- Authenticating User ---")
    auth_header = request.headers['Authorization']
    Rails.logger.debug("Received Authorization Header: #{auth_header.inspect}")

    token = extract_token_from_header
    Rails.logger.debug("Extracted Token: #{token.inspect}")

    unless token
      Rails.logger.debug("Authentication Fail: Token extraction failed.")
      render json: { error: 'Authorization header missing or invalid' }, status: :unauthorized
      return
    end

    Rails.logger.debug("Looking up ApiToken with token: #{token}")
    api_token = ApiToken.find_by(token: token)
    
    if api_token.nil?
      Rails.logger.debug("Authentication Fail: ApiToken not found in DB.")
      render json: { error: 'Invalid or expired token' }, status: :unauthorized
      return
    elsif api_token.expired?
      Rails.logger.debug("Authentication Fail: ApiToken found but expired at #{api_token.expires_at}.")
      render json: { error: 'Invalid or expired token' }, status: :unauthorized
      return
    end

    # Token is valid and active, set the current user
    @current_user = api_token.user
    Rails.logger.debug("Authentication Success: User ID #{@current_user.id} set.")

  rescue ActiveRecord::RecordNotFound => e
     Rails.logger.debug("Authentication Fail: User for token not found. Error: #{e.message}")
     render json: { error: 'User not found for token' }, status: :unauthorized
  end

  private

  # Extracts the token value from the Authorization header
  def extract_token_from_header
    header = request.headers['Authorization']
    header&.match(/^Bearer\s+(.*)$/)&.captures&.first
  end
end
