# frozen_string_literal: true

require 'process_runner/worker'
require 'process_runner/base'

RSpec.describe ProcessRunner::Worker do
  let(:worker_index) { 0 }

  let(:instance) { described_class.new(pool, worker_index, job_options) }
  let(:pool) { instance_double(Concurrent::ThreadPoolExecutor) }
  let(:future) { instance_double(Concurrent::Promises::Future) }
  let(:cancellation) { ProcessRunner::Private::Cancellation.new }
  let(:origin) { cancellation.origin }

  let(:job) { job_class.new(worker_index, job_options) }
  let(:job_options) { {id: :my_job, class: 'MyJob'} }
  let(:job_class) { Class.new(ProcessRunner::Base) }

  before do
    stub_const('MyJob', job_class)
    allow(job_class).to receive(:new).and_return(job)
    allow(Concurrent::Promises).to receive(:future_on).and_return(future)
    allow(ProcessRunner::Private::Cancellation).to receive(:new).and_return([cancellation, origin])
  end

  shared_context 'when future running' do
    before do
      allow(future).to receive(:resolved?).and_return(false)
      allow(future).to receive(:fulfilled?).and_return(false)
      allow(future).to receive(:rejected?).and_return(false)

      allow(cancellation).to receive(:canceled?).and_return(false)
      allow(origin).to receive(:resolved?).and_return(false)
    end
  end

  shared_context 'when future cancelled' do
    before do
      allow(future).to receive(:resolved?).and_return(false)
      allow(future).to receive(:fulfilled?).and_return(false)
      allow(future).to receive(:rejected?).and_return(false)

      allow(cancellation).to receive(:canceled?).and_return(true)
      allow(origin).to receive(:resolved?).and_return(true)
    end
  end

  shared_context 'when future stopped' do
    before do
      allow(future).to receive(:resolved?).and_return(true)
      allow(future).to receive(:fulfilled?).and_return(true)
      allow(future).to receive(:rejected?).and_return(false)

      allow(cancellation).to receive(:canceled?).and_return(false)
      allow(origin).to receive(:resolved?).and_return(false)
    end
  end

  shared_context 'when future cancelled and stopped' do
    before do
      allow(future).to receive(:resolved?).and_return(true)
      allow(future).to receive(:fulfilled?).and_return(true)
      allow(future).to receive(:rejected?).and_return(false)

      allow(cancellation).to receive(:canceled?).and_return(true)
      allow(origin).to receive(:resolved?).and_return(true)
    end
  end

  shared_context 'when future errored' do
    before do
      allow(future).to receive(:resolved?).and_return(true)
      allow(future).to receive(:fulfilled?).and_return(false)
      allow(future).to receive(:rejected?).and_return(true)

      allow(cancellation).to receive(:canceled?).and_return(false)
      allow(origin).to receive(:resolved?).and_return(false)
    end
  end

  describe '#initialize' do
    it 'sets the worker index' do
      expect(instance.instance_variable_get(:@worker_index)).to eq(worker_index)
    end

    it 'sets the future' do
      expect(instance.instance_variable_get(:@future)).to eq(future)
    end

    it 'sets the job_options' do
      expect(instance.instance_variable_get(:@job_options)).to eq(job_options)
    end

    it 'sets the cancellation origin' do
      expect(instance.instance_variable_get(:@origin)).to eq(origin)
    end
  end

  describe '#stop' do
    subject { instance.stop }

    it 'resolves the cancellation' do
      expect(origin).to receive(:resolve)

      subject
    end
  end

  describe '#running?' do
    subject { instance.running? }

    context 'when future is still running' do
      include_context 'when future running'

      it 'returns true' do
        is_expected.to eq(true)
      end
    end

    context 'when the future has been cancelled' do
      include_context 'when future cancelled'

      it 'returns false' do
        is_expected.to eq(false)
      end
    end

    context 'when the future has stopped' do
      include_context 'when future stopped'

      it 'returns false' do
        is_expected.to eq(false)
      end
    end
  end

  describe '#stopped?' do
    subject { instance.stopped? }

    context 'when future is still running' do
      include_context 'when future running'

      it 'returns false' do
        is_expected.to eq(false)
      end
    end

    context 'when the future has been cancelled' do
      include_context 'when future cancelled'

      it 'returns false' do
        is_expected.to eq(false)
      end
    end

    context 'when the future has stopped' do
      include_context 'when future stopped'

      it 'returns true' do
        is_expected.to eq(true)
      end
    end
  end

  describe '#runner' do
    subject { instance.send :runner, cancellation }

    let(:job_class) do
      Class.new(ProcessRunner::Base) do
        def initialize(*args)
          super
          @ran = false
        end

        def perform
          return :abort if @ran

          @ran = true
        end
      end
    end

    context 'when the cancellation has been cancelled' do
      before do
        origin.resolve
      end

      it 'does not process the job' do
        expect(job).to_not receive(:perform)

        subject
      end

      it 'returns :cancelled' do
        is_expected.to eq(:cancelled)
      end
    end

    context 'when the cancellation has not been cancelled' do
      it 'processes the job multiple times' do
        expect(job).to receive(:perform).twice.and_call_original

        subject
      rescue StandardError
        nil
      end
    end

    context 'when the job wants to sleep' do
      before do
        allow(instance).to receive(:sleep)
        allow(job).to receive(:perform).and_return([:sleep, 5], :abort)
      end

      it 'sleeps the specified amount' do
        expect(instance).to receive(:sleep).with(5)

        subject
      rescue StandardError
        nil
      end
    end

    context 'when the job wants to abort' do
      before do
        allow(job).to receive(:perform).and_return(:abort)
      end

      it 'only runs the job the first time' do
        expect(job).to receive(:perform).once

        subject
      end
    end

    context 'with a namespaced job class name' do
      before do
        stub_const('MyJobs::MyJob', job_class)
        job_options[:class] = 'MyJobs::MyJob'
      end

      it 'still loads the job' do
        expect(job).to receive(:perform).and_return(:abort)

        subject
      end
    end
  end
end
