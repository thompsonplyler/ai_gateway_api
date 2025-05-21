require 'openai' # Though OpenaiResponsesService handles direct interaction

# app/jobs/refine_evaluation_job.rb
class RefineEvaluationJob < ApplicationJob
  # Define AGENTS_CONFIG at the top of the class for early loading and robust initialization.
  begin
    # Attempt to load the configuration.
    loaded_config = Rails.application.config.try(:x).try(:agents).try(:AGENTS_CONFIG)

    if loaded_config.is_a?(Hash)
      AGENTS_CONFIG = loaded_config.freeze # Freeze to prevent accidental modification
    else
      Rails.logger.warn "[RefineEvaluationJob] AGENTS_CONFIG was not a Hash or not found. Defaulting to empty Hash. Check config/initializers/agents.rb. Loaded value: #{loaded_config.inspect}"
      AGENTS_CONFIG = {}.freeze
    end
  rescue StandardError => e
    Rails.logger.error "[RefineEvaluationJob] Failed to load AGENTS_CONFIG: #{e.message}. Defaulting to empty hash."
    AGENTS_CONFIG = {}.freeze
  end

  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 15.minutes

  retry_on Faraday::TooManyRequestsError, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::ServerError, wait: :polynomially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  MAX_REVISION_ATTEMPTS = 5 # Define a limit for revision attempts

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "RefineEvaluationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    unless evaluation.status == 'needs_revision'
      Rails.logger.info "RefineEvaluationJob: Evaluation ##{evaluation_id} has status #{evaluation.status} (expected 'needs_revision'). Skipping."
      return
    end

    if evaluation.revision_attempts >= MAX_REVISION_ATTEMPTS
      msg = "Evaluation ##{evaluation.id} reached maximum revision attempts (#{MAX_REVISION_ATTEMPTS}). Failing evaluation."
      Rails.logger.warn msg
      evaluation.processing_failed(msg)
      return
    end

    evaluation.update(status: 'refining_evaluation')

    unless evaluation.current_text_output.present? && 
           evaluation.supervisor_feedback.present? && 
           evaluation.supervisor_llm_api_response_id.present?
      evaluation.processing_failed("Cannot refine evaluation: Missing current text, supervisor feedback, or supervisor LLM response ID.")
      return
    end

    agent_config = AGENTS_CONFIG[evaluation.agent_identifier]
    unless agent_config && agent_config[:instructions]
      msg = "Missing agent config or instructions for identifier #{evaluation.agent_identifier} during refinement."
      Rails.logger.error msg
      evaluation.processing_failed(msg)
      return
    end

    openai_api_key = Rails.application.credentials.dig(:openai, :api_key)
    unless openai_api_key
      evaluation.processing_failed("OpenAI API key not found for refinement.")
      return
    end

    begin
      responses_service = OpenaiResponsesService.new(api_key: openai_api_key)

      # Construct the prompt for refinement
      # It should include the previous text, supervisor feedback, and original agent instructions.
      refinement_prompt_input = <<~PROMPT
        The following evaluation text needs revision:
        --- BEGIN PREVIOUS EVALUATION TEXT ---
        #{evaluation.current_text_output}
        --- END PREVIOUS EVALUATION TEXT ---

        The supervisor provided the following feedback:
        --- BEGIN SUPERVISOR FEEDBACK ---
        #{evaluation.supervisor_feedback}
        --- END SUPERVISOR FEEDBACK ---

        Please revise the evaluation text based on this feedback. 
        Remember, the evaluation must be concise (spoken duration of approximately 20-25 seconds) 
        and adhere to your persona as defined by the original instructions (recalled below for context).
        Your goal is to produce a revised evaluation that addresses the supervisor's concerns.
      PROMPT

      # Original agent instructions for persona and style context
      agent_instructions = agent_config[:instructions]

      # The previous_response_id is the supervisor_llm_api_response_id
      # This links the refinement call to the supervisor's feedback context.
      previous_response_id_for_refinement = evaluation.supervisor_llm_api_response_id

      api_response = responses_service.generate_evaluation_text(
        generation_prompt: refinement_prompt_input,
        instructions: agent_instructions, # Reinforce original agent persona
        previous_response_id: previous_response_id_for_refinement
        # model: "gpt-4o" # Or make configurable
      )

      if api_response["error"]
        error_message = api_response.dig("error", "message") || "Unknown error from OpenAI Responses API during refinement"
        evaluation.processing_failed("Failed to refine evaluation: #{error_message}")
        return
      end

      refined_text = api_response.dig("output", "evaluation_text")
      new_llm_response_id = api_response["id"]

      if refined_text.blank? || new_llm_response_id.blank?
        evaluation.processing_failed("OpenAI Responses API returned empty text or no response ID during refinement.")
        return
      end

      # Successfully refined evaluation text
      evaluation.current_text_output = refined_text
      evaluation.llm_api_response_id = new_llm_response_id # This is the ID of the latest text version
      evaluation.revision_attempts += 1
      evaluation.status = 'pending_supervision' # Send back for supervision
      evaluation.save!

      Rails.logger.info "Evaluation ##{evaluation.id} refined (Attempt ##{evaluation.revision_attempts}). Enqueuing supervision."
      SuperviseEvaluationJob.perform_later(evaluation.id)

    rescue Faraday::Error => e
      Rails.logger.error "RefineEvaluationJob: Faraday Error for Evaluation ##{evaluation_id}: #{e.message}"
      evaluation.processing_failed("Network or API error during evaluation refinement: #{e.message}")
      raise e # Re-raise for Sidekiq
    rescue StandardError => e
      Rails.logger.error "RefineEvaluationJob: StandardError for Evaluation ##{evaluation_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during evaluation refinement: #{e.message}")
      # Do not re-raise for non-network errors
    end
  end

  private

  # Load AGENTS_CONFIG, similar to GenerateEvaluationJob
  # AGENTS_CONFIG = Rails.application.config.x.agents.AGENTS_CONFIG rescue {}

end 