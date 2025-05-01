class CreateTextEvaluations < ActiveRecord::Migration[7.1]
  def change
    create_table :text_evaluations do |t|
      t.references :text_evaluation_job, null: false, foreign_key: true
      t.string :agent_identifier
      t.string :status
      t.text :text_result
      t.text :error_message

      t.timestamps
    end
  end
end
