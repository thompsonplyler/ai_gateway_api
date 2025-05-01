require 'elevenlabs' # Assuming you have the elevenlabs gem

class TtsGenerationJob < ApplicationJob
  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 5.minutes

  # TODO: Define specific ElevenLabs errors for retry if available
  # retry_on ElevenLabs::ApiError, wait: :exponentially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "TtsGenerationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    # Ensure the previous step completed successfully
    unless evaluation.status == 'generating_audio' && evaluation.text_result.present?
      Rails.logger.info "TtsGenerationJob: Evaluation ##{evaluation_id} has status #{evaluation.status} or missing text. Skipping."
      # Consider failing the job if text is missing but status is generating_audio
      if evaluation.status == 'generating_audio' && evaluation.text_result.blank?
        evaluation.processing_failed("Missing text result for TTS generation.")
      end
      return
    end

    begin
      Rails.logger.info "Generating TTS for Evaluation ##{evaluation.id}"
      # TODO: Configure ElevenLabs client with API key
      # client = ElevenLabs::Client.new(api_key: Rails.application.credentials.elevenlabs[:api_key])

      # TODO: Choose voice ID and model
      # voice_id = 'some_voice_id' # Find appropriate voice ID from ElevenLabs
      # model_id = 'eleven_multilingual_v2' # Or another suitable model

      # Placeholder: Simulate API call and getting audio data
      # audio_data = client.text_to_speech.create(
      #   voice_id: voice_id,
      #   model_id: model_id,
      #   text: evaluation.text_result
      # ) # This likely returns binary audio data
      audio_data = "fake_mp3_data_for_#{evaluation.id}".force_encoding('BINARY')
      audio_filename = "evaluation_#{evaluation.id}_#{evaluation.agent_identifier}.mp3"
      sleep(3) # Simulate API call delay

      # Attach the received audio data using ActiveStorage
      evaluation.audio_file.attach(
        io: StringIO.new(audio_data),
        filename: audio_filename,
        content_type: 'audio/mpeg'
      )

      evaluation.update!(status: 'generating_video')

      # Enqueue the next step: Text-to-Video generation
      TtvGenerationJob.perform_later(evaluation.id)
      Rails.logger.info "TTS generation complete for Evaluation ##{evaluation.id}. Enqueuing TTV."

    # rescue ElevenLabs::ApiError => e
    #   Rails.logger.error "ElevenLabs API error for Evaluation ##{evaluation.id}: #{e.message}"
    #   evaluation.processing_failed("ElevenLabs API error: #{e.message}")
    #   # raise e # Optional: Re-raise for retries
    rescue StandardError => e
      Rails.logger.error "Unexpected error in TtsGenerationJob for Evaluation ##{evaluation.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during TTS generation: #{e.message}")
    end
  end
end 