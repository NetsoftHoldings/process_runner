# frozen_string_literal: true

module ProcessRunner
  # Rails integration
  class Rails < ::Rails::Engine
    initializer 'process_runner.active_record' do
      ActiveSupport.on_load :active_record do
        ProcessRunner.configure do |config|
          config.options[:reloader] = ProcessRunner::Rails::ActiveRecordCleanup.new
        end
      end
    end

    # cleanup active record connections
    class ActiveRecordCleanup
      def initialize(app = ::Rails.application)
        @app = app
      end

      def call
        yield
      ensure
        ActiveRecord::Base.clear_active_connections!
      end
    end
  end
end