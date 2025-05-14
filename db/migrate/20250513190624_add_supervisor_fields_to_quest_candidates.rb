class AddSupervisorFieldsToQuestCandidates < ActiveRecord::Migration[7.1]
  def change
    add_column :quest_candidates, :supervisor_raw_api_response_id, :string
    add_column :quest_candidates, :supervisor_approved, :boolean
  end
end
