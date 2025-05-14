module Api
  module V1
    class QuestCandidatesController < ApplicationController # Or Api::V1::BaseController if you have one

      # Implement authentication if your API requires it
      # before_action :authenticate_user!, except: [:index, :show] # Example

      # GET /api/v1/quest_candidates
      def index
        @quest_candidates = QuestCandidate.order(created_at: :desc).page(params[:page]).per(params[:per_page] || 20)
        render json: @quest_candidates
      end

      # GET /api/v1/quest_candidates/:id
      def show
        @quest_candidate = QuestCandidate.find(params[:id])
        render json: @quest_candidate
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Quest candidate not found" }, status: :not_found
      end

      # POST /api/v1/quest_candidates/generate
      def generate
        GenerateQuestCandidateJob.perform_later
        render json: { message: "Quest generation job enqueued successfully." }, status: :accepted
      rescue StandardError => e
        Rails.logger.error "Failed to enqueue GenerateQuestCandidateJob: #{e.message}"
        render json: { error: "Failed to enqueue quest generation job." }, status: :internal_server_error
      end
    end
  end
end 