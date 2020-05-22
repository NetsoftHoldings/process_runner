# frozen_string_literal: true

require 'concurrent/options'
# require 'concurrent/future'
require 'concurrent/promises'
require_relative 'private/cancellation'

module ProcessRunner
  class Worker # :nodoc:
    attr_reader :worker_index

    def initialize(pool, worker_index, job_class, job_options)
      @pool                 = pool
      @worker_index         = worker_index
      @job_options          = job_options
      @job_class            = job_class
      cancellation, @origin = Private::Cancellation.new
      @job                  = job_class.new(worker_index, job_options)
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

    private

    def runner(cancellation)
      Thread.current.name = "Worker: #{@job_options[:id]} @ #{@worker_index}"
      loop do
        cancellation.check!

        operation, *args = @job.perform

        case operation
        when :abort
          cancellation.origin.resolve
        when :sleep
          sleep args[0]
        end
      end
    rescue Concurrent::CancelledOperationError
      # happy path where we finish because we were cancelled
      :cancelled
    end
  end
end
