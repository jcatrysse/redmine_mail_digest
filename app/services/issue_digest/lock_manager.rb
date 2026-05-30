# frozen_string_literal: true

require 'zlib'

module IssueDigest
  class LockManager
    # CRC32 of 'issue_digest_send' — far less likely to collide with other plugins
    # than a simple byte sum. PostgreSQL advisory locks share a single 64-bit namespace
    # per database, so plugin-unique keys matter.
    LOCK_KEY = Zlib.crc32('issue_digest_send').freeze

    def self.with_lock(&block)
      adapter = ActiveRecord::Base.connection.adapter_name.downcase
      if adapter.include?('postgresql')
        pg_lock(&block)
      else
        file_lock(&block)
      end
    end

    def self.pg_lock(&block)
      conn = ActiveRecord::Base.connection
      acquired = conn.execute("SELECT pg_try_advisory_lock(#{LOCK_KEY})").first['pg_try_advisory_lock']
      unless acquired
        Rails.logger.warn '[IssueDigest] Could not acquire advisory lock; another process may be running.'
        return false
      end
      begin
        block.call
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})")
      end
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
