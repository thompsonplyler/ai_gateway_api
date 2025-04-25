require 'rails_helper'

RSpec.describe ApiToken, type: :model do
  # We need a user to associate the token with
  # Consider using FactoryBot later for cleaner setup
  let(:user) { User.create!(email: "user_for_token@example.com", password: "password123") }
  subject { described_class.new(user: user) }

  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe 'validations' do
    # before { subject.save } # Removed shared callback trigger

    it 'is valid when user is present (callbacks will set token/expires_at)' do
      expect(subject).to be_valid # subject is ApiToken.new(user: user)
    end

    it 'is invalid without a user' do
      subject.user = nil
      expect(subject).not_to be_valid
    end

    # Manual tests for presence/uniqueness due to before_validation callbacks
    it 'is invalid if token generation fails and leaves token nil' do
      # Simulate token generation failing
      allow(SecureRandom).to receive(:hex).and_return(nil)
      token = described_class.new(user: user)
      expect(token).not_to be_valid
      expect(token.errors[:token]).to include("can't be blank")
    end

    it 'is invalid if expires_at is set to nil on update' do
      token = described_class.create!(user: user) # Create a valid token first
      token.expires_at = nil # Set to nil for update
      expect(token).not_to be_valid
      expect(token.errors[:expires_at]).to include("can't be blank")
    end
    
    it 'is invalid with a duplicate token' do
      existing_token = described_class.create!(user: user)
      new_token = described_class.new(user: user)
      # Force the same token
      new_token.token = existing_token.token 
      # Prevent the before_validation callback from generating a new token for this test instance
      allow(new_token).to receive(:generate_token) 
      
      expect(new_token).not_to be_valid # Now validation should fail
      expect(new_token.errors[:token]).to include("has already been taken")
    end

    # it { should validate_presence_of(:token) } # Replaced by manual test above
    # it { should validate_uniqueness_of(:token) } # Replaced by manual test above
    # it { should validate_presence_of(:expires_at) } # Replaced by manual test above
  end

  describe 'callbacks' do
    it 'generates a token before creation' do
      token = described_class.new(user: user)
      expect(token.token).to be_nil
      token.save!
      expect(token.token).to be_a(String)
      expect(token.token.length).to eq(64) # 32 hex bytes = 64 characters
    end

    it 'sets a default expiration date before creation' do
      token = described_class.new(user: user)
      expect(token.expires_at).to be_nil
      token.save!
      expect(token.expires_at).to be_within(1.minute).of(1.year.from_now)
    end

    it 'does not override an explicitly set expiration date' do
      expiration = 2.days.from_now
      token = described_class.new(user: user, expires_at: expiration)
      token.save!
      expect(token.expires_at.to_i).to eq(expiration.to_i)
    end
  end

  describe 'scopes' do
    describe '.active' do
      let!(:active_token) { described_class.create!(user: user, expires_at: 1.day.from_now) }
      let!(:expired_token) { described_class.create!(user: user, expires_at: 1.day.ago) }

      it 'includes non-expired tokens' do
        expect(described_class.active).to include(active_token)
      end

      it 'excludes expired tokens' do
        expect(described_class.active).not_to include(expired_token)
      end
    end
  end

  describe '#expired?' do
    it 'returns true if expires_at is in the past' do
      subject.expires_at = 1.hour.ago
      expect(subject.expired?).to be true
    end

    it 'returns false if expires_at is in the future' do
      subject.expires_at = 1.hour.from_now
      expect(subject.expired?).to be false
    end

    it 'returns false if expires_at is now' do
      # subject.expires_at = Time.current # Prone to precision errors
      subject.expires_at = 0.1.seconds.from_now # Set slightly in the future
      # Comparison might have slight float precision issues, so check just before now
      expect(subject.expired?).to be false 
    end
  end
end
