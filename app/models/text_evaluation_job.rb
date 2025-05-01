class TextEvaluationJob < ApplicationRecord
  # Represents the overall job for generating three text evaluations for one PPT

  # === ASSOCIATIONS ===
  has_one_attached :powerpoint_file
  has_many :text_evaluations, dependent: :destroy

  # === ATTRIBUTES ===
  # status: e.g., 'queued', 'processing', 'completed', 'failed'
  attribute :status, :string, default: 'queued'
  attribute :error_message, :text

  # === VALIDATIONS ===
  validates :powerpoint_file, presence: true

  # === CONSTANTS ===
  # Reuse agent identifiers from EvaluationJob or define here if needed
  AGENT_IDENTIFIERS = EvaluationJob::AGENT_IDENTIFIERS

  # === CALLBACKS ===
  after_create_commit :initialize_evaluations_and_start_processing

  # === INSTANCE METHODS ===
  # Called by child jobs to check if all siblings are done
  def check_and_complete
    # Reload to get latest status of siblings
    self.reload
    return unless status == 'processing'

    if text_evaluations.all? { |e| e.status == 'completed' }
      update!(status: 'completed')
      Rails.logger.info "All text evaluations complete for TextEvaluationJob ##{id}. Marked as completed."
    elsif text_evaluations.any? { |e| e.status == 'failed' }
      # Optional: If one fails, mark the whole job as failed immediately
      # update(status: 'failed', error_message: "One or more text evaluations failed.")
      # Rails.logger.warn "One or more text evaluations failed for TextEvaluationJob ##{id}."
    end
  end

  private

  # Renamed from start_processing
  def initialize_evaluations_and_start_processing
    AGENT_IDENTIFIERS.each do |agent_id|
      text_evaluations.create!(agent_identifier: agent_id, status: 'queued')
    end

    update!(status: 'processing')

    text_evaluations.each do |text_eval|
      # Use the renamed job, passing the child ID
      ProcessSingleTextEvaluationJob.perform_later(text_eval.id)
    end
  rescue ActiveRecord::RecordInvalid => e
    update(status: 'failed', error_message: "Initialization failed: #{e.message}")
    Rails.logger.error "Failed to initialize TextEvaluationJob ##{id}: #{e.message}"
  end

  # Helper method for jobs to mark failure
  def processing_failed(message)
    update(status: 'failed', error_message: message)
  end
end
