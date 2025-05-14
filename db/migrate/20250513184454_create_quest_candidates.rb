class CreateQuestCandidates < ActiveRecord::Migration[7.1]
  def change
    create_table :quest_candidates do |t|
      t.string :chosen_variables_species
      t.string :chosen_variables_hat
      t.string :chosen_variables_mood
      t.string :chosen_variables_item_needed
      t.text :quest_intro
      t.text :quest_complete_message
      t.string :raw_api_response_id
      t.string :status
      t.text :supervisory_notes
      t.datetime :approved_at

      t.timestamps
    end
  end
end
