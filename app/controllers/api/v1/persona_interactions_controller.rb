module Api
  module V1
    class PersonaInteractionsController < ApplicationController
      before_action :set_persona_interaction, only: [:show]

      # GET /api/v1/persona_interactions
      def index
        @persona_interactions = PersonaInteraction.order(created_at: :desc)
        render json: @persona_interactions
      rescue StandardError => e
        Rails.logger.error "PersonaInteractionsController#index failed: #{e.message}"
        render json: { error: "Failed to retrieve persona interactions: #{e.message}" }, status: :internal_server_error
      end

      # GET /api/v1/persona_interactions/:id
      def show
        render json: @persona_interaction
      rescue StandardError => e
        Rails.logger.error "PersonaInteractionsController#show failed for ID #{@persona_interaction&.id}: #{e.message}"
        render json: { error: "Failed to retrieve persona interaction: #{e.message}" }, status: :internal_server_error
      end

      # POST /api/v1/persona_interactions
      def create
        @persona_interaction = PersonaInteraction.new(persona_interaction_params)
        @persona_interaction.status = :pending_generation

        if @persona_interaction.save
          # Enqueue the first job in the chain. For now, it will be a simple placeholder.
          GeneratePersonaResponseJob.perform_later(@persona_interaction.id)
          Rails.logger.info "PersonaInteraction ##{@persona_interaction.id} created. GeneratePersonaResponseJob enqueued."
          render json: {
            message: "Persona interaction created and generation process started.",
            persona_interaction_id: @persona_interaction.id,
            status: @persona_interaction.status,
            details_url: api_v1_persona_interaction_url(@persona_interaction)
          }, status: :created
        else
          render json: { errors: @persona_interaction.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error "PersonaInteractionsController#create failed: #{e.message}"
        render json: { error: "Failed to create persona interaction: #{e.message}" }, status: :internal_server_error
      end

      private

      def set_persona_interaction
        @persona_interaction = PersonaInteraction.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "PersonaInteraction not found" }, status: :not_found
      end

      def persona_interaction_params
        params.require(:persona_interaction).permit(
          :trigger_description, 
          :initial_prompt, 
          :personality_key
          # Add other permitted params as the feature evolves, e.g., for initial conversation_history or action_details
        )
      end
    end
  end
end 