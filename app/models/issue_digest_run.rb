# frozen_string_literal: true

# Redmine 6+ translates attribute names (the field_* locale keys used by form
# labels and error messages) in ApplicationRecord; Redmine 5.1 has no
# ApplicationRecord and patches ActiveRecord::Base instead.
class IssueDigestRun < (defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base)
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
