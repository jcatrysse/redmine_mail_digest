# frozen_string_literal: true

FactoryBot.define do
  factory :issue_digest_rule do
    association :project, factory: :project
    sequence(:name) { |n| "Digest Rule #{n}" }
    active { true }
    schedule_type { 'daily' }
    schedule_config { {} }
    send_time { '08:00:00' }
    timezone { 'UTC' }
    grace_window_hours { 24 }
    business_days_only { false }
    non_business_day_behavior { 'skip' }
    include_open { true }
    recipient_modes { ['project_members'] }
    group_by { 'none' }
    association :created_by, factory: :user

    trait :weekly do
      schedule_type { 'weekly' }
      schedule_config { { 'day' => 1 } }
    end

    trait :weekdays do
      schedule_type { 'weekdays' }
      schedule_config { { 'days' => [1, 3, 5] } }
    end

    trait :monthly_date do
      schedule_type { 'monthly_date' }
      schedule_config { { 'day' => 15 } }
    end

    trait :monthly_last_day do
      schedule_type { 'monthly_last_day' }
      schedule_config { {} }
    end

    trait :interval_days do
      schedule_type { 'interval_days' }
      schedule_config { { 'every' => 3 } }
    end

    trait :interval_weeks do
      schedule_type { 'interval_weeks' }
      schedule_config { { 'every' => 2 } }
    end

    trait :interval_hours do
      schedule_type { 'interval_hours' }
      schedule_config { { 'every' => 2 } }
      send_time { nil }
    end

    trait :interval_minutes do
      schedule_type { 'interval_minutes' }
      schedule_config { { 'every' => 15 } }
      send_time { nil }
    end

    trait :manual do
      schedule_type { 'manual' }
      schedule_config { {} }
      send_time { nil }
    end

    trait :disabled do
      active { false }
    end

    trait :expired do
      end_on { 1.day.ago.to_date }
    end

    trait :pending do
      start_on { 1.day.from_now.to_date }
    end
  end
end
