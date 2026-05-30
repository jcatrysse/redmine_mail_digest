# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::QueryAdapter, type: :service do
  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
  end

  let!(:role)    { Role.create!(name: "QARole_#{SecureRandom.hex(4)}", permissions: [:view_issues]) }
  let!(:project) { create(:project, is_public: true) }
  let!(:other_project) { create(:project, is_public: false) }
  let!(:author)  { create(:user, admin: true) }

  describe '#apply_to' do
    it 'returns the original scope when query_id is blank' do
      rule = create(:issue_digest_rule, project: project, query: nil)
      scope = Issue.all
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'returns the original scope when the query no longer exists' do
      rule = create(:issue_digest_rule, project: project)
      rule.update_column(:query_id, 999_999)
      scope = Issue.all
      expect(Rails.logger).to receive(:warn).with(/not found/)
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'returns the original scope when the query belongs to a different project' do
      private_query = IssueQuery.create!(
        name: 'private_q',
        project: other_project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author
      )
      rule = build(:issue_digest_rule, project: project, query: private_query)
      scope = Issue.all
      expect(Rails.logger).to receive(:warn).with(/not in project/)
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'skips a public project-scoped query from another project' do
      public_query = IssueQuery.create!(
        name: 'public_q',
        project: other_project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = build(:issue_digest_rule, project: project, query: public_query)
      scope = Issue.all
      expect(Rails.logger).to receive(:warn).with(/not in project/)
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'applies a same-project private query owned by the rule creator' do
      private_query = IssueQuery.create!(
        name: 'own_q',
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = build(:issue_digest_rule, project: project, query: private_query, created_by: author)
      scope = Issue.all
      result = described_class.new(rule).apply_to(scope)
      expect(result.to_sql).to match(/issue_statuses|is_closed/i)
    end

    it 'applies a same-project private query regardless of who owns it' do
      owner = create(:user)
      creator = create(:user)
      private_query = IssueQuery.create!(
        name: 'other_private_q',
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: owner,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = build(:issue_digest_rule, project: project, query: private_query, created_by: creator)
      scope = Issue.all
      result = described_class.new(rule).apply_to(scope)
      expect(result.to_sql).to match(/issue_statuses|is_closed/i)
    end

    it 'applies a global (no project) query' do
      global_query = IssueQuery.create!(
        name: 'global_q',
        project: nil,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = build(:issue_digest_rule, project: project, query: global_query, created_by: author)
      scope = Issue.all
      result = described_class.new(rule).apply_to(scope)
      expect(result.to_sql).to match(/issue_statuses|is_closed/i)
    end

    it 'swallows any unexpected exception and returns the original scope' do
      rule = create(:issue_digest_rule, project: project)
      bad_query = IssueQuery.create!(
        name: 'bad_q',
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author
      )
      rule.update_column(:query_id, bad_query.id)
      allow_any_instance_of(IssueQuery).to receive(:statement).and_raise(StandardError, 'boom')
      scope = Issue.all
      expect(Rails.logger).to receive(:warn).with(/query adapter error/)
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'returns the original scope when statement is blank' do
      empty_query = IssueQuery.create!(
        name: 'empty_q',
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author
      )
      rule = build(:issue_digest_rule, project: project, query: empty_query)
      allow_any_instance_of(IssueQuery).to receive(:statement).and_return('')
      scope = Issue.all
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end
  end

  describe '#warning' do
    it 'is nil when query_id is blank' do
      rule = create(:issue_digest_rule, project: project, query: nil)
      adapter = described_class.new(rule)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to be_nil
    end

    it 'is nil when the query applies successfully' do
      public_query = IssueQuery.create!(
        name: 'ok_q',
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author
      )
      rule = build(:issue_digest_rule, project: project, query: public_query)
      adapter = described_class.new(rule)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to be_nil
    end

    it 'is set when the query no longer exists' do
      rule = create(:issue_digest_rule, project: project)
      rule.update_column(:query_id, 999_999)
      adapter = described_class.new(rule)
      expect(Rails.logger).to receive(:warn).with(/not found/)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to match(/no longer exists/)
    end

    it 'is set when the query belongs to another project' do
      private_query = IssueQuery.create!(
        name: 'priv_q',
        project: other_project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author
      )
      rule = build(:issue_digest_rule, project: project, query: private_query)
      adapter = described_class.new(rule)
      expect(Rails.logger).to receive(:warn).with(/not in project/)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to match(/does not belong to this project/)
    end

    it 'is set when an unexpected error occurs' do
      bad_query = IssueQuery.create!(
        name: 'bad_q',
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author
      )
      rule = build(:issue_digest_rule, project: project, query: bad_query)
      allow_any_instance_of(IssueQuery).to receive(:statement).and_raise(StandardError, 'oops')
      adapter = described_class.new(rule)
      expect(Rails.logger).to receive(:warn).with(/query adapter error/)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to match(/oops/)
    end
  end
end
