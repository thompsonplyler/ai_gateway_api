require 'openai'
# Note: Removed require 'pptx' and require 'tempfile'

# app/jobs/llm_evaluation_job.rb
class LlmEvaluationJob < ApplicationJob
  queue_as :default

  # Assistants API calls can involve multiple steps and polling
  sidekiq_options retry: 3, dead: true, lock: :until_executed, lock_ttl: 15.minutes

  # Define potential errors for retry using Faraday errors (for ruby-openai gem)
  # Use :polynomially_longer as :exponentially_longer is deprecated
  retry_on Faraday::TooManyRequestsError, wait: :polynomially_longer, attempts: 5 # HTTP 429
  retry_on Faraday::ServerError, wait: :polynomially_longer, attempts: 5          # HTTP 5xx

  discard_on ActiveJob::DeserializationError

  # Define personalities/instructions for the Run
  AGENT_INSTRUCTIONS = {
    'agent_1' => "You are Vince, a thoughtful and serious businessman who is sharp and concise. He's a technologist, and he gets most excited about things that move technology and the world forward. He doesn't pull punches, and he doesn't mince words. He's concise and clear. He will provide evaluation based on his main interest being advanced technology and the practicality. He won't lose his temper unless an idea or pitch is absurd on its face and impossible to implement. He feels that wastes his time. Your responses must be short while still fitting your character description. No more than 15 seconds of spoken words for this evaluation.",
    'agent_2' => "You are Ella, a supportive and encouraging evaluator. Ella appreciates the bravery of people who approach her with their ideas, and she is never rude, condescending, or mean-spirited. That said, she's very smart, and she doesn't hesitate to point out when something is impractical or pointless. If it seems like someone is mainly interested in making money, she finds it disappointing, because she believes there's a world where everyone can come out winners and make the world a better place. She is not blandly kind. She is more like a stern mother who knows what's best for everyone. Her evaluations will typically be appreciative and neutral, although she'll point out flaws in a product or plan. If she senses that a product primarily exists to make money, she won't be mad, but she will be vocally disappointed. Your responses must be short while still fitting your character description. No more than 15 seconds of spoken words for this evaluation.",
    'agent_3' => "You are Reginald, a snide aristocrat multi-millionaire who goes into every pitch meeting expecting to be unimpressed. His ratings will typically be below average. In addition to the criteria set out in the instructions. He will generally evaluate projects and pitches for imagination, the feasibility of a return, and the practicality of making it to market without getting obliterated by competition. If a project doesn't work for all three of these, he will be more than critical, he will be rude. His evaluations are precise, specific, and usually right. If a project works for all his criteria, he will grudgingly praise it. It's important that while he is snide, rude, and condescending, he isn't IMPOSSIBLE to please, so if a project is truly amazing, he will reluctantly say so. Your responses must be short while still fitting your character description. No more than 15 seconds of spoken words for this evaluation."
  }.freeze

  # Timeouts for polling the Run status
  RUN_POLL_INTERVAL = 5 # seconds
  RUN_TIMEOUT = 20 * 60 # 20 minutes (Increased from 10)

  # Token limit for Assistant response
  MAX_COMPLETION_TOKENS = 250

  def perform(evaluation_id)
    evaluation = Evaluation.find_by(id: evaluation_id)
    unless evaluation
      Rails.logger.warn "LlmEvaluationJob: Evaluation ##{evaluation_id} not found. Skipping."
      return
    end

    # Prevent re-processing if already started or finished
    unless evaluation.status == 'pending'
      Rails.logger.info "LlmEvaluationJob: Evaluation ##{evaluation_id} has status #{evaluation.status}. Skipping."
      return
    end

    evaluation.update(status: 'evaluating')
    evaluation_job = evaluation.evaluation_job
    powerpoint = evaluation_job.powerpoint_file

    unless powerpoint.attached?
      evaluation.processing_failed("Original PowerPoint file is missing.")
      return
    end

    # Get Assistant ID and agent-specific instructions
    assistant_id = Rails.application.credentials.dig(:openai, :assistant_id)
    agent_instructions = AGENT_INSTRUCTIONS[evaluation.agent_identifier]

    unless assistant_id && agent_instructions
      msg = "Missing OpenAI Assistant ID or instructions for agent #{evaluation.agent_identifier}"
      Rails.logger.error msg
      evaluation.processing_failed(msg)
      return
    end

    begin
      # Initialize client with API key and required V2 header
      client = OpenAI::Client.new(
        access_token: Rails.application.credentials.dig(:openai, :api_key),
        extra_headers: {
          'OpenAI-Beta' => 'assistants=v2'
        }
      )
      Rails.logger.info "Starting Assistants API V2 flow for Evaluation ##{evaluation.id}"

      # 1. Upload the file to OpenAI
      # Download blob to tempfile and pass the File object to the API
      file_id = nil
      powerpoint.blob.open do |temp_file|
        Rails.logger.info "Uploading file #{powerpoint.filename} (Temp path: #{temp_file.path}) to OpenAI..."
        file_response = client.files.upload(
          parameters: {
            file: temp_file, # Pass the temp File object
            purpose: 'assistants'
          }
        )
        file_id = file_response['id']
      end # Tempfile is automatically closed and unlinked here

      unless file_id
        # Log the response if available, even if ID is missing
        log_msg = "Failed to upload file to OpenAI."
        log_msg += " Response: #{file_response.inspect}" if defined?(file_response)
        raise log_msg
      end
      Rails.logger.info "File uploaded (ID: #{file_id}) for Evaluation ##{evaluation.id}"

      # 2. Create a Thread
      # Reverted: Removed attempt to pass headers directly
      thread_response = client.threads.create
      thread_id = thread_response['id']
      Rails.logger.info "Thread created (ID: #{thread_id}) for Evaluation ##{evaluation.id}"

      # 3. Add a Message to the Thread, attaching the file
      message_content = "Please evaluate the attached presentation according to your specific instructions."
      client.messages.create(
        thread_id: thread_id,
        parameters: {
          role: "user",
          content: message_content,
          attachments: [
            { file_id: file_id, tools: [{ type: "file_search" }] }
          ]
        }
      )
      Rails.logger.info "Message added to thread #{thread_id} for Evaluation ##{evaluation.id}"

      # 4. Create a Run, providing agent-specific instructions and token limits
      run_response = client.runs.create(
        thread_id: thread_id,
        parameters: {
          assistant_id: assistant_id,
          instructions: agent_instructions, # Override/add personality here
          max_completion_tokens: MAX_COMPLETION_TOKENS
        }
      )
      run_id = run_response['id']
      Rails.logger.info "Run created (ID: #{run_id}, Max Tokens: #{MAX_COMPLETION_TOKENS}) for Evaluation ##{evaluation.id}"

      # 5. Poll for Run completion
      start_time = Time.now
      loop do
        run = client.runs.retrieve(thread_id: thread_id, id: run_id)
        Rails.logger.debug "Polling Run ##{run_id} status: #{run['status']} (Eval ##{evaluation.id})"

        case run['status']
        when 'completed'
          Rails.logger.info "Run ##{run_id} completed for Evaluation ##{evaluation.id}"
          break # Exit loop
        when 'requires_action'
          # Handle function calls if you add them later, for now, we fail.
          evaluation.processing_failed("Run ##{run_id} requires unexpected action.")
          # Clean up uploaded file? Maybe not if retryable.
          return
        when 'failed', 'cancelled', 'expired'
          error_message = run.dig('last_error', 'message') || "Run #{run['status']}"
          evaluation.processing_failed("Run ##{run_id} #{run['status']}: #{error_message}")
          # Clean up uploaded file?
          # client.files.delete(file_id: file_id) rescue nil # Best effort cleanup
          return
        end

        # Timeout check
        if Time.now - start_time > RUN_TIMEOUT
          evaluation.processing_failed("Run ##{run_id} timed out after #{RUN_TIMEOUT} seconds.")
          # Attempt cancellation?
          # client.runs.cancel(thread_id: thread_id, id: run_id) rescue nil
          # client.files.delete(file_id: file_id) rescue nil # Best effort cleanup
          return
        end

        sleep RUN_POLL_INTERVAL
      end

      # 6. Retrieve the Assistant's response Message
      messages_response = client.messages.list(thread_id: thread_id, parameters: { order: 'desc' })
      assistant_message = messages_response['data'].find { |m| m['role'] == 'assistant' }

      if assistant_message && assistant_message['content'].present?
        # Content is an array, join text values if multiple blocks
        text_result = assistant_message['content']
                        .select { |c| c['type'] == 'text' }
                        .map { |c| c.dig('text', 'value') }
                        .join("\n")
                        .strip

        if text_result.blank?
          evaluation.processing_failed("Assistant message was empty.")
        else
          evaluation.update!(text_result: text_result, status: 'generating_audio')
          TtsGenerationJob.perform_later(evaluation.id)
          Rails.logger.info "LLM evaluation complete (Assistants API) for Evaluation ##{evaluation.id}. Enqueuing TTS."
        end
      else
        evaluation.processing_failed("Could not find assistant message in thread ##{thread_id}. Response: #{messages_response.inspect}")
      end

      # 7. Clean up the uploaded file (optional, saves costs)
      # client.files.delete(file_id: file_id) rescue StandardError => e
      #   Rails.logger.warn "Failed to delete OpenAI file #{file_id}: #{e.message}"
      # end

    rescue Faraday::Error => e # Catch API/HTTP errors
      error_message = "OpenAI API Faraday error: #{e.message}"
      error_message += " (Status: #{e.response[:status]})" if e.respond_to?(:response) && e.response
      Rails.logger.error "#{error_message} for Evaluation ##{evaluation.id}"
      evaluation.processing_failed(error_message)
    rescue StandardError => e # Catch other unexpected errors
      Rails.logger.error "Unexpected error in LlmEvaluationJob for Evaluation ##{evaluation.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      evaluation.processing_failed("Unexpected error: #{e.message}")
    end
  end

  # No longer need extract_ppt_content method
end 

