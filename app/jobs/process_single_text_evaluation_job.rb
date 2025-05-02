require 'openai'

# app/jobs/process_single_text_evaluation_job.rb
class ProcessSingleTextEvaluationJob < ApplicationJob
  queue_as :default

  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 15.minutes

  # Define potential errors for retry using Faraday errors
  retry_on Faraday::TooManyRequestsError, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::ServerError, wait: :polynomially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  # Timeouts for polling the Run status
  RUN_POLL_INTERVAL = 5 # seconds
  RUN_TIMEOUT = 20 * 60 # 20 minutes

  # Token limit for Assistant response
  MAX_COMPLETION_TOKENS = 500 # Allow a bit more for a general summary

  # Takes TextEvaluation ID instead of TextEvaluationJob ID
  def perform(text_evaluation_id)
    text_evaluation = TextEvaluation.find_by(id: text_evaluation_id)
    unless text_evaluation
      Rails.logger.warn "ProcessSingleTextEvaluationJob: TextEvaluation ##{text_evaluation_id} not found. Skipping."
      return
    end

    # Prevent re-processing if already started/finished
    unless text_evaluation.status == 'queued' # Check for queued status
      Rails.logger.info "ProcessSingleTextEvaluationJob: TextEvaluation ##{text_evaluation_id} has status #{text_evaluation.status}. Skipping."
      return
    end

    text_evaluation.update(status: 'processing') # Set to processing
    parent_job = text_evaluation.text_evaluation_job
    powerpoint = parent_job.powerpoint_file

    unless powerpoint.attached?
      text_evaluation.processing_failed("Original PowerPoint file is missing.") # Use helper on child record
      return
    end

    assistant_id = Rails.application.credentials.dig(:openai, :assistant_id)
    agent_config = AGENTS_CONFIG[text_evaluation.agent_identifier]

    unless assistant_id && agent_config
      msg = "Missing OpenAI Assistant ID or agent config for identifier #{text_evaluation.agent_identifier}"
      Rails.logger.error msg
      text_evaluation.processing_failed(msg)
      return
    end

    agent_instructions = agent_config[:instructions]
    unless agent_instructions
      msg = "Missing instructions in agent config for identifier #{text_evaluation.agent_identifier}"
      Rails.logger.error msg
      text_evaluation.processing_failed(msg)
      return
    end

    begin
      client = OpenAI::Client.new(
        access_token: Rails.application.credentials.dig(:openai, :api_key),
        extra_headers: { 'OpenAI-Beta' => 'assistants=v2' }
      )
      Rails.logger.info "Starting Assistants API flow for TextEvaluation ##{text_evaluation_id}"

      # 1. Upload file
      file_id = nil
      powerpoint.blob.open do |temp_file|
        # NOTE: We upload the same file for each agent's evaluation.
        # Consider optimizing if file uploads are costly/slow (e.g., upload once, store file_id on parent job)
        file_response = client.files.upload(
          parameters: { file: temp_file, purpose: 'assistants' }
        )
        file_id = file_response['id']
      end
      raise "Failed to upload file to OpenAI." unless file_id
      Rails.logger.info "File uploaded (ID: #{file_id}) for TextEvaluation ##{text_evaluation_id}"

      # 2. Create Thread
      thread_response = client.threads.create
      thread_id = thread_response['id']
      Rails.logger.info "Thread created (ID: #{thread_id}) for TextEvaluation ##{text_evaluation_id}"

      # 3. Add Message
      message_content = "Please evaluate the attached presentation according to your specific instructions."
      client.messages.create(
        thread_id: thread_id,
        parameters: {
          role: "user",
          content: message_content,
          attachments: [{ file_id: file_id, tools: [{ type: "file_search" }] }]
        }
      )
      Rails.logger.info "Message added to thread #{thread_id} for TextEvaluation ##{text_evaluation_id}"

      # 4. Create Run (using specific agent instructions)
      run_response = client.runs.create(
        thread_id: thread_id,
        parameters: {
          assistant_id: assistant_id,
          instructions: agent_instructions,
          max_completion_tokens: MAX_COMPLETION_TOKENS
        }
      )
      run_id = run_response['id']
      Rails.logger.info "Run created (ID: #{run_id}) for TextEvaluation ##{text_evaluation_id}"

      # 5. Poll for Run completion
      start_time = Time.now
      loop do
        run = client.runs.retrieve(thread_id: thread_id, id: run_id)
        Rails.logger.debug "Polling Run ##{run_id} status: #{run['status']} (TextEval ##{text_evaluation_id})"

        case run['status']
        when 'completed'
          Rails.logger.info "Run ##{run_id} completed for TextEvaluation ##{text_evaluation_id}"
          break
        when 'requires_action'
          text_evaluation.processing_failed("Run ##{run_id} requires unexpected action.")
          return
        when 'failed', 'cancelled', 'expired'
          error_message = run.dig('last_error', 'message') || "Run #{run['status']}"
          text_evaluation.processing_failed("Run ##{run_id} #{run['status']}: #{error_message}")
          return
        end

        if Time.now - start_time > RUN_TIMEOUT
          text_evaluation.processing_failed("Run ##{run_id} timed out after #{RUN_TIMEOUT} seconds.")
          return
        end
        sleep RUN_POLL_INTERVAL
      end

      # 6. Retrieve the Assistant's response Message
      messages_response = client.messages.list(thread_id: thread_id, parameters: { order: 'desc' })
      assistant_message = messages_response['data'].find { |m| m['role'] == 'assistant' }

      if assistant_message && assistant_message['content'].present?
        # Extract the raw text content
        raw_text_result = assistant_message['content']
                        .select { |c| c['type'] == 'text' }
                        .map { |c| c.dig('text', 'value') }
                        .join("\n")
                        .strip

        # Clean the annotation tags (e.g., 【4:0†source】 or 【4:0†filename.pptx】)
        # This regex matches the general pattern observed.
        cleaned_text_result = raw_text_result.gsub(/【\d+:\d+†.*?】/, '').strip

        if cleaned_text_result.blank?
          text_evaluation.processing_failed("Assistant message was empty after cleaning annotations.")
        else
          # Save the cleaned result to the TextEvaluation record
          text_evaluation.update!(text_result: cleaned_text_result, status: 'completed')
          Rails.logger.info "Text evaluation complete for TextEvaluation ##{text_evaluation_id}."
          # Check if the parent job is now complete
          parent_job.check_and_complete
        end
      else
        text_evaluation.processing_failed("Could not find assistant message in thread ##{thread_id}. Response: #{messages_response.inspect}")
      end

    rescue Faraday::Error => e
      error_message = "OpenAI API Faraday error: #{e.message}"
      error_message += " (Status: #{e.response[:status]})" if e.respond_to?(:response) && e.response
      Rails.logger.error "#{error_message} for TextEvaluation ##{text_evaluation_id}"
      text_evaluation.processing_failed(error_message)
    rescue StandardError => e
      sanitized_msg = e.message.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      Rails.logger.error "Unexpected error in ProcessSingleTextEvaluationJob for TextEvaluation ##{text_evaluation_id}: #{sanitized_msg}\n#{e.backtrace.join("\n")}"
      text_evaluation.processing_failed("Unexpected error: #{sanitized_msg}")
    ensure
      # Optional: Clean up uploaded file
      # client.files.delete(file_id: file_id) rescue nil if defined?(file_id) && file_id
    end
  end
end 