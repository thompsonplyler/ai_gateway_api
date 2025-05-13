require 'faraday'
require 'json'

# Initializer likely loaded the schemas into this module
# require_relative '../../config/initializers/openai_quest_schemas'

class OpenaiResponsesService
  BASE_URL = 'https://api.openai.com/v1'.freeze

  def initialize(api_key = nil)
    # In real app, prefer Rails.application.credentials.openai[:api_key]
    @api_key = api_key || ENV['OPENAI_API_KEY'] 
    @connection = Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :json # Encode request bodies as JSON
      faraday.response :json # Decode response bodies as JSON
      faraday.adapter Faraday.default_adapter # Use the default adapter
    end
  end

  # New method specifically for generating quest candidates
  def generate_quest_candidate(generation_prompt:, instructions:, model: "gpt-4o")
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