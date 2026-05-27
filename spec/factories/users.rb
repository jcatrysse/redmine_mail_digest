# frozen_string_literal: true

FactoryBot.define do
  factory :user, class: 'User' do
    sequence(:login) { |n| "rd_user_#{n}" }
    sequence(:firstname) { |n| "First#{n}" }
    sequence(:lastname) { |n| "Last#{n}" }
    sequence(:mail) { |n| "rd_user_#{n}@example.com" }
    password { 'topsecret123' }
    password_confirmation { 'topsecret123' }
    status { User::STATUS_ACTIVE }
    admin { false }
    language { 'en' }
    mail_notification { 'all' }
  end
end
