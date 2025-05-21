class AddSupervisionFieldsToEvaluations < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluations, :supervisor_status, :string
    add_column :evaluations, :revision_attempts, :integer
    add_column :evaluations, :raw_text_output, :text
    add_column :evaluations, :current_text_output, :text
  end
end
