# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe IssueDigestRule, type: :model do
  describe 'validations' do
    it 'is valid with required fields' do
      expect(build(:issue_digest_rule)).to be_valid
    end

    it 'is invalid without name' do
      rule = build(:issue_digest_rule, name: nil)
      expect(rule).not_to be_valid
      expect(rule.errors[:name]).to be_present
    end

    it 'is invalid without schedule_type' do
      expect(build(:issue_digest_rule, schedule_type: nil)).not_to be_valid
    end

    it 'is invalid without send_time for non-manual schedules' do
      expect(build(:issue_digest_rule, send_time: nil)).not_to be_valid
    end

    it 'is valid without send_time for manual schedules' do
      expect(build(:issue_digest_rule, :manual)).to be_valid
    end

    it 'is invalid without recipient_modes' do
      rule = build(:issue_digest_rule, recipient_modes: [])
      expect(rule).not_to be_valid
      expect(rule.errors[:recipient_modes]).to be_present
    end

    it 'is invalid with unknown schedule_type' do
      expect(build(:issue_digest_rule, schedule_type: 'hourly')).not_to be_valid
    end

    %i[weekdays weekly monthly_date monthly_last_day interval_days interval_weeks manual].each do |trait|
      it "is valid with #{trait} schedule" do
        expect(build(:issue_digest_rule, trait)).to be_valid
      end
    end

    it 'rejects interval_days with every: 0' do
      rule = build(:issue_digest_rule, :interval_days, schedule_config: { 'every' => 0 })
      expect(rule).not_to be_valid
    end

    it 'rejects monthly_date with day > 28' do
      rule = build(:issue_digest_rule, :monthly_date, schedule_config: { 'day' => 29 })
      expect(rule).not_to be_valid
    end

    it 'rejects weekly with day out of range' do
      rule = build(:issue_digest_rule, :weekly, schedule_config: { 'day' => 8 })
      expect(rule).not_to be_valid
    end

    it 'rejects weekdays with empty days array' do
      rule = build(:issue_digest_rule, :weekdays, schedule_config: { 'days' => [] })
      expect(rule).not_to be_valid
    end

    it 'rejects weekdays with out-of-range day numbers' do
      [[0], [8], [-1], [1, 9]].each do |days|
        rule = build(:issue_digest_rule, :weekdays, schedule_config: { 'days' => days })
        expect(rule).not_to be_valid, "expected days=#{days.inspect} to be invalid"
      end
    end

    it 'rejects monthly_date day 0' do
      rule = build(:issue_digest_rule, :monthly_date, schedule_config: { 'day' => 0 })
      expect(rule).not_to be_valid
    end

    it 'accepts monthly_date day 28 (boundary)' do
      rule = build(:issue_digest_rule, :monthly_date, schedule_config: { 'day' => 28 })
      expect(rule).to be_valid
    end

    it 'accepts grace_window_hours of 23' do
      expect(build(:issue_digest_rule, grace_window_hours: 23)).to be_valid
    end

    it 'accepts grace_window_hours of 24 (1 day — new default)' do
      expect(build(:issue_digest_rule, grace_window_hours: 24)).to be_valid
    end

    it 'accepts grace_window_hours of 48 (boundary)' do
      expect(build(:issue_digest_rule, grace_window_hours: 48)).to be_valid
    end

    it 'rejects grace_window_hours of 49 (above boundary)' do
      expect(build(:issue_digest_rule, grace_window_hours: 49)).not_to be_valid
    end

    it 'rejects negative grace_window_hours' do
      expect(build(:issue_digest_rule, grace_window_hours: -1)).not_to be_valid
    end

    it 'rejects schedule_config that is not a hash' do
      rule = build(:issue_digest_rule, schedule_config: ['not', 'a', 'hash'])
      expect(rule).not_to be_valid
    end

    it 'accepts grace_window_hours of 0' do
      expect(build(:issue_digest_rule, grace_window_hours: 0)).to be_valid
    end

    it 'rejects unknown non_business_day_behavior' do
      expect(build(:issue_digest_rule, non_business_day_behavior: 'holiday')).not_to be_valid
    end

    it 'is invalid when end_on is before start_on' do
      expect(build(:issue_digest_rule, start_on: Date.tomorrow, end_on: Date.current)).not_to be_valid
    end

    it 'is valid when start_on equals end_on' do
      today = Date.current
      expect(build(:issue_digest_rule, start_on: today, end_on: today)).to be_valid
    end

    it 'rejects invalid recipient_mode strings' do
      expect(build(:issue_digest_rule, recipient_modes: ['bad_mode'])).not_to be_valid
    end

    it 'rejects SQL-injection-style recipient_mode strings' do
      rule = build(:issue_digest_rule, recipient_modes: ["'; DROP TABLE issues; --"])
      expect(rule).not_to be_valid
    end

    it 'accepts role:<id> mode' do
      expect(build(:issue_digest_rule, recipient_modes: ['role:3'])).to be_valid
    end

    it 'accepts user:<id> mode' do
      expect(build(:issue_digest_rule, recipient_modes: ['user:42'])).to be_valid
    end

    it 'accepts a valid IANA timezone' do
      expect(build(:issue_digest_rule, timezone: 'Europe/Brussels')).to be_valid
    end

    it 'rejects an invalid timezone' do
      expect(build(:issue_digest_rule, timezone: 'Not/A/Real/Zone')).not_to be_valid
    end
  end

  describe '#active?' do
    it 'returns true for an active, in-range rule' do
      expect(build(:issue_digest_rule).active?).to be true
    end

    it 'returns false when active is false' do
      expect(build(:issue_digest_rule, :disabled).active?).to be false
    end

    it 'returns false when start_on is in the future' do
      expect(build(:issue_digest_rule, :pending).active?).to be false
    end

    it 'returns false when end_on is in the past' do
      expect(build(:issue_digest_rule, :expired).active?).to be false
    end
  end

  describe '#status_label' do
    it 'returns :active for an active, in-range rule' do
      expect(build(:issue_digest_rule).status_label).to eq(:active)
    end

    it 'returns :disabled when active is false' do
      expect(build(:issue_digest_rule, :disabled).status_label).to eq(:disabled)
    end

    it 'returns :expired when end_on is past' do
      expect(build(:issue_digest_rule, :expired).status_label).to eq(:expired)
    end

    it 'returns :pending when start_on is future' do
      expect(build(:issue_digest_rule, :pending).status_label).to eq(:pending)
    end
  end

  describe 'serialization' do
    it 'round-trips schedule_config as JSON' do
      rule = create(:issue_digest_rule, :weekdays)
      expect(rule.reload.schedule_config).to eq('days' => [1, 3, 5])
    end

    it 'round-trips recipient_modes as a JSON array' do
      rule = create(:issue_digest_rule, recipient_modes: %w[project_members user:1])
      expect(rule.reload.recipient_modes).to eq(%w[project_members user:1])
    end
  end

  describe 'associations' do
    it 'belongs to a project' do
      expect(build(:issue_digest_rule).project).to be_a(Project)
    end

    it 'has many issue_digest_runs' do
      rule = create(:issue_digest_rule)
      create(:issue_digest_run, issue_digest_rule: rule)
      create(:issue_digest_run, issue_digest_rule: rule)
      expect(rule.issue_digest_runs.count).to eq(2)
    end

    it 'cascade-deletes runs on destroy' do
      rule = create(:issue_digest_rule)
      create(:issue_digest_run, issue_digest_rule: rule)
      expect { rule.destroy }.to change(IssueDigestRun, :count).by(-1)
    end
  end

  describe '#last_run' do
    it 'returns the most recent run by started_at' do
      rule = create(:issue_digest_rule)
      _older = create(:issue_digest_run, issue_digest_rule: rule, started_at: 2.days.ago)
      newer = create(:issue_digest_run, issue_digest_rule: rule, started_at: 1.day.ago)
      expect(rule.last_run).to eq(newer)
    end

    it 'returns nil when there are no runs' do
      expect(create(:issue_digest_rule).last_run).to be_nil
    end
  end

  describe '.active_for_project' do
    it 'returns only active rules scoped to the given project' do
      project_a = create(:project)
      project_b = create(:project)
      rule_a = create(:issue_digest_rule, project: project_a)
      _rule_a_disabled = create(:issue_digest_rule, :disabled, project: project_a)
      _rule_b = create(:issue_digest_rule, project: project_b)

      expect(IssueDigestRule.active_for_project(project_a)).to contain_exactly(rule_a)
    end
  end

  describe 'interval_hours / interval_minutes (sub-daily)' do
    it 'is valid with just every set' do
      rule = build(:issue_digest_rule, :interval_hours)
      expect(rule).to be_valid
    end

    it 'is valid without send_time (not required for sub-daily)' do
      rule = build(:issue_digest_rule, :interval_hours, send_time: nil)
      expect(rule).to be_valid
    end

    it 'is invalid when every is missing' do
      rule = build(:issue_digest_rule, :interval_hours, schedule_config: {})
      expect(rule).to be_invalid
      expect(rule.errors[:schedule_config]).not_to be_empty
    end

    it 'is invalid when every is zero' do
      rule = build(:issue_digest_rule, :interval_hours, schedule_config: { 'every' => 0 })
      expect(rule).to be_invalid
    end

    it 'is valid with a time window' do
      rule = build(:issue_digest_rule, :interval_hours,
                   schedule_config: { 'every' => 1, 'from' => '09:00', 'to' => '17:00' })
      expect(rule).to be_valid
    end

    it 'is invalid with a malformed time window' do
      rule = build(:issue_digest_rule, :interval_hours,
                   schedule_config: { 'every' => 1, 'from' => 'not-a-time', 'to' => '17:00' })
      expect(rule).to be_invalid
    end

    it 'is valid with a days filter' do
      rule = build(:issue_digest_rule, :interval_hours,
                   schedule_config: { 'every' => 1, 'days' => [1, 2, 3] })
      expect(rule).to be_valid
    end

    it 'is invalid with out-of-range days' do
      rule = build(:issue_digest_rule, :interval_hours,
                   schedule_config: { 'every' => 1, 'days' => [0, 8] })
      expect(rule).to be_invalid
    end

    it '#sub_daily_schedule? returns true for interval_hours' do
      rule = build(:issue_digest_rule, :interval_hours)
      expect(rule.sub_daily_schedule?).to be true
    end

    it '#sub_daily_schedule? returns false for daily' do
      rule = build(:issue_digest_rule)
      expect(rule.sub_daily_schedule?).to be false
    end
  end

  describe 'only_since_last_run' do
    it 'defaults to false' do
      rule = create(:issue_digest_rule)
      expect(rule.only_since_last_run).to be false
    end

    it 'can be set to true' do
      rule = create(:issue_digest_rule, only_since_last_run: true)
      expect(rule.only_since_last_run).to be true
    end
  end

  describe 'scheduler scopes' do
    it '.enabled returns only rules with active=true' do
      enabled = create(:issue_digest_rule)
      _disabled = create(:issue_digest_rule, :disabled)
      expect(IssueDigestRule.enabled).to contain_exactly(enabled)
    end

    it '.in_date_range filters out pending and expired rules' do
      current = create(:issue_digest_rule)
      _pending = create(:issue_digest_rule, :pending)
      _expired = create(:issue_digest_rule, :expired)
      expect(IssueDigestRule.in_date_range).to contain_exactly(current)
    end

    it '.due_now chains enabled and in_date_range' do
      candidate = create(:issue_digest_rule)
      _disabled = create(:issue_digest_rule, :disabled)
      _pending = create(:issue_digest_rule, :pending)
      _expired = create(:issue_digest_rule, :expired)
      expect(IssueDigestRule.due_now).to contain_exactly(candidate)
    end
  end
end
