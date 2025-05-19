# app/jobs/generate_lyrics_job.rb
class GenerateLyricsJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 5
  retry_on Faraday::TimeoutError, wait: :exponentially_longer, attempts: 5

  DEFAULT_BUFFY_TOPIC = """how great my dog Buffy is. She's a rescue dog.
We adopted her from Puerto Rico, but she's a Queens girl all the way.
She has beautiful black fur and tan markings.
She is very food/treat motivated, and she is always down to high-five."""

  # This template now assumes the topic has just been stated.
  INITIAL_LYRIC_INSTRUCTIONS_TEMPLATE = """

Please ensure your output is creative, heartfelt, and follows a typical song structure
(e.g., verses, chorus). The lyrics should be suitable for a pop or folk song.
Focus on evocative language. Show, don't just tell. Explore nuances and aim for originality. 
Your lyrics should aim to tell interesting stories or describe interesting places and feelings 
in a way that resonates emotionally and intellectually.
Adhere strictly to the JSON schema provided for your response.
"""

  # Instructions for the AI (can be refined)
  AI_INSTRUCTIONS_GENERATION = """You are a creative and talented songwriter. Your task is to generate song lyrics based on the provided topic. 
Focus on evocative language, showing rather than telling. Explore nuances, aim for originality, and try to tell interesting stories or describe interesting places and feelings in a way that resonates emotionally and intellectually. 
Pay attention to rhyme, rhythm, and emotional tone. Format your output strictly according to the JSON schema."""

  def perform(lyric_set_id)
    Rails.logger.info "GenerateLyricsJob started for LyricSet ID: #{lyric_set_id}"
    lyric_set = LyricSet.find_by(id: lyric_set_id)

    unless lyric_set
      Rails.logger.error "GenerateLyricsJob: LyricSet with ID #{lyric_set_id} not found. Skipping."
      return
    end

    unless lyric_set.status == 'pending_initial_generation'
      Rails.logger.warn "GenerateLyricsJob: LyricSet ID #{lyric_set_id} is not in 'pending_initial_generation' status (current: #{lyric_set.status}). Skipping."
      return
    end

    actual_topic = lyric_set.topic || "a creative theme about overcoming challenges" # Fallback
    generation_prompt = "Write a song about #{actual_topic}." + INITIAL_LYRIC_INSTRUCTIONS_TEMPLATE
    
    Rails.logger.debug "GenerateLyricsJob: Using generation prompt:\n#{generation_prompt}" # Added for debugging

    service = OpenaiResponsesService.new

    begin
      api_response = service.generate_lyrics(
        prompt: generation_prompt,
        instructions: AI_INSTRUCTIONS_GENERATION,
        previous_response_id: nil
      )

      if api_response["error"]
        Rails.logger.error "GenerateLyricsJob: API Error for LyricSet ID #{lyric_set_id} - #{api_response['error']}"
        lyric_set.update(status: :pending_initial_generation)
        return
      end

      raw_output_text = api_response.dig("output", 0, "content", 0, "text")
      unless raw_output_text
        refusal_message = api_response.dig("output", 0, "refusal")
        Rails.logger.error "GenerateLyricsJob: API returned no text output for LyricSet ID #{lyric_set_id}. Refusal: #{refusal_message || 'N/A'}"
        lyric_set.update(status: :pending_initial_generation)
        return
      end

      parsed_lyrics_data = JSON.parse(raw_output_text)
      generated_lyrics_body = parsed_lyrics_data['lyrics_body']
      # suggested_title = parsed_lyrics_data['suggested_song_title'] # We can use this later

      # Create the first entry in revision_history
      new_history_entry = {
        lyrics_content: generated_lyrics_body,
        generation_prompt_used: generation_prompt,
        supervisor_feedback: nil,
        supervisor_suggested_improvements: nil,
        supervisor_approved_this_version: false,
        api_response_id_generation: api_response['id'],
        api_response_id_supervision: nil,
        created_at: Time.current,
        user_edit_instructions_for_next_version: nil # For future use
      }

      lyric_set.revision_history = (lyric_set.revision_history || []) << new_history_entry
      lyric_set.current_lyrics = generated_lyrics_body
      lyric_set.status = :pending_supervision
      lyric_set.save!

      Rails.logger.info "GenerateLyricsJob: Successfully generated initial lyrics for LyricSet ID #{lyric_set_id}. Enqueuing SuperviseLyricsJob."
      SuperviseLyricsJob.perform_later(lyric_set.id)

    rescue JSON::ParserError => e
      Rails.logger.error "GenerateLyricsJob: Failed to parse JSON response for LyricSet ID #{lyric_set_id}. Error: #{e.message}. Raw text: #{raw_output_text}"
      lyric_set.update(status: :pending_initial_generation)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "GenerateLyricsJob: Failed to save LyricSet ID #{lyric_set_id}. Errors: #{e.record.errors.full_messages.join(', ')}"
      # Status remains pending_initial_generation or handle as error
    rescue StandardError => e
      Rails.logger.error "GenerateLyricsJob: Unexpected error for LyricSet ID #{lyric_set_id}. Error: #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"
      lyric_set.update(status: :pending_initial_generation)
    end
  end
end 