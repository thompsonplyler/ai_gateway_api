class LyricSet < ApplicationRecord
  enum status: { pending_initial_generation: 0, pending_supervision: 1, needs_revision: 2, approved: 3 }

  # any other model logic, validations, associations will go here
end
