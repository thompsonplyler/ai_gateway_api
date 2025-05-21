require 'faraday'
require 'json'

# Initializer likely loaded the schemas into this module
# require_relative '../../config/initializers/openai_quest_schemas'

class OpenaiResponsesService
  BASE_URL = 'https://api.openai.com/v1'.freeze
  # Define timeouts in seconds
  OPEN_TIMEOUT = 10 # Time to open the connection
  READ_TIMEOUT = 120 # Time to wait for response data (increased from default)
  WRITE_TIMEOUT = 60 # Time to wait for a write operation to complete (if applicable, less common for GET/POST data)

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
      # Configure timeouts
      faraday.options.open_timeout = OPEN_TIMEOUT
      faraday.options.timeout = READ_TIMEOUT # This is the overall read/inactive timeout
      # faraday.options.write_timeout = WRITE_TIMEOUT # If you need to set write timeout specifically
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

  # Method for generating lyrics
  def generate_lyrics(prompt:, instructions:, model: "gpt-4o", previous_response_id: nil)
    # LYRIC_GENERATION_SCHEMA should be available from config/initializers/openai_lyric_schemas.rb
    request_body = {
      model: model,
      input: prompt,
      instructions: instructions,
      text: {
        format: {
          type: "json_schema",
          name: "lyric_generation_output",
          schema: LYRIC_GENERATION_SCHEMA, # From initializer
          strict: true
        }
      },
      store: true
    }
    request_body[:previous_response_id] = previous_response_id if previous_response_id.present?

    post_request("responses", request_body)
  end

  # Method for supervising lyrics
  def supervise_lyrics(prompt:, instructions:, previous_response_id:, model: "gpt-4o")
    # LYRIC_SUPERVISION_SCHEMA should be available from config/initializers/openai_lyric_schemas.rb
    request_body = {
      model: model,
      input: prompt,
      instructions: instructions,
      previous_response_id: previous_response_id, # Required for supervision context
      text: {
        format: {
          type: "json_schema",
          name: "lyric_supervision_output",
          schema: LYRIC_SUPERVISION_SCHEMA, # From initializer
          strict: true
        }
      },
      store: true
    }
    post_request("responses", request_body)
  end

  # Method for generating a persona response
  def generate_persona_response(prompt:, instructions:, model: "gpt-4o", previous_response_id: nil)
    # PERSONA_RESPONSE_SCHEMA should be available from config/initializers/openai_persona_schemas.rb
    request_body = {
      model: model,
      input: prompt,
      instructions: instructions,
      text: {
        format: {
          type: "json_schema",
          name: "persona_response_output", # Consistent naming convention
          schema: OpenaiPersonaSchemas::PERSONA_RESPONSE_SCHEMA, # From initializer
          strict: true
        }
      },
      store: true # Store response for potential conversation chaining
    }
    request_body[:previous_response_id] = previous_response_id if previous_response_id.present?

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