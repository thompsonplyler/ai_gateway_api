require 'elevenlabs' # Assuming you have the elevenlabs gem

class TtsGenerationJob < ApplicationJob
  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 5.minutes

  # TODO: Define specific ElevenLabs errors for retry if available
  # See elevenlabs gem documentation for error classes
  # retry_on ElevenLabs::ApiError, wait: :polynomially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  # --- Configuration --- 
  # Map Agent Identifiers to ElevenLabs Voice IDs
  # AGENT_VOICE_IDS = { ... } # REMOVED

  # Default model (can be overridden if needed)
  DEFAULT_MODEL_ID = "eleven_multilingual_v2"
  # ---------------------

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

    # Get API Key
    api_key = Rails.application.credentials.dig(:elevenlabs, :api_key)
    unless api_key
      msg = "ElevenLabs API key not found in credentials."
      Rails.logger.error "TtsGenerationJob: #{msg}"
      evaluation.processing_failed(msg)
      return
    end

    # Get agent configuration
    agent_config = AGENTS_CONFIG[evaluation.agent_identifier]
    unless agent_config
      msg = "Agent configuration not found for identifier: #{evaluation.agent_identifier}"
      Rails.logger.error "TtsGenerationJob: #{msg}"
      evaluation.processing_failed(msg)
      return
    end

    # Get agent-specific voice ID from central config
    agent_voice_id = agent_config[:voice_id]
    unless agent_voice_id
      msg = "ElevenLabs Voice ID not configured in AGENTS_CONFIG for agent: #{evaluation.agent_identifier}"
      Rails.logger.error "TtsGenerationJob: #{msg}"
      evaluation.processing_failed(msg)
      return
    end

    begin
      Rails.logger.info "Generating TTS for Evaluation ##{evaluation.id} using Voice ID: #{agent_voice_id}"
      client = Elevenlabs::Client.new(api_key: api_key)

      # Make the API call using the agent-specific voice ID
      # Pass voice_id and text as positional arguments, options as a third hash
      response = client.text_to_speech(
        agent_voice_id,
        evaluation.text_result,
        { model_id: DEFAULT_MODEL_ID }
        # stability: 0.7, # Optional parameters can be added to the hash
        # similarity_boost: 0.7
      )

      # Assuming the response body is the binary audio data
      audio_data = response
      unless audio_data.is_a?(String) && audio_data.encoding == Encoding::BINARY
        # If the gem wraps the response, you might need something like: audio_data = response.body
        # Log the actual response class to understand its structure if needed.
        Rails.logger.error "TtsGenerationJob: Unexpected response format from ElevenLabs. Class: #{response.class}"
        raise "Unexpected response format from ElevenLabs API."
      end

      if audio_data.blank?
        evaluation.processing_failed("ElevenLabs returned empty audio data.")
        return
      end

      # Attach the received audio data using ActiveStorage
      audio_filename = "evaluation_#{evaluation.id}_#{evaluation.agent_identifier}.mp3"
      evaluation.audio_file.attach(
        io: StringIO.new(audio_data),
        filename: audio_filename,
        content_type: 'audio/mpeg'
      )

      # Keep this status update so the frontend knows audio *should* be available
      evaluation.update!(status: 'generating_video') 

      # Enqueue the next step: Text-to-Video generation
      # TtvGenerationJob.perform_later(evaluation.id) # << COMMENTED OUT FOR TESTING
      Rails.logger.info "TTS generation complete for Evaluation ##{evaluation.id}. TTV step skipped for testing."

    # rescue ElevenLabs::ApiError => e # Use actual error class from gem
    #   Rails.logger.error "ElevenLabs API error for Evaluation ##{evaluation.id}: #{e.message}"
    #   evaluation.processing_failed("ElevenLabs API error: #{e.message}")
    rescue StandardError => e
      Rails.logger.error "Unexpected error in TtsGenerationJob for Evaluation ##{evaluation.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during TTS generation: #{e.message}")
    end
  end
end 