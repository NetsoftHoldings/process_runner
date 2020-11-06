# frozen_string_literal: true

require 'process_balancer/watcher'
require 'process_balancer/base'

RSpec.describe ProcessBalancer::Watcher do
  let(:job_class) do
    Class.new(ProcessBalancer::Base) do
      def lock_records
        status_abort

        nil
      end

      def unlock_records; end

      # naive implementation for tests
      def worker_lock
        yield OpenStruct.new(extend!: true)
      end
    end
  end
  let(:job_config) { {id: :test_job, class: 'MyClass'} }
  let(:instance) { described_class.new(pool, job_config) }
  let(:pool) { instance_double(Concurrent::ThreadPoolExecutor) }
  let(:future) { instance_double(Concurrent::Promises::Future, resolved?: false, rejected?: false) }
  let(:cancellation) { instance_double(ProcessBalancer::Private::Cancellation) }
  let(:origin) { instance_double(Concurrent::Promises.resolvable_event.class, resolve: true, resolved?: false) }

  let(:running_workers) { instance.instance_variable_get(:@running) }
  let(:stopping_workers) { instance.instance_variable_get(:@stopping) }

  before do
    stub_const('MyClass', job_class)
    allow(ProcessBalancer.logger).to receive(:info)
    allow(Concurrent::Promises).to receive(:future_on).and_return(future)
    allow(ProcessBalancer::Private::Cancellation).to receive(:new).and_return([cancellation, origin])
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

    it 'calls check_workers' do
      expect(instance).to receive(:check_workers)

      subject
    end

    context 'when there are no current workers' do
      context 'and there should be 1' do
        it 'spawns the worker' do
          expect(instance).to receive(:start_worker).with(0)

          subject
        end

        it 'updates the stats' do
          expect { subject }.to change { instance.stats }.to({running: [{id: 0}], stopping: []})
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

        it 'updates the stats' do
          expect { subject }.to change { instance.stats }.to({running: [{id: 0}, {id: 2}], stopping: []})
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

        it 'updates the stats' do
          expect { subject }.to change { instance.stats }.to({running: [{id: 0}, {id: 3}], stopping: []})
        end

        context 'when the process index is 1' do
          let(:process_index) { 1 }

          it 'spawns every other worker id (1-based)' do
            expect(instance).to receive(:start_worker).with(1)
            expect(instance).to receive(:start_worker).with(4)

            subject
          end

          it 'updates the stats' do
            expect { subject }.to change { instance.stats }.to({running: [{id: 1}, {id: 4}], stopping: []})
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

        it 'updates the stats' do
          expect { subject }.to change { instance.stats }.to({running: [{id: 0}], stopping: [{id: 1}]})
        end
      end

      context 'when the job count is the same' do
        let(:job_count) { 2 }

        it 'does not stop any jobs' do
          expect(instance).to_not receive(:stop_worker)

          subject
        end

        it 'updates the stats' do
          expect { subject }.to change { instance.stats }.to({running: [{id: 0}, {id: 1}], stopping: []})
        end

        context 'when the process count changes' do
          let(:process_count) { 2 }

          it 'stops jobs unneeded jobs on this server' do
            expect(instance).to receive(:stop_worker).with(1)

            subject
          end

          it 'updates the stats' do
            expect { subject }.to change { instance.stats }.to({running: [{id: 0}], stopping: [{id: 1}]})
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

    it 'passes that job options to the worker new' do
      expect(ProcessBalancer::Worker).to receive(:new).with(pool, worker_id, job_config)

      subject
    end
  end

  describe '#stop_worker' do
    subject { instance.send(:with_lock) { instance.send(:stop_worker, worker_id) } }

    include_context 'with spin up workers', ids: [0]

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
        expect_any_instance_of(ProcessBalancer::Worker).to_not receive(:stop) # rubocop: disable RSpec/AnyInstance

        subject
      end
    end
  end

  describe '#check_workers' do
    subject { instance.send(:with_lock) { instance.send(:check_workers) } }

    include_context 'with spin up workers', ids: [0]

    let(:worker) { running_workers[0] }

    context 'when not run within the lock' do
      it 'raises a runtime error' do
        expect { instance.send(:check_workers) }.to raise_error('Not called within synchronize block')
      end
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
