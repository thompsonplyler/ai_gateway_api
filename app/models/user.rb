class User < ApplicationRecord
  # For password hashing
  has_secure_password

  # Associations
  # dependent: :destroy ensures tokens/tasks are deleted when the user is deleted
  has_many :api_tokens, dependent: :destroy
  has_many :ai_tasks, dependent: :destroy

  # Validations
  validates :email, presence: true, 
                    uniqueness: { case_sensitive: false }, 
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "must be a valid email address" }
  
  # Add minimum length, only on create to allow updates without providing password
  validates :password, presence: true, length: { minimum: 8 }, if: -> { new_record? || !password.nil? }
end
