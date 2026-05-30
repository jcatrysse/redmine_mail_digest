# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::DigestRulesHelper, type: :helper do
  let(:project) { create(:project) }
  let(:user)    { create(:user) }

  # Build a rule without hitting the DB for most tests.
  def build_rule(attrs = {})
    IssueDigestRule.new(
      {
        project:                  project,
        created_by:               user,
        name:                     'Test',
        active:                   true,
        schedule_type:            'daily',
        send_time:                Time.utc(2000, 1, 1, 8, 0, 0),
        timezone:                 'UTC',
        grace_window_hours:       24,
        non_business_day_behavior: 'skip',
        recipient_modes:          ['project_members'],
        group_by:                 'none',
        due_soon_days:            7,
        recently_updated_days:    7,
        recently_created_days:    7
      }.merge(attrs)
    )
  end

  # ── schedule_description ──────────────────────────────────────────────────

  describe '#schedule_description' do
    it 'returns a daily description' do
      rule = build_rule(schedule_type: 'daily', timezone: 'UTC')
      desc = helper.schedule_description(rule)
      expect(desc).to include('Daily').and include('08:00').and include('UTC')
    end

    it 'returns a weekdays description listing the selected days' do
      rule = build_rule(schedule_type: 'weekdays', schedule_config: { 'days' => [1, 3] })
      desc = helper.schedule_description(rule)
      expect(desc).to include('Monday').and include('Wednesday')
    end

    it 'returns a weekly description with the day name' do
      rule = build_rule(schedule_type: 'weekly', schedule_config: { 'day' => 5 })
      desc = helper.schedule_description(rule)
      expect(desc).to include('Friday')
    end

    it 'returns a monthly_date description with the day number' do
      rule = build_rule(schedule_type: 'monthly_date', schedule_config: { 'day' => 15 })
      desc = helper.schedule_description(rule)
      expect(desc).to include('15')
    end

    it 'returns a monthly_last_day description' do
      rule = build_rule(schedule_type: 'monthly_last_day')
      desc = helper.schedule_description(rule)
      expect(desc).to include('last day')
    end

    it 'returns an interval_days description with the interval' do
      rule = build_rule(schedule_type: 'interval_days', schedule_config: { 'every' => 3 })
      desc = helper.schedule_description(rule)
      expect(desc).to include('3')
    end

    it 'returns an interval_weeks description with the interval' do
      rule = build_rule(schedule_type: 'interval_weeks', schedule_config: { 'every' => 2 })
      desc = helper.schedule_description(rule)
      expect(desc).to include('2')
    end

    it 'returns the manual label for manual schedule type' do
      rule = build_rule(schedule_type: 'manual', send_time: nil)
      desc = helper.schedule_description(rule)
      expect(desc).to eq(I18n.t(:schedule_type_manual))
    end

    it 'falls back to the raw schedule_type string for unknown types' do
      rule = build_rule(schedule_type: 'daily')
      allow(rule).to receive(:schedule_type).and_return('custom_type')
      desc = helper.schedule_description(rule)
      expect(desc).to eq('custom_type')
    end
  end

  # ── day_of_week_name ──────────────────────────────────────────────────────

  describe '#day_of_week_name' do
    it 'returns the English name for Monday (1)' do
      # Redmine core l10n keys (label_monday etc.) are not loaded in plugin specs;
      # the helper falls back to Date::DAYNAMES — verify that fallback here.
      expect(helper.day_of_week_name(1)).to eq('Monday')
    end

    it 'returns the English name for Sunday (7)' do
      expect(helper.day_of_week_name(7)).to eq('Sunday')
    end

    it 'returns an empty string for a blank value' do
      expect(helper.day_of_week_name(nil)).to eq('')
      expect(helper.day_of_week_name('')).to eq('')
    end

    it 'returns the raw string for an out-of-range integer' do
      expect(helper.day_of_week_name(99)).to eq('99')
    end
  end

  # ── recipient_mode_label ─────────────────────────────────────────────────

  describe '#recipient_mode_label' do
    it 'returns the project_members label' do
      expect(helper.recipient_mode_label('project_members')).to eq(I18n.t(:recipient_mode_project_members))
    end

    it 'returns the assignees label' do
      expect(helper.recipient_mode_label('assignees')).to eq(I18n.t(:recipient_mode_assignees))
    end

    it 'returns the authors label' do
      expect(helper.recipient_mode_label('authors')).to eq(I18n.t(:recipient_mode_authors))
    end

    it 'returns the watchers label' do
      expect(helper.recipient_mode_label('watchers')).to eq(I18n.t(:recipient_mode_watchers))
    end

    it 'includes the role name for a role: mode' do
      role = Role.find_by(name: 'DigestHelperTestRole') ||
             Role.create!(name: 'DigestHelperTestRole', permissions: [], issues_visibility: 'all')
      label = helper.recipient_mode_label("role:#{role.id}")
      expect(label).to include(role.name)
    end

    it 'uses the role id when the role no longer exists' do
      label = helper.recipient_mode_label('role:99999')
      expect(label).to include('99999')
    end

    it 'includes the user name for a user: mode' do
      label = helper.recipient_mode_label("user:#{user.id}")
      expect(label).to include(user.name)
    end

    it 'uses the user id when the user no longer exists' do
      label = helper.recipient_mode_label('user:99999')
      expect(label).to include('99999')
    end

    it 'returns unknown modes as-is' do
      expect(helper.recipient_mode_label('unknown_mode')).to eq('unknown_mode')
    end
  end

  # ── recipient_modes_description ──────────────────────────────────────────

  describe '#recipient_modes_description' do
    it 'returns empty string for no modes' do
      rule = build_rule(recipient_modes: [])
      expect(helper.recipient_modes_description(rule)).to eq('')
    end

    it 'joins multiple modes with a comma' do
      rule = build_rule(recipient_modes: ['project_members', 'assignees'])
      desc = helper.recipient_modes_description(rule)
      expect(desc).to include(',')
      expect(desc).to include(I18n.t(:recipient_mode_project_members))
      expect(desc).to include(I18n.t(:recipient_mode_assignees))
    end
  end

  # ── recipient_label_cache (N+1 fix) ──────────────────────────────────────

  describe '#recipient_label_cache' do
    it 'preloads roles and users referenced across the given rules' do
      role = Role.create!(name: "CacheRole_#{SecureRandom.hex(4)}", permissions: [], issues_visibility: 'all')
      r1 = build_rule(recipient_modes: ["role:#{role.id}", 'project_members'])
      r2 = build_rule(recipient_modes: ["user:#{user.id}", "role:#{role.id}"])

      cache = helper.recipient_label_cache([r1, r2])
      expect(cache[:roles][role.id]).to eq(role)
      expect(cache[:users][user.id]).to eq(user)
    end

    it 'lets recipient_mode_label resolve names from the cache without a query' do
      cache = helper.recipient_label_cache([build_rule(recipient_modes: ["user:#{user.id}"])])
      # Any stray find_by would mean the cache was bypassed.
      expect(User).not_to receive(:find_by)
      label = helper.recipient_mode_label("user:#{user.id}", cache: cache)
      expect(label).to include(user.name)
    end

    it 'falls back to the id when a cached record is missing' do
      cache = { roles: {}, users: {} }
      expect(helper.recipient_mode_label('user:99999', cache: cache)).to include('99999')
      expect(helper.recipient_mode_label('role:88888', cache: cache)).to include('88888')
    end
  end

  # ── filter_summary ───────────────────────────────────────────────────────

  describe '#filter_summary' do
    it 'returns the no-filters message when all flags are off' do
      rule = build_rule(include_open: false, include_closed: false, include_overdue: false,
                        include_due_soon: false, include_recently_updated: false,
                        include_recently_created: false, include_subprojects: false)
      expect(helper.filter_summary(rule)).to eq(I18n.t(:text_no_active_filters))
    end

    it 'includes the open-issues label when include_open is true' do
      rule = build_rule(include_open: true, include_closed: false)
      expect(helper.filter_summary(rule)).to include(I18n.t(:field_include_open))
    end

    it 'includes the closed-issues label when include_closed is true' do
      rule = build_rule(include_open: false, include_closed: true)
      expect(helper.filter_summary(rule)).to include(I18n.t(:field_include_closed))
    end

    it 'includes the due-soon summary with the day count' do
      rule = build_rule(include_open: false, include_due_soon: true, due_soon_days: 5)
      expect(helper.filter_summary(rule)).to include('5')
    end

    it 'includes the recently-updated summary with the day count' do
      rule = build_rule(include_open: false, include_recently_updated: true, recently_updated_days: 14)
      expect(helper.filter_summary(rule)).to include('14')
    end

    it 'joins multiple active filters with a comma' do
      rule = build_rule(include_open: true, include_overdue: true, include_closed: false)
      summary = helper.filter_summary(rule)
      expect(summary).to include(I18n.t(:field_include_open))
      expect(summary).to include(I18n.t(:field_include_overdue))
      expect(summary).to include(',')
    end

    it 'includes the since-last-run-created label when that flag is set' do
      rule = build_rule(include_open: false, since_last_run_created: true)
      expect(helper.filter_summary(rule)).to include(I18n.t(:filter_since_last_run_created))
    end

    it 'includes the since-last-run-updated label when that flag is set' do
      rule = build_rule(include_open: false, since_last_run_updated: true)
      expect(helper.filter_summary(rule)).to include(I18n.t(:filter_since_last_run_updated))
    end
  end

  # ── status badges (i18n aria-label) ───────────────────────────────────────

  describe '#digest_rule_status_badge' do
    it 'renders the status badge with a localized aria-label' do
      rule = build_rule(active: true)
      html = helper.digest_rule_status_badge(rule)
      expect(html).to include(I18n.t(:aria_rule_status, label: I18n.t(:status_active)))
    end
  end

  # ── personalization_summary ──────────────────────────────────────────────

  describe '#personalization_summary' do
    it 'returns nil when no personalization flags are set' do
      rule = build_rule(filter_assigned_to_recipient: false,
                        filter_watched_by_recipient: false,
                        filter_authored_by_recipient: false)
      expect(helper.personalization_summary(rule)).to be_nil
    end

    it 'returns the assigned-to label when filter_assigned_to_recipient is true' do
      rule = build_rule(filter_assigned_to_recipient: true)
      expect(helper.personalization_summary(rule)).to include(I18n.t(:field_filter_assigned_to_recipient))
    end

    it 'returns the watched-by label when filter_watched_by_recipient is true' do
      rule = build_rule(filter_watched_by_recipient: true)
      expect(helper.personalization_summary(rule)).to include(I18n.t(:field_filter_watched_by_recipient))
    end

    it 'joins multiple active personalization flags with a comma' do
      rule = build_rule(filter_assigned_to_recipient: true, filter_authored_by_recipient: true)
      summary = helper.personalization_summary(rule)
      expect(summary).to include(',')
      expect(summary).to include(I18n.t(:field_filter_assigned_to_recipient))
      expect(summary).to include(I18n.t(:field_filter_authored_by_recipient))
    end
  end

  # ── available_queries_for_project ────────────────────────────────────────

  describe '#available_queries_for_project' do
    it 'returns an empty relation when issue_tracking is disabled' do
      project.enabled_modules.where(name: 'issue_tracking').delete_all
      project.reload
      result = helper.available_queries_for_project(project)
      expect(result.to_a).to eq([])
    end

    it 'returns public queries for the project when issue_tracking is enabled' do
      public_query = IssueQuery.create!(
        name: "PublicQ_#{SecureRandom.hex(4)}",
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: user
      )
      result = helper.available_queries_for_project(project)
      expect(result.map(&:id)).to include(public_query.id)
    end

    it 'includes project-scoped private queries regardless of owner' do
      owner = create(:user)
      private_query = IssueQuery.create!(
        name: "PrivQ_#{SecureRandom.hex(4)}",
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: owner
      )
      result = helper.available_queries_for_project(project)
      expect(result.map(&:id)).to include(private_query.id)
    end

    it 'includes global queries' do
      global_query = IssueQuery.create!(
        name: "GlobalQ_#{SecureRandom.hex(4)}",
        project: nil,
        visibility: Query::VISIBILITY_PUBLIC,
        user: user
      )
      result = helper.available_queries_for_project(project)
      expect(result.map(&:id)).to include(global_query.id)
    end

    it 'excludes queries scoped to another project' do
      other_project = create(:project)
      other_query = IssueQuery.create!(
        name: "OtherProjQ_#{SecureRandom.hex(4)}",
        project: other_project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: user
      )
      result = helper.available_queries_for_project(project)
      expect(result.map(&:id)).not_to include(other_query.id)
    end
  end

  # ── digest_rule_status_badge ──────────────────────────────────────────────

  describe '#digest_rule_status_badge' do
    it 'returns a success badge for an active rule' do
      rule = build_rule(active: true)
      html = helper.digest_rule_status_badge(rule)
      expect(html).to include('badge-success')
    end

    it 'returns an inactive badge for a disabled rule' do
      rule = build_rule(active: false)
      html = helper.digest_rule_status_badge(rule)
      expect(html).to include('badge-inactive')
    end

    it 'returns an error badge for an expired rule' do
      rule = build_rule(active: true, end_on: Date.current - 1)
      html = helper.digest_rule_status_badge(rule)
      expect(html).to include('badge-error')
    end

    it 'returns a warning badge for a pending rule' do
      rule = build_rule(active: true, start_on: Date.current + 1)
      html = helper.digest_rule_status_badge(rule)
      expect(html).to include('badge-warning')
    end
  end
end
