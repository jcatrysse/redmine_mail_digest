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

        scope = IssueDigestRule
                .joins(:project)
                .joins('INNER JOIN enabled_modules ON enabled_modules.project_id = projects.id')
                .where(enabled_modules: { name: 'issue_digest' })
                .where("#{Project.table_name}.status != ?", Project::STATUS_ARCHIVED)
                .where(active: true)
                .includes(:project, :query)

        scope = scope.where("#{Project.table_name}.identifier = ?", project_identifier) if project_identifier
        scope = scope.where(id: rule_id) if rule_id

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
          end

          Rails.logger.info "[IssueDigest] Processing rule ##{rule.id}: #{rule.name.inspect} (project: #{rule.project.identifier})"
          puts "[IssueDigest] Processing rule ##{rule.id}: #{rule.name} (project: #{rule.project.identifier})" if verbose

          begin
            sender = IssueDigest::DigestSender.new(
              rule,
              dry_run: dry_run,
              trigger: trigger,
              schedule_key: schedule_key
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
      settings       = Setting.plugin_redmine_digest rescue {}
      retention_days = (settings && settings['run_history_retention_days']).to_i

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
