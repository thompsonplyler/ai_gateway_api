class EnsureCorrectQuestCandidateSchema < ActiveRecord::Migration[7.1]
  def change
    # Table name is :quest_candidates

    # 1. Handle refinement_attempts
    if column_exists?(:quest_candidates, :refinement_attempts)
      # Column exists, ensure its properties are correct.
      # Update existing NULLs to 0 before changing null constraint.
      QuestCandidate.where(refinement_attempts: nil).update_all(refinement_attempts: 0) if defined?(QuestCandidate)
      change_column_null :quest_candidates, :refinement_attempts, false, 0
      change_column_default :quest_candidates, :refinement_attempts, from: nil, to: 0
      Rails.logger.info "Ensured :refinement_attempts column on quest_candidates has default 0 and is not null."
    else
      # Column doesn't exist, add it correctly.
      add_column :quest_candidates, :refinement_attempts, :integer, default: 0, null: false
      Rails.logger.info "Added :refinement_attempts column to quest_candidates with default 0, null: false."
    end

    # 2. Handle supervisory_notes (the old text column)
    if column_exists?(:quest_candidates, :supervisory_notes)
      # Consider migrating data if necessary before removing.
      # For now, we remove it as per previous discussions.
      remove_column :quest_candidates, :supervisory_notes, :text
      Rails.logger.info "Removed old :supervisory_notes (text) column from quest_candidates."
    else
      Rails.logger.info "Old :supervisory_notes (text) column not found on quest_candidates."
    end

    # 3. Handle supervisory_notes_history (the new jsonb column)
    unless column_exists?(:quest_candidates, :supervisory_notes_history)
      add_column :quest_candidates, :supervisory_notes_history, :jsonb, default: [], null: false
      Rails.logger.info "Added :supervisory_notes_history (jsonb) column to quest_candidates with default [], null: false."
    else
      # If it exists, ensure its properties are correct (e.g., default, null constraint).
      # This is mainly for thoroughness; typically, if it exists, it was added by a previous migration attempt.
      # Note: changing default for jsonb to an empty array if it was something else (like nil) might require specific syntax or steps.
      # For now, we assume if it exists, its structure is likely what was intended by a previous attempt to add it.
      change_column_default :quest_candidates, :supervisory_notes_history, from: nil, to: []
      change_column_null :quest_candidates, :supervisory_notes_history, false, []
      Rails.logger.info "Ensured :supervisory_notes_history column on quest_candidates has default [] and is not null."
    end
  end
end
