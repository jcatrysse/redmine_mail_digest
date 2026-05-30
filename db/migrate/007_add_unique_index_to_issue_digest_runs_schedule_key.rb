# frozen_string_literal: true

# Defense-in-depth idempotency (M8): prevent more than one scheduled run record
# per (rule, schedule_key). The primary guard is the atomic last_schedule_key
# claim on issue_digest_rules; this DB constraint catches the edge cases (e.g.
# a crash/retry, or a future change to force/manual behaviour).
#
# A composite unique index is portable across PostgreSQL, MySQL and SQLite
# because all three treat NULLs as distinct, so the many forced/manual/dry runs
# (which persist a NULL schedule_key) remain unconstrained.
class AddUniqueIndexToIssueDigestRunsScheduleKey < ActiveRecord::Migration[6.1]
  INDEX_NAME = 'idx_issue_digest_runs_rule_schedule_key'

  def up
    deduplicate_existing_schedule_keys!

    add_index :issue_digest_runs,
              [:issue_digest_rule_id, :schedule_key],
              unique: true,
              name: INDEX_NAME
  end

  def down
    remove_index :issue_digest_runs, name: INDEX_NAME
  end

  private

  # Older data may contain duplicate (rule, schedule_key) rows (e.g. forced
  # re-runs that reused a window key). Keep the earliest row per key and clear
  # schedule_key on the rest so the unique index can be created safely.
  def deduplicate_existing_schedule_keys!
    duplicates = IssueDigestRun.where.not(schedule_key: nil)
                               .group(:issue_digest_rule_id, :schedule_key)
                               .having('COUNT(*) > 1')
                               .pluck(:issue_digest_rule_id, :schedule_key)

    duplicates.each do |rule_id, key|
      keep_id = IssueDigestRun.where(issue_digest_rule_id: rule_id, schedule_key: key)
                              .order(:id)
                              .limit(1)
                              .pluck(:id)
                              .first
      IssueDigestRun.where(issue_digest_rule_id: rule_id, schedule_key: key)
                    .where.not(id: keep_id)
                    .update_all(schedule_key: nil)
    end
  end
end
