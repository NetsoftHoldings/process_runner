# frozen_string_literal: true

require 'English'

module ProcessRunner
  module Util # :nodoc:
    def logger
      ProcessRunner.logger
    end

    def hostname
      ProcessRunner.hostname
    end

    def identity
      ProcessRunner.identity
    end

    def redis(&block)
      ProcessRunner.redis(&block)
    end

    def start_thread(name, &block)
      Thread.new do
        Thread.current.name = name
        watchdog(&block)
      end
    end

    def watchdog
      yield
    rescue Exception => e # rubocop: disable Lint/RescueException
      logger.error("#{Thread.current.name} :: #{e.message}")
      raise e
    end
  end
end
