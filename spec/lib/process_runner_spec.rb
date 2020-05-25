# frozen_string_literal: true

require 'process_runner'

RSpec.describe ProcessRunner do
  worker_count_key = ProcessRunner::WORKER_COUNT_KEY
  processes_key = ProcessRunner::PROCESSES_KEY

  it 'has a version number' do
    expect(ProcessRunner::VERSION).to_not be nil
  end

  describe '.options' do
    subject { described_class.options }

    it 'returns the default options' do
      is_expected.to eq(described_class::DEFAULTS)
    end
  end

  describe '.options=' do
    subject { described_class.options = {mine: true} }

    it 'sets the options' do
      is_expected.to eq({mine: true})
    end

    it 'does not touch the DEFAULT' do
      expect { subject }.to_not change { described_class::DEFAULTS }
    end
  end

  describe '.logger' do
    subject { described_class.logger }

    it 'returns a ruby logger instance' do
      is_expected.to be_a(Logger)
    end
  end

  describe '.redis' do
    let(:redis) { MockRedis.new }

    context 'when called without a block' do
      it 'raises an argument error' do
        expect { described_class.redis }.to raise_error(ArgumentError, 'requires a block')
      end
    end

    context 'when called with a block' do
      it 'calls redis_pool' do
        expect(described_class).to receive(:redis_pool).and_return(instance_double('ConnectionPool', with: true))

        described_class.redis {}
      end

      it 'yields control with the redis connection' do
        pool = instance_double('ConnectionPool')
        allow(pool).to receive(:with).and_yield(redis)
        allow(described_class).to receive(:redis_pool).and_return(pool)

        expect { |y| described_class.redis(&y) }.to yield_with_args(redis)
      end

      context 'when a command error is raised' do
        subject do
          pass = 0
          described_class.redis do |_c|
            pass += 1
            passes[pass - 1].call
          end
        end

        let(:pass_1) { -> {} }
        let(:pass_2) { -> {} }
        let(:pass_3) { -> {} }
        let(:passes) { [pass_1, pass_2, pass_3] }

        before do
          pool = instance_double('ConnectionPool')
          allow(pool).to receive(:with).and_yield(redis)
          allow(described_class).to receive(:redis_pool).and_return(pool)
        end

        context 'when mentioning READONLY' do
          let(:pass_1) { -> { raise Redis::CommandError, 'something READONLY' } }

          it 'retries the block once' do
            expect(pass_2).to receive(:call)

            subject
          end

          it 'disconnects from the connection' do
            expect(redis).to receive(:disconnect!)

            subject
          end

          context 'when the second pass also raises READONLY' do
            let(:pass_2) { -> { raise Redis::CommandError, 'something READONLY' } }

            it 'does not retry the block twice' do
              expect(pass_3).to_not receive(:call)

              subject
            rescue StandardError
              nil
            end

            it 'raises the error out' do
              expect { subject }.to raise_error(Redis::CommandError)
            end
          end
        end

        context 'when not mentioning READONLY' do
          let(:pass_1) { -> { raise Redis::CommandError, 'something else' } }

          it 'does not retry' do
            expect(pass_2).to_not receive(:call)

            subject
          rescue Redis::CommandError
            nil
          end

          it 'raises the error out' do
            expect { subject }.to raise_error(Redis::CommandError)
          end
        end
      end
    end
  end

  describe '.redis_pool' do
    subject { described_class.redis_pool }

    it 'calls calls RedisConnection to create a pool' do
      described_class.options[:redis] = {test_key: true}
      expect(ProcessRunner::RedisConnection).to receive(:create).with(test_key: true)

      subject
    end
  end

  describe '.hostname' do
    subject { described_class.hostname }

    context 'with no DYNO env' do
      around do |ex|
        with_modified_env({DYNO: nil}, &ex)
      end

      it 'returns the system hostname' do
        allow(Socket).to receive(:gethostname).and_return('MyTestHost')

        is_expected.to eq('MyTestHost')
      end
    end

    context 'with a DYNO env' do
      around do |ex|
        with_modified_env({DYNO: 'MyDyno'}, &ex)
      end

      it 'returns the DYNO env' do
        allow(Socket).to receive(:gethostname).and_return('MyTestHost')

        is_expected.to eq('MyDyno')
      end
    end
  end

  describe '.process_nonce' do
    subject { described_class.process_nonce }

    it 'returns the secure random hex result' do
      allow(SecureRandom).to receive(:hex).with(6).and_return('deadbe')

      is_expected.to eq('deadbe')
    end

    it 'memoizes the value' do
      first = described_class.process_nonce

      is_expected.to eq(first)
    end
  end

  describe '.identity' do
    subject { described_class.identity }

    it 'returns combination of the hostname, PID, and process nonce' do
      allow(described_class).to receive(:hostname).and_return('hostname')
      allow(described_class).to receive(:process_nonce).and_return('nonce')

      is_expected.to match(/hostname:\d+:nonce/)
    end

    it 'memoizes the value' do
      first = described_class.identity

      is_expected.to eq(first)
    end
  end

  describe '.adjust_scheduled_workers' do
    include_context 'with redis'

    subject { described_class.adjust_scheduled_workers(job_id, **params) }

    let(:job_id) { :my_job }
    let(:params) { {} }

    context 'when neither to: or by: is specified' do
      it 'raises an ArgumentError' do
        expect { subject }.to raise_error(ArgumentError)
      end
    end

    context 'when to is specified' do
      let(:params) { {to: 5} }

      it 'sets the value exactly' do
        expect { subject }.to change { redis.hget(worker_count_key, job_id.to_s) }.to('5')
      end
    end

    context 'when by is specified' do
      before do
        redis.hset(worker_count_key, job_id.to_s, '2')
      end

      let(:params) { {by: 3} }

      it 'increments by that amount' do
        expect { subject }.to change { redis.hget(worker_count_key, job_id.to_s) }.to('5')
      end

      context 'when a negative value is specified' do
        let(:params) { {by: -1} }

        it 'decrements by that amount' do
          expect { subject }.to change { redis.hget(worker_count_key, job_id.to_s) }.to('1')
        end
      end
    end
  end

  describe '.scheduled_workers' do
    include_context 'with redis'

    subject { described_class.scheduled_workers(job_id) }

    let(:job_id) { :my_job }

    context 'when no override is set' do
      it 'returns 1' do
        is_expected.to eq(1)
      end
    end

    context 'when an override is set' do
      before do
        redis.hset(worker_count_key, job_id.to_s, '5')
      end

      it 'returns the override value' do
        is_expected.to eq(5)
      end
    end
  end

  describe '.running_workers' do
    include_context 'with redis'

    subject { described_class.running_workers(job_id) }

    let(:identity_1) { 'deadbeef' }
    let(:identity_2) { 'beefdead' }
    let(:worker_key_1) { "#{identity_1}:workers" }
    let(:worker_key_2) { "#{identity_2}:workers" }

    let(:job_id) { :my_job }

    before do
      processes.each do |identifier|
        redis.rpush(processes_key, identifier)
      end
    end

    context 'when no processes are running' do
      let(:processes) { [] }

      it 'returns 0' do
        is_expected.to eq(0)
      end
    end

    context 'when one process is running' do
      let(:processes) { [identity_1] }

      before do
        redis.mapped_hmset(worker_key_1, worker_1_data.transform_values(&:to_json))
      end

      context 'when the job is running in the process' do
        let(:worker_1_data) { {job_id => {running: [{id: 0}, {id: 1}], stopping: [{id: 2}]}} }

        it 'returns the count of running jobs' do
          is_expected.to eq(2)
        end
      end

      context 'when the job is not running in the process' do
        let(:worker_1_data) { {'other_job' => {running: [{id: 0}, {id: 1}], stopping: [{id: 2}]}} }

        it 'returns 0' do
          is_expected.to eq(0)
        end
      end
    end

    context 'when two processes are running' do
      let(:processes) { [identity_1, identity_2] }

      before do
        redis.mapped_hmset(worker_key_1, worker_1_data.transform_values(&:to_json))
        redis.mapped_hmset(worker_key_2, worker_2_data.transform_values(&:to_json))
      end

      context 'when the job is defined' do
        let(:worker_1_data) { {job_id => {running: [{id: 0}, {id: 2}], stopping: []}} }
        let(:worker_2_data) { {job_id => {running: [{id: 1}], stopping: [{id: 3}]}} }

        it 'returns the count of running jobs' do
          is_expected.to eq(3)
        end
      end

      context 'when the job is not running in the process' do
        let(:worker_1_data) { {'other_job' => {running: [{id: 0}, {id: 2}], stopping: []}} }
        let(:worker_2_data) { {'other_job' => {running: [{id: 1}], stopping: [{id: 3}]}} }

        it 'returns 0' do
          is_expected.to eq(0)
        end
      end
    end
  end
end
