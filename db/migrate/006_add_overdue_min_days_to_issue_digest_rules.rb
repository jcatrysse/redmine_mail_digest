# frozen_string_literal: true

class AddOverdueMinDaysToIssueDigestRules < ActiveRecord::Migration[6.1]
  def change
    add_column :issue_digest_rules, :overdue_min_days, :integer
  end
end
