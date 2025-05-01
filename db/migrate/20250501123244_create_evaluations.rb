class CreateEvaluations < ActiveRecord::Migration[7.1]
  def change
    create_table :evaluations do |t|
      t.references :evaluation_job, null: false, foreign_key: true
      t.string :agent_identifier
      t.text :text_result
      t.string :status
      t.text :error_message

      t.timestamps
    end
  end
end
