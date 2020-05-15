# frozen_string_literal: true

require 'process_runner/util'

RSpec.describe ProcessRunner::Util do
  let(:test_class) do
    Class.new do
      include ProcessRunner::Util
    end
  end

  let(:instance) { test_class.new }

  describe '#logger' do
    subject { instance.logger }

    it 'returns the ProcessRunner.logger' do
      allow(ProcessRunner).to receive(:logger).and_return('MyLogger')

      is_expected.to eq('MyLogger')
    end
  end

  describe '#hostname' do
    subject { instance.hostname }

    it 'calls ProcessRunner.hostname' do
      expect(ProcessRunner).to receive(:hostname)

      subject
    end
  end

  describe '#identity' do
    subject { instance.identity }

    it 'calls ProcessRunner.identity' do
      expect(ProcessRunner).to receive(:identity)

      subject
    end
  end

  describe '#redis' do
    it 'forwards to ProcessRunner.redis' do
      block = proc {}
      expect(ProcessRunner).to receive(:redis) { |&b| expect(b).to eq(block) }

      instance.redis(&block)
    end
  end

  describe '#start_thread' do
    subject { instance.start_thread('my_name', &block) }

    let(:block) { proc {} }

    it 'spins up a thread' do
      expect(Thread).to receive(:new)

      subject
    end

    it 'calls the watchdog for the thread' do
      expect(instance).to receive(:watchdog) do |&b|
        expect(b).to eq(block)
      end

      t = subject
      t.join
    end

    describe 'checking thread properties' do
      let(:output) { {} }
      let(:block) { proc { output[:name] = Thread.current.name } }

      it 'sets the thread name' do
        subject.join

        expect(output).to include(name: 'my_name')
      end
    end
  end

  describe '#watchdog' do
    subject { instance.watchdog(&block) }

    let(:block) { proc {} }

    it 'yields control' do
      expect { |y| instance.watchdog(&y) }.to yield_control
    end

    context 'when an exception is raised' do
      let(:block) { proc { raise 'something' } }

      before do
        allow(ProcessRunner.logger).to receive(:error)
      end

      it 'logs the error' do
        expect(ProcessRunner.logger).to receive(:error)

        subject
      rescue StandardError
        nil
      end

      it 're-raises the exception' do
        expect { subject }.to raise_error(RuntimeError, 'something')
      end
    end
  end
end
