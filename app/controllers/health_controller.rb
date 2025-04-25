class HealthController < ApplicationController  
    def show   
        render json: { status: 'ok' }, status: :ok\n  
    end
end
