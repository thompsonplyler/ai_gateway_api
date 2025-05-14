class RefineQuestCandidateJob < ApplicationJob
  queue_as :default

  def perform(quest_candidate_id)
    Rails.logger.info "Starting RefineQuestCandidateJob for QuestCandidate ID: #{quest_candidate_id}"
    quest_candidate = QuestCandidate.find_by(id: quest_candidate_id)

    unless quest_candidate
      Rails.logger.error "RefineQuestCandidateJob: QuestCandidate with ID #{quest_candidate_id} not found."
      return
    end

    # Ensure there are notes to work from and it's in the correct status
    unless quest_candidate.status == 'needs_revision' && quest_candidate.supervisory_notes_history.present?
      Rails.logger.warn "RefineQuestCandidateJob: QC ID #{quest_candidate_id} not in 'needs_revision' or no supervisory notes history. Skipping."
      return
    end

    latest_review_entry = quest_candidate.supervisory_notes_history.last
    unless latest_review_entry && latest_review_entry['note'].present?
      Rails.logger.warn "RefineQuestCandidateJob: QC ID #{quest_candidate_id} has no valid latest supervisory note. Skipping."
      return
    end
    supervisor_feedback_text = latest_review_entry['note']

    service = OpenaiResponsesService.new

    refinement_prompt_text = <<~REFINE_PROMPT
    A previous version of a quest was generated and reviewed. Please revise it based on the feedback provided.

    Original Chosen Variables:
    Species: #{quest_candidate.chosen_variables_species}
    Hat: #{quest_candidate.chosen_variables_hat}
    Mood: #{quest_candidate.chosen_variables_mood}
    Item Needed: #{quest_candidate.chosen_variables_item_needed}

    Original Quest Intro:
    #{quest_candidate.quest_intro}

    Original Quest Complete Message:
    #{quest_candidate.quest_complete_message}

    Supervisor Feedback (Review Notes to address):
    #{supervisor_feedback_text}

    Your task is to rewrite the Quest Intro and Quest Complete Message to address the feedback. 
    Maintain the original chosen variables. 
    The output *must* conform to the original JSON schema (containing chosen_variables, quest_intro, and quest_complete_message).
    Focus on incorporating the feedback effectively to improve the quest dialogue.
    REFINE_PROMPT

    refinement_api_instructions = "You are a narrative editor. Revise the provided quest dialogue based on the supervisor's feedback. Ensure the revised output strictly adheres to the specified JSON schema (it must include chosen_variables, quest_intro, and quest_complete_message). The chosen_variables should remain IDENTICAL to the original ones provided above."

    api_response = service.generate_quest_candidate(
      generation_prompt: refinement_prompt_text,
      instructions: refinement_api_instructions,
      previous_response_id: latest_review_entry['review_api_id'] # Use the API ID of the review that gave this feedback
    )

    if api_response["error"]
      Rails.logger.error "RefineQuestCandidateJob: API Error for QC ID #{quest_candidate_id} - #{api_response['error']}"
      return
    end

    raw_output_text = api_response.dig("output", 0, "content", 0, "text")
    if raw_output_text.blank?
      refusal = api_response.dig("output", 0, "refusal")
      Rails.logger.error "RefineQuestCandidateJob: API returned no text output for QC ID #{quest_candidate_id}. Refusal: #{refusal || 'N/A'}. Full response: #{api_response.inspect}"
      return
    end

    begin
      parsed_revised_data = JSON.parse(raw_output_text)
      revised_chosen_vars = parsed_revised_data['chosen_variables']
      unless revised_chosen_vars.is_a?(Hash) && 
             revised_chosen_vars['species'] == quest_candidate.chosen_variables_species &&
             revised_chosen_vars['hat'] == quest_candidate.chosen_variables_hat &&
             revised_chosen_vars['mood'] == quest_candidate.chosen_variables_mood &&
             revised_chosen_vars['item_needed'] == quest_candidate.chosen_variables_item_needed
        Rails.logger.error "RefineQuestCandidateJob: Revised data altered or omitted chosen_variables for QC ID #{quest_candidate_id}. Original: #{quest_candidate.chosen_variables_species}, etc. Revised: #{revised_chosen_vars.inspect}"
        return
      end

      update_params = {
        quest_intro: parsed_revised_data['quest_intro'],
        quest_complete_message: parsed_revised_data['quest_complete_message'],
        raw_api_response_id: api_response['id'], 
        status: :pending_review, 
        # supervisory_notes_history is NOT cleared here; it accumulates.
        # supervisor_approved, supervisor_raw_api_response_id, approved_at are effectively cleared by the next supervision round.
        # However, to be explicit about a reset for this *revision* attempt:
        supervisor_approved: nil,
        supervisor_raw_api_response_id: nil, # This will be set by the next SuperviseJob
        approved_at: nil
        # refinement_attempts is incremented by the supervising job *before* calling this refine job.
      }

      quest_candidate.update!(update_params)
      Rails.logger.info "RefineQuestCandidateJob: Successfully refined and updated QuestCandidate ID #{quest_candidate_id}. Reset to pending_review."

      SuperviseQuestCandidateJob.perform_later(quest_candidate.id)
      Rails.logger.info "RefineQuestCandidateJob: Re-enqueued SuperviseQuestCandidateJob for refined QuestCandidate ID #{quest_candidate.id}"

    rescue JSON::ParserError => e
      Rails.logger.error "RefineQuestCandidateJob: Failed to parse JSON refinement response for QC ID #{quest_candidate_id}. Error: #{e.message}. Raw text: #{raw_output_text}"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "RefineQuestCandidateJob: Failed to update QuestCandidate ID #{quest_candidate_id} with refinement. Errors: #{e.record.errors.full_messages.join(', ')}. Data: #{parsed_revised_data.inspect rescue 'N/A'}"
    rescue StandardError => e
      Rails.logger.error "RefineQuestCandidateJob: An unexpected error occurred for QC ID #{quest_candidate_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
    end
  end
end 