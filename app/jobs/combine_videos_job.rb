require 'tmpdir'
require 'open3'

class CombineVideosJob < ApplicationJob
  queue_as :default # Or a specific queue for video processing if needed

  sidekiq_options retry: 3, dead: true # Standard retry options

  def perform(evaluation_job_id)
    Rails.logger.info "CombineVideosJob STARTING - EvaluationJob ID: #{evaluation_job_id}"
    evaluation_job = EvaluationJob.includes(evaluations: { video_file_attachment: :blob }).find_by(id: evaluation_job_id)

    unless evaluation_job
      Rails.logger.warn "CombineVideosJob: EvaluationJob ##{evaluation_job_id} not found. Skipping."
      return
    end

    # Potentially set a status like 'combining_videos' on evaluation_job here
    # evaluation_job.update(status: 'combining_videos')

    downloaded_video_info = []

    Dir.mktmpdir("ffmpeg-concat-job-#{evaluation_job.id}-") do |temp_dir|
      evaluation_job.evaluations.order(:agent_identifier).each do |evaluation|
        # Robust check: Ensure video is actually complete and ready
        # This status might need to be 'video_generated' or similar from your model
        if evaluation.status == 'video_generated' && evaluation.video_file.attached?
          blob = evaluation.video_file.blob
          safe_filename = blob.filename.to_s.gsub(/[^0-9A-Za-z.\-_]/, '')
          temp_path = File.join(temp_dir, safe_filename)
          
          begin
            File.open(temp_path, 'wb') { |file| blob.download { |chunk| file.write(chunk) } }
            downloaded_video_info << { original_filename: blob.filename.to_s, temp_path: temp_path }
            Rails.logger.info "CombineVideosJob: Downloaded #{blob.filename} to #{temp_path} for job ##{evaluation_job.id}"
          rescue StandardError => e
            Rails.logger.error "CombineVideosJob: Failed to download video #{blob.filename} for job ##{evaluation_job.id}: #{e.message}"
            # If a download fails, we probably can't combine.
            # evaluation_job.update(status: 'failed', error_message: "Failed to download video for combination: #{blob.filename}")
            # return # Or raise an error to allow for retry
            raise "Failed to download video #{blob.filename} for combination. Error: #{e.message}"
          end
        else
          Rails.logger.warn "CombineVideosJob: Skipping evaluation ##{evaluation.id} for job ##{evaluation_job.id} - status '#{evaluation.status}' or no video file."
        end
      end

      unless downloaded_video_info.count == EvaluationJob::AGENT_IDENTIFIERS.count
        error_msg = "CombineVideosJob: Not all videos were ready/downloaded for job ##{evaluation_job.id}. Expected #{EvaluationJob::AGENT_IDENTIFIERS.count}, got #{downloaded_video_info.count}."
        Rails.logger.error error_msg
        # evaluation_job.update(status: 'failed', error_message: error_msg)
        # return # Or raise an error
        raise error_msg # Fail the job if not all videos are present
      end

      concat_list_path = File.join(temp_dir, "concat_list.txt")
      File.open(concat_list_path, 'w') do |list_file|
        downloaded_video_info.each do |video_info|
          list_file.puts "file '#{video_info[:temp_path]}'"
        end
      end
      Rails.logger.info "CombineVideosJob: Created concat list file at #{concat_list_path} for job ##{evaluation_job.id}"

      output_filename = "combined_job_#{evaluation_job.id}_#{Time.now.to_i}.mp4" # Add timestamp to ensure uniqueness
      output_path = File.join(temp_dir, output_filename)

      ffmpeg_command = "ffmpeg -y -f concat -safe 0 -i \"#{concat_list_path}\" -c copy \"#{output_path}\""
      Rails.logger.info "CombineVideosJob: Executing ffmpeg for job ##{evaluation_job.id}: #{ffmpeg_command}"

      _stdout_str, stderr_str, status = Open3.capture3(ffmpeg_command)

      if status.success?
        Rails.logger.info "CombineVideosJob: ffmpeg combination successful for job ##{evaluation_job.id}. Output at #{output_path}"
        
        evaluation_job.combined_video_file.attach(
          io: File.open(output_path),
          filename: output_filename,
          content_type: 'video/mp4'
        )

        if evaluation_job.save
          Rails.logger.info "CombineVideosJob: Attached combined video and COMPLETED job ##{evaluation_job.id}"
          # Final success status - ensure this aligns with EvaluationJob#check_completion logic or sets a new distinct final status
          evaluation_job.update(status: 'completed', error_message: nil) # Or a new status like 'combined_video_ready'
        else
          error_msg = "CombineVideosJob: ffmpeg successful BUT failed to attach/save combined video for job ##{evaluation_job.id}: #{evaluation_job.errors.full_messages.join(', ')}"
          Rails.logger.error error_msg
          # evaluation_job.update(status: 'failed', error_message: error_msg)
          raise error_msg # Raise to retry or mark as dead
        end
      else
        error_msg = "CombineVideosJob: ffmpeg combination FAILED for job ##{evaluation_job.id}. STDERR: #{stderr_str}"
        Rails.logger.error error_msg
        # evaluation_job.update(status: 'failed', error_message: "ffmpeg error: #{stderr_str.truncate(255)}")
        raise error_msg # Raise to retry or mark as dead
      end
    end # Temp directory and its contents are automatically removed
  rescue StandardError => e
    Rails.logger.error "CombineVideosJob: Unhandled error for EvaluationJob ID #{evaluation_job_id}: #{e.message}\n#{e.backtrace.join("\n")}"
    evaluation_job = EvaluationJob.find_by(id: evaluation_job_id) # Re-fetch if needed
    evaluation_job&.update(status: 'failed', error_message: "CombineVideosJob failed: #{e.message.truncate(255)}")
    raise # Re-raise for Sidekiq to handle
  end
end 