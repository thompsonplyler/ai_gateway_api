class CreateTextEvaluationJobs < ActiveRecord::Migration[7.1]
  def change
    create_table :text_evaluation_jobs do |t|
      t.string :status
      t.text :text_result
      t.text :error_message

      t.timestamps
    end
  end
end
