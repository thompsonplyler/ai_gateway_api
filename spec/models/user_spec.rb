require 'rails_helper'

RSpec.describe User, type: :model do
  # Using FactoryBot or fixtures is recommended for more complex scenarios
  # For now, let's build a valid user manually
  let(:valid_attributes) { { email: "test@example.com", password: "password123", password_confirmation: "password123" } }

  subject { described_class.new(valid_attributes) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(subject).to be_valid
    end

    it 'is invalid without an email' do
      subject.email = nil
      expect(subject).not_to be_valid
      expect(subject.errors[:email]).to include("can't be blank")
    end

    it 'is invalid with a duplicate email (case-insensitive)' do
      described_class.create!(valid_attributes)
      duplicate_user = described_class.new(email: "TEST@example.com", password: "password456")
      expect(duplicate_user).not_to be_valid
      expect(duplicate_user.errors[:email]).to include("has already been taken")
    end

    it 'is invalid with an invalid email format' do
      subject.email = "invalid-email"
      expect(subject).not_to be_valid
      expect(subject.errors[:email]).to include("must be a valid email address")
    end

    it 'is invalid without a password on create' do
      user = described_class.new(email: "new@example.com")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to include("can't be blank")
    end

    it 'is invalid with a password shorter than 8 characters on create' do
      user = described_class.new(email: "short@example.com", password: "1234567", password_confirmation: "1234567")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to include("is too short (minimum is 8 characters)")
    end

    it 'is valid without a password on update (if not changing it)' do
      subject.save!
      subject.email = "updated@example.com" # Change something else
      expect(subject).to be_valid
    end
  end

  describe 'associations' do
    it { should have_many(:api_tokens).dependent(:destroy) }
    it { should have_many(:ai_tasks).dependent(:destroy) }
  end

  describe '#has_secure_password' do
    it 'stores password digest' do
      expect(subject.password_digest).not_to be_blank
      expect(subject.password_digest).not_to eq("password123")
    end

    it 'provides an authenticate method' do
      subject.save!
      expect(subject.authenticate("password123")).to eq(subject)
      expect(subject.authenticate("wrongpassword")).to be_falsey
    end
  end
end
