class SuperviseQuestCandidateJob < ApplicationJob
  queue_as :default

  def perform(quest_candidate_id)
    Rails.logger.info "Starting SuperviseQuestCandidateJob for QuestCandidate ID: #{quest_candidate_id}"
    quest_candidate = QuestCandidate.find_by(id: quest_candidate_id)

    unless quest_candidate
      Rails.logger.error "SuperviseQuestCandidateJob: QuestCandidate with ID #{quest_candidate_id} not found."
      return
    end

    unless quest_candidate.raw_api_response_id.present?
      Rails.logger.error "SuperviseQuestCandidateJob: QuestCandidate ID #{quest_candidate_id} missing raw_api_response_id from generation step."
      # Potentially re-enqueue generation or mark as error
      return
    end

    service = OpenaiResponsesService.new

    # Construct the text to be sent for review
    review_text = <<~REVIEW_PROMPT
    Please review the following generated quest content based on the criteria of warmth, variety, feel-good tone, character voice consistency, natural speech, avoiding repetition, clean phrasing, and emotional sincerity. The hat should subtly inform voice. Do not mention item location.

    Chosen Variables:
    Species: #{quest_candidate.chosen_variables_species}
    Hat: #{quest_candidate.chosen_variables_hat}
    Mood: #{quest_candidate.chosen_variables_mood}
    Item Needed: #{quest_candidate.chosen_variables_item_needed}

    Quest Intro:
    #{quest_candidate.quest_intro}

    Quest Complete Message:
    #{quest_candidate.quest_complete_message}

    Output your review strictly according to the provided JSON schema, indicating if it's approved, and providing feedback or suggested changes if not.
    REVIEW_PROMPT

    # Neutral instructions for the AI supervisor
    supervisor_instructions = "You are a meticulous QA Narrative Designer. Evaluate the quest content provided for warmth, variety, feel-good tone, character voice consistency, natural speech, avoiding repetition, clean phrasing, and emotional sincerity. The hat should subtly inform voice. Do not mention item location. Adhere strictly to the JSON schema for your output. Provide specific feedback if there are areas for improvement, otherwise, indicate approval."

    api_response = service.review_quest_candidate(
      quest_text_for_review: review_text,
      generation_response_id: quest_candidate.raw_api_response_id, # Important for context linking
      instructions: supervisor_instructions
    )

    if api_response["error"]
      Rails.logger.error "SuperviseQuestCandidateJob: API Error for QC ID #{quest_candidate_id} - #{api_response['error']}"
      # Potentially update quest_candidate status to a review_failed state
      return
    end

    raw_output_text = api_response.dig("output", 0, "content", 0, "text")
    if raw_output_text.blank?
      refusal = api_response.dig("output", 0, "refusal")
      Rails.logger.error "SuperviseQuestCandidateJob: API returned no text output for QC ID #{quest_candidate_id}. Refusal: #{refusal || 'N/A'}. Full response: #{api_response.inspect}"
      # Potentially update quest_candidate status
      return
    end

    begin
      parsed_review_data = JSON.parse(raw_output_text)
      ai_approved = parsed_review_data['approved']
      ai_feedback = parsed_review_data['feedback'].presence
      ai_suggested_changes = parsed_review_data['suggested_changes'].presence

      # Randomly decide the outcome for testing purposes
      # This gives a 50/50 chance of forcing a rejection if the AI approved, 
      # or forcing an approval if the AI rejected.
      # For more rejections, you can weight this differently e.g. rand(3) == 0 for approval (1/3 chance)
      final_approved_status = [true, false].sample 
      current_supervisory_note = nil

      if final_approved_status 
        # We randomly decided to approve it
        current_supervisory_note = ai_feedback || ai_suggested_changes # Keep AI notes if any, even on approval
        if !ai_approved && current_supervisory_note.blank? # AI rejected but gave no notes, and we override to approve
           current_supervisory_note = "AI initially had concerns, but test override approved."
        elsif ai_approved && current_supervisory_note.blank? # AI approved and gave no notes.
           current_supervisory_note = "Approved by AI and test override."
        end
      else 
        # We randomly decided to reject it (or AI rejected it and random agreed)
        current_supervisory_note = ai_feedback || ai_suggested_changes
        if current_supervisory_note.blank? # AI might have approved, but we force reject, ensure there's a note.
          current_supervisory_note = "Randomly selected for revision (testing). Please review and improve."
        end
      end
      
      new_notes_history = quest_candidate.supervisory_notes_history || []
      if current_supervisory_note.present?
        new_notes_history << { 
          reviewed_at: Time.current,
          review_api_id: api_response['id'], 
          note: current_supervisory_note,
          originally_ai_approved: ai_approved # Track what the AI thought
        }
      end

      update_params = {
        supervisor_raw_api_response_id: api_response['id'],
        supervisor_approved: final_approved_status, # Use our random decision
        supervisory_notes_history: new_notes_history
      }

      if final_approved_status
        update_params[:status] = :approved
        update_params[:approved_at] = Time.current
      else
        update_params[:status] = :needs_revision
      end
      
      quest_candidate.update!(update_params)
      Rails.logger.info "SuperviseQuestCandidateJob: Reviewed QC ID #{quest_candidate_id}. AI approved: #{ai_approved}. Final status: #{quest_candidate.status}. Notes: #{current_supervisory_note}"

      if quest_candidate.status == 'needs_revision'
        # Increment refinement attempts before enqueuing refinement
        quest_candidate.increment!(:refinement_attempts)
        Rails.logger.info "SuperviseQuestCandidateJob: Incremented refinement_attempts to #{quest_candidate.refinement_attempts} for QC ID #{quest_candidate_id}"
        RefineQuestCandidateJob.perform_later(quest_candidate.id)
        Rails.logger.info "SuperviseQuestCandidateJob: Enqueued RefineQuestCandidateJob for QC ID #{quest_candidate.id}"
      end

    rescue JSON::ParserError => e
      Rails.logger.error "SuperviseQuestCandidateJob: Failed to parse JSON review for QC ID #{quest_candidate_id}. Error: #{e.message}. Raw text: #{raw_output_text}"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "SuperviseQuestCandidateJob: Failed to update QC ID #{quest_candidate_id}. Errors: #{e.record.errors.full_messages.join(', ')}. Data: #{parsed_review_data.inspect rescue 'N/A'}"
    rescue StandardError => e
      Rails.logger.error "SuperviseQuestCandidateJob: Unexpected error for QC ID #{quest_candidate_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
    end
  end
end 