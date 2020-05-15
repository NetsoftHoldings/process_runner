# frozen_string_literal: true

module ProcessRunner
  module Lock
    # this is a simple implementation of a lock t ensure only one job runner is running for a worker
    # This is only save for a single redis instance setup
    # something more resilient should be used instead,
    # e.g. and advisory lock in a DB or using RedLock ( https://github.com/leandromoreira/redlock-rb )
    module SimpleRedis
      def self.time_source
        @time_source ||= if defined?(Process::CLOCK_MONOTONIC)
                           proc { (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i }
                         else
                           proc { (Time.now.to_f * 1000).to_i }
                         end
      end

      def worker_lock(&block)
        lock_id     = "lock_#{job_id}_#{worker_index}"
        lock_value  = ProcessRunner.identity
        time_source = ProcessRunner::Lock::SimpleRedis.time_source
        timeout_ms  = 5000
        wait_time   = 0.02..0.1
        start       = time_source.call

        while !(obtained = try_lock(lock_id, lock_value)) && (time_source.call - start) < timeout_ms
          sleep rand(wait_time)
        end

        if obtained
          begin
            block.call
          ensure
            ProcessRunner.redis do |c|
              c.del(lock_id)
            end
          end
        end
      end

      private

      def try_lock(key, value)
        ProcessRunner.redis do |c|
          c.set(key, value, nx: true, ex: runtime_lock_timeout)
        end
      end
    end
  end
end
