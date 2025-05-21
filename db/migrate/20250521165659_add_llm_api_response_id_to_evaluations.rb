class AddLlmApiResponseIdToEvaluations < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluations, :llm_api_response_id, :string
  end
end
