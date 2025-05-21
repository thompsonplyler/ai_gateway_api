require 'openai' # Though OpenaiResponsesService handles direct interaction

# app/jobs/supervise_evaluation_job.rb
class SuperviseEvaluationJob < ApplicationJob
  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 15.minutes

  retry_on Faraday::TooManyRequestsError, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::ServerError, wait: :polynomially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  # Instructions for the supervisor LLM.
  # These could also be made more dynamic or loaded from config if needed.
  SUPERVISOR_INSTRUCTIONS = <<~PROMPT.
    You are an Evaluation Supervisor. Your task is to review the provided evaluation text.
    Ensure the following criteria are met:
    1. Length: The spoken duration of the text should be approximately 20-25 seconds. Be critical about this.
    2. Tone & Persona: The evaluation must be consistent with the agent's specified persona (which will be part of the context of the original generation).
    3. Quality: The evaluation should be clear, coherent, and provide meaningful feedback.

    Respond using the provided JSON schema with your assessment.
    If `is_approved` is false, provide specific `feedback` on why, focusing on length, tone, or quality issues.
    If the primary issue is length, ensure `is_correct_length` is false.
  PROMPT

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "SuperviseEvaluationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    unless evaluation.status == 'pending_supervision'
      Rails.logger.info "SuperviseEvaluationJob: Evaluation ##{evaluation_id} has status #{evaluation.status} (expected 'pending_supervision'). Skipping."
      return
    end

    evaluation.update(status: 'supervising_evaluation')

    unless evaluation.current_text_output.present? && evaluation.llm_api_response_id.present?
      evaluation.processing_failed("Cannot supervise evaluation: Missing current text or original LLM response ID.")
      return
    end

    openai_api_key = Rails.application.credentials.dig(:openai, :api_key)
    unless openai_api_key
      evaluation.processing_failed("OpenAI API key not found for supervision.")
      return
    end

    begin
      responses_service = OpenaiResponsesService.new(api_key: openai_api_key)

      # The input to the supervisor is the text generated in the previous step.
      text_to_review = evaluation.current_text_output

      # The generation_response_id is the llm_api_response_id from the Evaluation record,
      # which was stored after the GenerateEvaluationJob ran.
      generation_response_id = evaluation.llm_api_response_id

      api_response = responses_service.supervise_evaluation_text(
        evaluation_text_to_review: text_to_review,
        generation_response_id: generation_response_id,
        instructions: SUPERVISOR_INSTRUCTIONS
        # model: "gpt-4o" # Or make configurable
      )

      if api_response["error"]
        error_message = api_response.dig("error", "message") || "Unknown error from OpenAI Responses API during supervision"
        evaluation.processing_failed("Failed to supervise evaluation: #{error_message}")
        return
      end

      # Expected output from EVALUATION_SUPERVISION_SCHEMA:
      # { "is_approved": true/false, "is_correct_length": true/false, "feedback": "..." or null }
      supervisor_output = api_response.dig("output")
      supervisor_response_id = api_response["id"]

      unless supervisor_output && supervisor_response_id.present?
        evaluation.processing_failed("OpenAI Responses API returned empty output or no response ID during supervision.")
        return
      end

      is_approved = supervisor_output["is_approved"]
      is_correct_length = supervisor_output["is_correct_length"]
      feedback = supervisor_output["feedback"]

      # Update evaluation record with supervision results
      evaluation.supervisor_feedback = feedback
      evaluation.supervisor_llm_api_response_id = supervisor_response_id

      # Determine supervisor_status for a simple string representation
      # This can be refined based on how you want to use supervisor_status
      eval_supervisor_status = "pending_approval"
      if is_approved && is_correct_length
        eval_supervisor_status = "approved"
      elsif !is_correct_length
        eval_supervisor_status = "rejected_length"
      else
        eval_supervisor_status = "rejected_quality" # Or a more general term
      end
      evaluation.supervisor_status = eval_supervisor_status

      if is_approved && is_correct_length
        evaluation.status = 'approved_for_tts'
        evaluation.save!
        Rails.logger.info "Evaluation ##{evaluation.id} approved by supervisor. Current_text_output is final."
        # Enqueue TTS job if not skipped
        evaluation_job = evaluation.evaluation_job
        if evaluation_job.skip_tts?
          Rails.logger.info "TTS step skipped for EvaluationJob ##{evaluation_job.id}. Checking job completion."
          evaluation_job.check_completion
        else
          TtsGenerationJob.perform_later(evaluation.id)
          Rails.logger.info "Enqueuing TTS for approved Evaluation ##{evaluation.id}."
        end
      else
        evaluation.status = 'needs_revision'
        evaluation.save!
        Rails.logger.info "Evaluation ##{evaluation.id} needs revision. Feedback: #{feedback}. Enqueuing refinement."
        RefineEvaluationJob.perform_later(evaluation.id) # This job will be created in Phase 3
      end

    rescue Faraday::Error => e
      Rails.logger.error "SuperviseEvaluationJob: Faraday Error for Evaluation ##{evaluation_id}: #{e.message}"
      evaluation.processing_failed("Network or API error during evaluation supervision: #{e.message}")
      raise e # Re-raise for Sidekiq
    rescue StandardError => e
      Rails.logger.error "SuperviseEvaluationJob: StandardError for Evaluation ##{evaluation_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error during evaluation supervision: #{e.message}")
      # Do not re-raise for non-network errors
    end
  end
end 