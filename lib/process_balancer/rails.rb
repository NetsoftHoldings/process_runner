# frozen_string_literal: true

module ProcessBalancer
  # Rails integration
  class Rails < ::Rails::Engine
    config.after_initialize do
      ProcessBalancer.configure do |config|
        if config.server?
          config.options[:reloader] = ProcessBalancer::Rails::Reloader.new
        end
      end
    end

    # cleanup active record connections
    class Reloader
      def initialize(app = ::Rails.application)
        @app = app
      end

      def call
        @app.reloader.wrap do
          yield
        end
        # ensure
        # ActiveRecord::Base.clear_active_connections!
      end
    end
  end
end
