# frozen_string_literal: true

module ProcessRunner
  class Rails < ::Rails::Engine
    config.after_initialize do
      ProcessRunner.configure do |config|
        config.options[:reloader] = ProcessRunner::Rails::Reloader.new
      end
    end

    class Reloader
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