# frozen_string_literal: true

require 'mock_redis'

RSpec.shared_context 'with redis' do
  let(:redis) { MockRedis.new }

  before do
    allow(ProcessBalancer).to receive(:redis).and_yield(redis)
  end
end
