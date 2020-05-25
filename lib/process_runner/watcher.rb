# frozen_string_literal: true

require_relative 'worker'
require_relative 'util'

module ProcessRunner
  class Watcher # :nodoc:
    include Util

    attr_reader :job_config, :stats

    def initialize(pool, job_config)
      @pool       = pool
      @job_config = job_config
      @running    = {}
      @stopping   = []
      @stats      = {}
      @lock       = Mutex.new
    end

    # called when the worker index has changed
    def update_worker_config(process_index, process_count, job_count)
      keep_set = process_count.zero? ? [] : (0...job_count).select { |i| (i % process_count) == process_index }

      with_lock do
        check_workers

        running_set = @running.keys
        create_set  = keep_set - running_set
        stop_set    = running_set - keep_set

        create_set.each do |worker_id|
          start_worker(worker_id)
        end

        stop_set.each do |worker_id|
          stop_worker(worker_id)
        end

        update_stats
      end
    end

    private

    def with_lock(&block)
      @lock.synchronize(&block)
    end

    def start_worker(worker_id)
      raise 'Not called within synchronize block' unless @lock.owned?

      logger.info "Starting worker #{job_id} @ #{worker_id}"
      @running[worker_id] = Worker.new(@pool, worker_id, job_class, job_config)
    end

    def stop_worker(worker_id, reason: '')
      raise 'Not called within synchronize block' unless @lock.owned?

      logger.info "Stopping worker #{job_id} @ #{worker_id} :: #{reason}"

      worker = @running.delete(worker_id)
      if worker
        @stopping << worker
        worker.stop
      end
    end

    def check_workers
      raise 'Not called within synchronize block' unless @lock.owned?

      @running.each do |k, v|
        if v.running?
          # TODO: build up status info
        else
          stop_worker(k, reason: v.reason)
        end
      end

      @stopping.delete_if do |e|
        if e.stopped?
          logger.debug("Reaping worker #{job_id} @ #{e.worker_index} :: #{e.reason}")
          true
        end
      end
    end

    def update_stats
      stats = {
          running:  [],
          stopping: [],
      }

      @running.each_value do |v|
        stats[:running] << {
            id: v.worker_index,
        }
      end

      @stopping.each do |v|
        stats[:stopping] << {
            id: v.worker_index,
        }
      end

      @stats = stats
    end

    def job_id
      job_config[:id]
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
