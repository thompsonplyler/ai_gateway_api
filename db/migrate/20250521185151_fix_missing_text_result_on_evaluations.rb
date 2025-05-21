class FixMissingTextResultOnEvaluations < ActiveRecord::Migration[7.1]
  def change
    unless column_exists?(:evaluations, :text_result)
      add_column :evaluations, :text_result, :text
      Rails.logger.info "Fixer Migration: Added missing text_result column to evaluations table."
    else
      Rails.logger.info "Fixer Migration: text_result column already exists in evaluations table. No change made."
    end
  end
end
