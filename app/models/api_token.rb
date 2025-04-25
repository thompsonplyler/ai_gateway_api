class ApiToken < ApplicationRecord
  belongs_to :user

  # Ensure token is present and unique before saving
  before_validation :generate_token, on: :create
  before_validation :set_expiration, on: :create

  validates :token, presence: true, uniqueness: true
  validates :expires_at, presence: true

  # Scope to find non-expired tokens
  scope :active, -> { where("expires_at > ?", Time.current) }

  # Method to check if token is expired
  def expired?
    expires_at < Time.current
  end

  private

  def generate_token
    # loop ensures uniqueness, although collisions are highly unlikely with SecureRandom.hex
    loop do
      self.token = SecureRandom.hex(32) # Generates a 64-character hex string
      break unless self.class.exists?(token: token)
    end
  end

  def set_expiration
    # Set expiration to 1 year from now if not already set
    self.expires_at ||= 1.year.from_now
  end
end
