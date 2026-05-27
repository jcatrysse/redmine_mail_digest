# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::IssueResolver, type: :service do
  # Use an admin user so Issue.visible bypasses module-enable and role checks,
  # letting these specs focus solely on filter logic.
  let!(:project)  { create(:project, is_public: true) }
  # Lazy `let` so the user is created only after deliver_security_notification
  # is stubbed in the before block (avoids DeserializationError on AnonymousUser).
  let(:user)      { create(:user, admin: true) }
  let!(:open_st)  { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
  let!(:closed_st){ create(:issue_status, name: "Closed_#{SecureRandom.hex(4)}", is_closed: true) }
  let!(:tracker)  { t = create(:tracker, default_status: open_st); project.trackers << t; t }
  let!(:priority) { create(:issue_priority, is_default: true) }

  before do
    # Prevent security-notification emails from being enqueued during user creation;
    # the inline job adapter tries to deserialize a stale AnonymousUser id across
    # rolled-back transactions, causing DeserializationError failures.
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    # Prevent after_create_commit :add_auto_watcher from adding the issue author as
    # a watcher on every created issue, which would corrupt the watched-by filter tests.
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
  end

  def make_issue(attrs = {})
    # Extract status before merging so the caller's value wins.
    status_override = attrs.delete(:status)
    issue = create(:issue, { project: project, tracker: tracker, priority: priority,
                              status: open_st, author: user }.merge(attrs))
    if status_override && status_override != open_st
      # Redmine's tracker= callback resets the status to the tracker's default when
      # the chosen status isn't in the tracker's workflow.  Reload first because
      # Rails 7.2's update_all (called by add_as_root nested-set hook) auto-increments
      # lock_version in the DB without updating the in-memory object, so any
      # subsequent update_column with the stale lock_version affects 0 rows.
      issue.reload.update_column(:status_id, status_override.id)
    end
    issue
  end

  let!(:rule) do
    create(:issue_digest_rule,
           project: project,
           include_open: true,
           include_closed: false,
           include_overdue: false,
           include_due_soon: false,
           include_recently_updated: false,
           include_recently_created: false,
           filter_assigned_to_recipient: false,
           filter_watched_by_recipient: false,
           filter_authored_by_recipient: false)
  end

  describe '#resolve' do
    it 'returns open issues when include_open=true' do
      i1 = make_issue
      make_issue(status: closed_st)
      resolver = described_class.new(rule, user: user)
      result = resolver.resolve
      expect(result.map(&:id)).to include(i1.id)
      expect(result.count).to eq(1)
    end

    it 'returns closed issues when include_closed=true' do
      make_issue
      c = make_issue(status: closed_st)
      r = create(:issue_digest_rule, project: project, include_open: false, include_closed: true)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to eq([c.id])
    end

    it 'returns overdue issues when include_overdue=true' do
      overdue = make_issue(due_date: 3.days.ago.to_date)
      not_overdue = make_issue(due_date: 3.days.from_now.to_date)
      r = create(:issue_digest_rule, project: project, include_open: false, include_overdue: true)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(overdue.id)
      expect(result.map(&:id)).not_to include(not_overdue.id)
    end

    it 'applies overdue_min_days to require minimum overdue age' do
      just_overdue = make_issue(due_date: 2.days.ago.to_date)
      long_overdue = make_issue(due_date: 10.days.ago.to_date)
      r = create(:issue_digest_rule, project: project, include_open: false,
                 include_overdue: true, overdue_min_days: 7)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(long_overdue.id)
      expect(result.map(&:id)).not_to include(just_overdue.id)
    end

    it 'returns due-soon issues within the window' do
      due_soon = make_issue(due_date: 3.days.from_now.to_date)
      due_far = make_issue(due_date: 15.days.from_now.to_date)
      r = create(:issue_digest_rule, project: project, include_open: false,
                 include_due_soon: true, due_soon_days: 7)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(due_soon.id)
      expect(result.map(&:id)).not_to include(due_far.id)
    end

    it 'returns recently updated issues' do
      recent = make_issue
      old = make_issue
      old.reload.update_column(:updated_on, 10.days.ago)
      r = create(:issue_digest_rule, project: project, include_open: false,
                 include_recently_updated: true, recently_updated_days: 7)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(recent.id)
      expect(result.map(&:id)).not_to include(old.id)
    end

    it 'returns recently created issues' do
      recent = make_issue
      old = make_issue
      old.reload.update_column(:created_on, 10.days.ago)
      r = create(:issue_digest_rule, project: project, include_open: false,
                 include_recently_created: true, recently_created_days: 7)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(recent.id)
      expect(result.map(&:id)).not_to include(old.id)
    end

    it 'excludes issues from other projects' do
      other_project = create(:project, is_public: true)
      other_tracker = create(:tracker, default_status: open_st)
      other_project.trackers << other_tracker
      make_issue
      other = create(:issue, project: other_project, tracker: other_tracker,
                     status: open_st, author: user, priority: priority)
      result = described_class.new(rule, user: user).resolve
      expect(result.map(&:id)).not_to include(other.id)
    end

    it 'applies filter_assigned_to_recipient' do
      assigned = make_issue(assigned_to: user)
      make_issue
      r = create(:issue_digest_rule, project: project, include_open: true,
                 filter_assigned_to_recipient: true)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to eq([assigned.id])
    end

    it 'applies filter_authored_by_recipient' do
      other_user = create(:user)
      authored = make_issue(author: user)
      not_authored = make_issue(author: other_user)
      r = create(:issue_digest_rule, project: project, include_open: true,
                 filter_authored_by_recipient: true)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(authored.id)
      expect(result.map(&:id)).not_to include(not_authored.id)
    end

    it 'applies filter_watched_by_recipient' do
      watched = make_issue
      not_watched = make_issue
      Watcher.find_or_create_by!(watchable: watched, user: user)
      r = create(:issue_digest_rule, project: project, include_open: true,
                 filter_watched_by_recipient: true)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to eq([watched.id])
    end

    it 'returns Issue.none on exception' do
      bad_rule = build(:issue_digest_rule, project: project, include_open: true)
      allow(bad_rule).to receive(:project).and_raise(StandardError, 'boom')
      result = described_class.new(bad_rule, user: user).resolve
      expect(result).to eq(Issue.none)
    end
  end

  describe 'base_scope' do
    it 'returns a relation scoped to the project' do
      i = make_issue
      other_project = create(:project, is_public: true)
      other_tracker = create(:tracker, default_status: open_st)
      other_project.trackers << other_tracker
      create(:issue, project: other_project, tracker: other_tracker,
             status: open_st, author: user, priority: priority)
      scope = described_class.new(rule, user: nil).base_scope
      expect(scope.map(&:id)).to include(i.id)
      expect(scope.count).to eq(1)
    end

    it 'returns project issues for a private project when user is nil' do
      private_proj = create(:project, is_public: false)
      private_proj.trackers << tracker unless private_proj.trackers.include?(tracker)
      issue = create(:issue, project: private_proj, tracker: tracker,
                     status: open_st, author: user, priority: priority)
      priv_rule = create(:issue_digest_rule, project: private_proj, include_open: true)
      scope = described_class.new(priv_rule, user: nil).base_scope
      expect(scope.map(&:id)).to include(issue.id)
    end

    it 'excludes archived projects when user is nil' do
      i = make_issue
      project.update_column(:status, Project::STATUS_ARCHIVED)
      scope = described_class.new(rule, user: nil).base_scope
      expect(scope.map(&:id)).not_to include(i.id)
    end
  end

  describe '#resolve with only_since_last_run' do
    let(:base_attrs) do
      {
        project: project,
        include_open: true,
        include_closed: false,
        include_overdue: false,
        include_due_soon: false,
        include_recently_updated: false,
        include_recently_created: false,
        filter_assigned_to_recipient: false,
        filter_watched_by_recipient: false,
        filter_authored_by_recipient: false,
        only_since_last_run: true
      }
    end

    it 'includes issues created after last_success_at' do
      cutoff = 2.hours.ago
      old_issue = make_issue
      old_issue.reload.update_column(:created_on, 3.hours.ago)
      old_issue.reload.update_column(:updated_on, 3.hours.ago)
      new_issue = make_issue
      new_issue.reload.update_column(:created_on, 1.hour.ago)

      r = create(:issue_digest_rule, base_attrs.merge(last_success_at: cutoff))
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(new_issue.id)
      expect(result.map(&:id)).not_to include(old_issue.id)
    end

    it 'includes issues updated after last_success_at even when created before it' do
      cutoff = 2.hours.ago
      old_but_updated = make_issue
      old_but_updated.reload.update_column(:created_on, 3.hours.ago)
      old_but_updated.reload.update_column(:updated_on, 1.hour.ago)
      old_and_stale = make_issue
      old_and_stale.reload.update_column(:created_on, 3.hours.ago)
      old_and_stale.reload.update_column(:updated_on, 3.hours.ago)

      r = create(:issue_digest_rule, base_attrs.merge(last_success_at: cutoff))
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(old_but_updated.id)
      expect(result.map(&:id)).not_to include(old_and_stale.id)
    end

    it 'includes all project issues when last_success_at is nil (uses created_at as cutoff)' do
      # When there is no last_success_at, we fall back to rule.created_at.
      # All issues created after the rule was created should be included.
      r = create(:issue_digest_rule, base_attrs.merge(last_success_at: nil))
      issue = make_issue
      issue.reload.update_column(:created_on, 1.second.from_now)
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(issue.id)
    end

    it 'returns all issues when only_since_last_run is false' do
      old_issue = make_issue
      old_issue.reload.update_column(:created_on, 1.day.ago)
      r = create(:issue_digest_rule, base_attrs.merge(only_since_last_run: false, last_success_at: 1.hour.ago))
      result = described_class.new(r, user: user).resolve
      expect(result.map(&:id)).to include(old_issue.id)
    end
  end

  describe '#query_adapter_warning' do
    it 'is nil when no query is set' do
      expect(described_class.new(rule, user: user).resolve).to be_truthy
      resolver = described_class.new(rule, user: user)
      resolver.resolve
      expect(resolver.query_adapter_warning).to be_nil
    end

    it 'is set when the query is missing' do
      rule.update_column(:query_id, 999_999)
      resolver = described_class.new(rule, user: user)
      expect(Rails.logger).to receive(:warn).with(/not found/)
      resolver.resolve
      expect(resolver.query_adapter_warning).to match(/no longer exists/)
    end
  end
end
