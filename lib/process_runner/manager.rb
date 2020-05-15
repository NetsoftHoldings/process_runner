# frozen_string_literal: true

require 'English'
require 'json'

require_relative 'util'
require_relative 'watcher'

require 'concurrent/atomic/atomic_fixnum'
require 'concurrent/executor/thread_pool_executor'

module ProcessRunner
  class Manager # :nodoc:
    include Util

    PROCESSES_KEY = 'processes'

    def initialize(options)
      @options       = options
      @done          = false
      @process_index = Concurrent::AtomicFixnum.new(-1)
      @process_count = Concurrent::AtomicFixnum.new(0)
      @pool          = Concurrent::ThreadPoolExecutor.new(max_threads: options[:max_threads])

      setup_job_watchers
    end

    def process_count
      @process_count.value
    end

    def process_index
      v = @process_index.value
      v == -1 ? nil : v
    end

    def workers_for_job(job_id)
      value = ProcessRunner.worker_count(job_id)

      value.nil? ? 1 : value
    end

    def run
      @thread = start_thread('heartbeat', &method(:run_heartbeat))
    end

    def quiet
      @done = true
    end

    def stop
      @done = true
      clear_heartbeat
    end

    def stopping?
      @done
    end

    private

    def process_count=(value)
      @process_count.value = value
    end

    def process_index=(value)
      v = value.nil? ? -1 : value

      @process_index.value = v
    end

    def run_heartbeat
      loop do
        heartbeat
        sleep 5
      end
      logger.info('Heartbeat stopping...')
    end

    def clear_heartbeat
      redis do |c|
        c.lrem(PROCESSES_KEY, 0, identity)
      end
    rescue StandardError
      # ignore errors
    end

    def heartbeat
      update_process_index

      _exists, msg = update_state

      if msg
        ::Process.kill(msg, $PID)
      else
        update_jobs
      end
    rescue StandardError => e
      logger.error("heartbeat: #{e.message} @ #{e.backtrace_locations.first}")
    end

    def update_state
      exists, _, _, msg = redis do |c|
        c.multi do
          c.exists(identity)
          c.hmset(identity, 'info', info_json, 'beat', Time.now.to_f, 'quiet', @done, 'worker', process_index)
          c.expire(identity, 60)
          c.rpop("#{identity}-signals")
        end
      end

      [exists, msg]
    end

    def update_process_index
      redis do |c|
        c.watch(PROCESSES_KEY)

        workers     = c.lrange(PROCESSES_KEY, 0, -1)
        num_workers = workers.size
        index       = workers.find_index(identity)

        if index.nil?
          new_length = c.multi do
            c.rpush(PROCESSES_KEY, identity)
          end
          unless new_length.nil?
            num_workers = new_length.first
            index       = new_length.first - 1
          end
        else
          c.unwatch
        end
        self.process_index = index
        self.process_count = num_workers
      end
    end

    def update_jobs
      @job_watchers.each do |job_id, watcher|
        watcher.update_worker_config(process_index, process_count, workers_for_job(job_id))
      end
    end

    def setup_job_watchers
      @job_watchers = {}
      @options.fetch(:job_sets, []).each do |job_config|
        @job_watchers[job_config[:id].to_sym] = Watcher.new(job_config)
      end
    end

    def to_data
      {
          hostname: hostname,
          pid:      ::Process.pid,
          identity: identity,
      }
    end

    def info_json
      @info_json ||= JSON.dump(to_data)
    end
  end
end
