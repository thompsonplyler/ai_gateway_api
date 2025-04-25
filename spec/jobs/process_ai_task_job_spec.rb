# spec/jobs/process_ai_task_job_spec.rb
require 'rails_helper'

RSpec.describe ProcessAiTaskJob, type: :job do
  include ActiveJob::TestHelper # Provides perform_enqueued_jobs etc.

  let(:user) { User.create!(email: "jobuser@example.com", password: "password123") }
  let(:ai_task) { user.ai_tasks.create!(prompt: "Summarize this.") }
  let(:prompt) { ai_task.prompt }
  let(:task_id) { ai_task.id }
  let(:openai_api_key) { "test_openai_key" } # Dummy key for tests
  let(:openai_client) { instance_double(OpenAI::Client) }
  let(:openai_success_response) do
    {
      "id"=>"chatcmpl-xxxx",
      "object"=>"chat.completion",
      "created"=>1700000000,
      "model"=>ProcessAiTaskJob::OPENAI_MODEL,
      "choices"=>[{
        "index"=>0,
        "message"=>{
          "role"=>"assistant",
          "content"=>"This is the mocked AI response."
        },
        "finish_reason"=>"stop"
      }],
      "usage"=>{"prompt_tokens"=>10, "completion_tokens"=>20, "total_tokens"=>30}
    }
  end
  let(:openai_error_response) { { "error" => { "message" => "Invalid API key" } } }

  # Clear jobs before each test
  before do
    clear_enqueued_jobs
    # Stub Rails credentials
    allow(Rails.application.credentials).to receive(:openai).and_return({ api_key: openai_api_key })
    # Stub OpenAI client initialization and chat method
    allow(OpenAI::Client).to receive(:new).with(access_token: openai_api_key).and_return(openai_client)
  end

  it "executes perform, calls OpenAI, and updates task status and result" do
    # Expect the chat method to be called
    expect(openai_client).to receive(:chat).with(parameters: {
      model: ProcessAiTaskJob::OPENAI_MODEL,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.7
    }).and_return(openai_success_response)

    # Spy on the logger methods (optional now, as we mock the call)
    allow(Rails.logger).to receive(:info)

    expect(ai_task.status).to eq('queued') # Initial state

    described_class.perform_now(prompt, task_id)

    # Verify logger calls after the job runs
    expect(Rails.logger).to have_received(:info).with(/Processing AI task ##{task_id}/)
    expect(Rails.logger).to have_received(:info).with(/Finished processing AI task ##{task_id}/)

    ai_task.reload # Reload from DB to see changes
    expect(ai_task.status).to eq('completed')
    expect(ai_task.result).to eq("This is the mocked AI response.")
    expect(ai_task.error_message).to be_nil
  end

  it "queues the job in the default queue" do
    expect {
      described_class.perform_later(prompt, task_id)
    }.to have_enqueued_job(described_class).with(prompt, task_id).on_queue('default')
  end
  
  it "handles OpenAI API errors and updates task status to failed" do
    # Make the chat method raise an OpenAI error
    openai_error = OpenAI::Error.new("Simulated OpenAI Error")
    expect(openai_client).to receive(:chat).and_raise(openai_error)
    
    # Spy on the logger method
    allow(Rails.logger).to receive(:error)

    # Expect perform_now to re-raise the error for Sidekiq retry
    expect {
      described_class.perform_now(prompt, task_id)
    }.to raise_error(OpenAI::Error, "Simulated OpenAI Error")
    
    # Verify logger call after the job runs
    expect(Rails.logger).to have_received(:error).with(/OpenAI API Error processing AI task ##{task_id}: Simulated OpenAI Error/)

    ai_task.reload
    expect(ai_task.status).to eq('failed')
    expect(ai_task.result).to be_nil
    expect(ai_task.error_message).to eq("OpenAI Error: Simulated OpenAI Error")
  end
  
  it "handles responses with no content and updates task status to failed" do
     # Mock response with missing content
    no_content_response = openai_success_response.deep_dup
    no_content_response["choices"][0]["message"].delete("content")
    expect(openai_client).to receive(:chat).and_return(no_content_response)

    allow(Rails.logger).to receive(:error)

    expect {
      described_class.perform_now(prompt, task_id)
    }.not_to raise_error # Should not re-raise StandardError here

    expect(Rails.logger).to have_received(:error).with(/No content in OpenAI response/)

    ai_task.reload
    expect(ai_task.status).to eq('failed')
    expect(ai_task.error_message).to include("No content received from OpenAI")
  end

  it "does nothing if task is not found" do
    # Spy on the logger method
    allow(Rails.logger).to receive(:error)
    # Ensure OpenAI client is not called if task is missing
    expect(OpenAI::Client).not_to receive(:new)
    expect(openai_client).not_to receive(:chat)

    expect {
      described_class.perform_now(prompt, task_id + 999)
    }.not_to raise_error
    # Verify logger call after the job runs
    expect(Rails.logger).to have_received(:error).with("ProcessAiTaskJob: AiTask with ID #{task_id + 999} not found.")
  end

  # Add more tests here:
  # - Mock external API calls if you integrate a real service
  # - Test different scenarios and edge cases
end