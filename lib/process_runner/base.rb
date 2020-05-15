# frozen_string_literal: true

module ProcessRunner
  class Base # :nodoc:
    attr_reader :worker_index
    attr_reader :status
    attr_reader :options

    def initialize(worker_index, options = {})
      @worker_index = worker_index
      @options      = options
    end

    def perform
      worker_lock do
        @status = nil
        records = lock_records
        records&.each do |r|
          process_record(r)
        end
        @status
      ensure
        unlock_records
      end
    end

    def status_abort
      @status = :abort
    end

    def status_sleep(duration)
      @status = [:sleep, duration]
    end

    def worker_lock(&block)
      block.call
    end

    def runtime_lock_timeout
      options[:runtime_lock_timeout] || 30
    end

    def job_id
      options[:id]
    end

    private

    def lock_records
      raise NotImplementedError
    end

    def unlock_records
      raise NotImplementedError
    end

    def process_record(record)
      raise NotImplementedError
    end
  end
end
