# frozen_string_literal: true

# "Include issues starting soon" (inclusion option, OR-combined like
# include_due_soon) and "Only unassigned issues" (narrowing, AND-combined).
# Defaults keep every existing rule's behaviour unchanged.
class AddStartingSoonAndUnassignedToIssueDigestRules < ActiveRecord::Migration[6.1]
  def change
    add_column :issue_digest_rules, :include_starting_soon, :boolean, default: false, null: false
    add_column :issue_digest_rules, :starting_soon_days, :integer, default: 7, null: false
    add_column :issue_digest_rules, :filter_unassigned, :boolean, default: false, null: false
  end
end
