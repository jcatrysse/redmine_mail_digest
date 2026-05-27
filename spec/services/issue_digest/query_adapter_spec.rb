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

    it 'returns the original scope when the query is private and belongs to a different project' do
      private_query = IssueQuery.create!(
        name: 'private_q',
        project: other_project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author
      )
      rule = create(:issue_digest_rule, project: project, query: private_query)
      scope = Issue.all
      expect(Rails.logger).to receive(:warn).with(/not visible/)
      expect(described_class.new(rule).apply_to(scope).to_sql).to eq(scope.to_sql)
    end

    it 'applies a public query from another project' do
      public_query = IssueQuery.create!(
        name: 'public_q',
        project: other_project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = create(:issue_digest_rule, project: project, query: public_query)
      scope = Issue.all
      result = described_class.new(rule).apply_to(scope)
      # Sanity: the WHERE clause should reference issue_statuses (set by the
      # 'o' = "open" filter).
      expect(result.to_sql).to match(/issue_statuses|is_closed/i)
    end

    it 'applies a query belonging to the same project even if not public' do
      private_query = IssueQuery.create!(
        name: 'own_q',
        project: project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author,
        filters: { 'status_id' => { operator: 'o', values: [''] } }
      )
      rule = create(:issue_digest_rule, project: project, query: private_query)
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
      rule = create(:issue_digest_rule, project: project, query: empty_query)
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
      rule = create(:issue_digest_rule, project: project, query: public_query)
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

    it 'is set when the query is not visible' do
      private_query = IssueQuery.create!(
        name: 'priv_q',
        project: other_project,
        visibility: Query::VISIBILITY_PRIVATE,
        user: author
      )
      rule = create(:issue_digest_rule, project: project, query: private_query)
      adapter = described_class.new(rule)
      expect(Rails.logger).to receive(:warn).with(/not visible/)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to match(/not visible/)
    end

    it 'is set when an unexpected error occurs' do
      bad_query = IssueQuery.create!(
        name: 'bad_q',
        project: project,
        visibility: Query::VISIBILITY_PUBLIC,
        user: author
      )
      rule = create(:issue_digest_rule, project: project, query: bad_query)
      allow_any_instance_of(IssueQuery).to receive(:statement).and_raise(StandardError, 'oops')
      adapter = described_class.new(rule)
      expect(Rails.logger).to receive(:warn).with(/query adapter error/)
      adapter.apply_to(Issue.all)
      expect(adapter.warning).to match(/oops/)
    end
  end
end
