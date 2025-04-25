module Api
  module V1
    # Inherit from ApplicationController to get authentication logic
    class AiTasksController < ApplicationController 
      # Require authentication for all actions in this controller
      before_action :authenticate_user! 
      before_action :set_ai_task, only: [:show] # Find task for show action

      # GET /api/v1/ai_tasks
      def index
        # Only show tasks belonging to the current authenticated user
        @ai_tasks = current_user.ai_tasks.order(created_at: :desc) # Order by most recent
        render json: @ai_tasks
      end

      # GET /api/v1/ai_tasks/:id
      def show
        # @ai_task is set by before_action :set_ai_task
        # Authorization is implicitly handled because set_ai_task finds within current_user
        render json: @ai_task
      end

      # POST /api/v1/ai_tasks
      def create
        prompt = params.require(:prompt) # Basic parameter validation

        # Associate the task with the current authenticated user
        ai_task = current_user.ai_tasks.build(prompt: prompt) # Use build for association
        # Status defaults to 'queued' via DB default

        if ai_task.save
          # Enqueue the job to run in the background, passing the task id
          ProcessAiTaskJob.perform_later(prompt, ai_task.id) # Pass ai_task.id 

          # Respond immediately (202 Accepted is suitable for background jobs)
          render json: { 
            message: "AI task accepted for processing.", 
            task_id: ai_task.id,
            status: ai_task.status # Include initial status
          }, status: :accepted
        else
          render json: { errors: ai_task.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      # Finds the AiTask scoped to the current user
      def set_ai_task
        @ai_task = current_user.ai_tasks.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Task not found" }, status: :not_found
      end
    end
  end
end