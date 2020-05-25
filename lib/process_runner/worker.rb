# frozen_string_literal: true

require 'concurrent/options'
# require 'concurrent/future'
require 'concurrent/promises'
require_relative 'private/cancellation'

module ProcessRunner
  class Worker # :nodoc:
    attr_reader :worker_index

    def initialize(pool, worker_index, job_options)
      @pool                 = pool
      @worker_index         = worker_index
      @job_options          = job_options
      cancellation, @origin = Private::Cancellation.new
      @reloader             = ProcessRunner.options[:reloader]
      @future               = Concurrent::Promises.future_on(@pool, cancellation, &method(:runner))
    end

    def running?
      !@origin.resolved? && !@future.resolved?
    end

    def stopped?
      @future.resolved?
    end

    def stop
      @origin.resolve
      true
    end

    def reason
      @future.rejected? ? @future.reason : ''
    end

    private

    def constantize(str)
      return Object.const_get(str) unless str.include?('::')

      names = str.split('::')
      names.shift if names.empty? || names.first.empty?

      names.inject(Object) do |constant, name|
        constant.const_get(name, false)
      end
    end

    def runner(cancellation)
      Thread.current.name = "Worker: #{@job_options[:id]} @ #{@worker_index}"
      @reloader.call do
        klass = constantize(@job_options[:class])
        job   = klass.new(worker_index, @job_options)

        loop do
          cancellation.check!

          operation, *args = job.perform

          case operation
          when :abort
            ProcessRunner.logger.debug("Abort worker #{@job_options[:id]} @ #{@worker_index}")
            cancellation.origin.resolve
          when :sleep
            sleep args[0]
          end
        end
      end
    rescue Concurrent::CancelledOperationError
      # happy path where we finish because we were cancelled
      :cancelled
    end
  end
end
