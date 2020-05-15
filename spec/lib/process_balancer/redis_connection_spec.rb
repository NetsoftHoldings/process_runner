# frozen_string_literal: true

require 'process_balancer/redis_connection'

RSpec.describe ProcessBalancer::RedisConnection do
  let(:redis) { MockRedis.new }
  let(:options) { {} }

  before do
    allow(Redis).to receive(:new).and_return(redis)
  end

  describe '.create' do
    subject { described_class.create(options) }

    it 'creates a connection pool' do
      is_expected.to be_a(ConnectionPool)
    end

    context 'when no config passed' do
      it 'uses the default pool timeout and size' do
        expect(ConnectionPool).to receive(:new).with(timeout: 1, size: 2)

        subject
      end
    end

    context 'when config passed' do
      let(:options) { {pool_timeout: 5, size: 5} }

      it 'uses the config values for pool timeout and size' do
        expect(ConnectionPool).to receive(:new).with(timeout: 5, size: 5)

        subject
      end
    end
  end

  describe 'pool connection' do
    subject { pool.with {} }

    let(:pool) { described_class.create(options) }
    let(:env) { {REDIS_URL: nil, REDIS_PROVIDER: nil} }

    around do |ex|
      with_modified_env(env, &ex)
    end

    describe 'redis URL location' do
      context 'with no env' do
        it 'uses nil URL' do
          expect(described_class).to receive(:build_client).with(url: nil).and_return(redis)

          subject
        end
      end

      context 'with only REDIS_URL env' do
        let(:env) { {REDIS_URL: 'redis://localhost/5', REDIS_PROVIDER: nil} }

        it 'uses the REDIS URL' do
          expect(described_class).to receive(:build_client).with(url: 'redis://localhost/5').and_return(redis)

          subject
        end
      end

      context 'with REDIS_PROVIDER env set to a no-existent ENV' do
        let(:env) { {REDIS_URL: 'redis://localhost/5', REDIS_PROVIDER: 'BAD_ENV'} }

        it 'uses nil URL' do
          expect(described_class).to receive(:build_client).with(url: nil).and_return(redis)

          subject
        end
      end

      context 'with REDIS_PROVIDER env set to a URL' do
        let(:env) { {REDIS_URL: 'redis://localhost/5', REDIS_PROVIDER: 'redis://localhost/1'} }

        it 'logs an error to the logger' do
          expect(ProcessBalancer.logger).to receive(:error)

          subject
        end

        it 'uses nil URL' do
          allow(ProcessBalancer.logger).to receive(:error)

          expect(described_class).to receive(:build_client).with(url: nil).and_return(redis)

          subject
        end
      end

      context 'with REDIS_PROVIDER env set to a correct ENV' do
        let(:env) { {REDIS_URL: 'redis://localhost/5', REDIS_PROVIDER: 'GOOD_ENV', GOOD_ENV: 'redis://localhost/1'} }

        it 'uses the URL in the alternate ENV' do
          expect(described_class).to receive(:build_client).with(url: 'redis://localhost/1').and_return(redis)

          subject
        end
      end
    end

    describe 'redis options' do
      it 'sets the default driver options' do
        expect(Redis).to receive(:new).with(driver: Redis::Connection::Ruby, reconnect_attempts: 1, url: nil)

        subject
      end

      it 'yields a Redis instance to the pool' do
        pool.with { |c| expect(c).to eq(redis) }
      end

      context 'with namespace' do
        let(:options) { {namespace: 'test'} }

        it 'does not send that to the redis driver' do
          expect(Redis).to receive(:new).with(driver: Redis::Connection::Ruby, reconnect_attempts: 1, url: nil)

          subject
        end

        it 'yields a Redis::Namespace instance to the pool' do
          pool.with { |c| expect(c).to be_a(Redis::Namespace) }
        end

        context 'when the namespace gem is not loaded' do
          before do
            allow(Redis::Namespace).to receive(:new).and_raise(LoadError)
            allow(described_class).to receive(:exit)
          end

          it 'logs an error' do
            expect(ProcessBalancer.logger).to receive(:error).and_raise(RuntimeError)

            subject
          rescue StandardError
            nil
          end

          it 'exits the process' do
            allow(ProcessBalancer.logger).to receive(:error)
            expect(described_class).to receive(:exit).with(-127).and_raise(RuntimeError)

            subject
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
