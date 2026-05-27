# frozen_string_literal: true

module IssueDigest
  # Creates and updates IssueDigestRun and IssueDigestDelivery records on
  # behalf of DigestSender. All DB writes happen here; the sender remains
  # focused on orchestration.
  #
  # Failures inside the recorder are logged but never raised — a recording
  # error should not abort the rest of the run.
  class RunRecorder
    VALID_TRIGGERS  = %w[scheduled manual dry_run].freeze
    DELIVERY_STATUSES = %w[sent failed skipped].freeze
    RUN_STATUSES = %w[running success partial_failure failed error skipped].freeze

    attr_reader :run

    def initialize(rule, trigger: :scheduled, schedule_key: nil)
      @rule         = rule
      @trigger      = trigger.to_s
      @schedule_key = schedule_key
      @run          = nil
    end

    # Creates the IssueDigestRun row with status='running' and returns it.
    # Returns nil and logs if creation fails (caller can decide how to proceed).
    def start
      raise ArgumentError, "invalid trigger: #{@trigger}" unless VALID_TRIGGERS.include?(@trigger)

      begin
        @run = IssueDigestRun.create!(
          issue_digest_rule: @rule,
          status: 'running',
          trigger: @trigger,
          started_at: Time.current,
          schedule_key: @schedule_key
        )
        @run
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule&.id}: failed to create run record: #{e.class}: #{e.message}"
        nil
      end
    end

    # Records a per-recipient delivery row.
    # status: one of 'sent', 'failed', 'skipped'.
    def record_delivery(user, status, issues_count: 0, error_message: nil, sent_at: nil)
      status = status.to_s
      raise ArgumentError, "invalid delivery status: #{status}" unless DELIVERY_STATUSES.include?(status)

      begin
        IssueDigestDelivery.create!(
          issue_digest_run: @run,
          user: user,
          email: user&.mail.to_s,
          status: status,
          issues_count: issues_count.to_i,
          sent_at: sent_at,
          error_message: error_message&.to_s&.truncate(2000)
        )
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule&.id}: failed to record delivery for user ##{user&.id}: #{e.class}: #{e.message}"
        nil
      end
    end

    # Finalizes the run with the given counts and status.
    def finish(status, recipients_count: 0, emails_sent_count: 0, emails_failed_count: 0,
               issues_count: 0, error_message: nil, warning_message: nil)
      status = status.to_s
      raise ArgumentError, "invalid run status: #{status}" unless RUN_STATUSES.include?(status)
      return nil if @run.nil?

      begin
        @run.update!(
          status: status,
          finished_at: Time.current,
          recipients_count: recipients_count.to_i,
          emails_sent_count: emails_sent_count.to_i,
          emails_failed_count: emails_failed_count.to_i,
          issues_count: issues_count.to_i,
          warning_message: warning_message&.to_s&.truncate(2000),
          error_message: error_message&.to_s&.truncate(2000)
        )
        @run
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule&.id}: failed to finalize run ##{@run&.id}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
