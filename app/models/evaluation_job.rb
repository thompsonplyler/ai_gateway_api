class EvaluationJob < ApplicationRecord
  # Represents the entire process for one PPT file

  # === ASSOCIATIONS ===
  has_one_attached :powerpoint_file # The original PPT file submitted
  has_many :evaluations, dependent: :destroy # Each job has multiple evaluation tasks (e.g., for different agents)

  # === ATTRIBUTES ===
  # Status field to track progress
  # Possible values: 'pending', 'processing_evaluations', 'completed', 'failed'
  attribute :status, :string, default: 'pending'

  # Store any overall error message
  attribute :error_message, :text

  # === VALIDATIONS ===
  validates :powerpoint_file, presence: true

  # === CONSTANTS ===
  # Define agent identifiers if they are static
  AGENT_IDENTIFIERS = ['agent_1', 'agent_2', 'agent_3'].freeze

  # === CALLBACKS ===
  after_create_commit :initialize_evaluations_and_start_processing

  # === INSTANCE METHODS ===

  private

  def initialize_evaluations_and_start_processing
    # This callback runs after the job record is created.
    # Create placeholder Evaluation records for each agent.
    AGENT_IDENTIFIERS.each do |agent_id|
      # Use create! to raise an error if creation fails
      evaluations.create!(agent_identifier: agent_id, status: 'pending')
    end

    # Update status and enqueue the initial processing job for each evaluation.
    # Use update! to raise an error if update fails
    update!(status: 'processing_evaluations')
    evaluations.each do |evaluation|
      # Ensure evaluation id is available before enqueuing
      LlmEvaluationJob.perform_later(evaluation.id)
    end
  rescue ActiveRecord::RecordInvalid => e
    # Handle validation errors during Evaluation creation or status update
    update(status: 'failed', error_message: "Initialization failed: #{e.message}")
    Rails.logger.error "Failed to initialize EvaluationJob ##{id}: #{e.message}"
  end
end
