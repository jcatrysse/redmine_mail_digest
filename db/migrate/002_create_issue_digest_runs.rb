# frozen_string_literal: true

class CreateIssueDigestRuns < ActiveRecord::Migration[6.1]
  def change
    create_table :issue_digest_runs do |t|
      t.references :issue_digest_rule,
                   null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'idx_issue_digest_runs_rule_id' }
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :status, null: false, default: 'running', limit: 20
      t.string :trigger, null: false, default: 'scheduled', limit: 20
      t.string :schedule_key, limit: 100
      t.integer :recipients_count, null: false, default: 0
      t.integer :emails_sent_count, null: false, default: 0
      t.integer :emails_failed_count, null: false, default: 0
      t.integer :issues_count, null: false, default: 0
      t.text :warning_message
      t.text :error_message
      t.timestamps
    end

    add_index :issue_digest_runs, :status
    add_index :issue_digest_runs, :started_at
    add_index :issue_digest_runs,
              [:issue_digest_rule_id, :started_at],
              name: 'idx_issue_digest_runs_rule_started'
  end
end
