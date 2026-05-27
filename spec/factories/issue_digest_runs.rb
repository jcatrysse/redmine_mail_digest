# frozen_string_literal: true

FactoryBot.define do
  factory :issue_digest_run do
    association :issue_digest_rule
    started_at { Time.current }
    status { 'success' }
    trigger { 'scheduled' }
    recipients_count { 0 }
    emails_sent_count { 0 }
    emails_failed_count { 0 }
    issues_count { 0 }
  end
end
