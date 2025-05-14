# OpenAI Responses API Quick Reference

This document summarizes key information for interacting with the OpenAI Responses API (`/v1/responses`),
particularly focusing on stateful conversations and structured JSON output, as relevant to this project.

## Core API Endpoint: Create a Model Response

`POST https://api.openai.com/v1/responses`

**Purpose:** Creates a model response. Can take text, image, or file inputs to generate text or JSON outputs. Supports custom tools and built-in tools.

### Key Request Body Parameters:

*   `input` (string or array, Required):
    *   Text, image, or file inputs to the model.
*   `model` (string, Required):
    *   Model ID (e.g., `gpt-4o`).
*   `instructions` (string or null, Optional):
    *   System/developer message inserted at the start of the model's context.
    *   **Important for Chaining**: When used with `previous_response_id`, instructions from the *previous* response are NOT carried over, allowing for fresh instructions at each turn.
*   `previous_response_id` (string or null, Optional):
    *   The unique ID of the previous response from this API.
    *   **Essential for multi-turn conversations and maintaining state.**
*   `store` (boolean or null, Optional, Defaults to `true`):
    *   Whether to store the generated model response for later retrieval and for `previous_response_id` to function.
*   `text` (object, Optional):
    *   Configuration options for a text response from the model.
    *   Used for requesting structured JSON output.
    *   **Structure for JSON Schema Output (as determined through iteration for this API):**
        ```json
        "text": {
          "format": {
            "type": "json_schema",
            "name": "your_schema_name", // A descriptive name for your schema
            "schema": { /* Your JSON Schema definition (as a JSON object) */ },
            "strict": true // Enforces schema adherence
          }
        }
        ```
*   `tools` (array, Optional):
    *   Array of tools (built-in or custom function calls) the model may use.
*   `tool_choice` (string or object, Optional):
    *   Controls how the model selects tools.
*   Other common parameters: `max_output_tokens`, `temperature`, `top_p`, `metadata`, `stream`, `user`.

### JSON Schema for Structured Outputs (Key Constraints when used with `text.format`):

*   **Schema Definition**: Provided within `text.format.schema`.
*   **`strict: true`**: Should be used to ensure schema adherence.
*   **`name: "your_schema_name"`**: Required under `text.format` when `type` is `json_schema`.
*   **Supported Types**: String, Number, Boolean, Integer, Object, Array, Enum, `anyOf`.
*   **Root Object**: Must be an object (not `anyOf`).
*   **Required Fields**: All fields in your schema objects must generally be listed in a `required` array for those objects.
*   **`additionalProperties: false`**: Must be set in schema objects.
*   **Limitations**: On nesting depth (e.g., 5 levels), total properties (e.g., 100), string sizes in schema definition, and enum sizes.
*   **Refusals**: If the model refuses a request for safety reasons when structured output is requested, the API response will include a `refusal` field in the output message instead of the schema-compliant JSON.

### Example Response Object Structure (Simplified):

```json
{
  "id": "resp_...", // Unique ID for this response
  "object": "response",
  "created_at": 1741476542,
  "status": "completed", // or failed, in_progress, incomplete
  "error": null, // Error object if status is failed
  "model": "gpt-4o-...
  "output": [
    {
      "type": "message",
      "id": "msg_...",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "... (model's text output, or JSON string if structured output requested) ..."
        }
        // Or other content types like refusals, tool calls
      ]
    }
  ],
  "previous_response_id": "resp_..." // ID of the request this was a response to, if provided
  // ... other fields like usage, store, temperature, etc.
}
```

## Other Relevant Endpoints:

*   `GET https://api.openai.com/v1/responses/{response_id}`:
    *   Retrieves a specific model response by its ID.
*   `DELETE https://api.openai.com/v1/responses/{response_id}`:
    *   Deletes a stored model response.
*   `GET https://api.openai.com/v1/responses/{response_id}/input_items`:
    *   Lists input items for a given response.

## Key Learnings from Project Integration:

*   The exact structure for `text.format` to enable JSON schema output (`type`, `name`, `schema`, `strict` placement) for the Responses API required iterative refinement based on API error messages. It differs subtly from how `response_format` might be used in other OpenAI APIs like Chat Completions.
*   `previous_response_id` is critical for chaining calls and maintaining context for multi-stage workflows (e.g., generation -> review -> refinement).
*   The `instructions` parameter being non-inheriting when `previous_response_id` is used is highly beneficial for setting distinct roles/tasks at each stage of a conversation. 