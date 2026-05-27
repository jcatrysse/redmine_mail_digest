# frozen_string_literal: true

module IssueDigest
  class LockManager
    LOCK_KEY = 'issue_digest_send'.bytes.sum.freeze

    def self.with_lock(&block)
      adapter = ActiveRecord::Base.connection.adapter_name.downcase
      if adapter.include?('postgresql')
        pg_lock(&block)
      else
        file_lock(&block)
      end
    end

    def self.pg_lock(&block)
      result = false
      ActiveRecord::Base.connection.transaction do
        acquired = ActiveRecord::Base.connection.execute(
          "SELECT pg_try_advisory_xact_lock(#{LOCK_KEY})"
        ).first['pg_try_advisory_xact_lock']

        if acquired
          result = block.call
        else
          Rails.logger.warn '[IssueDigest] Could not acquire advisory lock; another process may be running.'
        end
      end
      result
    end
    private_class_method :pg_lock

    def self.file_lock(&block)
      lock_file = Rails.root.join('tmp', 'issue_digest.lock')
      File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |f|
        if f.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            block.call
          ensure
            f.flock(File::LOCK_UN)
          end
        else
          Rails.logger.warn '[IssueDigest] Could not acquire file lock; another process may be running.'
          false
        end
      end
    end
    private_class_method :file_lock
  end
end
