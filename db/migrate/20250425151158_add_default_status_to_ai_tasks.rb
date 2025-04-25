class AddDefaultStatusToAiTasks < ActiveRecord::Migration[7.1]
  def change
    change_column_default :ai_tasks, :status, from: nil, to: 'queued'
  end
end
