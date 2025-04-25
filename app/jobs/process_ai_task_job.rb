class ProcessAiTaskJob < ApplicationJob
  queue_as :default # You can define different queues (e.g., :ai_requests)

  def perform(prompt, task_id = nil)
    # In a real app:
    # 1. Find associated record (e.g., AiTask.find(task_id))
    # 2. Make the actual API call to the external AI service using the 'prompt'
    #    - Use gems like Faraday or HTTParty
    #    - Handle API keys securely (e.g., Rails credentials or ENV vars)
    #    - Example: response = Faraday.post('AI_SERVICE_URL', { prompt: prompt }, { 'Authorization' => "Bearer #{ENV['AI_API_KEY']}" })
    # 3. Process the response
    # 4. Handle errors and retries (Sidekiq handles basic retries)
    # 5. Update the status of the associated record (e.g., task.update(status: 'completed', result: response.body))

    puts "Processing AI task for prompt: '#{prompt}' (Task ID: #{task_id || 'N/A'})"
    sleep 5 # Simulate work
    puts "Finished processing AI task for prompt: '#{prompt}'"

  rescue StandardError => e
    # Log error, potentially update task status to 'failed'
    Rails.logger.error("Error processing AI task for prompt '#{prompt}': #{e.message}")
    # Sidekiq will automatically retry based on its configuration
    raise e # Re-raise to allow Sidekiq retry mechanisms
  end
end