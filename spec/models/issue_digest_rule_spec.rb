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

    # The schedule_config / recipient_modes columns are NOT NULL with no DB
    # default (MySQL forbids defaults on TEXT). The model must backfill them so
    # a persisted row never receives NULL on any database.
    it 'coerces a nil schedule_config to an empty hash and persists it' do
      rule = build(:issue_digest_rule, schedule_type: 'daily', schedule_config: nil)
      expect(rule).to be_valid
      expect(rule.schedule_config).to eq({})
      rule.save!
      expect(rule.reload.schedule_config).to eq({})
    end

    it 'coerces a nil recipient_modes to an empty array (then fails presence)' do
      rule = build(:issue_digest_rule, recipient_modes: nil)
      expect(rule).not_to be_valid
      expect(rule.recipient_modes).to eq([])
      expect(rule.errors[:recipient_modes]).to be_present
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

  describe 'since-last-run flags' do
    it 'both default to false' do
      rule = create(:issue_digest_rule)
      expect(rule.since_last_run_created).to be false
      expect(rule.since_last_run_updated).to be false
    end

    it 'can be set independently' do
      rule = create(:issue_digest_rule, since_last_run_created: true, since_last_run_updated: false)
      expect(rule.since_last_run_created).to be true
      expect(rule.since_last_run_updated).to be false
    end

    it 'can both be enabled (cumulative)' do
      rule = create(:issue_digest_rule, since_last_run_created: true, since_last_run_updated: true)
      expect(rule.since_last_run_created).to be true
      expect(rule.since_last_run_updated).to be true
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
  describe 'query project validation' do
    it 'accepts a private query owned by the rule creator' do
      creator = create(:user)
      project = create(:project)
      query = IssueQuery.create!(
        name: "OwnedDigestQ_#{SecureRandom.hex(4)}",
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: creator
      )
      rule = build(:issue_digest_rule, project: project, created_by: creator, query: query)
      expect(rule).to be_valid
    end

    it 'accepts a same-project private query owned by another user' do
      creator = create(:user)
      owner = create(:user)
      project = create(:project)
      query = IssueQuery.create!(
        name: "OtherDigestQ_#{SecureRandom.hex(4)}",
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: owner
      )
      rule = build(:issue_digest_rule, project: project, created_by: creator, query: query)
      expect(rule).to be_valid
    end

    it 'accepts a global query' do
      creator = create(:user)
      project = create(:project)
      query = IssueQuery.create!(
        name: "GlobalDigestQ_#{SecureRandom.hex(4)}",
        project: nil,
        visibility: Query::VISIBILITY_PUBLIC,
        user: creator
      )
      rule = build(:issue_digest_rule, project: project, created_by: creator, query: query)
      expect(rule).to be_valid
    end

    it 'rejects a query belonging to another project' do
      creator = create(:user)
      project = create(:project)
      other_project = create(:project)
      query = IssueQuery.create!(
        name: "ForeignDigestQ_#{SecureRandom.hex(4)}",
        project: other_project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: creator
      )
      rule = build(:issue_digest_rule, project: project, created_by: creator, query: query)
      expect(rule).not_to be_valid
      expect(rule.errors[:query_id]).to be_present
    end

    it 'rejects a query_id that no longer exists' do
      project = create(:project)
      rule = build(:issue_digest_rule, project: project, created_by: create(:user))
      rule.query_id = 999_999
      expect(rule).not_to be_valid
      expect(rule.errors[:query_id]).to be_present
    end
  end

  describe 'timezone-aware date range' do
    it 'interprets end_on in the rule timezone at the day boundary' do
      project = create(:project)
      # Pacific/Kiritimati is UTC+14: at this UTC instant the rule's local date
      # has already rolled over to 2026-05-31 while the server/UTC date is still
      # 2026-05-30. The window check must use the rule's local date.
      rule = build(:issue_digest_rule, project: project, timezone: 'Pacific/Kiritimati')
      travel_to(Time.utc(2026, 5, 30, 12, 0, 0)) do
        rule.end_on = Date.new(2026, 5, 30)
        expect(rule.within_date_range?).to be(false)

        rule.end_on = Date.new(2026, 5, 31)
        expect(rule.within_date_range?).to be(true)
      end
    end
  end

  describe 'recipient_modes normalization' do
    it 'removes blanks and duplicates before validation while preserving order' do
      project = create(:project)
      rule = build(:issue_digest_rule, project: project,
                                       recipient_modes: ['project_members', '', 'authors', 'project_members'])
      rule.valid?
      expect(rule.recipient_modes).to eq(%w[project_members authors])
    end
  end
end
