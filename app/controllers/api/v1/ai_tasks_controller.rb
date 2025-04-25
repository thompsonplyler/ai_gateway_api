module Api
  module V1
    class AiTasksController < ApplicationController # Should inherit from ApplicationController (which inherits from ActionController::API)
      def create
        prompt = params.require(:prompt) # Basic parameter validation

        # Optional: Create a record in DB to track the task before queueing
        # ai_task = AiTask.create!(prompt: prompt, status: 'queued')

        # Enqueue the job to run in the background
        ProcessAiTaskJob.perform_later(prompt) # Pass ai_task.id if created

        # Respond immediately (202 Accepted is suitable for background jobs)
        render json: { message: "AI task accepted for processing.", prompt: prompt }, status: :accepted
      rescue ActionController::ParameterMissing => e
        render json: { error: e.message }, status: :bad_request
      end
    end
  end
end