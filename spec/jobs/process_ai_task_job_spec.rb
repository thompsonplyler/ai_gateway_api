# spec/jobs/process_ai_task_job_spec.rb
require 'rails_helper'

RSpec.describe ProcessAiTaskJob, type: :job do
  include ActiveJob::TestHelper # Provides perform_enqueued_jobs etc.

  let(:user) { User.create!(email: "jobuser@example.com", password: "password123") }
  let(:ai_task) { user.ai_tasks.create!(prompt: "Summarize this.") }
  let(:prompt) { ai_task.prompt }
  let(:task_id) { ai_task.id }

  # Clear jobs before each test
  before { clear_enqueued_jobs }

  it "executes perform and updates task status and result" do
    # Spy on the logger methods
    allow(Rails.logger).to receive(:info)

    expect(ai_task.status).to eq('queued') # Initial state

    described_class.perform_now(prompt, task_id)

    # Verify logger calls after the job runs
    expect(Rails.logger).to have_received(:info).with("Processing AI task ##{task_id} for prompt: '#{prompt}'")
    expect(Rails.logger).to have_received(:info).with("Finished processing AI task ##{task_id}")

    ai_task.reload # Reload from DB to see changes
    expect(ai_task.status).to eq('completed')
    expect(ai_task.result).to include("simulated AI response")
    expect(ai_task.error_message).to be_nil
  end

  it "queues the job in the default queue" do
    expect {
      described_class.perform_later(prompt, task_id)
    }.to have_enqueued_job(described_class).with(prompt, task_id).on_queue('default')
  end
  
  it "handles errors and updates task status to failed" do
    # Stub the sleep method to raise an error
    allow_any_instance_of(described_class).to receive(:sleep).and_raise(StandardError.new("Simulated job error"))
    # Spy on the logger method
    allow(Rails.logger).to receive(:error)

    # Expect perform_now to re-raise the error for Sidekiq retry
    expect {
      described_class.perform_now(prompt, task_id)
    }.to raise_error(StandardError, "Simulated job error")
    
    # Verify logger call after the job runs
    expect(Rails.logger).to have_received(:error).with("Error processing AI task ##{task_id} for prompt '#{prompt}': Simulated job error")

    ai_task.reload
    expect(ai_task.status).to eq('failed')
    expect(ai_task.result).to be_nil
    expect(ai_task.error_message).to eq("Simulated job error")
  end
  
  it "does nothing if task is not found" do
    # Spy on the logger method
    allow(Rails.logger).to receive(:error)
    expect {
      described_class.perform_now(prompt, task_id + 999)
    }.not_to raise_error
    # Verify logger call after the job runs
    expect(Rails.logger).to have_received(:error).with("ProcessAiTaskJob: AiTask with ID #{task_id + 999} not found.") # Match exact error message
  end

  # Add more tests here:
  # - Mock external API calls if you integrate a real service
  # - Test different scenarios and edge cases
end