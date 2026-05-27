# frozen_string_literal: true

class IssueDigestDelivery < ActiveRecord::Base
  STATUSES = %w[sent failed skipped].freeze

  belongs_to :issue_digest_run
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :email, presence: true, length: { maximum: 255 }
  validates :issues_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
