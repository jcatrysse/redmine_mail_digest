# frozen_string_literal: true

FactoryBot.define do
  factory :project, class: 'Project' do
    sequence(:name) { |n| "Test Project #{n}" }
    sequence(:identifier) { |n| "test-project-#{n}" }
    status { Project::STATUS_ACTIVE }
    is_public { true }

  end
end
