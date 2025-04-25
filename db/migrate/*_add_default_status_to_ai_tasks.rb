class AddDefaultStatusToAiTasks < ActiveRecord::Migration[7.1]
  def change
    # Set the default value for the status column to 'queued'
    change_column_default :ai_tasks, :status, from: nil, to: 'queued'
  end
end 