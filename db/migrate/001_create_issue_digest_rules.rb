# frozen_string_literal: true

class CreateIssueDigestRules < ActiveRecord::Migration[6.1]
  def change
    create_table :issue_digest_rules do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false, limit: 255
      t.boolean :active, null: false, default: true

      # Scheduling
      t.string :schedule_type, null: false, limit: 30
      t.text :schedule_config, null: false, default: '{}'
      t.date :start_on
      t.date :end_on
      t.time :send_time
      t.string :timezone, null: false, default: 'UTC', limit: 64
      t.integer :grace_window_hours, null: false, default: 4
      t.string :last_schedule_key, limit: 100
      t.boolean :business_days_only, null: false, default: false
      t.string :non_business_day_behavior, null: false, default: 'skip', limit: 20

      # Issue filters
      t.integer :query_id
      t.boolean :include_subprojects, null: false, default: false
      t.boolean :include_open, null: false, default: true
      t.boolean :include_closed, null: false, default: false
      t.boolean :include_overdue, null: false, default: false
      t.boolean :include_due_soon, null: false, default: false
      t.integer :due_soon_days, null: false, default: 7
      t.boolean :include_recently_updated, null: false, default: false
      t.integer :recently_updated_days, null: false, default: 7
      t.boolean :include_recently_created, null: false, default: false
      t.integer :recently_created_days, null: false, default: 7
      t.boolean :filter_assigned_to_recipient, null: false, default: false
      t.boolean :filter_watched_by_recipient, null: false, default: false
      t.boolean :filter_authored_by_recipient, null: false, default: false

      # Recipients and email
      t.text :recipient_modes, null: false, default: '[]'
      t.string :group_by, null: false, default: 'none', limit: 20
      t.boolean :send_empty, null: false, default: false
      t.string :email_subject, limit: 255
      t.text :email_intro

      # Run tracking (for display; idempotency uses last_schedule_key)
      t.datetime :last_run_at
      t.datetime :last_success_at

      # Audit
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :issue_digest_rules, :active
    add_index :issue_digest_rules, :query_id
    add_index :issue_digest_rules, :last_run_at
    add_index :issue_digest_rules, :last_schedule_key
    add_index :issue_digest_rules,
              [:active, :project_id, :last_run_at],
              name: 'idx_issue_digest_rules_due'
  end
end
