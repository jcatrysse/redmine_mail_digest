# frozen_string_literal: true

module IssueDigest
  # Orchestrates delivery for a single IssueDigestRule:
  # 1. Resolves recipients
  # 2. For each recipient, resolves their visible issues
  # 3. Sends the digest email (via IssueDigestMailer)
  # 4. Records per-recipient delivery results and the overall run
  #
  # Issue visibility is enforced per-recipient via IssueResolver
  # (which always starts with Issue.visible(user)); no shared issue list
  # is ever sent to multiple recipients.
  #
  # In dry_run mode, no DB writes happen and no emails are delivered;
  # the planned actions are echoed to STDOUT.
  class DigestSender
    DEFAULT_MAX_ISSUES_PER_EMAIL = 500
    MIN_MAX_ISSUES_PER_EMAIL = 1
    MAX_MAX_ISSUES_PER_EMAIL = 5000

    attr_reader :rule

    def initialize(rule, dry_run: false, trigger: nil, schedule_key: nil, emit_stdout: true)
      @rule         = rule
      @dry_run      = dry_run
      @trigger      = (trigger || (dry_run ? :dry_run : :scheduled)).to_s
      @schedule_key = schedule_key
      @emit_stdout  = emit_stdout
    end

    # Executes the full delivery flow.
    # Returns the IssueDigestRun (or a value object hash in dry_run mode).
    def send
      if @dry_run
        return run_dry
      end

      recorder = IssueDigest::RunRecorder.new(@rule, trigger: @trigger, schedule_key: @schedule_key)
      recorder.start

      begin
        # Detect any saved-query issues once (orphaned query, visibility) so the
        # warning can be attached to the run regardless of recipient count.
        query_warning = detect_query_warning

        # Recipient discovery uses the *filtered* matching scope so that
        # assignees/authors/watchers modes only resolve users tied to issues the
        # rule actually matches (not every historical assignee in the project).
        candidate_scope = IssueDigest::IssueResolver.new(@rule, user: nil).resolve
        recipients = IssueDigest::RecipientResolver.new(@rule, issues_scope: candidate_scope).recipients

        if recipients.empty?
          Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: no recipients resolved; skipping"
          recorder.finish('skipped', recipients_count: 0, warning_message: query_warning)
          return recorder.run
        end

        sent_count    = 0
        failed_count  = 0
        total_issues  = 0

        recipients.each do |recipient|
          result = deliver_to(recipient, recorder, query_warning: query_warning)
          case result[:status]
          when :sent
            sent_count   += 1
            total_issues += result[:issues_count]
          when :failed
            failed_count += 1
          end
        end

        final_status = compute_final_status(recipients.size, sent_count, failed_count)
        recorder.finish(final_status,
                        recipients_count: recipients.size,
                        emails_sent_count: sent_count,
                        emails_failed_count: failed_count,
                        issues_count: total_issues,
                        warning_message: query_warning)

        # last_success_at tracks "last time at least one email was actually delivered",
        # not "last time the rule ran". Skipped runs (no recipients, or everyone had
        # zero matching issues) intentionally leave this timestamp unchanged.
        if %w[success partial_failure].include?(final_status) && sent_count.positive?
          begin
            @rule.update_column(:last_success_at, Time.current.utc)
          rescue StandardError => e
            Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: failed to update last_success_at: #{e.class}: #{e.message}"
          end
        end

        recorder.run
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: DigestSender failed: #{e.class}: #{e.message.to_s.truncate(200)}"
        recorder.finish('error', error_message: "#{e.class}: #{e.message}")
        recorder.run
      end
    end

    private

    def run_dry
      query_warning   = detect_query_warning
      candidate_scope = IssueDigest::IssueResolver.new(@rule, user: nil).resolve
      recipients      = IssueDigest::RecipientResolver.new(@rule, issues_scope: candidate_scope).recipients

      # Collect the human-readable lines into summary[:log] so callers (the rake
      # task CLI *and* the in-UI preview) share one source of truth. The lines
      # are still echoed to STDOUT to preserve the existing `DRY_RUN=1` output.
      log = []
      emit = lambda do |line|
        puts line if @emit_stdout
        log << line
      end

      emit.call "[DRY_RUN] Rule ##{@rule.id} (#{@rule.name}): #{recipients.size} recipients"
      emit.call "  [DRY_RUN] WARNING: #{query_warning}" if query_warning.present?

      summary = { rule_id: @rule.id, recipients_count: recipients.size, plans: [],
                  warning_message: query_warning, log: log }

      recipients.each do |recipient|
        user = recipient.user
        # Mirror the real run: when the saved query is unusable every delivery
        # fails, so the dry-run preview must report FAIL rather than issue counts
        # computed from the (broader) unfiltered scope.
        if query_warning.present?
          emit.call "  [DRY_RUN] Would FAIL user ##{user.id} (saved query unusable; no digest sent)"
          summary[:plans] << { user_id: user.id, action: :fail, issues_count: 0 }
          next
        end

        issues = IssueDigest::IssueResolver.new(@rule, user: user, recipient_modes: recipient.modes)
                                           .resolve.limit(max_issues_per_email)
        count  = issues.count

        if count.zero? && !@rule.send_empty?
          emit.call "  [DRY_RUN] Would skip user ##{user.id} (0 issues, send_empty=false)"
          summary[:plans] << { user_id: user.id, action: :skip, issues_count: 0 }
          next
        end

        emit.call "  [DRY_RUN] Would send #{count} issues to user ##{user.id}"
        summary[:plans] << { user_id: user.id, action: :send, issues_count: count }
      end

      summary
    end

    # Returns a hash {status:, issues_count:} for the per-recipient outcome.
    def deliver_to(recipient, recorder, query_warning: nil)
      user = recipient.user
      if query_warning.present?
        recorder.record_delivery(user, 'failed', issues_count: 0, error_message: query_warning.to_s.truncate(2000))
        return { status: :failed, issues_count: 0 }
      end

      issues = IssueDigest::IssueResolver.new(@rule, user: user, recipient_modes: recipient.modes)
                                         .resolve.limit(max_issues_per_email)
      issues = preload_issue_associations(issues).to_a
      issues_count = issues.size

      if issues.empty? && !@rule.send_empty?
        recorder.record_delivery(user, 'skipped', issues_count: 0)
        return { status: :skipped, issues_count: 0 }
      end

      grouped_issues = group_issues(issues, @rule.group_by)

      begin
        IssueDigestMailer.digest_email(@rule, user, issues, grouped_issues).deliver_now
        recorder.record_delivery(user, 'sent', issues_count: issues_count, sent_at: Time.current)
        { status: :sent, issues_count: issues_count }
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: delivery to user ##{user.id} failed: #{e.class}: #{e.message.to_s.truncate(200)}"
        recorder.record_delivery(user, 'failed', issues_count: issues_count, error_message: e.message.to_s.truncate(2000))
        { status: :failed, issues_count: issues_count }
      end
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: issue resolution for user ##{user.id} failed: #{e.class}: #{e.message.to_s.truncate(200)}"
      recorder.record_delivery(user, 'failed', issues_count: 0, error_message: e.message.to_s.truncate(2000))
      { status: :failed, issues_count: 0 }
    end

    def preload_issue_associations(scope)
      scope.includes(:tracker, :status, :priority, :assigned_to, :fixed_version, :category)
    end

    # Returns nil for group_by='none'; otherwise returns a hash {label => [issues]}.
    def group_issues(issues, group_by)
      return nil if group_by.blank? || group_by == 'none'
      return nil unless IssueDigestRule::GROUP_BY_OPTIONS.include?(group_by)

      issues.group_by { |issue| group_label(issue, group_by) }
    end

    def group_label(issue, group_by)
      case group_by
      when 'assignee'
        issue.assigned_to&.name || I18n.t('redmine_mail_digest.mailer.unassigned', default: '(unassigned)')
      when 'priority'
        issue.priority&.name || I18n.t('redmine_mail_digest.mailer.no_priority', default: '(no priority)')
      when 'tracker'
        issue.tracker&.name || I18n.t('redmine_mail_digest.mailer.no_tracker', default: '(no tracker)')
      when 'status'
        issue.status&.name  || I18n.t('redmine_mail_digest.mailer.no_status', default: '(no status)')
      when 'version'
        issue.fixed_version&.name || I18n.t('redmine_mail_digest.mailer.no_version', default: '(no version)')
      when 'category'
        issue.category&.name || I18n.t('redmine_mail_digest.mailer.no_category', default: '(no category)')
      end
    end

    def compute_final_status(recipients_count, sent, failed)
      return 'skipped' if recipients_count.zero?
      return 'success' if failed.zero? && sent.positive?
      return 'failed'  if sent.zero? && failed.positive?
      return 'partial_failure' if sent.positive? && failed.positive?

      # All recipients had 0 issues and send_empty=false → skipped
      'skipped'
    end

    def detect_query_warning
      return nil if @rule.query_id.blank?

      adapter = IssueDigest::QueryAdapter.new(@rule)
      adapter.apply_to(Issue.all)
      adapter.warning
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: detect_query_warning failed: #{e.class}: #{e.message}"
      nil
    end

    def max_issues_per_email
      settings = Setting.respond_to?(:plugin_redmine_mail_digest) ? Setting.plugin_redmine_mail_digest : nil
      value = settings && settings['max_issues_per_email']
      self.class.clamped_max_issues_per_email(value)
    end

    def self.clamped_max_issues_per_email(value)
      number = value.present? ? value.to_i : DEFAULT_MAX_ISSUES_PER_EMAIL
      number = DEFAULT_MAX_ISSUES_PER_EMAIL if number <= 0
      [[number, MIN_MAX_ISSUES_PER_EMAIL].max, MAX_MAX_ISSUES_PER_EMAIL].min
    end
  end
end
