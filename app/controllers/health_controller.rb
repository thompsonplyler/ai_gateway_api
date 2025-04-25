class HealthController < ApplicationController\n  def show\n    render json: { status: 'ok' }, status: :ok\n  end\nend
