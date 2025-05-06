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

  # Method to check if all child evaluations are done based on skip flags
  def check_completion
    # Reload to ensure we have the latest state, especially child statuses
    reload
    # Don't proceed if already completed or failed by other means
    return unless status == 'processing_evaluations'

    # Determine the expected terminal status for children based on flags
    expected_terminal_status = if skip_ttv?
                                 # If TTS is also skipped, the final state is just after LLM finishes.
                                 # We set this to 'generating_audio' in LlmEvaluationJob.
                                 skip_tts? ? 'generating_audio' : 'generating_video'
                               else
                                 'video_generated'
                               end
    
    terminal_states = [expected_terminal_status, 'failed']

    # Check if all child evaluations have reached a terminal state
    all_children_finished = evaluations.all? { |e| e.status.in?(terminal_states) }

    if all_children_finished
      # Check if *any* child successfully reached the expected terminal state
      any_successful = evaluations.any? { |e| e.status == expected_terminal_status }

      if any_successful
        Rails.logger.info "All evaluations finished for EvaluationJob ##{id}. Marking as completed."
        update!(status: 'completed', error_message: nil)
      else
        # All children must have failed
        Rails.logger.info "All evaluations failed for EvaluationJob ##{id}. Marking as failed."
        # Avoid overwriting a more specific error message if one was already set
        unless error_message.present?
          update!(status: 'failed', error_message: "All individual evaluations failed before completing requested steps.")
        else
          update!(status: 'failed')
        end
      end
    else
      Rails.logger.debug "EvaluationJob ##{id} still processing. Children statuses: #{evaluations.map(&:status)}"
    end
  rescue StandardError => e
      Rails.logger.error "Error during check_completion for EvaluationJob ##{id}: #{e.message}\n#{e.backtrace.join("\n")}"
      # Avoid failing the job just because the check failed - log and move on.
  end

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
