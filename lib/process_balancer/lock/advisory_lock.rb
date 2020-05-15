# frozen_string_literal: true

module ProcessBalancer
  module Lock
    # This is lock implementation using advisory locks on the database via the with_advisory_lock gem
    module AdvisoryLock
      # class to wrap the lock handling and provide the "extend!" method contract
      class DummyLock
        def extend!; end
      end

      def worker_lock
        key = "worker_lock_#{job_id}_#{worker_index}"
        lock = DummyLock.new
        ActiveRecord::Base.with_advisory_lock(key) do
          yield lock
        end
      end
    end
  end
end
