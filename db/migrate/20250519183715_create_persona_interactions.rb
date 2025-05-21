class CreatePersonaInteractions < ActiveRecord::Migration[7.1]
  def change
    create_table :persona_interactions do |t|
      t.text :trigger_description
      t.text :initial_prompt
      t.string :personality_key
      t.integer :status
      t.text :generated_response
      t.jsonb :action_details
      t.string :current_api_response_id
      t.jsonb :conversation_history

      t.timestamps
    end
  end
end
