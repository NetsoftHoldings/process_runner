# frozen_string_literal: true

require_relative 'worker'

module ProcessRunner
  class Watcher # :nodoc:
    attr_reader :job_config

    def initialize(job_config)
      @job_config = job_config
      @running    = {}
      @stopping   = []
      @lock       = Mutex.new
    end

    # called when the worker index has changed
    def update_worker_config(process_index, process_count, job_count)
      keep_set = process_count.zero? ? [] : (0...job_count).select { |i| (i % process_count) == process_index }

      with_lock do
        running_set = @running.keys
        create_set  = keep_set - running_set
        stop_set    = running_set - keep_set

        create_set.each do |worker_id|
          start_worker(worker_id)
        end

        stop_set.each do |worker_id|
          stop_worker(worker_id)
        end
      end
    end

    private

    def with_lock(&block)
      @lock.synchronize(&block)
    end

    def start_worker(worker_id)
      raise 'Not called within synchronize block' unless @lock.owned?

      @running[worker_id] = Worker.new(worker_id, job_class, job_config)
    end

    def stop_worker(worker_id)
      raise 'Not called within synchronize block' unless @lock.owned?

      worker = @running.delete(worker_id)
      if worker
        @stopping << worker
        worker.stop
      end
    end

    def check_workers
      with_lock do
        @running.each do |k, v|
          if v.running?
            # TODO: build up status info
          else
            stop_worker(k)
          end
        end

        @stopping.delete_if(&:stopped?)
      end
    end

    def job_class
      @job_class ||= constantize(job_config[:class])
    end

    def constantize(str)
      return Object.const_get(str) unless str.include?('::')

      names = str.split('::')
      names.shift if names.empty? || names.first.empty?

      names.inject(Object) do |constant, name|
        constant.const_get(name, false)
      end
    end
  end
end
