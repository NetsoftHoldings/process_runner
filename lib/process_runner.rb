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

  WORKER_COUNT_KEY = 'worker_counts'

  DEFAULTS = {
      redis:       {},
      job_sets:    [],
      require:     '.',
      max_threads: 10,
  }.freeze

  def self.options
    @options ||= DEFAULTS.dup
  end

  def self.options=(opts)
    @options = opts
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

  def self.adjust_worker_count(job_id, by: nil, to: nil)
    if !to.nil?
      redis { |c| c.hset(WORKER_COUNT_KEY, job_id.to_s, to) }
    elsif !by.nil?
      redis { |c| c.hincrby(WORKER_COUNT_KEY, job_id.to_s, by) }
    else
      raise ArgumentError, 'Must specify either by: (an increment/decrement) or to: (an exact value)'
    end
  end

  def self.worker_count(job_id)
    redis { |c| c.hget(WORKER_COUNT_KEY, job_id.to_s) }&.to_i
  end
end
