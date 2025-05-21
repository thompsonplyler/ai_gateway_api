class PersonaInteraction < ApplicationRecord
  enum status: { 
    pending_generation: 0, 
    generation_in_progress: 1, 
    generation_complete: 2, 
    generation_failed: 3, 
    action_pending: 4, # If the AI decides an action needs to be taken (e.g., create calendar event)
    action_complete: 5,
    action_failed: 6,
    archived: 7 # For completed or failed interactions that are no longer active
  }

  # Validations (can be added later)
  # validates :initial_prompt, presence: true
  # validates :personality_key, presence: true
end 