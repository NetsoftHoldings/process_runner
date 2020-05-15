# frozen_string_literal: true

require 'process_balancer/base'

RSpec.describe ProcessBalancer::Base do
  let(:worker_index) { 1 }
  let(:job_class) do
    Class.new(described_class) do
      def lock_records; end

      def process_record(_record) end

      def unlock_records; end

      # naive implementation for tests
      def worker_lock
        yield OpenStruct.new(extend!: true)
      end
    end
  end
  let(:job_options) { {id: :my_job, class: 'MyJob'} }
  let(:instance) { job_class.new(worker_index, job_options) }

  describe '#perform' do
    subject { instance.perform }

    it 'calls lock_records' do
      expect(instance).to receive(:lock_records)

      subject
    end

    context 'when lock_records returns nil' do
      before do
        allow(instance).to receive(:lock_records).and_return(nil)
      end

      it 'does not call process_record' do
        expect(instance).to_not receive(:process_record)

        subject
      end

      it 'calls unlock_records' do
        expect(instance).to receive(:unlock_records)

        subject
      end
    end

    context 'when lock_records returns an enumerable' do
      before do
        allow(instance).to receive(:lock_records).and_return(%w[r1 r2])
      end

      it 'calls process_record for each record' do
        expect(instance).to receive(:process_record).with('r1')
        expect(instance).to receive(:process_record).with('r2')

        subject
      end

      it 'calls unlock_records' do
        expect(instance).to receive(:unlock_records)

        subject
      end
    end

    context 'when the job does not change the status' do
      it 'returns nil' do
        is_expected.to be_nil
      end
    end

    context 'when the job sets the status' do
      before do
        allow(instance).to receive(:lock_records) do
          instance.status_abort
          nil
        end
      end

      it 'returns the status' do
        is_expected.to eq(:abort)
      end
    end

    context 'when process record raises' do
      before do
        allow(instance).to receive(:process_record).and_raise('error')
      end

      it 'still calls unlock_records' do
        expect(instance).to receive(:unlock_records)

        subject
      rescue StandardError
        nil
      end
    end
  end

  describe '#status_abort' do
    subject { instance.status_abort }

    it 'sets the status to :abort' do
      expect { subject }.to change { instance.status }.to(:abort)
    end
  end

  describe '#status_sleep' do
    subject { instance.status_sleep(5) }

    it 'sets the status to :sleep, 5' do
      expect { subject }.to change { instance.status }.to([:sleep, 5])
    end
  end

  describe '#runtime_lock_timeout' do
    subject { instance.runtime_lock_timeout }

    context 'when no options set' do
      it 'returns 30 seconds' do
        is_expected.to eq(30)
      end
    end

    context 'when runtime lock timeout option is set' do
      before do
        job_options[:runtime_lock_timeout] = 300
      end

      it 'returns the override value' do
        is_expected.to eq(300)
      end
    end
  end

  describe '#job_id' do
    subject { instance.job_id }

    it 'returns the job_id from the options' do
      is_expected.to eq(:my_job)
    end
  end

  describe '.lock_driver' do
    subject { job_class.lock_driver(:driver) }

    let(:driver) do
      Module.new do
        # naive implementation for tests
        def worker_lock
          yield OpenStruct.new(extend!: true)
        end
      end
    end
    let(:job_class) { Class.new(described_class) }

    context 'when the driver file exists' do
      before do
        allow(job_class).to receive(:require).with('process_balancer/lock/driver')
        stub_const('ProcessBalancer::Lock::Driver', driver)
      end

      it 'includes the driver into the job class' do
        expect(job_class).to receive(:include).with(ProcessBalancer::Lock::Driver)

        subject
      end

      it 'adds the replacement worker_lock method' do
        subject

        expect(job_class.instance_method(:worker_lock).owner).to eq(driver)
      end
    end

    context 'when the driver file does not exist' do
      before do
        allow(job_class).to receive(:require).with('process_balancer/lock/driver').and_raise(LoadError)
      end

      it 'raises the LoadError' do
        expect { subject }.to raise_error(LoadError)
      end
    end
  end

  describe 'not implemented methods' do
    let(:job_class) do
      Class.new(described_class)
    end

    it 'raises not implemented for worker_lock' do
      expect { instance.send(:worker_lock) {} }.to raise_error(NotImplementedError)
    end

    it 'raises not implemented for lock_records' do
      expect { instance.send(:lock_records) }.to raise_error(NotImplementedError)
    end

    it 'raises not implemented for process_record' do
      expect { instance.send(:process_record, 'r1') }.to raise_error(NotImplementedError)
    end

    it 'raises not implemented for unlock_records' do
      expect { instance.send(:unlock_records) }.to raise_error(NotImplementedError)
    end
  end
end
