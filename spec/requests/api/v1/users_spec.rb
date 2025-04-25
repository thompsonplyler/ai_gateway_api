require 'rails_helper'

RSpec.describe "Api::V1::Users", type: :request do
  describe "POST /api/v1/users" do
    let(:valid_user_params) do
      { user: { email: "test@example.com", password: "password123", password_confirmation: "password123" } }
    end

    context "with valid parameters" do
      it "creates a new User" do
        expect {
          post api_v1_users_path, params: valid_user_params
        }.to change(User, :count).by(1)
      end

      it "returns status :created (201)" do
        post api_v1_users_path, params: valid_user_params
        expect(response).to have_http_status(:created)
      end

      it "returns the created user details (without password_digest)" do
        post api_v1_users_path, params: valid_user_params
        json_response = JSON.parse(response.body)
        expect(json_response['email']).to eq("test@example.com")
        expect(json_response).not_to have_key('password_digest')
        expect(json_response['id']).to be_present
      end
    end

    context "with invalid parameters" do
      it "does not create a User if email is missing" do
        invalid_params = { user: { password: "password123", password_confirmation: "password123" } }
        expect {
          post api_v1_users_path, params: invalid_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include("Email can't be blank")
        expect(JSON.parse(response.body)['errors']).to include("Email must be a valid email address")
      end
      
      it "does not create a User if email format is invalid" do
        invalid_params = { user: { email: "invalid", password: "password123", password_confirmation: "password123" } }
        expect {
          post api_v1_users_path, params: invalid_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include("Email must be a valid email address")
      end

      it "does not create a User if password is too short" do
        invalid_params = { user: { email: "test@example.com", password: "123", password_confirmation: "123" } }
        expect {
          post api_v1_users_path, params: invalid_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include("Password is too short (minimum is 8 characters)")
      end

      it "does not create a User if password confirmation doesn't match" do
        invalid_params = { user: { email: "test@example.com", password: "password123", password_confirmation: "nomatch" } }
        expect {
          post api_v1_users_path, params: invalid_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        # Note: has_secure_password provides this validation
        expect(JSON.parse(response.body)['errors']).to include("Password confirmation doesn't match Password")
      end
      
      it "does not create a User if email is already taken" do
        User.create!(email: "test@example.com", password: "password456")
        expect {
          post api_v1_users_path, params: valid_user_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include("Email has already been taken")
      end
    end
    
    context "when user key is missing" do
      it "returns bad_request (400)" do
        post api_v1_users_path, params: { email: "test@example.com", password: "password123" } # Missing top-level :user key
        expect(response).to have_http_status(:bad_request) # Expect 400
        
        # Check the standard error format for ParameterMissing
        json_response = JSON.parse(response.body)
        expect(json_response['error']).to include("param is missing or the value is empty: user")
      end
    end
  end
end
