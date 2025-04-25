# spec/requests/api/v1/ai_tasks_spec.rb
require 'rails_helper'

RSpec.describe "Api::V1::AiTasks", type: :request do
  describe "POST /api/v1/ai_tasks" do
    let(:valid_params) { { prompt: "Translate 'hello' to French" } }
    let(:invalid_params) { { prompt: nil } } # Missing prompt

    context "with valid parameters" do
      it "returns status :accepted (202)" do
        post api_v1_ai_tasks_path, params: valid_params
        expect(response).to have_http_status(:accepted)
      end

      it "returns a confirmation message" do
        post api_v1_ai_tasks_path, params: valid_params
        json_response = JSON.parse(response.body)
        expect(json_response['message']).to eq("AI task accepted for processing.")
        expect(json_response['prompt']).to eq(valid_params[:prompt])
      end

      it "enqueues a ProcessAiTaskJob" do
         # Using Sidekiq::Testing.fake! (default for :request type)
         expect {
           post api_v1_ai_tasks_path, params: valid_params
         }.to have_enqueued_job(ProcessAiTaskJob).with(valid_params[:prompt]).on_queue("default")

         # Optional: Clear the queue if needed for subsequent tests in the same context
         # clear_enqueued_jobs
      end
    end

    context "with invalid parameters" do
      it "returns status :bad_request (400)" do
        post api_v1_ai_tasks_path, params: invalid_params
        expect(response).to have_http_status(:bad_request)
      end

      it "returns an error message" do
         post api_v1_ai_tasks_path, params: invalid_params
         json_response = JSON.parse(response.body)
         expect(json_response['error']).to include("param is missing or the value is empty: prompt")
       end

      it "does not enqueue a job" do
         expect {
           post api_v1_ai_tasks_path, params: invalid_params
         }.not_to have_enqueued_job(ProcessAiTaskJob)
       end
    end
  end
end