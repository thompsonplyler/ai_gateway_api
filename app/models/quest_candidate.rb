class QuestCandidate < ApplicationRecord
    enum status: {
      pending_review: 'pending_review',
      needs_revision: 'needs_revision',
      approved: 'approved',
      rejected: 'rejected'
    }
  end