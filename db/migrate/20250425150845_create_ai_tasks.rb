class CreateAiTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_tasks do |t|
      t.references :user, null: false, foreign_key: true
      t.text :prompt
      t.string :status
      t.text :result
      t.text :error_message

      t.timestamps
    end
  end
end
