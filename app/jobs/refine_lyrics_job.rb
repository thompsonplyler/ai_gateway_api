# app/jobs/refine_lyrics_job.rb
class RefineLyricsJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 5
  retry_on Faraday::TimeoutError, wait: :exponentially_longer, attempts: 5

  # Updated instructions for the AI during refinement, using %Q{} for safer string delimiting
  AI_INSTRUCTIONS_REFINEMENT = %Q{You are a creative and talented songwriter, tasked with revising a previous draft of lyrics based on specific feedback from a discerning supervisor.
Your goal is to elevate the lyrics to meet a high standard of quality across several criteria: emotional resonance, depth/meaning, wordplay/imagery, and thematic development.

**Your Revision Task:**
1.  Carefully review the 'Previous Lyrics Version'.
2.  Thoroughly analyze the 'Supervisor Feedback' and any 'Specific Suggestions' provided. This feedback is based on a detailed rubric and indicates areas where the lyrics fell short.
3.  Rewrite and refine the lyrics to directly address all points raised by the supervisor. 
4.  While revising, ensure you are still aiming for the original quality goals: 
    *   Evocative language (show, don't tell).
    *   Nuance and originality.
    *   Telling interesting stories or describing interesting places/feelings that resonate emotionally and intellectually.
    *   Sophisticated wordplay and vivid imagery, avoiding "on-the-nose" descriptions.
    *   Creative thematic development that explores associations and avoids mere repetition of the original topic.
5.  The revised lyrics should be a complete, new version of the song.

Format your output strictly according to the JSON schema, providing the revised `lyrics_body` and a `suggested_song_title`.}

  # Max refinement attempts to prevent infinite loops
  MAX_REFINEMENT_ATTEMPTS = 5

  def perform(lyric_set_id)
    Rails.logger.info "RefineLyricsJob started for LyricSet ID: #{lyric_set_id}"
    lyric_set = LyricSet.find_by(id: lyric_set_id)

    unless lyric_set
      Rails.logger.error "RefineLyricsJob: LyricSet with ID #{lyric_set_id} not found. Skipping."
      return
    end

    unless lyric_set.status == 'needs_revision'
      Rails.logger.warn "RefineLyricsJob: LyricSet ID #{lyric_set_id} is not in 'needs_revision' status (current: #{lyric_set.status}). Skipping."
      return
    end

    if lyric_set.refinement_attempts >= MAX_REFINEMENT_ATTEMPTS
      Rails.logger.warn "RefineLyricsJob: LyricSet ID #{lyric_set_id} has reached max refinement attempts (#{lyric_set.refinement_attempts}). Stopping refinement."
      # Optionally, set a status like :max_revisions_reached or :failed_approval
      lyric_set.update(status: :approved) # Or some other terminal status like :failed_review
      return
    end

    last_revision = lyric_set.revision_history&.last
    unless last_revision && last_revision['lyrics_content'].present? && 
           last_revision['supervisor_feedback'].present? && 
           last_revision['api_response_id_supervision'].present?
      Rails.logger.error "RefineLyricsJob: LyricSet ID #{lyric_set_id} is missing data from previous revision/supervision. Cannot refine."
      lyric_set.update(status: :pending_supervision) # Revert or set to error
      return
    end

    lyric_set.increment!(:refinement_attempts)

    previous_lyrics = last_revision['lyrics_content']
    supervisor_feedback = last_revision['supervisor_feedback']
    supervisor_suggestions = last_revision['supervisor_suggested_improvements']

    refinement_prompt = <<~PROMPT
    Original Topic: #{lyric_set.topic}

    Previous Lyrics Version:
    #{previous_lyrics}

    Supervisor Feedback:
    #{supervisor_feedback}
    #{supervisor_suggestions ? "\nSpecific Suggestions:\n#{supervisor_suggestions}" : ''}

    Please revise the lyrics based on the feedback to meet the supervisor's expectations and the original topic. Provide a new, complete version of the song lyrics.
    Ensure your output adheres strictly to the JSON schema.
    PROMPT

    service = OpenaiResponsesService.new

    begin
      api_response = service.generate_lyrics( # Still generating lyrics, but with more context
        prompt: refinement_prompt,
        instructions: AI_INSTRUCTIONS_REFINEMENT,
        previous_response_id: last_revision['api_response_id_supervision'] # Link to the supervisor's turn
      )

      if api_response["error"]
        Rails.logger.error "RefineLyricsJob: API Error for LyricSet ID #{lyric_set_id} - #{api_response['error']}"
        # Status could remain needs_revision for retry or go to an error state
        return
      end

      raw_output_text = api_response.dig("output", 0, "content", 0, "text")
      unless raw_output_text
        refusal_message = api_response.dig("output", 0, "refusal")
        Rails.logger.error "RefineLyricsJob: API returned no text output for LyricSet ID #{lyric_set_id}. Refusal: #{refusal_message || 'N/A'}"
        return
      end

      parsed_lyrics_data = JSON.parse(raw_output_text)
      refined_lyrics_body = parsed_lyrics_data['lyrics_body']

      # Create a new entry in revision_history for this refinement
      new_history_entry = {
        lyrics_content: refined_lyrics_body,
        generation_prompt_used: refinement_prompt,
        supervisor_feedback: nil, # Will be filled by next SuperviseLyricsJob
        supervisor_suggested_improvements: nil,
        supervisor_approved_this_version: false,
        api_response_id_generation: api_response['id'],
        api_response_id_supervision: nil,
        created_at: Time.current,
        user_edit_instructions_for_next_version: nil # For future use
      }

      lyric_set.revision_history << new_history_entry
      lyric_set.current_lyrics = refined_lyrics_body
      lyric_set.status = :pending_supervision # Send back for review
      lyric_set.save!

      Rails.logger.info "RefineLyricsJob: Successfully refined lyrics for LyricSet ID #{lyric_set_id}. Enqueuing SuperviseLyricsJob."
      SuperviseLyricsJob.perform_later(lyric_set.id)

    rescue JSON::ParserError => e
      Rails.logger.error "RefineLyricsJob: Failed to parse JSON response for LyricSet ID #{lyric_set_id}. Error: #{e.message}. Raw text: #{raw_output_text}"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "RefineLyricsJob: Failed to save LyricSet ID #{lyric_set_id}. Errors: #{e.record.errors.full_messages.join(', ')}"
    rescue StandardError => e
      Rails.logger.error "RefineLyricsJob: Unexpected error for LyricSet ID #{lyric_set_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
    end
  end
end 