require 'faraday'
require 'json'

# Initializer likely loaded the schemas into this module
# require_relative '../../config/initializers/openai_quest_schemas'

class OpenaiResponsesService
  BASE_URL = 'https://api.openai.com/v1'.freeze

  def initialize(api_key = nil)
    @api_key = api_key || Rails.application.credentials.dig(:openai, :api_key) || ENV['OPENAI_API_KEY']
    
    if @api_key.blank?
      Rails.logger.error "OpenAI API Key is blank. Please check credentials or ENV variables."
      # Consider raising an error here to make the problem more visible immediately
      # raise "OpenAI API Key is missing!"
    end

    @connection = Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :json # Encode request bodies as JSON
      faraday.response :json # Decode response bodies as JSON
      faraday.adapter Faraday.default_adapter # Use the default adapter
    end
  end

  # New method specifically for generating quest candidates
  def generate_quest_candidate(generation_prompt:, instructions:, model: "gpt-4o", previous_response_id: nil)
    schema_definition = OpenaiQuestSchemas::QUEST_GENERATION_SCHEMA # Renamed for clarity
    request_body = {
      model: model,
      input: generation_prompt,
      instructions: instructions,
      text: {
        format: {
          type: "json_schema",
          name: "quest_generation_output", 
          schema: schema_definition, # Schema definition now directly under format
          strict: true              # Strict mode also directly under format
          # Removed the json_schema: { ... } nesting
        }
      },
      store: true # Keep storing responses for potential chaining
    }
    request_body[:previous_response_id] = previous_response_id if previous_response_id.present?

    post_request("responses", request_body)
  end

  # Method for sending a quest candidate for supervisory review
  def review_quest_candidate(quest_text_for_review:, generation_response_id:, instructions:, model: "gpt-4o")
    # quest_text_for_review should be a string containing the intro, completion message,
    # and any chosen variables formatted for the supervisor AI to understand.
    
    schema = OpenaiQuestSchemas::SUPERVISOR_REVIEW_SCHEMA
    request_body = {
      model: model,
      input: quest_text_for_review,
      instructions: instructions, # Specific instructions for the supervisor AI
      previous_response_id: generation_response_id, # Link to the original generation context
      text: {
        format: {
          type: "json_schema",
          name: "supervisor_review_output", # Schema name for supervisor output
          schema: schema,
          strict: true
        }
      },
      store: true # Important for conversation history
    }

    post_request("responses", request_body)
  end

  # Method for generating evaluation text
  def generate_evaluation_text(generation_prompt:, instructions:, model: "gpt-4o", previous_response_id: nil)
    schema_definition = OpenaiQuestSchemas::EVALUATION_GENERATION_SCHEMA
    request_body = {
      model: model,
      input: generation_prompt, # This prompt should reference the file_id for the PPTX
      instructions: instructions, # Agent-specific instructions
      text: {
        format: {
          type: "json_schema",
          name: "evaluation_generation_output",
          schema: schema_definition,
          strict: true
        }
      },
      store: true # Store the response for potential chaining (e.g., refinement)
    }
    # previous_response_id is typically nil for the first generation step
    request_body[:previous_response_id] = previous_response_id if previous_response_id.present?

    post_request("responses", request_body)
  end

  # Method for supervising/reviewing evaluation text
  def supervise_evaluation_text(evaluation_text_to_review:, generation_response_id:, instructions:, model: "gpt-4o")
    schema_definition = OpenaiQuestSchemas::EVALUATION_SUPERVISION_SCHEMA
    request_body = {
      model: model,
      input: evaluation_text_to_review, # The generated text from the previous step
      instructions: instructions,        # Specific instructions for the supervisor AI
      previous_response_id: generation_response_id, # Link to the original generation context
      text: {
        format: {
          type: "json_schema",
          name: "evaluation_supervision_output",
          schema: schema_definition,
          strict: true
        }
      },
      store: true # Store the response for conversation history
    }

    post_request("responses", request_body)
  end

  # Original simplified method (kept for reference or basic tests)
  def create_simple_response(prompt_text:, model: "gpt-4o")
    request_body = {
      model: model,
      input: prompt_text,
      store: true
    }
    post_request("responses", request_body)
  end

  # Original structured method (kept for reference or basic tests)
  def create_structured_response(prompt_text:, schema:, schema_name: "custom_structured_output", model: "gpt-4o")
    schema_definition = schema # Using passed schema
    request_body = {
      model: model,
      input: prompt_text,
      instructions: "Generate a JSON object matching the provided schema.",
      text: {
        format: {
          type: "json_schema",
          name: schema_name, 
          schema: schema_definition, # Schema definition now directly under format
          strict: true              # Strict mode also directly under format
          # Removed the json_schema: { ... } nesting
        }
      },
      store: true
    }
    post_request("responses", request_body)
  end

  private

  def post_request(endpoint, body)
    response = @connection.post(endpoint) do |req|
      req.headers['Authorization'] = "Bearer #{@api_key}"
      req.headers['Content-Type'] = 'application/json'
      req.body = body
    end

    handle_response(response)
  rescue Faraday::Error => e
    # Basic error handling, can be expanded based on your project's needs
    Rails.logger.error "OpenAI API Error: #{e.message}"
    Rails.logger.error "Response body: #{e.response[:body] if e.response}"
    # Consider returning a specific error object or re-raising a custom error
    { "error" => { "message" => e.message, "type" => "api_connection_error" } }
  end

  def handle_response(response)
    unless response.success?
      # Log detailed error information from OpenAI if available
      error_info = response.body || { "message" => "HTTP Status #{response.status}" }
      Rails.logger.error "OpenAI API Error: Status #{response.status}, Body: #{error_info.inspect}"
      # Return the error body structure OpenAI uses
      return { "error" => error_info } 
    end
    response.body # This should be the parsed JSON (Hash)
  end
end 