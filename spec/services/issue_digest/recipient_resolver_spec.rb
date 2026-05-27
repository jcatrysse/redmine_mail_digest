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
        expect(Rails.logger).to have_received(:warn).with(/ghost@nowhere\.example/)
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
  end
end
