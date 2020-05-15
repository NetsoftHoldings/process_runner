# frozen_string_literal: true

$stdout.sync = true

require 'optparse'
require 'yaml'
require 'erb'

require_relative '../process_balancer'
require_relative 'manager'
require_relative 'util'

module ProcessBalancer
  class CLI # :nodoc:
    include Util

    attr_reader :manager, :environment

    def self.instance
      @instance ||= new
    end

    def parse(args = ARGV)
      setup_options(args)
      initialize_logger
      validate!
    end

    def run
      boot_system
      logger.info "Booted Rails #{::Rails.version} application in #{environment} environment" if rails_app?
      Thread.current.name = 'main'

      self_read, self_write = IO.pipe
      signals               = %w[INT TERM TTIN TSTP USR1 USR2]

      signals.each do |sig|
        trap sig do
          self_write.write("#{sig}\n")
        end
      rescue ArgumentError
        logger.info "Signal #{sig} not supported"
      end

      logger.info "Running in #{RUBY_DESCRIPTION}"

      if options[:job_sets].empty?
        logger.error 'No jobs configured! Configure your jobs in the configuration file.'
      else
        logger.info 'Configured jobs'
        options[:job_sets].each do |config|
          logger.info " - #{config[:id]}"
        end
      end

      @manager = ProcessBalancer::Manager.new(options)

      begin
        @manager.run

        while (readable_io = IO.select([self_read]))
          signal = readable_io.first[0].gets.strip
          handle_signal(signal)
        end
      rescue Interrupt
        logger.info 'Shutting down'
        @manager.stop
        logger.info 'Bye!'

        # Explicitly exit so busy Processor threads wont block process shutdown.
        exit(0)
      end
    end

    private

    # region initializing app
    def boot_system
      ENV['RACK_ENV'] = ENV['RAILS_ENV'] = environment
      if File.directory?(options[:require])
        require 'rails'
        if ::Rails::VERSION::MAJOR < 5
          raise 'Only rails 5+ is supported'
        else
          require 'process_balancer/rails'
          require File.expand_path("#{options[:require]}/config/environment.rb")
        end
      else
        require options[:require]
      end
    end

    # endregion

    # region option and configuration handling
    def parse_options(argv)
      opts = {redis: {}}

      @parser = OptionParser.new do |o|
        o.on('-eENVIRONMENT', '--environment ENVIRONMENT', 'Specify the app environment') do |arg|
          opts[:environment] = arg
        end

        o.on('-rREQUIRE', '--require REQUIRE', 'Specify rails app path or file to boot your app with jobs') do |arg|
          opts[:require] = arg
        end

        o.on('-cFILE', '--config FILE', 'Specify a configuration file. Default is config/process_balancer.yml in the rails app') do |arg|
          opts[:config_file] = arg
        end

        o.on('-v', '--[no-]verbose', 'Run verbosely') do |v|
          opts[:verbose] = v
        end
      end

      @parser.banner = 'process_balancer [options]'
      @parser.on_tail '-h', '--help', 'Show help' do
        logger.info parser.help
        exit(1)
      end

      @parser.parse!(argv)

      opts
    end

    def locate_config_file!(opts)
      if opts[:config_file]
        unless File.exist?(opts[:config_file])
          raise ArgumentError, "Config file not found: #{opts[:config_file]}"
        end
      else
        config_dir = if opts[:require] && File.directory?(opts[:require])
                       File.join(opts[:require], 'config')
                     else
                       File.join(options[:require], 'config')
                     end

        %w[process_balancer.yml process_balancer.yml.erb].each do |config_file|
          path = File.join(config_dir, config_file)
          if File.exist?(path)
            opts[:config_file] ||= path
          end
        end
      end
    end

    def parse_config(path)
      config = YAML.safe_load(ERB.new(File.read(path)).result, symbolize_names: true) || {}

      opts = {}
      # pull in global config
      opts.merge!(config.dig(:global) || {})
      # pull in ENV override config
      opts.merge!(config.dig(:environments, environment.to_sym) || {})

      opts[:job_sets] = parse_jobs(config)

      opts
    end

    def parse_jobs(config)
      (config[:jobs] || {}).map do |id, job|
        {
            id: id,
            **job,
        }
      end
    end

    def setup_options(args)
      opts = parse_options(args)

      setup_environment opts[:environment]

      locate_config_file!(opts)

      opts = parse_config(opts[:config_file]).merge(opts) if opts[:config_file]

      options.merge!(opts)
    end

    def validate!
      if !File.exist?(options[:require]) ||
          (File.directory?(options[:require]) && !File.exist?("#{options[:require]}/config/application.rb"))
        logger.info 'Please point process balancer to a Rails application or a Ruby file'
        logger.info 'to load your job classes with -r [DIR|FILE].'
        logger.info @parser.help
        exit(1)
      end
    end

    def options
      ProcessBalancer.options
    end

    def initialize_logger
      logger.level = ::Logger::DEBUG if options[:verbose]
    end

    # endregion

    # region signal handling
    SIGNAL_HANDLERS = {
        INT:  lambda { |_cli|
          # Ctrl-C in terminal
          raise Interrupt
        },
        TERM: lambda { |_cli|
          # TERM is the signal that process must exit.
          # Heroku sends TERM and then waits 30 seconds for process to exit.
          raise Interrupt
        },
        USR1: lambda { |cli|
          ProcessBalancer.logger.info 'Received USR1, no longer accepting new work'
          cli.manager.quiet
        },
        TSTP: lambda { |cli|
          ProcessBalancer.logger.info 'Received TSTP, no longer accepting new work'
          cli.manager.quiet
        },
        TTIN: lambda { |_cli|
          Thread.list.each do |thread|
            ProcessBalancer.logger.warn "Thread TID-#{(thread.object_id ^ ::Process.pid).to_s(36)} #{thread.name}"
            if thread.backtrace
              ProcessBalancer.logger.warn thread.backtrace.join("\n")
            else
              ProcessBalancer.logger.warn '<no backtrace available>'
            end
          end
        },
    }.freeze

    def handle_signal(sig)
      logger.debug "Got #{sig} signal"
      handle = SIGNAL_HANDLERS[sig.to_sym]
      if handle
        handle.call(self)
      else
        logger.info("No signal handler for #{sig}")
      end
    end

    # endregion

    # region environment
    def setup_environment(cli_env)
      @environment = cli_env || ENV['APP_ENV'] || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
    end

    def rails_app?
      defined?(::Rails) && ::Rails.respond_to?(:application)
    end
    # endregion
  end
end
