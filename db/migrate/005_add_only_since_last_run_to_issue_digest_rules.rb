# frozen_string_literal: true

class AddOnlySinceLastRunToIssueDigestRules < ActiveRecord::Migration[6.1]
  def change
    add_column :issue_digest_rules, :only_since_last_run, :boolean, default: false, null: false
  end
end
