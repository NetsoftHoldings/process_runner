# frozen_string_literal: true

require 'process_runner/manager'

RSpec.describe ProcessRunner::Manager do
  let(:base_options) { ProcessRunner::DEFAULTS }
  let(:job_sets) { [] }
  let(:options) { base_options.merge(job_sets: job_sets) }
  let(:pool) { instance_double(Concurrent::ThreadPoolExecutor, shutdown: true, wait_for_termination: true, kill: true) }
  let(:instance) { described_class.new(options) }

  before do
    allow(Concurrent::ThreadPoolExecutor).to receive(:new).and_return(pool)
  end

  processes_key = ProcessRunner::Manager::PROCESSES_KEY

  describe '#initialize' do
    let(:job_sets) { [{id: :test_job, class: 'MyClass'}] }
    let(:watchers) { instance.instance_variable_get(:@watchers) }

    it 'creates the watcher' do
      expect(watchers[:test_job]).to be_a(ProcessRunner::Watcher)
    end

    it 'sets the job config' do
      expect(watchers[:test_job].job_config).to eq(job_sets[0])
    end
  end

  describe '#run' do
    subject { instance.run }

    it 'starts the heartbeat thread' do
      expect(instance).to receive(:start_thread).with('heartbeat')

      subject
    end
  end

  describe '#quiet' do
    subject { instance.quiet }

    before do
      allow(instance).to receive(:update_jobs)
    end

    it 'changes the @done ivar to true' do
      expect { subject }.to change { instance.instance_variable_get(:@done) }.to(true)
    end

    it 'calls update_jobs' do
      expect(instance).to receive(:update_jobs)

      subject
    end
  end

  describe '#stop' do
    subject { instance.stop }

    before do
      allow(instance).to receive(:clear_heartbeat)
      allow(instance).to receive(:update_jobs)
    end

    it 'calls quiet' do
      expect(instance).to receive(:quiet)

      subject
    end

    it 'tells the pool to shutdown' do
      expect(pool).to receive(:shutdown)

      subject
    end

    it 'tells the pool to wait for termination' do
      expect(pool).to receive(:wait_for_termination).with(30)

      subject
    end

    it 'tells the pool to kill itself' do
      expect(pool).to receive(:kill)

      subject
    end

    it 'calls clear_heartbeat' do
      expect(instance).to receive(:clear_heartbeat)

      subject
    end
  end

  describe '#stopping?' do
    subject { instance.stopping? }

    before do
      allow(instance).to receive(:update_jobs)
    end

    context 'when not quieted' do
      it 'returns false' do
        is_expected.to eq(false)
      end
    end

    context 'when quieted' do
      before do
        instance.quiet
      end

      it 'returns true' do
        is_expected.to eq(true)
      end
    end
  end

  describe '#workers_for_job' do
    include_context 'with redis'

    subject { instance.workers_for_job(job_id) }

    let(:job_id) { :my_job }

    context 'when the manager is quieted' do
      before do
        instance.quiet
      end

      it 'returns 0' do
        is_expected.to eq(0)
      end
    end

    it 'calls the ProcessRunner.worker_count' do
      expect(ProcessRunner).to receive(:worker_count).with(job_id)

      subject
    end
  end

  describe '#clear_heartbeat' do
    include_context 'with redis'

    subject { instance.send(:clear_heartbeat) }

    before do
      redis.rpush(processes_key, instance.identity)
    end

    it 'removes the identity from the processes key' do
      expect { subject }.to change { redis.lrange(processes_key, 0, -1) }.to not_include(instance.identity)
    end
  end

  describe '#run_heartbeat' do
    subject { instance.send(:run_heartbeat) }

    before do
      # stub loop so we do not have an infinite loop
      allow(instance).to receive(:loop).and_yield
      allow(instance).to receive(:sleep)
      allow(instance).to receive(:heartbeat)
      allow(ProcessRunner.logger).to receive(:info)
    end

    it 'calls loop' do
      expect(instance).to receive(:loop)

      subject
    end

    it 'calls heartbeat in the loop' do
      expect(instance).to receive(:heartbeat)

      subject
    end

    it 'sleeps between iterations of running the heartbeat' do
      expect(instance).to receive(:sleep).with(5)

      subject
    end
  end

  describe '#heartbeat' do
    include_context 'with redis'

    subject { instance.send(:heartbeat) }

    before do
      # stub to prevent it from causing side-affects
      allow(Process).to receive(:kill)
    end

    describe 'update_process_index - managing the process index' do
      it 'watches the processes key' do
        expect(redis).to receive(:watch).with(processes_key)

        subject
      end

      context 'when there are no workers' do
        it 'changes the process index to 0' do
          expect { subject }.to change { instance.process_index }.to(0)
        end

        it 'changes the process count to 1' do
          expect { subject }.to change { instance.process_count }.to(1)
        end
      end

      context 'when there are other workers' do
        before do
          redis.rpush(processes_key, 'worker 1')
          redis.rpush(processes_key, 'worker 2')
        end

        it 'changes the process index to 2' do
          expect { subject }.to change { instance.process_index }.to(2)
        end

        it 'changes the process count to 3' do
          expect { subject }.to change { instance.process_count }.to(3)
        end

        context 'when the instance already has a process index' do
          before do
            instance.send(:process_index=, 2)
            instance.send(:process_count=, 3)
          end

          context 'and the instance identity is not in the worker list' do
            it 'adds it to the list' do
              expect(redis).to receive(:rpush).with(processes_key, instance.identity).and_call_original

              subject
            end
          end

          context 'and the instance identity is in the worker list' do
            before do
              redis.rpush(processes_key, instance.identity)
              redis.rpush(processes_key, 'worker 3')
              instance.send(:process_count=, 4)
            end

            it 'retains the same process index' do
              expect { subject }.to_not change { instance.process_index }.from(2)
            end

            it 'doe not change the process count' do
              expect { subject }.to_not change { instance.process_count }.from(4)
            end

            it 'calls unwatch' do
              expect(redis).to receive(:unwatch)

              subject
            end

            context 'and a prior worker is removed' do
              before do
                redis.lrem(processes_key, 0, 'worker 2')
              end

              it 'updates the process index to 1' do
                expect { subject }.to change { instance.process_index }.to(1)
              end

              it 'changes the process count to 3' do
                expect { subject }.to change { instance.process_count }.to(3)
              end
            end

            context 'and a later worker is removed' do
              before do
                redis.lrem(processes_key, 0, 'worker 3')
              end

              it 'does not change the process index' do
                expect { subject }.to_not change { instance.process_index }.from(2)
              end

              it 'changes the process count to 3' do
                expect { subject }.to change { instance.process_count }.to(3)
              end
            end
          end
        end
      end
    end

    describe 'update_state - updating the state in redis' do
      it 'creates/updates a hash key for its identity' do
        expect { subject }.to change { redis.exists(instance.identity) }.to(true)

        expect(redis.type(instance.identity)).to eq('hash')
      end

      it 'sets the info, beat, quiet, and worker keys' do
        subject

        expect(redis.hgetall(instance.identity)).to include('info', 'beat', 'quiet', 'worker')
      end

      it 'sets the expire on the identity key' do
        subject

        expect(redis.ttl(instance.identity)).to eq(60)
      end
    end

    describe 'update_jobs - managing the watchers' do
      let(:job_sets) { [{id: :test_job, class: 'MyClass'}] }
      let(:watcher) { instance_double(ProcessRunner::Watcher, update_worker_config: nil, stats: {}) }
      let(:workers_key) { "#{instance.identity}:workers" }

      before do
        allow(ProcessRunner::Watcher).to receive(:new).and_return(watcher)
      end

      it 'updates each watcher' do
        expect(watcher).to receive(:update_worker_config)

        subject
      end

      it 'updates the stats for the running workers' do
        expect { subject }.to change { redis.type(workers_key) }.to('hash')
      end
      
      it 'sets a key for each job in the workers hash' do
        expect { subject }.to change { redis.hgetall(workers_key) || {} }.to include('test_job' => '{}')
      end

      it 'sets the expire for the workers hash' do
        subject

        expect(redis.ttl(workers_key)).to eq(60)
      end
    end

    context 'when there are no messages on the identity-signals list' do
      it 'does not call process kill' do
        expect(Process).to_not receive(:kill)

        subject
      end
    end

    context 'when there is a message in the identity-signals list' do
      before do
        redis.lpush("#{instance.identity}-signals", 'USR1')
      end

      it 'sends the signal to the process' do
        expect(Process).to receive(:kill).with('USR1', anything)

        subject
      end
    end

    context 'when any error occurs' do
      before do
        allow(instance).to receive(:update_process_index).and_raise('Something')
      end

      it 'logs it' do
        expect(ProcessRunner.logger).to receive(:error).with(/heartbeat: Something/)

        subject
      end
    end
  end
end
