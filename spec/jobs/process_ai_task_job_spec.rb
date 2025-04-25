# spec/jobs/process_ai_task_job_spec.rb
require 'rails_helper'

RSpec.describe ProcessAiTaskJob, type: :job do
  include ActiveJob::TestHelper # Provides perform_enqueued_jobs etc.

  let(:prompt) { "Summarize a long text" }

  it "executes perform" do
    # Using Sidekiq::Testing.inline! (default for :job type)
    # We spy on puts to check output, in real app mock external calls
    expect(STDOUT).to receive(:puts).with(/Processing AI task for prompt: '#{prompt}'/).ordered
    expect(STDOUT).to receive(:puts).with(/Finished processing AI task for prompt: '#{prompt}'/).ordered

    described_class.perform_now(prompt)
  end

  it "queues the job in the default queue" do
    expect {
      described_class.perform_later(prompt)
    }.to have_enqueued_job(described_class).with(prompt).on_queue('default')
  end

  # Add more tests here to:
  # - Mock external API calls (using WebMock or RSpec mocks)
  # - Verify arguments passed to external services
  # - Test error handling and retries
  # - Test interactions with database models if you add them
end