# app/jobs/generate_persona_response_job.rb
class GeneratePersonaResponseJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 3 # Or your preferred retry count
  retry_on Faraday::TimeoutError, wait: :exponentially_longer, attempts: 5

  # PERSONA_TEMPLATES are now defined in config/initializers/persona_templates.rb
  # and accessible via PersonaConfig::PERSONA_TEMPLATES

  # Placeholder for AI instructions for this specific generation step
  AI_INSTRUCTIONS_PERSONA_GENERATION = """
  Based on the provided persona and the user's initial prompt, generate an appropriate response. 
  If the persona is meant to be conversational, your response should reflect that.
  If the prompt suggests a task or requires information that might lead to a calendar action later, ensure your response acknowledges this possibility naturally.
  Adhere strictly to the JSON schema provided for your response.
  """

  def perform(persona_interaction_id)
    Rails.logger.info "GeneratePersonaResponseJob started for PersonaInteraction ID: #{persona_interaction_id}"
    persona_interaction = PersonaInteraction.find_by(id: persona_interaction_id)

    unless persona_interaction
      Rails.logger.error "GeneratePersonaResponseJob: PersonaInteraction with ID #{persona_interaction_id} not found. Skipping."
      return
    end

    unless persona_interaction.status == 'pending_generation'
      Rails.logger.warn "GeneratePersonaResponseJob: PersonaInteraction ID #{persona_interaction_id} is not in 'pending_generation' status (current: #{persona_interaction.status}). Skipping."
      return
    end

    personality_instructions = PersonaConfig::PERSONA_TEMPLATES[persona_interaction.personality_key] || 
                               PersonaConfig::PERSONA_TEMPLATES[PersonaConfig::DEFAULT_PERSONA_KEY]
    
    # Construct the full prompt for the AI
    # This will likely evolve to include conversation history later
    full_prompt = <<~PROMPT
      Personality: #{personality_instructions}

      User Prompt: #{persona_interaction.initial_prompt}
    PROMPT

    Rails.logger.debug "GeneratePersonaResponseJob: Using personality: #{persona_interaction.personality_key}"
    Rails.logger.debug "GeneratePersonaResponseJob: Using full prompt:\n#{full_prompt}"

    service = OpenaiResponsesService.new
    api_response = nil # Initialize api_response

    begin
      persona_interaction.update(status: :generation_in_progress)
      api_response = service.generate_persona_response(
        prompt: full_prompt,
        instructions: AI_INSTRUCTIONS_PERSONA_GENERATION,
        # schema_name is implicitly part of the service method now through OpenaiPersonaSchemas::PERSONA_RESPONSE_SCHEMA
        previous_response_id: nil # For now, this is the first turn
      )

      if api_response["error"]
        Rails.logger.error "GeneratePersonaResponseJob: API Error for PersonaInteraction ID #{persona_interaction_id} - #{api_response['error']}"
        persona_interaction.update(status: :generation_failed, generated_response: api_response["error"].to_json)
        return
      end

      # Ensure the output structure matches what the service returns and the schema defines
      raw_output_text = api_response.dig("output", 0, "content", 0, "text")
      unless raw_output_text
        refusal_message = api_response.dig("output", 0, "refusal")
        Rails.logger.error "GeneratePersonaResponseJob: API returned no text output for PersonaInteraction ID #{persona_interaction_id}. Refusal: #{refusal_message || 'N/A'}"
        persona_interaction.update(status: :generation_failed, generated_response: { refusal: refusal_message || 'No text output and no refusal message.' }.to_json)
        return
      end

      parsed_persona_data = JSON.parse(raw_output_text)
      generated_text_output = parsed_persona_data['generated_text']
      identified_action_data = parsed_persona_data['identified_action'] # This could be nil

      # Update conversation history
      new_history_entry = {
        role: "assistant",
        content: generated_text_output,
        action_details: identified_action_data,
        prompt_used: full_prompt, # Store the exact prompt sent to the AI
        raw_api_response_id: api_response['id'], # Store the response ID from OpenAI API
        timestamp: Time.current
      }
      persona_interaction.conversation_history = (persona_interaction.conversation_history || []) << new_history_entry
      
      update_params = {
        generated_response: generated_text_output,
        current_api_response_id: api_response['id'],
        status: :generation_complete
      }
      update_params[:action_details] = identified_action_data if identified_action_data.present?
      # Determine next status based on identified_action
      if identified_action_data.present? && identified_action_data['action_type'].present?
        # For now, if any action is identified, mark as action_pending.
        # Later, we can have more granular logic, e.g., if confirmation_needed is true.
        update_params[:status] = :action_pending 
      end

      persona_interaction.update!(update_params)

      Rails.logger.info "GeneratePersonaResponseJob: Successfully processed PersonaInteraction ID #{persona_interaction_id}. Status: #{persona_interaction.status}."
      
      # if persona_interaction.status == 'action_pending'
      #   # Enqueue a new job to handle the action, e.g., ProcessPersonaActionJob.perform_later(persona_interaction.id)
      #   Rails.logger.info "GeneratePersonaResponseJob: Action pending for PersonaInteraction ID #{persona_interaction_id}. Enqueueing next job (placeholder)."
      # end

    rescue JSON::ParserError => e
      Rails.logger.error "GeneratePersonaResponseJob: Failed to parse JSON response for PersonaInteraction ID #{persona_interaction_id}. Error: #{e.message}. Raw text: #{raw_output_text || 'not available'}. API Response: #{api_response.inspect}"
      persona_interaction.update(status: :generation_failed, generated_response: { error: "JSON Parse Error", message: e.message, raw: raw_output_text }.to_json)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "GeneratePersonaResponseJob: Failed to save PersonaInteraction ID #{persona_interaction_id}. Errors: #{e.record.errors.full_messages.join(', ')}"
      # Status might already be generation_failed or generation_in_progress, consider if further update is needed
      persona_interaction.update(status: :generation_failed) unless persona_interaction.status == 'generation_failed'
    rescue StandardError => e
      Rails.logger.error "GeneratePersonaResponseJob: Unexpected error for PersonaInteraction ID #{persona_interaction_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
      persona_interaction.update(status: :generation_failed, generated_response: { error: "StandardError", message: e.message }.to_json) if persona_interaction && persona_interaction.persisted?
    end
  end
end 