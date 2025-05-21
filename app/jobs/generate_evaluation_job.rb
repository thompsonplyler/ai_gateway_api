require 'openai'

# app/jobs/generate_evaluation_job.rb
class GenerateEvaluationJob < ApplicationJob
  # Define AGENTS_CONFIG at the top of the class for early loading and robust initialization.
  begin
    # Attempt to load the configuration.
    loaded_config = Rails.application.config.try(:x).try(:agents).try(:AGENTS_CONFIG)

    if loaded_config.is_a?(Hash)
      AGENTS_CONFIG = loaded_config.freeze # Freeze to prevent accidental modification
    else
      Rails.logger.warn "[GenerateEvaluationJob] AGENTS_CONFIG was not a Hash or not found. Defaulting to empty Hash. Check config/initializers/agents.rb. Loaded value: #{loaded_config.inspect}"
      AGENTS_CONFIG = {}.freeze
    end
  rescue StandardError => e
    Rails.logger.error "[GenerateEvaluationJob] Failed to load AGENTS_CONFIG: #{e.message}. Defaulting to empty hash."
    AGENTS_CONFIG = {}.freeze
  end

  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 15.minutes

  retry_on Faraday::TooManyRequestsError, wait: :polynomially_longer, attempts: 5 # HTTP 429
  retry_on Faraday::ServerError, wait: :polynomially_longer, attempts: 5          # HTTP 5xx
  # Add other OpenAI specific errors if the service raises them

  discard_on ActiveJob::DeserializationError

  # Maximum tokens for the generated evaluation text. Adjust as needed for <25s speech.
  # This is a hint for the model; actual length control is via prompt and supervision.
  MAX_EVALUATION_TOKENS = 150 # Estimate, might need tuning

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "GenerateEvaluationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    # Prevent re-processing if already started or finished beyond initial generation
    unless evaluation.status == 'pending_generation'
      Rails.logger.info "GenerateEvaluationJob: Evaluation ##{evaluation_id} has status #{evaluation.status} (expected 'pending_generation'). Skipping."
      return
    end

    evaluation.update(status: 'generating_evaluation')
    evaluation_job = evaluation.evaluation_job
    powerpoint = evaluation_job.powerpoint_file

    unless powerpoint.attached?
      evaluation.processing_failed("Original PowerPoint file is missing.")
      return
    end

    agent_config = AGENTS_CONFIG[evaluation.agent_identifier]
    unless agent_config && agent_config[:instructions]
      msg = "Missing agent config or instructions for identifier #{evaluation.agent_identifier}"
      Rails.logger.error msg
      evaluation.processing_failed(msg)
      return
    end

    openai_api_key = Rails.application.credentials.dig(:openai, :api_key)

    # === BEGIN CRITICAL API KEY DEBUGGING ===
    Rails.logger.info "[GenerateEvaluationJob API Key Debug] For Evaluation ID: #{evaluation.id}"
    Rails.logger.info "[GenerateEvaluationJob API Key Debug] Value of 'openai_api_key' variable: #{openai_api_key.inspect}"
    Rails.logger.info "[GenerateEvaluationJob API Key Debug] Class of 'openai_api_key' variable: #{openai_api_key.class}"
    if openai_api_key.is_a?(String)
      Rails.logger.info "[GenerateEvaluationJob API Key Debug] Starts with 'sk-': #{openai_api_key.start_with?('sk-')}"
    end
    # === END CRITICAL API KEY DEBUGGING ===

    unless openai_api_key.is_a?(String) && openai_api_key.start_with?('sk-')
      # More specific failure if the key isn't a string starting with sk-
      error_msg = "OpenAI API key is not a valid string or does not start with 'sk-'. Value: #{openai_api_key.inspect}"
      Rails.logger.error "[GenerateEvaluationJob API Key Error] #{error_msg}"
      evaluation.processing_failed(error_msg)
      return
    end

    begin
      # Step 1: Upload the PowerPoint file to OpenAI to get a file_id
      # This part is similar to the old LlmEvaluationJob
      # We need an OpenAI client instance here for file upload if OpenaiResponsesService doesn't handle it.
      # Assuming standard OpenAI client for file operations for now.
      # The OpenaiResponsesService uses Faraday directly, so we might need two ways to talk to OpenAI
      # or extend OpenaiResponsesService to also handle file uploads.
      # For now, let's use the OpenAI client like in the previous job for consistency in file uploads.

      file_upload_client = OpenAI::Client.new(
        access_token: openai_api_key,
        # Assistants v2 header might not be needed for just /files endpoint, but doesn't hurt.
        # Or, it might be better to use a generic Faraday client if Responses API doesn't use this SDK.
        # Given OpenaiResponsesService uses Faraday, it might be cleaner to add file upload there.
        # For now, proceeding with OpenAI::Client for upload for expediency.
        extra_headers: { 'OpenAI-Beta' => 'assistants=v2' } # Check if this header is appropriate for v1/files
      )

      file_id = nil
      powerpoint.blob.open do |temp_file|
        Rails.logger.info "Uploading file #{powerpoint.filename} (Temp path: #{temp_file.path}) to OpenAI for GenerateEvaluationJob..."
        # Ensure the client and method are correct for the /v1/files endpoint.
        # The existing LlmEvaluationJob used `purpose: 'assistants'`. Check if this is okay
        # or if a different purpose is needed, or if it can be omitted for generic use.
        file_response = file_upload_client.files.upload(
          parameters: {
            file: temp_file,
            purpose: 'assistants' # This might need to be more generic if Responses API can use it
                                # If Responses API can't use 'assistants' purpose files, this is an issue.
                                # For now, assuming it's fine or the model can access it regardless of purpose.
          }
        )
        file_id = file_response['id']
      end

      unless file_id
        evaluation.processing_failed("Failed to upload PowerPoint to OpenAI.")
        return
      end
      Rails.logger.info "File uploaded to OpenAI (ID: #{file_id}) for Evaluation ##{evaluation.id}"

      # Step 2: Prepare prompt and call OpenaiResponsesService
      # Construct the input prompt for the LLM
      # This prompt needs to instruct the LLM to use the uploaded file (file_id)
      prompt_input = <<~PROMPT
        Please review the content of the presentation associated with file ID: #{file_id}.
        Your task is to provide an evaluation of this presentation.
        The evaluation should be concise, aiming for a spoken duration of approximately 20-25 seconds.
        Deliver this evaluation in your persona as defined by the subsequent instructions.
      PROMPT

      # Agent-specific instructions (persona, style, etc.)
      agent_instructions = agent_config[:instructions]

      # Initialize your OpenaiResponsesService
      responses_service = OpenaiResponsesService.new(api_key: openai_api_key)

      # Call a new method in OpenaiResponsesService for evaluation generation
      # This method will use the EVALUATION_GENERATION_SCHEMA
      # We pass nil for previous_response_id as this is the first call in the sequence.
      api_response = responses_service.generate_evaluation_text(
        generation_prompt: prompt_input,
        instructions: agent_instructions,
        # model: "gpt-4o", # Or make this configurable
        # max_tokens: MAX_EVALUATION_TOKENS # The service might handle this or pass it through
      )

      if api_response["error"]
        error_message = api_response.dig("error", "message") || "Unknown error from OpenAI Responses API"
        evaluation.processing_failed("Failed to generate evaluation: #{error_message}")
        # Consider if we should attempt to delete the uploaded file from OpenAI here
        # client.files.delete(file_id: file_id) rescue Rails.logger.warn("Failed to delete OpenAI file #{file_id}")
        return
      end

      # Assuming the schema returns { "evaluation_text": "..." }
      generated_text = api_response.dig("output", "evaluation_text")
      response_id = api_response["id"] # The ID of the response object from OpenAI Responses API

      if generated_text.blank? || response_id.blank?
        evaluation.processing_failed("OpenAI Responses API returned empty text or no response ID.")
        return
      end

      # Successfully generated evaluation text
      evaluation.update!(
        raw_text_output: generated_text,
        current_text_output: generated_text, # Initially same as raw
        llm_api_response_id: response_id,
        status: 'pending_supervision',
        revision_attempts: 0 # Reset on new generation
      )

      Rails.logger.info "Evaluation text generated for Evaluation ##{evaluation.id}. Enqueuing supervision."
      SuperviseEvaluationJob.perform_later(evaluation.id)

    rescue Faraday::Error => e
      # This will be caught by Sidekiq retry mechanism if it's a retryable Faraday error
      Rails.logger.error "GenerateEvaluationJob: Faraday Error for Evaluation ##{evaluation_id}: #{e.message}"
      evaluation.processing_failed("Network or API error during evaluation generation: #{e.message}")
      raise e # Re-raise for Sidekiq to handle retry based on retry_on configuration
    rescue StandardError => e
      Rails.logger.error "GenerateEvaluationJob: StandardError for Evaluation ##{evaluation_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during evaluation generation: #{e.message}")
      # Do not re-raise here if it's not a network error, let Sidekiq move to dead set if applicable
    end
  end

  private

  # Placeholder for AGENTS_CONFIG, should be loaded from an initializer similar to LlmEvaluationJob
  # For example: config/initializers/agents.rb
  # Ensure this is loaded correctly, e.g. by requiring the initializer or ensuring it's auto-loaded.
  # For now, this mirrors the approach in the existing LlmEvaluationJob summary.

end 