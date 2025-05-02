# app/jobs/ttv_generation_job.rb
# Assuming a hypothetical Hedra client/gem

require 'httparty'
require 'json'
require 'tempfile'

class TtvGenerationJob < ApplicationJob
  include HTTParty # Include HTTParty methods

  queue_as :default

  # Hedra processing involves multiple steps and polling
  sidekiq_options retry: 2, dead: true, lock: :until_executed, lock_ttl: 20.minutes

  # Define potential errors for retry
  # Consider retrying on specific network/timeout errors from HTTParty
  # retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 3
  # retry_on Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  # retry_on Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3

  discard_on ActiveJob::DeserializationError

  # Base path for evaluator images and Hedra API
  IMAGES_BASE_PATH = Rails.root.join('app', 'assets', 'images')
  HEDRA_BASE_URL = 'https://mercury.dev.dream-ai.com/api' # Base URL from docs

  # Mapping from agent identifier to image base filename
  # AGENT_IMAGE_BASENAMES = { ... } # REMOVED

  # Polling constants for project status
  PROJECT_POLL_INTERVAL = 8 # seconds
  PROJECT_TIMEOUT = 15 * 60 # 15 minutes

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "TtvGenerationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    # Ensure the previous step completed successfully and audio is present
    unless evaluation.status == 'generating_video' && evaluation.audio_file.attached?
      Rails.logger.info "TtvGenerationJob: Evaluation ##{evaluation_id} has status #{evaluation.status} or missing audio file. Skipping."
      if evaluation.status == 'generating_video' && !evaluation.audio_file.attached?
        evaluation.processing_failed("Missing audio file for TTV generation.")
      end
      return
    end

    # Get agent configuration from central initializer
    agent_config = AGENTS_CONFIG[evaluation.agent_identifier]
    unless agent_config
      msg = "Agent configuration not found for identifier: #{evaluation.agent_identifier}"
      Rails.logger.error "TtvGenerationJob: #{msg} for Evaluation ##{evaluation_id}"
      evaluation.processing_failed(msg)
      return
    end

    agent_image_filename = agent_config[:image_path]
    unless agent_image_filename
      msg = "Image path not configured in AGENTS_CONFIG for agent: #{evaluation.agent_identifier}"
      Rails.logger.error "TtvGenerationJob: #{msg} for Evaluation ##{evaluation_id}"
      evaluation.processing_failed(msg)
      return
    end

    # Construct the full path to the image file
    agent_image_path = IMAGES_BASE_PATH.join(agent_image_filename)

    unless File.exist?(agent_image_path)
      msg = "Agent start image is missing at expected path: #{agent_image_path}"
      Rails.logger.error "TtvGenerationJob: #{msg} for Evaluation ##{evaluation_id}"
      evaluation.processing_failed(msg)
      return
    end

    # Get API Key
    api_key = Rails.application.credentials.dig(:hedra, :api_key)
    unless api_key
      msg = "Hedra API key not found in credentials."
      Rails.logger.error "TtvGenerationJob: #{msg}"
      evaluation.processing_failed(msg)
      return
    end

    headers = { 'X-API-Key' => api_key } # Use X-API-Key header per docs
    audio_url = nil
    image_url = nil
    project_id = nil

    begin
      Rails.logger.info "Starting Hedra TTV flow for Evaluation ##{evaluation.id}"

      # 1. Upload Audio
      Rails.logger.info "Uploading audio for Evaluation ##{evaluation.id}"
      evaluation.audio_file.blob.open do |audio_file|
        audio_response = self.class.post(
          "#{HEDRA_BASE_URL}/v1/audio",
          headers: headers,
          multipart: true,
          body: { file: audio_file }
        )
        raise "Hedra audio upload failed: #{audio_response.code} - #{audio_response.body}" unless audio_response.success?
        audio_url = audio_response.parsed_response['url']
        raise "Hedra audio upload failed: No URL returned." unless audio_url
        Rails.logger.info "Audio uploaded (URL: #{audio_url}) for Evaluation ##{evaluation.id}"
      end

      # 2. Upload Image
      Rails.logger.info "Uploading image #{agent_image_filename} for Evaluation ##{evaluation.id}"
      File.open(agent_image_path, 'rb') do |image_file|
        image_response = self.class.post(
          "#{HEDRA_BASE_URL}/v1/portrait", # Assuming aspect ratio 1:1 default is okay
          headers: headers,
          multipart: true,
          body: { file: image_file }
        )
        # Note: Docs response schema shows UploadAudioResponseBody, but example implies a URL.
        # Assuming 'url' key based on example and common sense.
        raise "Hedra image upload failed: #{image_response.code} - #{image_response.body}" unless image_response.success?
        image_url = image_response.parsed_response['url']
        raise "Hedra image upload failed: No URL returned." unless image_url
        Rails.logger.info "Image uploaded (URL: #{image_url}) for Evaluation ##{evaluation.id}"
      end

      # 3. Initialize Character Generation
      Rails.logger.info "Initializing character generation for Evaluation ##{evaluation.id}"
      init_body = {
        avatarImage: image_url,
        audioSource: "audio",
        voiceUrl: audio_url,
        aspectRatio: "1:1" # Consistent with image upload assumption
      }.to_json
      init_response = self.class.post(
        "#{HEDRA_BASE_URL}/v1/characters",
        headers: headers.merge({ 'Content-Type' => 'application/json' }),
        body: init_body
      )
      raise "Hedra initialization failed: #{init_response.code} - #{init_response.body}" unless init_response.success?
      project_id = init_response.parsed_response['jobId'] # Key is jobId per docs
      raise "Hedra initialization failed: No jobId returned." unless project_id
      Rails.logger.info "Character generation initialized (Project ID: #{project_id}) for Evaluation ##{evaluation.id}"

      # 4. Poll Project Status
      Rails.logger.info "Polling project status (ID: #{project_id}) for Evaluation ##{evaluation.id}"
      start_time = Time.now
      final_video_url = nil
      loop do
        status_response = self.class.get(
          "#{HEDRA_BASE_URL}/v1/projects/#{project_id}",
          headers: headers
        )
        raise "Hedra project status check failed: #{status_response.code} - #{status_response.body}" unless status_response.success?

        project_data = status_response.parsed_response
        project_status = project_data['status'] # Key is status per docs
        Rails.logger.debug "Polling Project ##{project_id} status: #{project_status} (Eval ##{evaluation.id})"

        case project_status
        when 'Completed'
          final_video_url = project_data['videoUrl'] # Key is videoUrl per docs
          Rails.logger.info "Project ##{project_id} completed. Video URL: #{final_video_url}"
          break # Exit loop
        when 'Failed'
          error_message = project_data['errorMessage'] || "Project #{project_status}"
          raise "Hedra project ##{project_id} failed: #{error_message}"
        when 'Queued', 'InProgress'
          # Continue polling
        else
          # Log unexpected status but continue polling for a while just in case
          Rails.logger.warn "Hedra project ##{project_id} returned unexpected status: #{project_status}"
        end

        # Timeout check
        if Time.now - start_time > PROJECT_TIMEOUT
          raise "Hedra project ##{project_id} polling timed out after #{PROJECT_TIMEOUT} seconds. Last status: #{project_status}"
        end

        sleep PROJECT_POLL_INTERVAL
      end

      raise "Hedra project completed but no video URL found." unless final_video_url

      # 5. Download Video
      Rails.logger.info "Downloading final video from #{final_video_url} for Evaluation ##{evaluation.id}"
      # Use stream_body to handle potentially large files without loading all into memory
      video_data = ""
      video_response = self.class.get(final_video_url, stream_body: true) do |fragment|
        video_data << fragment
      end
      # Final check on status code after streaming finishes
      raise "Failed to download video: #{video_response.code} - #{video_response.body}" unless video_response.success?

      # 6. Attach Video
      video_filename = "evaluation_#{evaluation.id}_#{evaluation.agent_identifier}.mp4"
      evaluation.video_file.attach(
        io: StringIO.new(video_data),
        filename: video_filename,
        content_type: 'video/mp4' # Assuming mp4 output
      )

      evaluation.update!(status: 'video_generated')

      # 7. Check if parent job can be marked as completed
      check_and_complete_parent_job(evaluation.evaluation_job)

    rescue StandardError => e
      Rails.logger.error "Error in TtvGenerationJob for Evaluation ##{evaluation.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Hedra processing failed: #{e.message}")
    end
  end

  private

  # Checks if all evaluations for a given job are complete and updates the job status
  def check_and_complete_parent_job(evaluation_job)
    # Reload to ensure we have the latest status of siblings
    evaluation_job.reload
    # Only proceed if the job is still in the processing state
    return unless evaluation_job.status == 'processing_evaluations'

    # Check if all sibling evaluations (including the current one) are video_generated
    if evaluation_job.evaluations.all? { |e| e.status == 'video_generated' }
      Rails.logger.info "All evaluations complete for EvaluationJob ##{evaluation_job.id}. Marking as completed."
      evaluation_job.update!(status: 'completed')
    else
      # Log how many are still pending if needed
      pending_count = evaluation_job.evaluations.where.not(status: 'video_generated').count
      Rails.logger.info "EvaluationJob ##{evaluation_job.id} still has #{pending_count} evaluations pending video generation."
    end
  rescue StandardError => e
      # Log error but don't fail the current TtvGenerationJob just because the check failed
      Rails.logger.error "Error checking/completing parent EvaluationJob ##{evaluation_job&.id}: #{e.message}"
  end
end 