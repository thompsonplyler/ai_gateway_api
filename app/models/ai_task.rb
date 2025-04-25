class AiTask < ApplicationRecord
  belongs_to :user

  # Define possible statuses
  # Using an enum makes status handling cleaner and more robust
  enum status: {
    queued: 'queued',
    processing: 'processing',
    completed: 'completed',
    failed: 'failed'
  }, _prefix: true # Allows calling task.status_queued?, task.status_processing!, etc.

  # Validations
  validates :prompt, presence: true
  validates :status, presence: true, inclusion: { in: statuses.keys.map(&:to_s) }

  # Removed default status callback - enum/validation handles it
  # before_validation :set_default_status, on: :create

  # private

  # def set_default_status
  #   self.status ||= :queued
  # end
end
