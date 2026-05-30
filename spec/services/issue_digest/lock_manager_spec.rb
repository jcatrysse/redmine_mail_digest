# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::LockManager, type: :service do
  describe '.with_lock' do
    context 'file-based lock (non-PostgreSQL stub)' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return('SQLite')
      end

      it 'executes the block when the lock is acquired' do
        result = described_class.with_lock { :executed }
        expect(result).to eq(:executed)
      end

      it 'releases the lock after the block completes' do
        described_class.with_lock { :ok }
        # A second call should succeed (lock not held)
        result = described_class.with_lock { :second }
        expect(result).to eq(:second)
      end

      it 'releases the lock even when the block raises an exception' do
        expect do
          described_class.with_lock { raise 'oops' }
        end.to raise_error(RuntimeError, 'oops')

        # Lock must be released; second call succeeds
        result = described_class.with_lock { :after_raise }
        expect(result).to eq(:after_raise)
      end
    end

    context 'PostgreSQL advisory lock' do
      let(:pg_acquired) { [{ 'pg_try_advisory_lock' => true }] }
      let(:pg_busy)     { [{ 'pg_try_advisory_lock' => false }] }
      let(:pg_unlock)   { [{ 'pg_advisory_unlock' => true }] }

      before do
        allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return('PostgreSQL')
      end

      it 'executes the block when lock is acquired' do
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .with(/pg_try_advisory_lock/).and_return(pg_acquired)
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .with(/pg_advisory_unlock/).and_return(pg_unlock)
        result = described_class.with_lock { :pg_executed }
        expect(result).to eq(:pg_executed)
      end

      it 'returns false and logs a warning when lock is not acquired' do
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .with(/pg_try_advisory_lock/).and_return(pg_busy)
        expect(Rails.logger).to receive(:warn).with(/Could not acquire advisory lock/)
        result = described_class.with_lock { :should_not_run }
        expect(result).to be false
      end
    end
  end
end
