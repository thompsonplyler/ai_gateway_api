class Evaluation < ApplicationRecord
  # Represents one evaluation pathway (LLM -> TTS -> TTV) for a single agent

  # === ASSOCIATIONS ===
  belongs_to :evaluation_job
  has_one_attached :audio_file # MP3 file from TTS
  has_one_attached :video_file # Video file from TTV

  # === ATTRIBUTES ===
  # Identifier for the agent performing the evaluation (e.g., "agent_1")
  attribute :agent_identifier, :string

  # Text result from the LLM evaluation
  attribute :text_result, :text

  # Status for this specific evaluation pathway
  # Possible values: 'pending', 'evaluating', 'generating_audio', 'generating_video', 'video_generated', 'failed'
  attribute :status, :string, default: 'pending'

  # Store any specific error message for this evaluation path
  attribute :error_message, :text

  # === VALIDATIONS ===
  validates :agent_identifier, presence: true
  validates :evaluation_job, presence: true

  # === SCOPES ===
  scope :video_generated, -> { where(status: 'video_generated') }
  scope :failed, -> { where(status: 'failed') }

  # === CLASS METHODS ===
  def self.agent_identifiers
    EvaluationJob::AGENT_IDENTIFIERS
  end

  # === INSTANCE METHODS ===

  def processing_failed(message)
    update(status: 'failed', error_message: message)
    # Optionally notify the parent EvaluationJob
    evaluation_job.update(status: 'failed', error_message: "Evaluation #{id} failed: #{message}")
  end

end
