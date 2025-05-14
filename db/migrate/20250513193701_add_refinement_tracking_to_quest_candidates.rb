class AddRefinementTrackingToQuestCandidates < ActiveRecord::Migration[7.1]
  def change
    add_column :quest_candidates, :refinement_attempts, :integer
  end
end
