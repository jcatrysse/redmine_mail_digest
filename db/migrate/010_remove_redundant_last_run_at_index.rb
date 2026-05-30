# frozen_string_literal: true

class RemoveRedundantLastRunAtIndex < ActiveRecord::Migration[6.1]
  def up
    # The standalone last_run_at index is redundant: the compound index
    # (active, project_id, last_run_at) added in migration 001 already covers
    # any query that filters on last_run_at together with active/project_id,
    # and no query in the codebase filters on last_run_at alone.
    remove_index :issue_digest_rules, :last_run_at if index_exists?(:issue_digest_rules, :last_run_at)
  end

  def down
    add_index :issue_digest_rules, :last_run_at unless index_exists?(:issue_digest_rules, :last_run_at)
  end
end
