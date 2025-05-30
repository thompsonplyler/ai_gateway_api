module Api
  module V1
    class EvaluationJobsController < ApplicationController
      # TODO: Add authentication/authorization as needed (e.g., using your ApiToken model)
      # before_action :authenticate_user!

      # Thresholds for considering an evaluation stuck in an intermediate state
      LLM_STUCK_THRESHOLD = 90.seconds
      TTS_STUCK_THRESHOLD = 2.minutes
      TTV_STUCK_THRESHOLD = 5.minutes # Note: TTV job itself is currently disabled

      # POST /api/v1/evaluation_jobs
      def create
        # Validate presence and type of the uploaded file
        uploaded_file = params[:powerpoint_file]
        unless uploaded_file && uploaded_file.respond_to?(:content_type) && uploaded_file.content_type.in?(valid_upload_mime_types)
          render json: { error: 'Invalid or missing file. Please upload a .ppt, .pptx, or .pdf file.' }, status: :unprocessable_entity
          return
        end

        # Create the EvaluationJob and attach the file, including skip flags
        @evaluation_job = EvaluationJob.new(evaluation_job_params)
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

        # Base response data (overall job status)
        response_data = {
          id: @evaluation_job.id,
          status: @evaluation_job.status,
          skip_tts: @evaluation_job.skip_tts,
          skip_ttv: @evaluation_job.skip_ttv,
          created_at: @evaluation_job.created_at,
          updated_at: @evaluation_job.updated_at
        }
        # ... add overall error and uploaded_file_url ...
        if @evaluation_job.status == 'failed'
          response_data[:error_message] = @evaluation_job.error_message
        end
        if @evaluation_job.powerpoint_file.attached?
          response_data[:uploaded_file_url] = url_for(@evaluation_job.powerpoint_file)
        end

        # Prepare arrays for detailed results
        individual_evaluations = []
        individual_audio = []
        individual_videos = []

        # Process each child Evaluation record
        @evaluation_job.evaluations.order(:agent_identifier).each do |evaluation|
          # Pass the parent job flags to the status helpers
          llm_status = determine_llm_status(evaluation)
          tts_status = determine_tts_status(evaluation, skip_tts: @evaluation_job.skip_tts)
          ttv_status = determine_ttv_status(evaluation, skip_tts: @evaluation_job.skip_tts, skip_ttv: @evaluation_job.skip_ttv)

          # Common info for all sections related to this evaluation
          base_info = {
            evaluation_id: evaluation.id,
            agent_identifier: evaluation.agent_identifier,
            # Include original evaluation status for debugging/reference if needed
            # original_status: evaluation.status 
          }

          # Error message specific to this evaluation (if it failed overall)
          error_msg = evaluation.error_message if evaluation.status == 'failed'

          # 1. Individual LLM Evaluation Info
          individual_evaluations << base_info.merge({
            status: llm_status,
            text_result: evaluation.text_result,
            error_message: (error_msg if llm_status == 'llm_failed')
          }).compact

          # 2. Individual Audio Info (TTS)
          individual_audio << base_info.merge({
            status: tts_status,
            audio_url: (url_for(evaluation.audio_file) if evaluation.audio_file.attached?),
            error_message: (error_msg if tts_status == 'tts_failed')
          }).compact

          # 3. Individual Video Info (TTV)
          individual_videos << base_info.merge({
            status: ttv_status,
            video_url: (url_for(evaluation.video_file) if evaluation.video_file.attached?),
            error_message: (error_msg if ttv_status == 'ttv_failed')
          }).compact
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

      # POST /api/v1/evaluation_jobs/:id/retry_failed
      def retry_failed
        @evaluation_job = EvaluationJob.includes(:evaluations).find(params[:id])

        # Base query: Find explicitly failed evaluations
        query = @evaluation_job.evaluations.where(status: 'failed')

        # Add conditions for stuck intermediate states
        query = query.or(
          # Stuck in LLM evaluation
          @evaluation_job.evaluations.where(
            status: 'evaluating',
            updated_at: ..(Time.current - LLM_STUCK_THRESHOLD)
          )
        ).or(
          # Stuck generating audio
          @evaluation_job.evaluations.where(
            status: 'generating_audio',
            updated_at: ..(Time.current - TTS_STUCK_THRESHOLD)
          )
        )

        # Conditionally add check for stuck TTV step using the job's flag
        if !@evaluation_job.skip_ttv # Only check if TTV is NOT skipped for this job
          query = query.or(
            @evaluation_job.evaluations.where(
              status: 'generating_video',
              updated_at: ..(Time.current - TTV_STUCK_THRESHOLD)
            )
          )
        end

        # Execute the final query
        failed_or_stuck_evaluations = query

        if failed_or_stuck_evaluations.empty?
          render json: { message: "No failed or stuck evaluations found for job ##{@evaluation_job.id} based on current thresholds and enabled steps." }, status: :ok
          return
        end

        retried_ids = []
        failed_or_stuck_evaluations.find_each do |evaluation| # Use find_each for potentially many records
          retry_evaluation(evaluation)
          retried_ids << evaluation.id
        end

        # Reset parent job status only if we actually retried something
        if retried_ids.any? && @evaluation_job.status != 'processing_evaluations'
          @evaluation_job.update!(status: 'processing_evaluations')
        end

        render json: {
          message: "Attempting to retry #{retried_ids.count} failed or stuck evaluations.",
          retried_evaluation_ids: retried_ids
        }, status: :accepted

      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Evaluation job not found.' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "Error retrying failed or stuck evaluations for Job ##{params[:id]}: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: 'An unexpected error occurred while retrying evaluations.' }, status: :internal_server_error
      end

      private

      def valid_upload_mime_types
        [
          'application/vnd.ms-powerpoint', # .ppt
          'application/vnd.openxmlformats-officedocument.presentationml.presentation', # .pptx
          'application/pdf' # .pdf
        ]
      end

      # Strong parameters for creating EvaluationJob
      def evaluation_job_params
        # Permit the skip flags along with any other creatable attributes
        # Ensure they are cast to boolean (Rails does this often automatically from form data/JSON)
        params.permit(:skip_tts, :skip_ttv)
      end

      # Helper method to reset status and enqueue the correct job
      def retry_evaluation(evaluation)
        original_status = evaluation.status
        Rails.logger.info "Retrying Evaluation ##{evaluation.id} (current status: #{original_status})"
        # Reset error message just in case
        evaluation.error_message = nil

        # Determine where the failure/stall likely occurred based on available artifacts
        if evaluation.text_result.blank?
          # Failure/Stall likely in LLM step or before
          Rails.logger.info "--> Resetting to 'pending' and retrying LLM step for Evaluation ##{evaluation.id}"
          evaluation.status = 'pending' # Reset to initial state
          evaluation.save! # Save status change before enqueuing
          LlmEvaluationJob.perform_later(evaluation.id)
        elsif !evaluation.audio_file.attached?
          # Failure/Stall likely in TTS step
          Rails.logger.info "--> Resetting to 'generating_audio' and retrying TTS step for Evaluation ##{evaluation.id}"
          evaluation.status = 'generating_audio' # Reset to state before TTS
          evaluation.save! # Save status change before enqueuing
          TtsGenerationJob.perform_later(evaluation.id)
        elsif !evaluation.video_file.attached?
          # Failure/Stall likely in TTV step
          Rails.logger.info "--> Resetting to 'generating_video' and retrying TTV step for Evaluation ##{evaluation.id}"
          evaluation.status = 'generating_video' # Reset to state before TTV
          evaluation.save! # Save status change before enqueuing
          # TtvGenerationJob.perform_later(evaluation.id) # UNCOMMENT THIS WHEN TTV IS ENABLED
          Rails.logger.warn "--> TTV Job enqueue is currently commented out in TtsGenerationJob - TTV will not run."
        else
          # Evaluation is failed/stuck but has all artifacts? Unexpected.
          Rails.logger.warn "Evaluation ##{evaluation.id} (status: #{original_status}) seems to have all artifacts? No retry action taken."
        end
      end

      # --- Status Determination Helpers --- 
      def determine_llm_status(evaluation)
        if evaluation.text_result.present?
          'llm_complete'
        elsif evaluation.status == 'evaluating'
          'llm_processing'
        elsif evaluation.status == 'pending'
          'llm_pending'
        elsif evaluation.status == 'failed' # && evaluation.text_result.blank? implicitly true
          'llm_failed'
        else 
          nil # Or some default like 'unknown'
        end
      end

      def determine_tts_status(evaluation, skip_tts: false)
        has_text = evaluation.text_result.present?
        has_audio = evaluation.audio_file.attached?

        if has_audio
          'tts_complete'
        elsif evaluation.status == 'generating_audio'
          'tts_processing'
        elsif evaluation.status == 'failed' && !has_audio && has_text
          'tts_failed'
        elsif skip_tts && has_text && evaluation.status != 'failed' # If TTS was skipped
           'tts_skipped' 
        elsif has_text && !has_audio && evaluation.status != 'failed'
          'tts_pending' # Means LLM is done, waiting for TTS
        elsif !has_text && evaluation.status != 'failed'
          'tts_awaiting_llm'
        else
          nil
        end
      end

      def determine_ttv_status(evaluation, skip_tts: false, skip_ttv: false)
        has_audio = evaluation.audio_file.attached?
        has_video = evaluation.video_file.attached?

        if has_video
          'ttv_complete'
        elsif evaluation.status == 'generating_video' && !skip_ttv # Processing only if not skipped
          'ttv_processing'
        elsif evaluation.status == 'failed' && !has_video && has_audio
          'ttv_failed'
        elsif skip_ttv && has_audio && evaluation.status != 'failed' # If TTV was skipped
          'ttv_skipped' 
        elsif has_audio && !has_video && evaluation.status != 'failed'
           'ttv_pending' # Means TTS is done, waiting for TTV (if enabled)
        elsif skip_tts # If TTS was skipped, TTV is implicitly skipped/awaiting impossible pre-req
           'ttv_awaiting_tts' # Or could argue for ttv_skipped
        elsif !has_audio && evaluation.status != 'failed'
          'ttv_awaiting_tts'
        else
           nil
        end
      end
      # --- End Status Helpers --- 

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