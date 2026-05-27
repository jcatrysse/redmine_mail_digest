# frozen_string_literal: true

FactoryBot.define do
  factory :issue_status, class: 'IssueStatus' do
    sequence(:name) { |n| "Status #{n}" }
    is_closed { false }
  end

  factory :tracker, class: 'Tracker' do
    sequence(:name) { |n| "Tracker #{n}" }
    association :default_status, factory: :issue_status
  end

  factory :issue_priority, class: 'IssuePriority' do
    sequence(:name) { |n| "Priority #{n}" }
    type { 'IssuePriority' }
    is_default { false }
  end

  factory :issue, class: 'Issue' do
    sequence(:subject) { |n| "Issue #{n}" }
    association :project, factory: :project
    association :author, factory: :user
    association :tracker, factory: :tracker
    association :status, factory: :issue_status
    association :priority, factory: :issue_priority

    trait :closed do
      association :status, factory: :issue_status, is_closed: true
    end

    trait :overdue do
      due_date { 3.days.ago.to_date }
    end

    trait :due_soon do
      due_date { 3.days.from_now.to_date }
    end
  end
end
