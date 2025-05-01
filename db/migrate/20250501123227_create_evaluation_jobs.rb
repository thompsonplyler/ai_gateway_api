class CreateEvaluationJobs < ActiveRecord::Migration[7.1]
  def change
    create_table :evaluation_jobs do |t|
      t.string :status
      t.text :error_message

      t.timestamps
    end
  end
end
