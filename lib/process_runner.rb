# frozen_string_literal: true

require 'logger'
require 'socket'
require 'securerandom'
require 'yaml'

require_relative 'process_runner/version'
require_relative 'process_runner/redis_connection'
require_relative 'process_runner/base'

module ProcessRunner # :nodoc:
  class Error < StandardError; end

  PROCESSES_KEY    = 'processes'
  WORKER_COUNT_KEY = 'worker_counts'

  DEFAULTS = {
      redis:            {},
      job_sets:         [],
      require:          '.',
      max_threads:      10,
      shutdown_timeout: 30,
      reloader:         proc { |&block| block.call },
  }.freeze

  def self.options
    @options ||= DEFAULTS.dup
  end

  def self.options=(opts)
    @options = opts
  end

  ##
  # Configuration for ProcessRunner, use like:
  #
  #   ProcessRunner.configure do |config|
  #     config.redis = { :namespace => 'myapp', :size => 25, :url => 'redis://myhost:8877/0' }
  #     if config.server?
  #      # any configuration specific to server
  #     end
  #   end
  def self.configure
    yield self
  end

  def self.server?
    defined?(ProcessRunner::CLI)
  end

  def self.logger
    @logger ||= Logger.new(STDOUT, level: Logger::INFO)
  end

  def self.redis
    raise ArgumentError, 'requires a block' unless block_given?

    redis_pool.with do |conn|
      retryable = true
      begin
        yield conn
      rescue Redis::CommandError => e
        # if we are on a slave, disconnect and reopen to get back on the master
        (conn.disconnect!; retryable = false; retry) if retryable && e.message =~ /READONLY/
        raise
      end
    end
  end

  def self.redis_pool
    @redis_pool ||= RedisConnection.create(options[:redis])
  end

  def self.redis=(hash)
    @redis_pool = if hash.is_a?(ConnectionPool)
                    hash
                  else
                    RedisConnection.create(hash)
                  end
  end

  def self.reset
    @redis_pool    = nil
    @options       = nil
    @logger        = nil
    @process_nonce = nil
    @identity      = nil
  end

  def self.hostname
    ENV['DYNO'] || Socket.gethostname
  end

  def self.process_nonce
    @process_nonce ||= SecureRandom.hex(6)
  end

  def self.identity
    @identity ||= "#{hostname}:#{$PID}:#{process_nonce}"
  end

  def self.adjust_scheduled_workers(job_id, by: nil, to: nil)
    if !to.nil?
      redis { |c| c.hset(WORKER_COUNT_KEY, job_id.to_s, to) }
    elsif !by.nil?
      redis { |c| c.hincrby(WORKER_COUNT_KEY, job_id.to_s, by) }
    else
      raise ArgumentError, 'Must specify either by: (an increment/decrement) or to: (an exact value)'
    end
  end

  def self.scheduled_workers(job_id)
    value = redis { |c| c.hget(WORKER_COUNT_KEY, job_id.to_s) }&.to_i
    value.nil? ? 1 : value
  end

  def self.running_workers(job_id)
    count = 0

    redis do |c|
      workers = c.lrange(PROCESSES_KEY, 0, -1)

      workers.each do |worker|
        data = c.hget("#{worker}:workers", job_id)
        pp data: data
        if data
          data = JSON.parse(data, symbolize_names: true)
          count += (data.dig(:running)&.size || 0)
        end
      rescue JSON::ParserError
        nil
      end
    end

    count
  end
end

require 'process_runner/rails' if defined?(::Rails::Engine)
