class AddSupervisorFeedbackToEvaluations < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluations, :supervisor_feedback, :text
    add_column :evaluations, :supervisor_llm_api_response_id, :string
  end
end
