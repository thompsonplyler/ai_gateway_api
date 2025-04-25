require 'openai'

class ProcessAiTaskJob < ApplicationJob
  queue_as :default # You can define different queues (e.g., :ai_requests)

  # Set default model
  OPENAI_MODEL = "gpt-4o".freeze

  def perform(prompt, task_id)
    # Find the task
    task = AiTask.find_by(id: task_id)
    unless task
      Rails.logger.error("ProcessAiTaskJob: AiTask with ID #{task_id} not found.")
      return # Or raise an error
    end

    begin
      # Update status to 'processing'
      task.update!(status: 'processing') 

      # Simulate external API call
      Rails.logger.info("Processing AI task ##{task.id} with #{OPENAI_MODEL} for prompt: '#{prompt}'")

      # --- Debugging Credentials --- 
      Rails.logger.debug("Available Credentials Keys: #{Rails.application.credentials.keys.inspect}")
      Rails.logger.debug("OpenAI Credentials Object: #{Rails.application.credentials.openai.inspect}")
      # --- End Debugging ---

      # Initialize OpenAI client
      # Prioritize ENV var for production (e.g., Render), fallback to credentials for local dev
      access_token = ENV.fetch('OPENAI_API_KEY', nil) || Rails.application.credentials.openai![:api_key]
      client = OpenAI::Client.new(access_token: access_token)

      # Make the API call
      response = client.chat(parameters: {
        model: OPENAI_MODEL,
        messages: [{ role: "user", content: prompt }],
        temperature: 0.7, # Adjust temperature as needed
      })

      # Extract the result text
      result_text = response.dig("choices", 0, "message", "content")
      
      if result_text.present?
        Rails.logger.info("Finished processing AI task ##{task.id}")
        task.update!(status: 'completed', result: result_text.strip)
      else
        Rails.logger.error("Error processing AI task ##{task.id}: No content in OpenAI response. Response: #{response.inspect}")
        task.update!(status: 'failed', error_message: "No content received from OpenAI. Full response: #{response.inspect}")
      end

    rescue OpenAI::Error => e # Catch OpenAI specific errors
      Rails.logger.error("OpenAI API Error processing AI task ##{task.id}: #{e.message}")
      task.update(status: 'failed', error_message: "OpenAI Error: #{e.message}")
      raise e # Re-raise for potential Sidekiq retry
    rescue StandardError => e
      Rails.logger.error("General Error processing AI task ##{task.id}: #{e.message}")
      task.update(status: 'failed', error_message: e.message)
      raise e # Re-raise for potential Sidekiq retry
    end
  end
end