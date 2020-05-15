# frozen_string_literal: true

require 'process_balancer/cli'

RSpec.describe ProcessBalancer::CLI do
  let(:instance) { described_class.new }

  before do
    allow(instance.logger).to receive(:debug)
    allow(instance.logger).to receive(:info)
    allow(instance.logger).to receive(:error)
    allow(instance).to receive(:exit).and_raise('Exit called')
  end

  describe '.instance' do
    it 'creates a shared instance of the CLI' do
      expect(described_class.instance).to be_a(described_class)

      described_class.instance_variable_set(:@instance, nil)
    end
  end

  describe '#parse' do
    subject { instance.parse(args) }

    let(:args) { %w[] }

    around do |example|
      FakeFS.with_fresh do
        FileUtils.mkdir('./config')
        FileUtils.mkdir('./non_rails')
        FileUtils.touch('./config/application.rb')
        FileUtils.touch('boot.rb')
        example.call
      end
    end

    context 'with no args' do
      it 'initializes the logger to the default verbosity level' do
        expect { subject }.to_not change { instance.logger.level }
      end
    end

    context 'with verbose arg' do
      let(:args) { %w[-v] }

      it 'sets the verbosity option' do
        expect { subject }.to change { ProcessBalancer.options[:verbose] }.to(true)
      end

      it 'sets the log level to debug' do
        expect { subject }.to change { instance.logger.level }.to(::Logger::DEBUG)
      end
    end

    describe 'locating the config file' do
      context 'when no args specified' do
        context 'when that default config/process_balancer.yml file exists' do
          before do
            FileUtils.touch('./config/process_balancer.yml')
          end

          it 'loads that config file' do
            expect(instance).to receive(:parse_config).with('./config/process_balancer.yml').and_return({})

            subject
          end
        end

        context 'when that file does not exist' do
          it 'does not load any config file' do
            expect(instance).to_not receive(:parse_config)

            subject
          end
        end
      end

      context 'when the config arg is specified' do
        let(:args) { %w[-c config.yml] }

        context 'when that file exists' do
          before do
            FileUtils.touch('config.yml')
          end

          it 'loads that config file' do
            expect(instance).to receive(:parse_config).with('config.yml').and_return({})

            subject
          end
        end

        context 'when that file does not exist' do
          it 'raises an error' do
            expect { subject }.to raise_error(ArgumentError, /Config file not found/)
          end
        end
      end

      context 'when the require arg is specified' do
        before do
          FileUtils.mkdir_p('app/config')
          FileUtils.touch('app/boot.rb')
          FileUtils.touch('app/config/application.rb')
        end

        context 'and is a directory' do
          let(:args) { %w[-r app] }

          context 'when config file exists in that app root' do
            before do
              FileUtils.touch('app/config/process_balancer.yml')
            end

            it 'loads that config file' do
              expect(instance).to receive(:parse_config).with('app/config/process_balancer.yml').and_return({})

              subject
            end
          end

          context 'when that file does not exist' do
            it 'does not load any config file' do
              expect(instance).to_not receive(:parse_config)

              subject
            end
          end
        end

        context 'and is a file' do
          let(:args) { %w[-r app/boot.rb] }

          context 'when ./config/process_balancer.yml file exists' do
            before do
              FileUtils.touch('./config/process_balancer.yml')
            end

            it 'loads that config file' do
              expect(instance).to receive(:parse_config).with('./config/process_balancer.yml').and_return({})

              subject
            end
          end

          context 'when that file does not exist' do
            it 'does not load any config file' do
              expect(instance).to_not receive(:parse_config)

              subject
            end
          end
        end
      end
    end

    context 'with a configuration file' do
      let(:contents) { '' }

      before do
        File.write('./config/process_balancer.yml', contents)
      end

      it 'runs the file through ERB' do
        expect(ERB).to receive(:new).with(contents).and_return(instance_double('ERB', result: contents))

        subject
      end

      it 'parses the config file' do
        expect(YAML).to receive(:safe_load).with(contents, symbolize_names: true)

        subject
      end

      context 'with a simple config file' do
        let(:contents) do
          <<~YAML
            global:
              max_threads: 5
          YAML
        end

        it 'merges in the config options' do
          expect { subject }.to change { ProcessBalancer.options[:max_threads] }.to(5)
        end
      end

      context 'with overridden environments config' do
        let(:contents) do
          <<~YAML
            global:
              max_threads: 5
            environments:
              development:
                max_threads: 3
          YAML
        end

        it 'merges in the config options' do
          expect { subject }.to change { ProcessBalancer.options[:max_threads] }.to(3)
        end
      end

      context 'with an ERB commands in the config file' do
        let(:contents) do
          <<~YAML
            global:
              max_threads: <%= 2 + 3 %>
          YAML
        end

        it 'interprets the ERB code' do
          expect { subject }.to change { ProcessBalancer.options[:max_threads] }.to(5)
        end
      end

      context 'with jobs defined' do
        let(:contents) do
          <<~YAML
            jobs:
              sprockets:
                class: 'SprocketProcessor'
          YAML
        end

        it 'defines the job sets' do
          expect { subject }
              .to change { ProcessBalancer.options[:job_sets] }
                      .to(include(hash_including(id: :sprockets, class: 'SprocketProcessor')))
        end
      end
    end

    describe 'parameter validation' do
      shared_examples 'fail require validation' do
        it 'logs info' do
          allow(instance).to receive(:exit).with(1).and_return(nil)
          expect(instance.logger).to receive(:info).at_least(3).times

          subject
        end

        it 'exits the app' do
          expect(instance).to receive(:exit).with(1).and_return(nil)

          subject
        end
      end

      context 'when require file does not exist' do
        let(:args) { %w[-r ./nofile.rb] }

        include_examples 'fail require validation'
      end

      context 'when require is a file' do
        let(:args) { %w[-r ./boot.rb] }

        it 'passes validation' do
          expect(instance).to_not receive(:exit)

          subject
        end
      end

      context 'when require is a directory for a rails app' do
        it 'passes validation' do
          expect(instance).to_not receive(:exit)

          subject
        end
      end

      context 'when require is a directory for a non-rails app' do
        let(:args) { %w[-r ./non_rails] }

        include_examples 'fail require validation'
      end
    end
  end

  describe '#run' do
    subject { instance.run }

    let(:manager) { instance_double(ProcessBalancer::Manager, run: true, stop: true) }

    before do
      allow(ProcessBalancer::Manager).to receive(:new).and_return(manager)
      # stub this for testing
      allow(instance).to receive(:boot_system)
      # Stub so we do not run endlessly in tests
      allow(instance).to receive(:trap)
      allow(instance).to receive(:exit)
      allow(IO).to receive(:select).and_return([[instance_double('IO', gets: 'INT')]])
    end

    context 'when there are jobs configured' do
      before do
        ProcessBalancer.options[:job_sets] << {id: :my_job, class: 'MyClass'}
      end

      it 'logs the jobs' do
        expect(instance.logger).to receive(:info).with('Configured jobs')
        expect(instance.logger).to receive(:info).with(' - my_job')

        subject
      end
    end

    context 'when there are no jobs configured' do
      it 'logs that no jobs are configured' do
        expect(instance.logger).to receive(:error).with(/No jobs configured/)

        subject
      end
    end

    it 'traps signals' do
      expect(instance).to receive(:trap)

      subject
    end

    it 'creates a manager instance' do
      expect(ProcessBalancer::Manager).to receive(:new).with(ProcessBalancer.options).and_return(manager)

      subject
    end

    it 'starts the manager' do
      expect(manager).to receive(:run)

      subject
    end
  end

  describe '#boot_system' do
    subject { instance.send(:boot_system) }

    before do
      allow(instance).to receive(:require)
    end

    context 'when the require option is a directory' do
      let(:rails_version) { 5 }

      before do
        stub_const('Rails::VERSION::MAJOR', rails_version)
      end

      it 'attempts to load the rails app there' do
        expect(instance).to receive(:require).with('rails')

        subject
      end

      context 'when the rails version is less than 5' do
        let(:rails_version) { 4 }

        it 'raises an error' do
          expect { subject }.to raise_error(/Only rails 5\+/)
        end

        it 'does not load the environment' do
          expect(instance).to_not receive(:require).with(%r{config/environment.rb})

          subject
        rescue StandardError
          nil
        end
      end

      context 'when the rails version is 5 or newer' do
        it 'loads the environment' do
          expect(instance).to receive(:require).with(%r{config/environment.rb})

          subject
        end
      end
    end

    context 'when require option is a file' do
      before do
        ProcessBalancer.options[:require] = 'boot.rb'
      end

      it 'requires that file' do
        expect(instance).to receive(:require).with('boot.rb')

        subject
      end
    end
  end

  describe '::SIGNAL_HANDLERS' do
    subject { instance.send(:handle_signal, signal) }

    let(:manager) { instance_double(ProcessBalancer::Manager) }

    before do
      allow(instance).to receive(:manager).and_return(manager)
    end

    describe 'INT' do
      let(:signal) { 'INT' }

      it 'raises an Interrupt' do
        expect { subject }.to raise_error(Interrupt)
      end
    end

    describe 'TERM' do
      let(:signal) { 'TERM' }

      it 'raises an Interrupt' do
        expect { subject }.to raise_error(Interrupt)
      end
    end

    describe 'USR1' do
      let(:signal) { 'USR1' }

      it 'silences the manager' do
        expect(manager).to receive(:quiet)

        subject
      end
    end

    describe 'TSTP' do
      let(:signal) { 'TSTP' }

      it 'silences the manager' do
        expect(manager).to receive(:quiet)

        subject
      end
    end

    describe 'TTIN' do
      let(:signal) { 'TTIN' }

      it 'logs the running threads' do
        expect(instance.logger).to receive(:warn).at_least(:once)

        subject
      end
    end

    describe 'unknown' do
      let(:signal) { 'WHATEVER' }

      it 'logs an info that no handler was found' do
        expect(instance.logger).to receive(:info).with(/No signal handler/)

        subject
      end
    end
  end
end
