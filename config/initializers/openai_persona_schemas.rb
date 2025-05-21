# config/initializers/openai_persona_schemas.rb

# Schemas for AI interactions related to the Persona feature

module OpenaiPersonaSchemas
  # Schema for the AI generating the initial persona response
  PERSONA_RESPONSE_SCHEMA = {
    type: :object,
    properties: {
      generated_text: {
        type: :string,
        description: "The persona's textual response to the user's prompt, adhering to the specified personality."
      },
      identified_action: {
        type: :object,
        description: "Details of any action the persona has identified as necessary or has been asked to perform (e.g., scheduling an event). Null if no specific action is identified yet.",
        nullable: true,
        properties: {
          action_type: {
            type: :string,
            description: "The type of action identified (e.g., 'create_calendar_event', 'request_clarification', 'provide_information').",
            enum: ["create_calendar_event", "request_clarification", "provide_information", "other"]
          },
          action_parameters: {
            type: :object,
            description: "Parameters for the identified action. Structure depends on action_type.",
            # Example for create_calendar_event - this will be refined
            # properties: {
            #   event_summary: { type: :string, description: "The title or summary of the event." },
            #   start_time: { type: :string, format: :date_time, description: "Start date and time in ISO 8601 format." },
            #   end_time: { type: :string, format: :date_time, description: "End date and time in ISO 8601 format (optional)." },
            #   description: { type: :string, description: "More details about the event (optional)." },
            #   location: { type: :string, description: "Location of the event (optional)." },
            #   attendees: { type: :array, items: { type: :string, format: :email }, description: "List of attendee email addresses (optional)." }
            # },
            # required: ["event_summary", "start_time"]
          },
          confirmation_needed: {
            type: :boolean,
            description: "True if the persona needs to confirm this action with the user before proceeding (e.g., for creating a calendar event)."
          }
        },
        # required: ["action_type"] # Only if identified_action is not null
      }
    },
    required: ["generated_text"],
    additionalProperties: false
  }.freeze

  # We might add other schemas here later, for example, a schema for a supervisor AI
  # or a schema for a more detailed calendar event extraction.

end 