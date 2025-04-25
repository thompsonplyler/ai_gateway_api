# spec/requests/api/v1/ai_tasks_spec.rb
require 'rails_helper'

# Helper method to generate auth headers
def auth_headers(user)
  token = user.api_tokens.create!
  { 'Authorization' => "Bearer #{token.token}" }
end

RSpec.describe "Api::V1::AiTasks", type: :request do
  let!(:user) { User.create!(email: "user@example.com", password: "password123") }
  let!(:other_user) { User.create!(email: "other@example.com", password: "password123") }
  let!(:user_headers) { auth_headers(user) } # Generate headers for our main user

  describe "POST /api/v1/ai_tasks" do
    let(:valid_params) { { prompt: "Translate 'hello' to French" } }

    context "when authenticated" do
      context "with valid parameters" do
        it "returns status :accepted (202)" do
          post api_v1_ai_tasks_path, params: valid_params, headers: user_headers
          expect(response).to have_http_status(:accepted)
        end

        it "returns a confirmation message, task_id, and status" do
          post api_v1_ai_tasks_path, params: valid_params, headers: user_headers
          json_response = JSON.parse(response.body)
          expect(json_response['message']).to eq("AI task accepted for processing.")
          expect(json_response['task_id']).to be_a(Integer)
          expect(json_response['status']).to eq('queued')
        end

        it "creates an AiTask associated with the current user" do
          expect {
            post api_v1_ai_tasks_path, params: valid_params, headers: user_headers
          }.to change(user.ai_tasks, :count).by(1)
        end

        it "enqueues a ProcessAiTaskJob with prompt and task_id" do
          # Ensure the job test helper runs jobs inline for this check
          ActiveJob::Base.queue_adapter = :inline 
          # We need to check the *arguments* passed to the job
          expect(ProcessAiTaskJob).to receive(:perform_later).with(valid_params[:prompt], instance_of(Integer)).and_call_original
          post api_v1_ai_tasks_path, params: valid_params, headers: user_headers
          # Reset adapter if necessary for other tests
          ActiveJob::Base.queue_adapter = :test 
        end
      end

      context "with invalid parameters (missing prompt)" do
        let(:invalid_params) { { prompt: nil } }
        
        it "returns status :bad_request (400)" do
          post api_v1_ai_tasks_path, params: invalid_params, headers: user_headers
          expect(response).to have_http_status(:bad_request)
        end

        it "returns an error message" do
           post api_v1_ai_tasks_path, params: invalid_params, headers: user_headers
           json_response = JSON.parse(response.body)
           expect(json_response['error']).to include("param is missing or the value is empty: prompt")
         end

        it "does not create an AiTask" do
          expect {
            post api_v1_ai_tasks_path, params: invalid_params, headers: user_headers
          }.not_to change(AiTask, :count)
        end

        it "does not enqueue a job" do
          expect {
             post api_v1_ai_tasks_path, params: invalid_params, headers: user_headers
          }.not_to have_enqueued_job(ProcessAiTaskJob)
         end
      end
    end

    context "when not authenticated" do
      it "returns status :unauthorized (401)" do
        post api_v1_ai_tasks_path, params: valid_params # No headers
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end # End POST

  describe "GET /api/v1/ai_tasks" do # Index
    let!(:task1) { user.ai_tasks.create!(prompt: "Task 1") }
    let!(:task2) { user.ai_tasks.create!(prompt: "Task 2") }
    let!(:other_task) { other_user.ai_tasks.create!(prompt: "Other User Task") }

    context "when authenticated" do
      it "returns status :ok (200)" do
        get api_v1_ai_tasks_path, headers: user_headers
        expect(response).to have_http_status(:ok)
      end

      it "returns only the tasks belonging to the current user" do
        get api_v1_ai_tasks_path, headers: user_headers
        json_response = JSON.parse(response.body)
        expect(json_response.size).to eq(2)
        expect(json_response.map { |t| t['id'] }).to match_array([task1.id, task2.id])
        expect(json_response.map { |t| t['id'] }).not_to include(other_task.id)
      end
    end

    context "when not authenticated" do
      it "returns status :unauthorized (401)" do
        get api_v1_ai_tasks_path # No headers
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end # End GET Index

  describe "GET /api/v1/ai_tasks/:id" do # Show
    let!(:task) { user.ai_tasks.create!(prompt: "Task to show") }
    let!(:other_task) { other_user.ai_tasks.create!(prompt: "Another task") }

    context "when authenticated" do
      context "accessing own task" do
        it "returns status :ok (200)" do
          get api_v1_ai_task_path(task), headers: user_headers
          expect(response).to have_http_status(:ok)
        end

        it "returns the correct task details" do
          get api_v1_ai_task_path(task), headers: user_headers
          json_response = JSON.parse(response.body)
          expect(json_response['id']).to eq(task.id)
          expect(json_response['prompt']).to eq(task.prompt)
          expect(json_response['status']).to eq(task.status)
        end
      end

      context "accessing another user's task" do
        it "returns status :not_found (404)" do
          get api_v1_ai_task_path(other_task), headers: user_headers
          expect(response).to have_http_status(:not_found)
        end
      end

      context "accessing non-existent task" do
        it "returns status :not_found (404)" do
          get api_v1_ai_task_path(id: task.id + 100), headers: user_headers
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context "when not authenticated" do
      it "returns status :unauthorized (401)" do
        get api_v1_ai_task_path(task) # No headers
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end # End GET Show

end