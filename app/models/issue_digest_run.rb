# frozen_string_literal: true

class IssueDigestRun < ActiveRecord::Base
  STATUSES = %w[running success partial_failure failed error skipped].freeze
  TRIGGERS = %w[scheduled manual dry_run].freeze

  belongs_to :issue_digest_rule
  has_many :issue_digest_deliveries, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validates :started_at, presence: true
  validates :recipients_count,
            :emails_sent_count,
            :emails_failed_count,
            :issues_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent_first, -> { order(started_at: :desc) }
end
