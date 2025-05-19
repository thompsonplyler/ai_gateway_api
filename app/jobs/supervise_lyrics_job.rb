# app/jobs/supervise_lyrics_job.rb
class SuperviseLyricsJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 5
  retry_on Faraday::TimeoutError, wait: :exponentially_longer, attempts: 5

  # Updated instructions for the supervision AI, using %Q{} for safer string delimiting
  AI_INSTRUCTIONS_SUPERVISION = %Q{You are a highly discerning music critic and experienced lyricist, known for your rigorous standards and a keen ear for lyrics that are not just competent, but truly exceptional, beautiful, meaningful, and sophisticated.
Your task is to review the provided song lyrics based on the initial topic: '{topic}'.

**Primary Adjudication Criteria & Strict Grading Scale (1-100 for each criterion):**
*   **A score of 70 represents a competent, average baseline.** Lyrics scoring around 70 are acceptable but likely need refinement to become truly memorable or impactful.
*   **A score of 90 or above is reserved for exceptional lyrics** that demonstrate mastery in that specific criterion. Do not award high scores lightly.
*   Be critical and fair. Your goal is to push for lyrical excellence.

1.  **Emotional Resonance:** Do the lyrics evoke genuine, nuanced feeling? Do they connect deeply with the listener? (1-100; 70=average, 90+=exceptional)
2.  **Depth and Meaning (Thought-Provoking):** Do the lyrics operate on multiple levels, offering insights or reflections that go beyond the superficial and invite contemplation? (1-100; 70=average, 90+=exceptional)
3.  **Wordplay and Imagery (Sophistication):** Is the language fresh, interesting, and artful? Is there sophisticated wordplay, clever/original use of metaphor, simile, or other literary devices? Is imagery vivid and unique? Crucially, do the lyrics AVOID "on-the-nose" descriptions (e.g., instead of "I'm sad," show sadness through evocative imagery or action)? (1-100; 70=average, 90+=exceptional)
4.  **Thematic Development (Originality & Associations):** How well do the lyrics develop the theme from the initial prompt? Do they explore it with creativity and originality, using rich synonyms, antonyms, and unexpected but relevant associations, rather than merely repeating or slightly rephrasing words and ideas from the prompt? The goal is to expand upon the topic in genuinely interesting and artistically valuable ways. (1-100; 70=average, 90+=exceptional)

**Rubric and Scoring Output:**
You MUST provide a score for each of the above criteria in the `rubric_scores` object.
Calculate the `average_score` from these four scores and include it.

**Approval and Feedback Logic (strictly follow for output schema fields `lyrics_approved` and `request_to_start_over`):
*   If `average_score` is > 90 (truly exceptional overall), set `lyrics_approved` to true. `points_for_revision` MUST be an empty array. `request_to_start_over` MUST be false.
*   If `average_score` is < 50 (unacceptable failure), set `lyrics_approved` to false and set `request_to_start_over` to true. Provide a brief `overall_critique` explaining why a restart is needed, focusing on the lowest-scoring areas. `points_for_revision` CAN be an empty array or have minimal high-level points.
*   If `average_score` is between 50 and 90 (inclusive), set `lyrics_approved` to false and `request_to_start_over` to false. Provide a detailed `overall_critique` and specific, actionable `points_for_revision` for each area that needs improvement, referencing your rubric scores and the high standards expected. `points_for_revision` MUST NOT be empty in this case unless the critique makes it exceptionally clear why.

Adhere strictly to the JSON schema for your output, ensuring all required fields are present and correctly populated based on this logic.}

  def perform(lyric_set_id)
    Rails.logger.info "SuperviseLyricsJob started for LyricSet ID: #{lyric_set_id}"
    lyric_set = LyricSet.find_by(id: lyric_set_id)

    unless lyric_set
      Rails.logger.error "SuperviseLyricsJob: LyricSet with ID #{lyric_set_id} not found. Skipping."
      return
    end

    unless lyric_set.status == 'pending_supervision'
      Rails.logger.warn "SuperviseLyricsJob: LyricSet ID #{lyric_set_id} is not in 'pending_supervision' status (current: #{lyric_set.status}). Skipping."
      return
    end

    current_revision = lyric_set.revision_history&.last
    unless current_revision && current_revision['lyrics_content'].present? && current_revision['api_response_id_generation'].present?
      Rails.logger.error "SuperviseLyricsJob: LyricSet ID #{lyric_set_id} has no current lyrics or generation API ID in revision_history. Cannot supervise."
      lyric_set.update(status: :pending_initial_generation)
      return
    end

    lyrics_to_review = current_revision['lyrics_content']
    supervisor_instructions_with_topic = AI_INSTRUCTIONS_SUPERVISION.gsub('{topic}', lyric_set.topic || "an unspecified topic")
    supervision_prompt = "Please review the following lyrics:\n\n#{lyrics_to_review}"
    service = OpenaiResponsesService.new

    begin
      api_response = service.supervise_lyrics(
        prompt: supervision_prompt,
        instructions: supervisor_instructions_with_topic,
        previous_response_id: current_revision['api_response_id_generation']
      )

      if api_response["error"]
        Rails.logger.error "SuperviseLyricsJob: API Error for LyricSet ID #{lyric_set_id} - #{api_response['error']}"
        return
      end

      raw_output_text = api_response.dig("output", 0, "content", 0, "text")
      unless raw_output_text
        refusal_message = api_response.dig("output", 0, "refusal")
        Rails.logger.error "SuperviseLyricsJob: API returned no text output for LyricSet ID #{lyric_set_id}. Refusal: #{refusal_message || 'N/A'}"
        return
      end

      parsed_review_data = JSON.parse(raw_output_text)
      
      # Extract all data from the new supervisor schema
      lyrics_approved = parsed_review_data['lyrics_approved']
      overall_critique = parsed_review_data['overall_critique']
      points_for_revision_data = parsed_review_data['points_for_revision'] # Array of objects
      rubric_scores = parsed_review_data['rubric_scores'] # Object with scores
      average_score = parsed_review_data['average_score']
      request_to_start_over = parsed_review_data['request_to_start_over']

      # Update the latest revision_history entry with all supervision details
      current_revision['supervisor_feedback'] = overall_critique
      current_revision['rubric_scores'] = rubric_scores # Store the full scores object
      current_revision['average_score'] = average_score
      current_revision['request_to_start_over'] = request_to_start_over
      
      if points_for_revision_data.present?
        # Keep points_for_revision as an array of objects if needed for structured display later,
        # or format into a string as before for simple suggestions.
        # For now, storing the raw array of objects from the schema.
        current_revision['supervisor_suggested_improvements_structured'] = points_for_revision_data
        # For backward compatibility or simple display, create the string version:
        suggestions_string = points_for_revision_data.map do |p|
          "- #{p['section_reference']}: #{p['issue_identified']} Suggestion: #{p['suggestion_for_improvement']}"
        end.join("\n")
        current_revision['supervisor_suggested_improvements'] = suggestions_string
      else
        current_revision['supervisor_suggested_improvements_structured'] = []
        current_revision['supervisor_suggested_improvements'] = nil
      end
      
      current_revision['supervisor_approved_this_version'] = lyrics_approved # This is now driven by average_score > 90 logic in AI
      current_revision['api_response_id_supervision'] = api_response['id']

      if request_to_start_over
        Rails.logger.info "SuperviseLyricsJob: Supervisor requested to start over for LyricSet ID #{lyric_set_id}. Resetting for new generation."
        # Reset relevant fields for a fresh start, keep topic and history
        lyric_set.status = :pending_initial_generation # Trigger GenerateLyricsJob again
        lyric_set.current_lyrics = nil # Or some indication of a restart
        lyric_set.refinement_attempts = 0 # Reset refinement attempts
        # Add a note to history indicating a restart was requested
        lyric_set.revision_history << {
          lyrics_content: "SUPERVISOR REQUESTED RESTART",
          generation_prompt_used: "Restart requested due to average score: #{average_score}",
          supervisor_feedback: overall_critique,
          rubric_scores: rubric_scores,
          average_score: average_score,
          request_to_start_over: true,
          supervisor_approved_this_version: false,
          api_response_id_generation: nil,
          api_response_id_supervision: api_response['id'],
          created_at: Time.current
        }
        GenerateLyricsJob.perform_later(lyric_set.id) # Enqueue a brand new generation
      elsif lyrics_approved
        lyric_set.status = :approved
        lyric_set.approved_at = Time.current
        Rails.logger.info "SuperviseLyricsJob: Lyrics approved for LyricSet ID #{lyric_set_id}. Average score: #{average_score}."
      else # Needs revision (and not starting over)
        lyric_set.status = :needs_revision
        Rails.logger.info "SuperviseLyricsJob: Lyrics need revision for LyricSet ID #{lyric_set_id}. Average score: #{average_score}. Enqueuing RefineLyricsJob."
        RefineLyricsJob.perform_later(lyric_set.id)
      end
      lyric_set.save!

    rescue JSON::ParserError => e
      Rails.logger.error "SuperviseLyricsJob: Failed to parse JSON review for LyricSet ID #{lyric_set_id}. Error: #{e.message}. Raw text: #{raw_output_text}"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "SuperviseLyricsJob: Failed to update LyricSet ID #{lyric_set_id}. Errors: #{e.record.errors.full_messages.join(', ')}"
    rescue StandardError => e
      Rails.logger.error "SuperviseLyricsJob: Unexpected error for LyricSet ID #{lyric_set_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
    end
  end
end 