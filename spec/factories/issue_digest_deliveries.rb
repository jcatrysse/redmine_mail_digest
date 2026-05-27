# frozen_string_literal: true

FactoryBot.define do
  factory :issue_digest_delivery do
    association :issue_digest_run
    sequence(:email) { |n| "recipient#{n}@example.com" }
    status { 'sent' }
    issues_count { 0 }
    sent_at { Time.current }
  end
end
