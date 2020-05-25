# frozen_string_literal: true

module ProcessRunner
  class Base # :nodoc:
    attr_reader :worker_index, :status, :options

    def self.lock_driver(driver)
      if driver.is_a?(Symbol)
        file = "process_runner/lock/#{driver}"
        driver = driver.to_s
        unless driver !~ /_/ && driver =~ /[A-Z]+.*/
          driver = driver.split('_').map(&:capitalize).join
        end
        require file
        klass = ProcessRunner::Lock.const_get(driver)
        include klass
      else
        raise ArgumentError, 'Please pass a symbol for the driver to use'
      end
    end

    def initialize(worker_index, options = {})
      @worker_index = worker_index
      @options      = options
    end

    def perform
      before_perform
      worker_lock do |lock|
        @status = nil
        records = lock_records
        lock.extend!
        records&.each do |r|
          process_record(r)
          lock.extend!
        end
        @status
      ensure
        unlock_records
        after_perform
      end
    end

    def status_abort
      @status = :abort
    end

    def status_sleep(duration)
      @status = [:sleep, duration]
    end

    def runtime_lock_timeout
      options[:runtime_lock_timeout] || 30
    end

    def job_id
      options[:id]
    end

    def before_perform; end

    def after_perform; end

    def lock_records
      raise NotImplementedError
    end

    def unlock_records
      raise NotImplementedError
    end

    def process_record(record)
      raise NotImplementedError
    end

    def worker_lock(&_block)
      raise NotImplementedError, 'Specify a locking driver via lock_driver :driver'
    end
  end
end
