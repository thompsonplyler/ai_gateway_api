class Evaluation < ApplicationRecord
  # Represents one evaluation pathway (LLM -> TTS -> TTV) for a single agent

  # === ASSOCIATIONS ===
  belongs_to :evaluation_job
  has_one_attached :audio_file # MP3 file from TTS
  has_one_attached :video_file # Video file from TTV

  # === ATTRIBUTES ===
  # Identifier for the agent performing the evaluation (e.g., "agent_1")
  attribute :agent_identifier, :string

  # Status for this specific evaluation pathway
  # Possible values:
  # 'pending_generation', 'generating_evaluation', 'pending_supervision',
  # 'supervising_evaluation', 'needs_revision', 'refining_evaluation',
  # 'approved_for_tts', 'generating_audio', 'generating_video', 'video_generated', 'failed'
  attribute :status, :string, default: 'pending_generation'

  # Store any specific error message for this evaluation path
  attribute :error_message, :text

  # Raw text output from the initial LLM generation
  attribute :raw_text_output, :text

  # Current version of the evaluation text, potentially after revisions
  attribute :current_text_output, :text

  # Status from the supervisor AI
  attribute :supervisor_status, :string # e.g., 'approved', 'rejected_length', 'rejected_tone'

  # Number of revision attempts made
  attribute :revision_attempts, :integer, default: 0

  # API response ID from the LLM for the latest generation/refinement
  attribute :llm_api_response_id, :string

  # Feedback text from the supervisor AI
  attribute :supervisor_feedback, :text

  # API response ID from the supervisor LLM call
  attribute :supervisor_llm_api_response_id, :string

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
