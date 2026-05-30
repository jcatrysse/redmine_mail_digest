# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::RecipientResolver, type: :service do
  let!(:role)    { Role.create!(name: "DigestTestRole_#{SecureRandom.hex(4)}", permissions: [:view_issues]) }
  let!(:project) { create(:project) }
  let!(:user_a)  { create(:user) }
  let!(:user_b)  { create(:user) }
  let!(:rule)    { create(:issue_digest_rule, project: project) }

  def add_member(user, proj = project, r = role)
    Member.create!(principal: user, project: proj, roles: [r])
  end

  describe '#resolve' do
    context 'project_members mode' do
      let!(:rule) { create(:issue_digest_rule, project: project, recipient_modes: ['project_members']) }

      it 'returns all active project members' do
        add_member(user_a)
        add_member(user_b)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to match_array([user_a.id, user_b.id])
      end

      it 'excludes locked users' do
        locked = create(:user, status: User::STATUS_LOCKED)
        add_member(user_a)
        add_member(locked)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to eq([user_a.id])
      end

      it 'excludes users with no email' do
        add_member(user_a)
        add_member(user_b)
        # In Redmine 6, email is stored in email_addresses table.
        user_b.email_addresses.delete_all
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to eq([user_a.id])
      end

      it 'returns empty array when project has no members' do
        expect(described_class.new(rule).resolve).to eq([])
      end
    end

    context 'role: mode' do
      let!(:other_role) { Role.create!(name: "OtherRole_#{SecureRandom.hex(4)}", permissions: [:view_issues]) }
      let!(:rule) { create(:issue_digest_rule, project: project, recipient_modes: ["role:#{role.id}"]) }

      it 'returns only members with the specified role' do
        add_member(user_a, project, role)
        add_member(user_b, project, other_role)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to eq([user_a.id])
      end
    end

    context 'user: mode' do
      let!(:rule) { create(:issue_digest_rule, project: project, recipient_modes: ["user:#{user_a.id}"]) }

      it 'returns the specific user when they are an active project member' do
        add_member(user_a)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to eq([user_a.id])
      end

      it 'excludes the user when they are not a project member' do
        # user_a NOT added as member
        users = described_class.new(rule).resolve
        expect(users).to eq([])
      end

      it 'excludes a locked user' do
        locked = create(:user, status: User::STATUS_LOCKED)
        add_member(locked)
        locked_rule = create(:issue_digest_rule, project: project, recipient_modes: ["user:#{locked.id}"])
        users = described_class.new(locked_rule).resolve
        expect(users).to eq([])
      end
    end

    context 'multiple modes' do
      let!(:rule) do
        create(:issue_digest_rule, project: project,
               recipient_modes: ['project_members', "user:#{user_b.id}"])
      end

      it 'unions recipients across modes' do
        add_member(user_a)
        add_member(user_b)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to match_array([user_a.id, user_b.id])
      end

      it 'deduplicates users that appear in multiple modes' do
        add_member(user_a)
        add_member(user_b)
        # Both modes will find user_b; should appear only once
        users = described_class.new(rule).resolve
        expect(users.count { |u| u.id == user_b.id }).to eq(1)
      end

      it 'emits one Recipient per user with the union of their source modes' do
        add_member(user_a)
        add_member(user_b)
        # user_b matches both project_members (:broad) and user:<id> (:broad).
        recipients = described_class.new(rule).recipients
        expect(recipients.count { |r| r.user.id == user_b.id }).to eq(1)
        b = recipients.find { |r| r.user.id == user_b.id }
        expect(b.modes).to contain_exactly(:broad)
      end
    end

    context 'assignees / authors / watchers modes on a private project' do
      let!(:private_project) { create(:project, is_public: false) }
      let!(:assigned_user)   { create(:user) }
      let!(:author_user)     { create(:user) }
      let!(:watcher_user)    { create(:user) }
      let!(:priv_tracker)    { t = create(:tracker); private_project.trackers << t; t }
      let!(:priv_priority)   { IssuePriority.find_by(is_default: true) || create(:issue_priority, is_default: true) }
      let!(:priv_open_st)    { create(:issue_status, is_closed: false) }

      before do
        [assigned_user, author_user, watcher_user].each do |u|
          Member.create!(principal: u, project: private_project, roles: [role])
        end
        allow_any_instance_of(User).to receive(:deliver_security_notification)
        allow_any_instance_of(Issue).to receive(:add_auto_watcher)
      end

      it 'resolves assignees on a private project' do
        priv_rule = create(:issue_digest_rule, project: private_project,
                           recipient_modes: ['assignees'], include_open: true)
        create(:issue, project: private_project, tracker: priv_tracker, status: priv_open_st,
               priority: priv_priority, author: assigned_user, assigned_to: assigned_user)
        users = described_class.new(priv_rule).resolve
        expect(users.map(&:id)).to include(assigned_user.id)
      end

      it 'resolves authors on a private project' do
        priv_rule = create(:issue_digest_rule, project: private_project,
                           recipient_modes: ['authors'], include_open: true)
        create(:issue, project: private_project, tracker: priv_tracker, status: priv_open_st,
               priority: priv_priority, author: author_user)
        users = described_class.new(priv_rule).resolve
        expect(users.map(&:id)).to include(author_user.id)
      end

      it 'resolves watchers on a private project' do
        priv_rule = create(:issue_digest_rule, project: private_project,
                           recipient_modes: ['watchers'], include_open: true)
        issue = create(:issue, project: private_project, tracker: priv_tracker,
                       status: priv_open_st, priority: priv_priority, author: author_user)
        Watcher.create!(watchable: issue, user: watcher_user)
        users = described_class.new(priv_rule).resolve
        expect(users.map(&:id)).to include(watcher_user.id)
      end
    end

    context 'email: mode' do
      before { allow_any_instance_of(User).to receive(:deliver_security_notification) }

      it 'resolves a Redmine user by email address when they are a project member' do
        add_member(user_a)
        email_rule = create(:issue_digest_rule, project: project,
                            recipient_modes: ["email:#{user_a.mail}"])
        users = described_class.new(email_rule).resolve
        expect(users.map(&:id)).to eq([user_a.id])
      end

      it 'logs a warning and returns empty when no Redmine user has that email' do
        email_rule = create(:issue_digest_rule, project: project,
                            recipient_modes: ['email:ghost@nowhere.example'])
        allow(Rails.logger).to receive(:warn)
        described_class.new(email_rule).resolve
        expect(Rails.logger).to have_received(:warn).with(/g\*\*\*@nowhere\.example/)
      end

      it 'excludes a locked user found by email' do
        locked = create(:user, status: User::STATUS_LOCKED)
        email_rule = create(:issue_digest_rule, project: project,
                            recipient_modes: ["email:#{locked.mail}"])
        users = described_class.new(email_rule).resolve
        expect(users).to eq([])
      end
    end

    context 'permission check' do
      let!(:no_perm_role) { Role.create!(name: "NoPerm_#{SecureRandom.hex(4)}", permissions: []) }
      let!(:rule) { create(:issue_digest_rule, project: project, recipient_modes: ['project_members']) }

      it 'excludes users without view_issues permission' do
        Member.create!(principal: user_a, project: project, roles: [no_perm_role])
        users = described_class.new(rule).resolve
        expect(users).to eq([])
      end
    end

    # Regression for the reported bug: a "new only / open issues" rule using the
    # `assignees` mode resolved every historical assignee in the project
    # (16 recipients, all with 0 matching issues) because recipient discovery ran
    # against base_scope instead of the rule's *filtered* matching scope.
    context 'assignees mode honours the rule filters (regression)' do
      let!(:open_st)   { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
      let!(:closed_st) { create(:issue_status, name: "Closed_#{SecureRandom.hex(4)}", is_closed: true) }
      let!(:tracker)   { t = create(:tracker, default_status: open_st); project.trackers << t; t }
      let!(:priority)  { IssuePriority.find_by(is_default: true) || create(:issue_priority, is_default: true) }
      let!(:assignee_open)   { create(:user) }
      let!(:assignee_closed) { create(:user) }

      before do
        allow_any_instance_of(User).to receive(:deliver_security_notification)
        allow_any_instance_of(Issue).to receive(:add_auto_watcher)
        [assignee_open, assignee_closed].each { |u| add_member(u) }
      end

      def make_issue(status, assignee)
        issue = create(:issue, project: project, tracker: tracker, priority: priority,
                               status: open_st, author: assignee, assigned_to: assignee)
        issue.reload.update_column(:status_id, status.id) if status != open_st
        issue
      end

      it 'excludes assignees whose only issues do not match the rule filters' do
        make_issue(open_st, assignee_open)
        make_issue(closed_st, assignee_closed)

        rule = create(:issue_digest_rule, project: project,
                      recipient_modes: ['assignees'], include_open: true, include_closed: false)

        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to eq([assignee_open.id])
        expect(users.map(&:id)).not_to include(assignee_closed.id)
      end

      it 'resolves zero recipients when no issue matches the filters' do
        make_issue(closed_st, assignee_closed)

        rule = create(:issue_digest_rule, project: project,
                      recipient_modes: ['assignees'], include_open: true, include_closed: false)

        expect(described_class.new(rule).resolve).to eq([])
      end

      it 'tags each recipient with the source mode category via #recipients' do
        make_issue(open_st, assignee_open)
        rule = create(:issue_digest_rule, project: project,
                      recipient_modes: ['assignees'], include_open: true)

        recipients = described_class.new(rule).recipients
        expect(recipients.map { |r| r.user.id }).to eq([assignee_open.id])
        expect(recipients.first.modes).to contain_exactly(:assignees)
      end

      it 'deduplicates a user listed both as an assignee and a specific user' do
        # Reproduces the original "assignees + specific user (Tim)" report: the
        # same person must be a single recipient (one email), carrying both the
        # :assignees and :broad source categories so the broad full-list wins.
        make_issue(open_st, assignee_open)
        rule = create(:issue_digest_rule, project: project,
                      recipient_modes: ['assignees', "user:#{assignee_open.id}"],
                      include_open: true)

        recipients = described_class.new(rule).recipients
        expect(recipients.count { |r| r.user.id == assignee_open.id }).to eq(1)
        expect(recipients.first.modes).to contain_exactly(:assignees, :broad)
      end
    end

    # S1: when the rule includes sub-projects, a recipient who can only view
    # issues in a sub-project (not in the rule's own project) must still be
    # eligible. Before the fix the eligibility gate checked the parent project
    # only, silently dropping such recipients.
    context 'sub-project recipients (include_subprojects)' do
      let!(:parent_project) { create(:project) }
      let!(:child_project)  { create(:project) }
      let!(:sub_member)     { create(:user) }
      let!(:tracker)        { t = create(:tracker); child_project.trackers << t; t }
      let!(:priority)       { IssuePriority.find_by(is_default: true) || create(:issue_priority, is_default: true) }
      let!(:open_st)        { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }

      before do
        allow_any_instance_of(User).to receive(:deliver_security_notification)
        allow_any_instance_of(Issue).to receive(:add_auto_watcher)
        child_project.set_parent!(parent_project)
        # set_parent! rewrites the nested-set bounds in the DB; refresh the
        # in-memory parent so its lft/rgt (used for the subtree scope) are current.
        parent_project.reload
        # sub_member belongs to the CHILD project only, not the parent.
        Member.create!(principal: sub_member, project: child_project, roles: [role])
      end

      def child_issue(assignee)
        create(:issue, project: child_project, tracker: tracker, status: open_st,
                       priority: priority, author: assignee, assigned_to: assignee)
      end

      it 'includes a sub-project-only assignee when include_subprojects is on' do
        child_issue(sub_member)
        rule = create(:issue_digest_rule, project: parent_project,
                      recipient_modes: ['assignees'], include_open: true,
                      include_subprojects: true)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).to include(sub_member.id)
      end

      it 'excludes the sub-project-only assignee when include_subprojects is off' do
        child_issue(sub_member)
        rule = create(:issue_digest_rule, project: parent_project,
                      recipient_modes: ['assignees'], include_open: true,
                      include_subprojects: false)
        users = described_class.new(rule).resolve
        expect(users.map(&:id)).not_to include(sub_member.id)
      end
    end
  end
end

RSpec.describe IssueDigest::RecipientResolver, type: :service do
  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
  end

  describe 'email lookup logging' do
    it 'redacts the local part of configured email recipients' do
      project = create(:project)
      user = create(:user)
      rule = build(:issue_digest_rule, project: project, created_by: user)
      resolver = described_class.new(rule)

      expect(resolver.send(:redacted_email, 'alice@example.com')).to eq('a***@example.com')
    end
  end
end
