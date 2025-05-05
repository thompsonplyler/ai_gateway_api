module Api
  module V1
    class TextEvaluationJobsController < ApplicationController
      # TODO: Add authentication/authorization as needed
      # before_action :authenticate_user!

      # POST /api/v1/text_evaluation_jobs
      def create
        uploaded_file = params[:powerpoint_file]
        unless uploaded_file && uploaded_file.respond_to?(:content_type) && uploaded_file.content_type.in?(valid_upload_mime_types)
          render json: { error: 'Invalid or missing file. Please upload a .ppt, .pptx, or .pdf file.' }, status: :unprocessable_entity
          return
        end

        @text_eval_job = TextEvaluationJob.new
        @text_eval_job.powerpoint_file.attach(uploaded_file)

        if @text_eval_job.save
          render json: { 
            message: 'Text evaluation job created successfully.',
            job_id: @text_eval_job.id,
            status: @text_eval_job.status,
            status_url: api_v1_text_evaluation_job_url(@text_eval_job)
          }, status: :created
        else
          render json: { errors: @text_eval_job.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error "Error creating TextEvaluationJob: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: 'An unexpected error occurred while creating the text evaluation job.' }, status: :internal_server_error
      end

      # GET /api/v1/text_evaluation_jobs/:id
      def show
        @text_eval_job = TextEvaluationJob.find(params[:id])

        response_data = {
          id: @text_eval_job.id,
          status: @text_eval_job.status,
          created_at: @text_eval_job.created_at,
          updated_at: @text_eval_job.updated_at
        }

        if @text_eval_job.powerpoint_file.attached?
          response_data[:powerpoint_file_url] = url_for(@text_eval_job.powerpoint_file)
        end

        # Include results from child evaluations
        evaluations_data = @text_eval_job.text_evaluations.order(:agent_identifier).map do |evaluation|
          {
            agent_identifier: evaluation.agent_identifier,
            status: evaluation.status,
            text_result: (evaluation.text_result if evaluation.status == 'completed'),
            error_message: (evaluation.error_message if evaluation.status == 'failed')
          }.compact # Remove keys with nil values
        end
        response_data[:evaluations] = evaluations_data

        # Include overall error message if the parent job failed
        if @text_eval_job.status == 'failed'
          response_data[:error_message] = @text_eval_job.error_message
        end

        render json: response_data, status: :ok

      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Text evaluation job not found.' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "Error retrieving TextEvaluationJob ##{params[:id]}: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: 'An unexpected error occurred while retrieving the job status.' }, status: :internal_server_error
      end

      private

      # Allowed MIME types for upload
      def valid_upload_mime_types
        [
          'application/vnd.ms-powerpoint', # .ppt
          'application/vnd.openxmlformats-officedocument.presentationml.presentation', # .pptx
          'application/pdf' # .pdf
        ]
      end

      # TODO: Implement authentication logic if needed
    end
  end
end 