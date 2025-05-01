class TextEvaluation < ApplicationRecord
  belongs_to :text_evaluation_job

  # === ATTRIBUTES ===
  attribute :agent_identifier, :string
  attribute :status, :string, default: 'queued' # e.g., queued, processing, completed, failed
  attribute :text_result, :text
  attribute :error_message, :text

  # === VALIDATIONS ===
  validates :agent_identifier, presence: true
  validates :text_evaluation_job, presence: true

  # === SCOPES ===
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }

  # Helper to mark failure and notify parent
  def processing_failed(message)
    update(status: 'failed', error_message: message)
    # Optionally notify the parent TextEvaluationJob
    text_evaluation_job.update(status: 'failed', error_message: "TextEvaluation #{id} failed: #{message}")
  end
end
