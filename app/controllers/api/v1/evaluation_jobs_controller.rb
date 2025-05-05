module Api
  module V1
    class EvaluationJobsController < ApplicationController
      # TODO: Add authentication/authorization as needed (e.g., using your ApiToken model)
      # before_action :authenticate_user!

      # POST /api/v1/evaluation_jobs
      def create
        # Validate presence and type of the uploaded file
        uploaded_file = params[:powerpoint_file]
        unless uploaded_file && uploaded_file.respond_to?(:content_type) && uploaded_file.content_type.in?(valid_upload_mime_types)
          render json: { error: 'Invalid or missing file. Please upload a .ppt, .pptx, or .pdf file.' }, status: :unprocessable_entity
          return
        end

        # Create the EvaluationJob and attach the file
        @evaluation_job = EvaluationJob.new
        @evaluation_job.powerpoint_file.attach(uploaded_file)

        if @evaluation_job.save
          # The after_create_commit callback in the model will handle creating
          # child Evaluation records and enqueuing the LlmEvaluationJobs.
          render json: { 
            message: 'Evaluation job created successfully.',
            evaluation_job_id: @evaluation_job.id,
            status: @evaluation_job.status,
            # Provide a URL to check status (implement the show action)
            status_url: api_v1_evaluation_job_url(@evaluation_job) 
          }, status: :created
        else
          render json: { errors: @evaluation_job.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error "Error creating EvaluationJob: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: 'An unexpected error occurred while creating the evaluation job.' }, status: :internal_server_error
      end

      # GET /api/v1/evaluation_jobs/:id
      def show
        # Eager load evaluations to avoid N+1 queries
        @evaluation_job = EvaluationJob.includes(:evaluations).find(params[:id])

        # Base response data
        response_data = {
          id: @evaluation_job.id,
          status: @evaluation_job.status, # Overall status
          created_at: @evaluation_job.created_at,
          updated_at: @evaluation_job.updated_at
        }

        # Add overall error if the parent job itself failed
        if @evaluation_job.status == 'failed'
          response_data[:error_message] = @evaluation_job.error_message
        end

        # Add URL to the originally uploaded file
        if @evaluation_job.powerpoint_file.attached?
          response_data[:uploaded_file_url] = url_for(@evaluation_job.powerpoint_file)
        end

        # Prepare arrays for detailed results
        individual_evaluations = []
        individual_audio = []
        individual_videos = []

        # Process each child Evaluation record
        @evaluation_job.evaluations.order(:agent_identifier).each do |evaluation|
          base_info = {
            evaluation_id: evaluation.id,
            agent_identifier: evaluation.agent_identifier,
            status: evaluation.status, # Specific status of this child evaluation
            error_message: (evaluation.error_message if evaluation.status == 'failed')
          }.compact # Remove nil error_message

          # 1. Individual LLM Evaluation Info
          llm_info = base_info.merge({
            text_result: evaluation.text_result
          }).compact # Remove nil text_result if not available yet
          individual_evaluations << llm_info

          # 2. Individual Audio Info (TTS)
          audio_info = base_info.dup # Start with base info
          audio_info[:audio_url] = url_for(evaluation.audio_file) if evaluation.audio_file.attached?
          individual_audio << audio_info

          # 3. Individual Video Info (TTV)
          video_info = base_info.dup # Start with base info
          video_info[:video_url] = url_for(evaluation.video_file) if evaluation.video_file.attached?
          individual_videos << video_info
        end

        # Add the detailed arrays to the response
        response_data[:individual_evaluations] = individual_evaluations
        response_data[:individual_audio] = individual_audio
        response_data[:individual_videos] = individual_videos

        render json: response_data, status: :ok

      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Evaluation job not found.' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "Error retrieving EvaluationJob ##{params[:id]}: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: 'An unexpected error occurred while retrieving the job status.' }, status: :internal_server_error
      end

      private

      def valid_upload_mime_types
        [
          'application/vnd.ms-powerpoint', # .ppt
          'application/vnd.openxmlformats-officedocument.presentationml.presentation', # .pptx
          'application/pdf' # .pdf
        ]
      end

      # TODO: Implement authentication logic if needed
      # def authenticate_user!
      #   # Example: Check for a valid token from request headers
      #   token = request.headers['Authorization']&.split(' ')&.last
      #   api_token = ApiToken.find_by(token: token)
      #   unless api_token && api_token.active?
      #     render json: { error: 'Unauthorized' }, status: :unauthorized
      #   end
      #   # @current_user = api_token.user # Optional: set current user
      # end
    end
  end
end 