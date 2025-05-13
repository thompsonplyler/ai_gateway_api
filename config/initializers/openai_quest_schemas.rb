module OpenaiQuestSchemas
  # Schema for the initial quest generation output
  QUEST_GENERATION_SCHEMA = {
    type: :object,
    properties: {
      chosen_variables: {
        type: :object,
        properties: {
          # Note: Enum values would ideally be populated dynamically later
          species: {type: :string, description: "Chosen species for the NPC"},
          hat: {type: :string, description: "Chosen hat for the NPC"},
          mood: {type: :string, description: "Chosen mood for the NPC"},
          item_needed: {type: :string, description: "Chosen item the NPC needs"}
        },
        required: ["species", "hat", "mood", "item_needed"],
        additionalProperties: false
      }.freeze,
      quest_intro: {
        type: :string,
        description: "2-3 sentences of dialogue introducing the quest."
      }.freeze,
      quest_complete_message: {
        type: :string,
        description: "2-3 sentences of dialogue for quest completion."
      }.freeze
    }.freeze,
    required: ["chosen_variables", "quest_intro", "quest_complete_message"],
    additionalProperties: false
  }.freeze

  # Schema for the supervisory review output
  SUPERVISOR_REVIEW_SCHEMA = {
    type: :object,
    properties: {
      approved: {
        type: :boolean,
        description: "Whether the generated quest meets the quality criteria."
      }.freeze,
      # Using array type with 'null' to emulate optional string
      feedback: {
        type: [:string, :null], 
        description: "Feedback on why the quest was disapproved, or null if approved."
      }.freeze,
      suggested_changes: {
        type: [:string, :null], 
        description: "Specific suggestions for improvement if disapproved, or null."
      }.freeze
    }.freeze,
    required: ["approved", "feedback", "suggested_changes"],
    additionalProperties: false
  }.freeze
end 