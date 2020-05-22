# frozen_string_literal: true

module ProcessRunner
  module Lock
    # This is a simple implementation of a lock to ensure only one job runner is running for a worker
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

      class LockHandler
        def initialize(key, value, ttl)
          @key      = key
          @value    = value
          @ttl      = ttl
          @acquired = false
        end

        def acquire!
          time_source = ProcessRunner::Lock::SimpleRedis.time_source

          timeout_ms = 5000
          wait_time  = 0.02..0.1
          start      = time_source.call

          while !(@acquired = try_lock) && (time_source.call - start) < timeout_ms
            sleep rand(wait_time)
          end
        end

        def release!
          ProcessRunner.redis do |c|
            c.del(@key)
          end
        end

        def acquired?
          @acquired
        end

        def try_lock
          ProcessRunner.redis do |c|
            c.set(@key, @value, nx: true, ex: @ttl)
          end
        end

        def extend!
          ProcessRunner.redis do |c|
            c.watch(@key)
            if c.get(@key) == @value
              c.multi do
                c.set(@key, @value, ex: @ttl)
              end
            end
          end
        end
      end

      def worker_lock
        lock = LockHandler.new("lock_#{job_id}_#{worker_index}", ProcessRunner.identity, runtime_lock_timeout)
        lock.acquire!

        if lock.acquired?
          begin
            yield lock
          ensure
            lock.release!
          end
        end
      end
    end
  end
end
