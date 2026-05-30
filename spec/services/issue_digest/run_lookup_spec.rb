# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::RunLookup, type: :service do
  describe '.latest_by_rule_id' do
    it 'returns the latest run per rule by started_at' do
      rule_a = create(:issue_digest_rule)
      rule_b = create(:issue_digest_rule)
      older = create(:issue_digest_run, issue_digest_rule: rule_a, started_at: 2.days.ago)
      newer = create(:issue_digest_run, issue_digest_rule: rule_a, started_at: 1.day.ago)
      only = create(:issue_digest_run, issue_digest_rule: rule_b, started_at: 3.days.ago)

      result = described_class.latest_by_rule_id([rule_a, rule_b])
      expect(result).to eq(rule_a.id => newer, rule_b.id => only)
      expect(result.values).not_to include(older)
    end

    it 'uses id as a deterministic tie-breaker when started_at matches' do
      rule = create(:issue_digest_rule)
      timestamp = Time.current.change(usec: 0)
      create(:issue_digest_run, issue_digest_rule: rule, started_at: timestamp)
      newer_id = create(:issue_digest_run, issue_digest_rule: rule, started_at: timestamp)

      expect(described_class.latest_by_rule_id([rule])).to eq(rule.id => newer_id)
    end

    it 'does not treat a higher id with an older started_at as latest' do
      rule = create(:issue_digest_rule)
      latest_by_time = create(:issue_digest_run, issue_digest_rule: rule, started_at: 1.hour.ago)
      older_by_time = create(:issue_digest_run, issue_digest_rule: rule, started_at: 2.hours.ago)

      expect(older_by_time.id).to be > latest_by_time.id
      expect(described_class.latest_by_rule_id([rule])).to eq(rule.id => latest_by_time)
    end

    it 'returns an empty hash without querying when there are no rules' do
      expect(IssueDigestRun).not_to receive(:where)
      expect(described_class.latest_by_rule_id([])).to eq({})
    end
  end
end
