require 'rails_helper'

RSpec.describe "Api::V1::Sessions", type: :request do
  let!(:user) { User.create!(email: "login@example.com", password: "password123", password_confirmation: "password123") }

  describe "POST /api/v1/session" do # Login
    let(:valid_credentials) { { session: { email: user.email, password: "password123" } } }
    let(:invalid_password_credentials) { { session: { email: user.email, password: "wrong" } } }
    let(:non_existent_user_credentials) { { session: { email: "nosuchuser@example.com", password: "password123" } } }
    let(:missing_params_credentials) { { session: { email: user.email } } } # Missing password
    let(:missing_session_key) { { email: user.email, password: "password123" } }

    context "with valid credentials" do
      it "returns status :created (201)" do
        post api_v1_session_path, params: valid_credentials
        expect(response).to have_http_status(:created)
      end

      it "returns a success message, token, and expiration" do
        post api_v1_session_path, params: valid_credentials
        json_response = JSON.parse(response.body)
        expect(json_response['message']).to eq("Login successful")
        expect(json_response['token']).to be_a(String)
        expect(json_response['token'].length).to eq(64)
        expect(json_response['expires_at']).to be_present
        # Check if expires_at is a valid date roughly 1 year from now
        expect(Time.parse(json_response['expires_at'])).to be_within(1.minute).of(1.year.from_now)
      end

      it "creates an ApiToken for the user" do
        expect {
          post api_v1_session_path, params: valid_credentials
        }.to change(user.api_tokens, :count).by(1)
      end
    end

    context "with invalid password" do
      it "returns status :unauthorized (401)" do
        post api_v1_session_path, params: invalid_password_credentials
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns an error message" do
        post api_v1_session_path, params: invalid_password_credentials
        json_response = JSON.parse(response.body)
        expect(json_response['error']).to eq("Invalid email or password")
      end

      it "does not create an ApiToken" do
        expect {
          post api_v1_session_path, params: invalid_password_credentials
        }.not_to change(ApiToken, :count)
      end
    end

    context "with non-existent user" do
      it "returns status :unauthorized (401)" do
        post api_v1_session_path, params: non_existent_user_credentials
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns an error message" do
        post api_v1_session_path, params: non_existent_user_credentials
        json_response = JSON.parse(response.body)
        expect(json_response['error']).to eq("Invalid email or password")
      end
    end

    context "with missing parameters" do
      it "returns status :bad_request (400)" do
        post api_v1_session_path, params: missing_params_credentials
        expect(response).to have_http_status(:bad_request)
        json_response = JSON.parse(response.body)
        expect(json_response['error']).to include("param is missing or the value is empty: password")
      end
    end
    
    context "with missing session key" do
      it "returns status :bad_request (400)" do
        post api_v1_session_path, params: missing_session_key
        expect(response).to have_http_status(:bad_request)
        json_response = JSON.parse(response.body)
        expect(json_response['error']).to include("param is missing or the value is empty: session")
      end
    end
  end

  # Basic placeholder test for logout - full testing requires authentication
  describe "DELETE /api/v1/session" do # Logout
    it "returns status :ok (200)" do
      delete api_v1_session_path
      expect(response).to have_http_status(:ok)
    end
  end
end
