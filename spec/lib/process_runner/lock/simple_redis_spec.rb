# frozen_string_literal: true

require 'process_runner/base'
require 'process_runner/lock/simple_redis'

RSpec.describe ProcessRunner::Lock::SimpleRedis do
  subject { instance.perform }

  let(:job_class) do
    Class.new(ProcessRunner::Base) do
      include ProcessRunner::Lock::SimpleRedis

      def lock_records; end

      def process_record(_record) end

      def unlock_records; end
    end
  end

  let(:worker_index) { 1 }
  let(:job_options) { {id: :my_job, class: 'MyJob'} }

  let(:instance) { job_class.new(worker_index, job_options) }

  include_context 'with redis'

  before do
    allow(instance).to receive(:sleep)
  end

  context 'when the lock is obtained' do
    it 'sets a lock in redis' do
      expect(redis).to receive(:set).with('lock_my_job_1', ProcessRunner.identity, hash_including(nx: true)).and_call_original
      expect(redis).to receive(:set).with('lock_my_job_1', ProcessRunner.identity, hash_not_including(nx: true)).and_call_original

      subject
    end

    it 'does not sleep' do
      expect(instance).to_not receive(:sleep)

      subject
    end

    it 'calls lock_records' do
      expect(instance).to receive(:lock_records)

      subject
    end

    it 'calls unlock_records' do
      expect(instance).to receive(:unlock_records)

      subject
    end

    it 'clears the lock when done' do
      expect(redis).to receive(:del).with('lock_my_job_1')

      subject
    end
  end

  context 'when the lock is not obtained' do
    before do
      redis.set('lock_my_job_1', 'already locked')
      time = Time.now.to_f * 1000
      allow(described_class.time_source).to receive(:call).and_return(time, time, time + 2500, time + 5000)
    end

    it 'tries to lock multiple times' do
      expect(redis).to receive(:set).with('lock_my_job_1', any_args).and_call_original.exactly(3).times

      subject
    end

    it 'sleeps between each attempt' do
      handler = described_class::LockHandler.new('lock_my_job_1', ProcessRunner.identity, 30)

      allow(described_class::LockHandler).to receive(:new).and_return(handler)

      expect(handler).to receive(:sleep).twice

      subject
    end

    it 'does not call lock_records' do
      expect(instance).to_not receive(:lock_records)

      subject
    end

    it 'does not call unlock_records' do
      expect(instance).to_not receive(:unlock_records)

      subject
    end

    it 'does not clear the lock' do
      expect(redis).to_not receive(:del)

      subject
    end
  end
end
