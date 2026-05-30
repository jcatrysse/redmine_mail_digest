# frozen_string_literal: true

namespace :redmine do
  namespace :issue_digest do
    desc 'Send due issue digest emails. ENV: DRY_RUN, PROJECT_IDENTIFIER, RULE_ID, VERBOSE, FORCE, MANUAL'
    task send: :environment do
      dry_run            = ENV['DRY_RUN'] == '1'
      project_identifier = ENV['PROJECT_IDENTIFIER'].presence
      rule_id            = ENV['RULE_ID'].presence
      verbose            = ENV['VERBOSE'] == '1'
      manual             = ENV['MANUAL'] == '1'
      force              = ENV['FORCE'] == '1' || manual
      trigger            = manual ? :manual : :scheduled
      started_at_utc     = Time.current.utc

      Rails.logger.info "[IssueDigest] Starting at #{started_at_utc.iso8601} (dry_run=#{dry_run}, force=#{force})"
      puts "[IssueDigest] Starting at #{started_at_utc.iso8601} (dry_run=#{dry_run}, force=#{force})" if verbose

      processed = 0
      emails    = 0
      failures  = 0

      lock_result = IssueDigest::LockManager.with_lock do
        Rails.logger.info '[IssueDigest] Lock acquired'

        # SQL pre-filter so we never load every rule into memory (S3). The date
        # window is widened by ±1 day on purpose: start_on/end_on are evaluated
        # in each rule's own timezone by ScheduleEvaluator#due?, which can differ
        # from the server date by a day. Keeping the prefilter loose avoids
        # dropping a rule that is valid in its timezone; due? remains the
        # authoritative check.
        today = Date.current
        scope = IssueDigestRule
                .joins(:project)
                .joins('INNER JOIN enabled_modules ON enabled_modules.project_id = projects.id')
                .where(enabled_modules: { name: 'issue_digest' })
                .where("#{Project.table_name}.status != ?", Project::STATUS_ARCHIVED)
                .where(active: true)
                .where('start_on IS NULL OR start_on <= ?', today + 1)
                .where('end_on IS NULL OR end_on >= ?', today - 1)
                .includes(:project, :query)

        scope = scope.where("#{Project.table_name}.identifier = ?", project_identifier) if project_identifier
        scope = scope.where(id: rule_id) if rule_id
        # MANUAL=1 without RULE_ID is intentionally scoped to manual schedule
        # rules only. MANUAL=1 with RULE_ID remains a deliberate one-off run of
        # that specific rule, regardless of its schedule_type. FORCE=1 keeps the
        # broader operator-controlled resend semantics.
        scope = scope.where(schedule_type: 'manual') if manual && rule_id.blank?

        rules = scope.to_a

        if rules.size > 10_000
          Rails.logger.warn "[IssueDigest] WARNING: #{rules.size} rules to evaluate; performance may be degraded"
        end

        current_time = Time.current
        due_rules = rules.select do |r|
          force || IssueDigest::ScheduleEvaluator.new(r, time: current_time).due?
        end

        Rails.logger.info "[IssueDigest] Found #{due_rules.size} due rules"
        puts "[IssueDigest] Found #{due_rules.size} due rules" if verbose

        due_rules.each do |rule|
          # Defense-in-depth atomic schedule_key claim (skipped on force/dry_run)
          schedule_key = IssueDigest::ScheduleEvaluator.new(rule, time: current_time, force: force).compute_schedule_key

          # Only the genuinely-claimed scheduled window persists its key on the
          # run record. Forced/dry runs leave it nil so they never collide with
          # the (issue_digest_rule_id, schedule_key) unique index, which protects
          # against duplicate scheduled run records (M8).
          persisted_schedule_key = nil

          unless dry_run || force
            claimed = IssueDigestRule
                      .where(id: rule.id)
                      .where('last_schedule_key IS NULL OR last_schedule_key != ?', schedule_key)
                      .update_all(last_schedule_key: schedule_key, last_run_at: Time.current.utc)

            if claimed.zero?
              Rails.logger.info "[IssueDigest] Rule ##{rule.id}: window already claimed (key=#{schedule_key}); skipping"
              next
            end
            rule.reload
            persisted_schedule_key = schedule_key
          end

          Rails.logger.info "[IssueDigest] Processing rule ##{rule.id}: #{rule.name.inspect} (project: #{rule.project.identifier})"
          puts "[IssueDigest] Processing rule ##{rule.id}: #{rule.name} (project: #{rule.project.identifier})" if verbose

          begin
            sender = IssueDigest::DigestSender.new(
              rule,
              dry_run: dry_run,
              trigger: trigger,
              schedule_key: persisted_schedule_key
            )
            result = sender.send
            processed += 1

            if dry_run
              if result.is_a?(Hash)
                puts "[IssueDigest] Rule ##{rule.id}: DRY_RUN summary: #{result[:plans].size} plans (#{result[:recipients_count]} recipients)" if verbose
              end
            elsif result.is_a?(IssueDigestRun)
              emails   += result.emails_sent_count.to_i
              failures += result.emails_failed_count.to_i
              Rails.logger.info "[IssueDigest] Rule ##{rule.id}: completed (#{result.status}, #{result.emails_sent_count} emails sent, #{result.emails_failed_count} failed)"
              puts "[IssueDigest] Rule ##{rule.id}: completed (#{result.status}, sent=#{result.emails_sent_count}, failed=#{result.emails_failed_count})" if verbose
            end
          rescue StandardError => e
            Rails.logger.error "[IssueDigest] Rule ##{rule.id}: unhandled error: #{e.class}: #{e.message.to_s.truncate(200)}"
          end
        end

        :ok
      end

      if lock_result == false
        Rails.logger.warn '[IssueDigest] Could not acquire lock; another process may be running. Exiting.'
        puts '[IssueDigest] Could not acquire lock; another process may be running. Exiting.' if verbose
      end

      finished_at_utc = Time.current.utc
      Rails.logger.info "[IssueDigest] Finished at #{finished_at_utc.iso8601} (#{processed} rules, #{emails} emails, #{failures} failures)"
      puts "[IssueDigest] Finished at #{finished_at_utc.iso8601} (#{processed} rules, #{emails} emails, #{failures} failures)" if verbose
    end

    desc 'Prune old IssueDigestRun records (and their deliveries) according to run_history_retention_days'
    task cleanup: :environment do
      settings       = Setting.plugin_redmine_mail_digest rescue {}
      retention_days = (settings && settings['run_history_retention_days']).to_i
      retention_days = 36_500 if retention_days > 36_500

      if retention_days <= 0
        Rails.logger.info '[IssueDigest] Cleanup: run_history_retention_days is 0; retaining all records.'
        next
      end

      cutoff = retention_days.days.ago

      Rails.logger.info "[IssueDigest] Cleanup: deleting runs older than #{retention_days} days"

      old_run_ids = IssueDigestRun.where('started_at < ?', cutoff).pluck(:id)
      run_count   = old_run_ids.size
      del_count   = IssueDigestDelivery.where(issue_digest_run_id: old_run_ids).count
      IssueDigestDelivery.where(issue_digest_run_id: old_run_ids).delete_all
      IssueDigestRun.where(id: old_run_ids).delete_all

      Rails.logger.info "[IssueDigest] Cleanup: deleted #{run_count} runs, #{del_count} deliveries"
      puts "[IssueDigest] Cleanup: deleted #{run_count} runs, #{del_count} deliveries"
    end
  end
end
