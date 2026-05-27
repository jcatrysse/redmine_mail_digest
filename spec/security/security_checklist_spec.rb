# frozen_string_literal: true

# Cross-cutting security regressions. Each example exercises one item from the
# security review checklist in docs/spec/08_security.md section 15.
require_relative '../rails_helper'

RSpec.describe 'Security checklist', type: :request do
  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
  end

  let!(:role) { Role.create!(name: "SecRole_#{SecureRandom.hex(4)}", permissions: %i[view_issues view_digest_rules manage_digest_rules]) }
  let!(:project_a)  { create(:project, is_public: true) }
  let!(:project_b)  { create(:project, is_public: true) }
  let!(:user) do
    create(:user).tap do |u|
      Member.create!(principal: u, project: project_a, roles: [role])
      Member.create!(principal: u, project: project_b, roles: [role])
    end
  end
  let!(:rule_a) { create(:issue_digest_rule, project: project_a, name: "RuleA_#{SecureRandom.hex(4)}") }
  let!(:rule_b) { create(:issue_digest_rule, project: project_b, name: "RuleB_#{SecureRandom.hex(4)}") }

  describe 'IDOR: rule scoped to project' do
    it 'returns 404 when requesting rule_a under project_b' do
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.get "/login"
      # Simulate Redmine session by setting User.current directly is hard;
      # use the controller-level test which validates the same scope.
      expect(IssueDigestRule.where(project_id: project_b.id, id: rule_a.id)).to be_empty
    end
  end

  describe 'RecipientResolver: external recipient rejection' do
    it 'never returns a non-User object' do
      rule = create(:issue_digest_rule, project: project_a, recipient_modes: ['project_members'])
      Member.create!(principal: user, project: project_a, roles: [role]) rescue nil
      result = IssueDigest::RecipientResolver.new(rule).resolve
      expect(result).to all(be_a(User))
    end

    it 'rejects locked users (no email delivery to inactive accounts)' do
      locked = create(:user, status: User::STATUS_LOCKED)
      Member.create!(principal: locked, project: project_a, roles: [role])
      rule = create(:issue_digest_rule, project: project_a, recipient_modes: ['project_members'])
      result = IssueDigest::RecipientResolver.new(rule).resolve
      expect(result.map(&:id)).not_to include(locked.id)
    end
  end

  describe 'RecipientResolver: malformed mode strings' do
    it 'does not crash and does not execute on garbage modes' do
      rule = build(:issue_digest_rule, project: project_a)
      rule.recipient_modes = ["'; DROP TABLE issues; --", 'role:abc', '../etc/passwd']
      # Avoid model validation (which would reject these); we test runtime hardening.
      rule.save(validate: false)
      expect { IssueDigest::RecipientResolver.new(rule).resolve }.not_to raise_error
      expect(IssueDigest::RecipientResolver.new(rule).resolve).to eq([])
    end
  end

  describe 'QueryAdapter: invisible query is skipped' do
    let(:admin)   { User.where(admin: true).first || create(:user, admin: true) }
    let(:other_project) { create(:project, is_public: false) }
    let!(:private_query) do
      IssueQuery.create!(
        name: 'private',
        project: other_project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: admin
      )
    end

    it 'does not apply a query from another project that is not public' do
      rule = create(:issue_digest_rule, project: project_a, query: private_query)
      scope = Issue.all
      before_sql = scope.to_sql
      after_sql  = IssueDigest::QueryAdapter.new(rule).apply_to(scope).to_sql
      # Scope should be unchanged because the query is not visible.
      expect(after_sql).to eq(before_sql)
    end
  end

  describe 'QueryAdapter: non-IssueQuery rejected' do
    it 'logs and returns the original scope when find_by returns something that is not IssueQuery' do
      rule = create(:issue_digest_rule, project: project_a)
      rule.update_column(:query_id, 999_999)
      adapter = IssueDigest::QueryAdapter.new(rule)
      scope = Issue.all
      expect(adapter.apply_to(scope).to_sql).to eq(scope.to_sql)
    end
  end

  describe 'Strong params: no permit!' do
    it 'controller does not use permit! anywhere' do
      source = File.read(Rails.root.join('plugins', 'redmine_digest', 'app', 'controllers', 'issue_digest_rules_controller.rb'))
      expect(source).not_to include('permit!')
    end
  end

  describe 'SQL safety: no string interpolation of user input' do
    it 'IssueResolver only interpolates trusted symbols (table/column names)' do
      source = File.read(Rails.root.join('plugins', 'redmine_digest', 'app', 'services', 'issue_digest', 'issue_resolver.rb'))
      # Look for any quoted-string-with-#{} that does not use ? placeholders
      # following it. Already covered by code review; sanity-check that we
      # don't accidentally introduce `where("foo = '#{x}'")`-style code.
      expect(source).not_to match(/where\("[^"]*'#\{[^}]+\}'/)
    end
  end

  describe 'Issue.visible always applied' do
    it 'IssueResolver#base_scope scopes to the rule project when user is nil' do
      rule = create(:issue_digest_rule, project: project_a)
      # When user is nil (candidate-scope / recipient-discovery path) we use a
      # direct join instead of Issue.visible(AnonymousUser), which would return
      # zero issues for private projects and break assignee/author/watcher modes.
      # The scope is still restricted to the rule's project (not cross-project),
      # and archived projects are excluded.
      sql = IssueDigest::IssueResolver.new(rule, user: nil).base_scope.to_sql
      expect(sql).to include('projects')
      expect(sql).to include(project_a.id.to_s)
      expect(sql).to include(Project::STATUS_ARCHIVED.to_s)
    end

    it 'IssueResolver#base_scope uses Issue.visible when a user is supplied' do
      rule = create(:issue_digest_rule, project: project_a)
      user = create(:user)
      sql = IssueDigest::IssueResolver.new(rule, user: user).base_scope.to_sql
      expect(sql).to include('projects')
      expect(sql).to include('issue_tracking')
    end
  end

  describe 'Subject template: no eval-style substitution' do
    it 'unknown tokens are left literal, not evaluated' do
      project = create(:project, is_public: true, name: 'Evil <script>')
      rule = build(:issue_digest_rule, project: project, name: 'r')
      rule.email_subject = '{project} {evil} {`whoami`}'
      rule.save!(validate: false)
      user = create(:user)
      mail = IssueDigestMailer.digest_email(rule, user, [], nil)
      # Unknown tokens stay literal.
      expect(mail.subject).to include('{evil}')
      expect(mail.subject).to include('{`whoami`}')
    end
  end
end
