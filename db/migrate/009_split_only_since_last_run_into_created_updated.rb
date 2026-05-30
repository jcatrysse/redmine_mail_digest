# frozen_string_literal: true

# Replace the single `only_since_last_run` flag with two independent,
# cumulative narrowing flags: `since_last_run_created` and
# `since_last_run_updated`.
#
# Previously one checkbox narrowed the digest to issues *created OR updated*
# since the last successful run. Splitting it lets a rule narrow on creation,
# on update, or on both (checking both reproduces the old behaviour).
#
# Backfill: every rule that had `only_since_last_run = true` gets BOTH new flags
# set to true, so existing rules keep their exact behaviour after the upgrade.
#
# A lightweight inline AR class is used for the data backfill so the migration
# never couples to the application model (its serialize/validation callbacks are
# irrelevant here and update_all bypasses them anyway).
class SplitOnlySinceLastRunIntoCreatedUpdated < ActiveRecord::Migration[6.1]
  class MigrationRule < ActiveRecord::Base
    self.table_name = 'issue_digest_rules'
  end

  def up
    unless column_exists?(:issue_digest_rules, :since_last_run_created)
      add_column :issue_digest_rules, :since_last_run_created, :boolean, default: false, null: false
    end
    unless column_exists?(:issue_digest_rules, :since_last_run_updated)
      add_column :issue_digest_rules, :since_last_run_updated, :boolean, default: false, null: false
    end

    if column_exists?(:issue_digest_rules, :only_since_last_run)
      MigrationRule.reset_column_information
      MigrationRule.where(only_since_last_run: true)
                   .update_all(since_last_run_created: true, since_last_run_updated: true)
      remove_column :issue_digest_rules, :only_since_last_run
    end

    MigrationRule.reset_column_information
  end

  def down
    unless column_exists?(:issue_digest_rules, :only_since_last_run)
      add_column :issue_digest_rules, :only_since_last_run, :boolean, default: false, null: false
    end

    MigrationRule.reset_column_information
    # Collapse the two flags back into the single legacy flag: a rule that
    # narrowed on either creation or update maps to the old "since last run".
    MigrationRule.where('since_last_run_created = ? OR since_last_run_updated = ?', true, true)
                 .update_all(only_since_last_run: true)

    remove_column :issue_digest_rules, :since_last_run_created if column_exists?(:issue_digest_rules, :since_last_run_created)
    remove_column :issue_digest_rules, :since_last_run_updated if column_exists?(:issue_digest_rules, :since_last_run_updated)

    MigrationRule.reset_column_information
  end
end
