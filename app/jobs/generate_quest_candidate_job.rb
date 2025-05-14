class GenerateQuestCandidateJob < ApplicationJob
  queue_as :default

  # Parameters for the job could be more dynamic later (e.g., specific prompt inputs)
  # For now, we'll use a generic set of instructions and a simple prompt.
  def perform(*args)
    Rails.logger.info "Starting GenerateQuestCandidateJob..."
    service = OpenaiResponsesService.new

    # Define the generation prompt and instructions
    # These would eventually be constructed from your full quest design prompt
    # and possibly dynamic variables if you want to pre-select some.
    species_list = ["Moose", "Beaver", "Wolf", "Human", "Fox", "Bear"]
    hat_list = ["None", "Trucker Hat", "Deerstalker Hat", "Baseball Cap", "Tiara"]
    mood_list = ["Happy", "Sad", "Grumpy", "Tired"]
    item_list = ["Logs", "Stones", "Mushrooms", "Flowers"]

    generation_prompt = <<~PROMPT
    You are a best-in-class narrative designer working on a cozy, emotionally intelligent farming/life sim.
    You are tasked with generating a brief, character-driven side quest with warmth, variety, and a feel-good tone.

    Each quest consists of:
        Quest Intro: 2–3 sentences of in-world dialogue from an NPC who requests a specific item.
        Quest Complete Message: 2–3 sentences of dialogue from the same NPC that references the intro and shows gratitude, improvement in mood, or a moment of connection.

    Instructions for the AI:
        Use the variables listed below to determine the character's personality and voice.
        The character's mood should subtly color their tone, but everyone should feel upbeat, hopeful, or better by the end of the quest.
        Write natural, coherent speech—sentences should feel connected, not random or whimsical for its own sake.
        Avoid overly repeated structures.
        Use clean, simple phrasing with personality. Dialogue should be breezy and emotionally sincere.
        Do not mention where the item can be found.
        The hat should subtly inform the voice (e.g., Trucker Hat: blue-collar; Deerstalker: reflective; Baseball Cap: relaxed; Tiara: expressive; None: neutral).

    Available Variables for the AI to choose from:
        Species: #{species_list.join(", ")}
        Hat: #{hat_list.join(", ")}
        Mood: #{mood_list.join(", ")}
        Item Needed: #{item_list.join(", ")}

    Output *must* conform to the provided JSON schema.
    PROMPT

    # For this initial job, the instructions to the API are simpler as much is in the prompt.
    api_instructions = "Generate a quest based on the provided context and variable lists. Adhere strictly to the JSON schema for output."

    api_response = service.generate_quest_candidate(
      generation_prompt: generation_prompt,
      instructions: api_instructions
    )

    if api_response["error"]
      Rails.logger.error "GenerateQuestCandidateJob: API Error - #{api_response['error']}"
      # Handle error appropriately - e.g., raise an error to make Sidekiq retry, or log and exit
      # For now, we'll just log and not create a record.
      return
    end

    raw_output_text = api_response.dig("output", 0, "content", 0, "text")
    if raw_output_text.blank?
      Rails.logger.error "GenerateQuestCandidateJob: API returned no text output. Full response: #{api_response.inspect}"
      # Handle case where output text is missing, e.g. a refusal
      refusal_message = api_response.dig("output", 0, "refusal")
      if refusal_message
         Rails.logger.warn "GenerateQuestCandidateJob: API refused the request: #{refusal_message}"
      end
      return
    end

    begin
      parsed_quest_data = JSON.parse(raw_output_text)
      
      # Ensure chosen_variables is present and is a hash
      chosen_vars = parsed_quest_data['chosen_variables']
      unless chosen_vars.is_a?(Hash)
        Rails.logger.error "GenerateQuestCandidateJob: 'chosen_variables' is missing or not a Hash. Data: #{parsed_quest_data.inspect}"
        return
      end

      quest_candidate = QuestCandidate.create!(
        chosen_variables_species: chosen_vars['species'],
        chosen_variables_hat: chosen_vars['hat'],
        chosen_variables_mood: chosen_vars['mood'],
        chosen_variables_item_needed: chosen_vars['item_needed'],
        quest_intro: parsed_quest_data['quest_intro'],
        quest_complete_message: parsed_quest_data['quest_complete_message'],
        raw_api_response_id: api_response['id'],
        status: :pending_review # Or 'pending_review'
      )
      Rails.logger.info "GenerateQuestCandidateJob: Successfully created QuestCandidate with ID #{quest_candidate.id} and API response ID #{api_response['id']}"

      # Automatically enqueue the supervision job
      SuperviseQuestCandidateJob.perform_later(quest_candidate.id)
      Rails.logger.info "GenerateQuestCandidateJob: Enqueued SuperviseQuestCandidateJob for QuestCandidate ID #{quest_candidate.id}"

    rescue JSON::ParserError => e
      Rails.logger.error "GenerateQuestCandidateJob: Failed to parse JSON response. Error: #{e.message}. Raw text: #{raw_output_text}"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "GenerateQuestCandidateJob: Failed to save QuestCandidate. Errors: #{e.record.errors.full_messages.join(', ')}. Data: #{parsed_quest_data.inspect}"
    rescue StandardError => e
      Rails.logger.error "GenerateQuestCandidateJob: An unexpected error occurred. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
    end
  end
end 