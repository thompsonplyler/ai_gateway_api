module Api
  module V1
    class LyricSetsController < ApplicationController
      # POST /api/v1/lyric_sets
      def create
        # Use the DEFAULT_BUFFY_TOPIC from GenerateLyricsJob if no topic is provided in params.
        topic_param = params.fetch(:topic, GenerateLyricsJob::DEFAULT_BUFFY_TOPIC)

        lyric_set = LyricSet.new(topic: topic_param, status: :pending_initial_generation)

        if lyric_set.save
          Rails.logger.info "LyricSet ID: #{lyric_set.id} saved successfully. Topic: '#{lyric_set.topic}', Status after save: '#{lyric_set.status}' (Raw status: #{lyric_set.read_attribute_before_type_cast(:status)})"
          GenerateLyricsJob.perform_later(lyric_set.id)
          render json: { 
            message: "Lyric generation started.", 
            lyric_set_id: lyric_set.id,
            status_url: api_v1_lyric_set_url(lyric_set) # Generates URL like /api/v1/lyric_sets/:id
          }, status: :created
        else
          Rails.logger.error "LyricSet failed to save. Errors: #{lyric_set.errors.full_messages.join(', ')}"
          render json: { errors: lyric_set.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error "LyricSetsController#create failed: #{e.message}"
        render json: { error: "Failed to start lyric generation: #{e.message}" }, status: :internal_server_error
      end

      # GET /api/v1/lyric_sets/:id
      def show
        lyric_set = LyricSet.find(params[:id])
        render json: lyric_set, status: :ok # This will use the default Rails serializer
      rescue ActiveRecord::RecordNotFound
        render json: { error: "LyricSet not found" }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "LyricSetsController#show failed: #{e.message}"
        render json: { error: "Failed to retrieve lyric set: #{e.message}" }, status: :internal_server_error
      end

      # GET /api/v1/lyric_sets
      def index
        lyric_sets = LyricSet.order(created_at: :desc) # Or any other ordering
        render json: lyric_sets, status: :ok
      rescue StandardError => e
        Rails.logger.error "LyricSetsController#index failed: #{e.message}"
        render json: { error: "Failed to retrieve lyric sets: #{e.message}" }, status: :internal_server_error
      end

      private

      # No specific private params method needed yet unless :topic becomes strictly required
      # def lyric_set_params
      #   params.require(:lyric_set).permit(:topic)
      # end
    end
  end
end 