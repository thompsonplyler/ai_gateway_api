class ProcessAiTaskJob < ApplicationJob
  queue_as :default # You can define different queues (e.g., :ai_requests)

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
      Rails.logger.info("Processing AI task ##{task.id} for prompt: '#{prompt}'")
      sleep 5 # Simulate work
      # In a real app, capture the result: result_text = call_ai_service(prompt)
      result_text = "This is the simulated AI response to '#{prompt}'."
      Rails.logger.info("Finished processing AI task ##{task.id}")
      
      # Update task with result and 'completed' status
      task.update!(status: 'completed', result: result_text)

    rescue StandardError => e
      # Log error and update task status to 'failed'
      Rails.logger.error("Error processing AI task ##{task.id} for prompt '#{prompt}': #{e.message}")
      task.update(status: 'failed', error_message: e.message) if task # Update status if task exists
      # Sidekiq will automatically retry based on its configuration
      raise e # Re-raise to allow Sidekiq retry mechanisms unless you want specific handling
    end
  end
end