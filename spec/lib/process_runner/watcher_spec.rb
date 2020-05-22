# frozen_string_literal: true

require 'process_runner/watcher'
require 'process_runner/base'

RSpec.describe ProcessRunner::Watcher do
  let(:job_class) do
    Class.new(ProcessRunner::Base) do
      def lock_records
        status_abort

        nil
      end

      def unlock_records; end

      # naive implementation for tests
      def worker_lock
        yield
      end
    end
  end
  let(:job_config) { {id: :test_job, class: 'MyClass'} }
  let(:instance) { described_class.new(job_config) }
  let(:running_workers) { instance.instance_variable_get(:@running) }
  let(:stopping_workers) { instance.instance_variable_get(:@stopping) }

  before do
    stub_const('MyClass', job_class)
    allow(ProcessRunner.logger).to receive(:info)
  end

  describe '#initialize' do
    it 'sets the job_config' do
      expect(instance.job_config).to eq(job_config)
    end
  end

  shared_context 'with spin up workers' do |ids:|
    before do
      instance.send(:with_lock) do
        ids.each { |id| instance.send(:start_worker, id) }
      end
    end
  end

  describe '#update_worker_config' do
    subject { instance.update_worker_config(process_index, process_count, job_count) }

    let(:process_index) { 0 }
    let(:process_count) { 1 }
    let(:job_count) { 1 }

    it 'runs everything in a lock' do
      expect(instance).to receive(:with_lock)

      subject
    end

    context 'when there are no current workers' do
      context 'and there should be 1' do
        it 'spawns the worker' do
          expect(instance).to receive(:start_worker).with(0)

          subject
        end
      end

      context 'and the process count is 2' do
        let(:process_count) { 2 }
        let(:job_count) { 4 }

        it 'spawns every other worker id' do
          expect(instance).to receive(:start_worker).with(0)
          expect(instance).to receive(:start_worker).with(2)

          subject
        end

        context 'when the process index is 1' do
          let(:process_index) { 1 }

          it 'spawns every other worker id (odd)' do
            expect(instance).to receive(:start_worker).with(1)
            expect(instance).to receive(:start_worker).with(3)

            subject
          end
        end
      end

      context 'and the process count is 3' do
        let(:process_count) { 3 }
        let(:job_count) { 5 }

        it 'spawns every third worker id' do
          expect(instance).to receive(:start_worker).with(0)
          expect(instance).to receive(:start_worker).with(3)

          subject
        end

        context 'when the process index is 1' do
          let(:process_index) { 1 }

          it 'spawns every other worker id (1-based)' do
            expect(instance).to receive(:start_worker).with(1)
            expect(instance).to receive(:start_worker).with(4)

            subject
          end
        end
      end
    end

    context 'when there are existing workers running' do
      include_context 'with spin up workers', ids: [0, 1]

      context 'and there should only be 1' do
        it 'stops unneeded running jobs' do
          expect(instance).to receive(:stop_worker).with(1)

          subject
        end
      end

      context 'when the job count is the same' do
        let(:job_count) { 2 }

        it 'does not stop any jobs' do
          expect(instance).to_not receive(:stop_worker)

          subject
        end

        context 'when the process count changes' do
          let(:process_count) { 2 }

          it 'stops jobs unneeded jobs on this server' do
            expect(instance).to receive(:stop_worker).with(1)

            subject
          end
        end
      end
    end
  end

  describe '#start_worker' do
    subject { instance.send(:with_lock) { instance.send(:start_worker, worker_id) } }

    let(:worker_id) { 0 }

    context 'when not run within the lock' do
      it 'raises a runtime error' do
        expect { instance.send(:start_worker, 0) }.to raise_error('Not called within synchronize block')
      end
    end

    it 'registers that worker in the workers hash' do
      expect { subject }.to change { running_workers }.to include(worker_id)
    end

    context 'with a simple job class name' do
      it 'passes that job class to the worker new' do
        expect(ProcessRunner::Worker).to receive(:new).with(worker_id, job_class, job_config)

        subject
      end
    end

    context 'with a namespaced job class name' do
      before do
        stub_const('MyJobs::MyJob', job_class)
        job_config[:class] = 'MyJobs::MyJob'
      end

      it 'passes that job class tot he worker new' do
        expect(ProcessRunner::Worker).to receive(:new).with(worker_id, job_class, job_config)

        subject
      end
    end
  end

  describe '#stop_worker' do
    include_context 'with spin up workers', ids: [0]

    subject { instance.send(:with_lock) { instance.send(:stop_worker, worker_id) } }

    context 'when not run within the lock' do
      it 'raises a runtime error' do
        expect { instance.send(:stop_worker, 0) }.to raise_error('Not called within synchronize block')
      end
    end

    context 'when the worker has been started already' do
      let(:worker_id) { 0 }

      it 'stops the worker' do
        expect(running_workers[worker_id]).to receive(:stop)

        subject
      end

      it 'adds the worker into the stopping list' do
        worker = running_workers[worker_id]

        expect { subject }.to change { stopping_workers }.to include(worker)
      end

      it 'removes the worker from the running list' do
        expect { subject }.to change { running_workers }.to not_include(worker_id)
      end
    end

    context 'when the worker has not been started' do
      let(:worker_id) { 1 }

      it 'does not change the running list' do
        expect { subject }.to_not change { running_workers }
      end

      it 'does not change the stopping list' do
        expect { subject }.to_not change { stopping_workers }
      end

      it 'does not call stop on any worker' do
        expect_any_instance_of(ProcessRunner::Worker).to_not receive(:stop) # rubocop: disable RSpec/AnyInstance

        subject
      end
    end
  end

  describe '#check_workers' do
    include_context 'with spin up workers', ids: [0]

    subject { instance.send(:check_workers) }

    let(:worker) { running_workers[0] }

    it 'runs everything in a lock' do
      expect(instance).to receive(:with_lock)

      subject
    end

    context 'when the worker is running' do
      before do
        allow(worker).to receive(:running?).and_return(true)
      end

      it 'does not move the worker to the stopping list' do
        expect { subject }.to_not change { stopping_workers }.from([])

        subject
      end

      it 'does not remove the worker from the running list' do
        expect { subject }.to_not change { running_workers }.from including(0)
      end
    end

    context 'when the worker is stopping' do
      before do
        allow(worker).to receive(:running?).and_return(false)
        allow(worker).to receive(:stopped?).and_return(false)
      end

      it 'moves the worker to the stopping list' do
        expect { subject }.to change { stopping_workers }.to include(worker)

        subject
      end

      it 'removes the worker from the running list' do
        expect { subject }.to change { running_workers }.to not_include(0)
      end
    end

    context 'when the worker is stopped' do
      before do
        allow(worker).to receive(:running?).and_return(false)
        allow(worker).to receive(:stopped?).and_return(true)
      end

      it 'does not move the worker to the stopping list' do
        expect { subject }.to_not change { stopping_workers }.from([])

        subject
      end

      it 'removes it from the running list' do
        expect { subject }.to change { running_workers }.to not_include(0)
      end

      context 'and the worker is already in the stopping list' do
        before do
          worker # preload
          instance.send(:with_lock) { instance.send(:stop_worker, 0) }
        end

        it 'removes the worker from the stopping list' do
          expect { subject }.to change { stopping_workers }.to not_include(worker)

          subject
        end

        it 'does not change the running list' do
          expect { subject }.to_not change { running_workers }.from({})
        end
      end
    end
  end
end
