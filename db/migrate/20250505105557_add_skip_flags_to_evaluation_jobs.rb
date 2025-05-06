class AddSkipFlagsToEvaluationJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluation_jobs, :skip_tts, :boolean, default: false
    add_column :evaluation_jobs, :skip_ttv, :boolean, default: false
  end
end
