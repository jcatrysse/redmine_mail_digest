# frozen_string_literal: true

class CreateIssueDigestDeliveries < ActiveRecord::Migration[6.1]
  def change
    create_table :issue_digest_deliveries do |t|
      t.references :issue_digest_run,
                   null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'idx_issue_digest_deliveries_run_id' }
      t.references :user, foreign_key: true
      t.string :email, null: false, limit: 255
      t.string :status, null: false, default: 'sent', limit: 20
      t.integer :issues_count, null: false, default: 0
      t.datetime :sent_at
      t.text :error_message
      t.timestamps
    end

    add_index :issue_digest_deliveries, :status
  end
end
