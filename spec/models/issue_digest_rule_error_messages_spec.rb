# frozen_string_literal: true

require_relative '../rails_helper'

# The model adds its own error codes (errors.add(:schedule_config, :invalid_day)
# and so on). Without a translation the form showed "Translation missing.
# Options considered were: ..." to the user. Every shipped locale needs them.
RSpec.describe IssueDigestRule, 'error messages' do
  let(:project) { create(:project) }

  def full_messages_for(attrs)
    rule = build(:issue_digest_rule, { project: project }.merge(attrs))
    rule.valid?
    rule.errors.full_messages
  end

  CASES = {
    'end before start'      => { start_on: Date.new(2026, 12, 31), end_on: Date.new(2026, 1, 1) },
    'bad time window'       => { schedule_type: 'interval_hours', send_time: nil,
                                 schedule_config: { 'every' => 1, 'from' => '25:99', 'to' => '18:00' } },
    'bad days of week'      => { schedule_type: 'weekdays', schedule_config: { 'days' => [9] } },
    'bad day of week'       => { schedule_type: 'weekly', schedule_config: { 'day' => 9 } },
    'bad day of month'      => { schedule_type: 'monthly_date', schedule_config: { 'day' => 31 } },
    'bad interval'          => { schedule_type: 'interval_days', schedule_config: { 'every' => 0 } }
  }.freeze

  locales = Dir[File.expand_path('../../config/locales/*.yml', __dir__)].map { |f| File.basename(f, '.yml') }.sort

  locales.each do |locale|
    CASES.each do |name, attrs|
      it "translates the #{name} error in #{locale}" do
        messages = I18n.with_locale(locale) { full_messages_for(attrs) }
        expect(messages).not_to be_empty
        expect(messages.join(' | ')).not_to match(/translation missing/i)
      end
    end
  end
end
