# frozen_string_literal: true

require 'connection_pool'
require 'redis'

module ProcessBalancer
  module RedisConnection # :nodoc:
    def self.create(options = {})
      options[:url] = determine_redis_provider
      size          = options[:size] || 2
      pool_timeout  = options[:pool_timeout] || 1
      ConnectionPool.new(timeout: pool_timeout, size: size) do
        build_client(options)
      end
    end

    class << self
      private

      def determine_redis_provider
        if ENV['REDIS_PROVIDER'] =~ /[^A-Za-z_]/
          ProcessBalancer.logger.error 'REDIS_PROVIDER should be set to the name of the environment variable that contains the redis URL'
        end
        ENV[
            ENV['REDIS_PROVIDER'] || 'REDIS_URL'
        ]
      end

      def client_opts(options)
        opts = options.dup
        opts.delete(:namespace)

        opts[:driver]             ||= Redis::Connection.drivers.last || 'ruby'
        opts[:reconnect_attempts] ||= 1
        opts
      end

      def build_client(options)
        namespace = options[:namespace]

        client = Redis.new client_opts(options)
        if namespace
          begin
            require 'redis/namespace'
            Redis::Namespace.new(namespace, redis: client)
          rescue LoadError
            ProcessBalancer.logger.error "Your redis configuration uses namespace '#{namespace}' but redis-namespace gem is not in your Gemfile"
            exit(-127)
          end
        else
          client
        end
      end
    end
  end
end
