# app/jobs/ttv_generation_job.rb
# Assuming a hypothetical Hedra client/gem

class TtvGenerationJob < ApplicationJob
  queue_as :default

  # Hedra processing might take longer
  sidekiq_options retry: 2, dead: true, lock: :until_executed, lock_ttl: 20.minutes

  # TODO: Define specific Hedra errors for retry if available
  # retry_on Hedra::ApiError, wait: :exponentially_longer, attempts: 3

  discard_on ActiveJob::DeserializationError

  # Define path to your static starting image
  # This could be in `app/assets/images`, `public/`, or configured elsewhere
  STATIC_IMAGE_PATH = Rails.root.join('app', 'assets', 'images', 'hedra_start_image.png')

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

    unless File.exist?(STATIC_IMAGE_PATH)
      Rails.logger.error "TtvGenerationJob: Static image not found at #{STATIC_IMAGE_PATH} for Evaluation ##{evaluation_id}"
      evaluation.processing_failed("Static start image is missing.")
      return
    end

    begin
      Rails.logger.info "Generating TTV for Evaluation ##{evaluation.id}"
      # TODO: Configure Hedra client with API key
      # client = Hedra::Client.new(api_key: Rails.application.credentials.hedra[:api_key])

      # Download the audio file content from ActiveStorage
      audio_data = evaluation.audio_file.download

      # Placeholder: Simulate Hedra API call
      # response = client.generate_video(
      #   audio_data: audio_data,
      #   image_path: STATIC_IMAGE_PATH,
      #   # other Hedra parameters...
      # )
      # video_data = response.video_content # Assuming API returns binary video data
      video_data = "fake_mp4_data_for_#{evaluation.id}".force_encoding('BINARY')
      video_filename = "evaluation_#{evaluation.id}_#{evaluation.agent_identifier}.mp4"
      sleep(10) # Simulate API call delay

      # Attach the received video data using ActiveStorage
      evaluation.video_file.attach(
        io: StringIO.new(video_data),
        filename: video_filename,
        content_type: 'video/mp4'
      )

      evaluation.update!(status: 'video_generated')

      # Check if all evaluations for the parent job are done
      evaluation.evaluation_job.check_and_start_concatenation
      Rails.logger.info "TTV generation complete for Evaluation ##{evaluation.id}. Checked for concatenation."

    # rescue Hedra::ApiError => e
    #   Rails.logger.error "Hedra API error for Evaluation ##{evaluation.id}: #{e.message}"
    #   evaluation.processing_failed("Hedra API error: #{e.message}")
    #   # raise e # Optional: Re-raise for retries
    rescue StandardError => e
      Rails.logger.error "Unexpected error in TtvGenerationJob for Evaluation ##{evaluation.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during TTV generation: #{e.message}")
    end
  end
end 