require 'rails_helper'

RSpec.describe AiTask, type: :model do
  let(:user) { User.create!(email: "user_for_task@example.com", password: "password123") }
  let(:valid_attributes) { { user: user, prompt: "Write a poem about Ruby." } }
  subject { described_class.new(valid_attributes) }

  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(subject).to be_valid
    end

    it 'is invalid without a user' do
      subject.user = nil
      expect(subject).not_to be_valid
      # Shoulda-matchers checks the belongs_to association, which implies user presence
    end

    it 'is invalid without a prompt' do
      subject.prompt = nil
      expect(subject).not_to be_valid
      expect(subject.errors[:prompt]).to include("can't be blank")
    end

    it 'is invalid without a status' do
      # Need to bypass the default setting for this test
      task = described_class.new(user: user, prompt: "test", status: nil)
      # task.valid? # Trigger validations - removed as save! below triggers them
      expect { task.save! }.to raise_error(ActiveRecord::RecordInvalid) do |error|
        expect(error.record.errors[:status]).to include("can't be blank")
        expect(error.record.errors[:status]).to include("is not included in the list") # Also triggers inclusion validation
      end
    end
  end

  describe 'enums' do
    it { should define_enum_for(:status).with_values(queued: 'queued', processing: 'processing', completed: 'completed', failed: 'failed').backed_by_column_of_type(:string).with_prefix }
  end

  describe 'defaults' do
    it 'defaults status to queued on initialization' do
      task = described_class.new(user: user, prompt: "test")
      # Status is initialized with DB default *before* save
      expect(task.status).to eq('queued') 
      expect(task.status_queued?).to be true
      # Verify it persists correctly on save
      task.save!
      task.reload
      expect(task.status).to eq('queued')
    end
  end
end
