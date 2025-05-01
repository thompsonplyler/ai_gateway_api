require 'streamio-ffmpeg' # Use streamio-ffmpeg gem for video processing
require 'tempfile'

class VideoConcatenationJob < ApplicationJob
  queue_as :default

  # Concatenation might take time and be resource-intensive
  sidekiq_options retry: 1, dead: true, lock: :until_executed, lock_ttl: 30.minutes

  discard_on ActiveJob::DeserializationError

  def perform(evaluation_job_id)
    evaluation_job = EvaluationJob.find_by(id: evaluation_job_id)
    unless evaluation_job
      Rails.logger.warn "VideoConcatenationJob: EvaluationJob ##{evaluation_job_id} not found. Skipping."
      return
    end

    # Ensure the job is in the correct state
    unless evaluation_job.status == 'concatenating'
      Rails.logger.info "VideoConcatenationJob: EvaluationJob ##{evaluation_job_id} has status #{evaluation_job.status}. Skipping."
      return
    end

    # Ensure all child evaluations have generated videos
    evaluations = evaluation_job.evaluations.order(:agent_identifier) # Ensure consistent order
    unless evaluations.all? { |e| e.status == 'video_generated' && e.video_file.attached? }
      message = "Not all evaluation videos are ready for concatenation."
      Rails.logger.error "VideoConcatenationJob: #{message} for EvaluationJob ##{evaluation_job_id}"
      evaluation_job.update(status: 'failed', error_message: message)
      return
    end

    video_files = evaluations.map { |e| e.video_file }

    # Create temporary files for ffmpeg input/output
    Tempfile.create(['ffmpeg_list', '.txt']) do |list_file|
      # Create a file list for ffmpeg concat demuxer
      video_files.each do |video|
        # Download each video blob to a temporary local path
        temp_video_path = video.blob.service.download(video.blob.key)
        list_file.puts("file '#{temp_video_path}'")
      end
      list_file.flush # Ensure content is written to disk

      Tempfile.create(['concatenated_video', '.mp4']) do |output_file|
        begin
          Rails.logger.info "Starting video concatenation for EvaluationJob ##{evaluation_job_id}"
          # Use ffmpeg to concatenate videos
          # Note: This requires ffmpeg to be installed on the server where Sidekiq runs
          # The `-safe 0` option is needed if temporary file paths might contain special characters
          # The `-c copy` attempts to copy codecs without re-encoding, which is faster but less reliable if formats differ.
          # Consider removing `-c copy` if concatenation fails, forcing re-encoding.
          ffmpeg_command = FFMPEG::Command.new(
            nil,
            [
              ['-f', 'concat'],
              ['-safe', '0'],
              ['-i', list_file.path],
              ['-c', 'copy'], # Try direct stream copy first
              output_file.path
            ]
          )

          # Execute ffmpeg command
          # stdout, stderr, status = ffmpeg_command.run # Use this if you need output/status
          ffmpeg_command.run # Simpler execution

          # Check if output file was created and is not empty
          unless File.exist?(output_file.path) && File.size?(output_file.path)
            raise "FFmpeg failed to create output file or file is empty."
          end

          # Attach the final concatenated video to the EvaluationJob
          evaluation_job.concatenated_video.attach(
            io: File.open(output_file.path),
            filename: "evaluation_job_#{evaluation_job_id}_final.mp4",
            content_type: 'video/mp4'
          )

          evaluation_job.update!(status: 'completed')
          Rails.logger.info "Video concatenation successful for EvaluationJob ##{evaluation_job_id}"

        rescue FFMPEG::Error => e
          error_msg = "FFmpeg concatenation failed: #{e.message}"
          Rails.logger.error "VideoConcatenationJob: #{error_msg} for EvaluationJob ##{evaluation_job_id}"
          # Attempt re-encoding if simple copy failed?
          # You might add more sophisticated error handling/retry logic here
          evaluation_job.update(status: 'failed', error_message: error_msg)
        rescue StandardError => e
          error_msg = "Unexpected error during concatenation: #{e.message}"
          Rails.logger.error "VideoConcatenationJob: #{error_msg} for EvaluationJob ##{evaluation_job_id}\n#{e.backtrace.join("\n")}"
          evaluation_job.update(status: 'failed', error_message: error_msg)
        ensure
          # Clean up downloaded temporary video files explicitly if needed
          # (ActiveStorage might handle this depending on service/configuration)
          # File.delete(temp_video_path) for each video
          # Tempfile handles its own cleanup automatically
        end
      end
    end
  end
end 