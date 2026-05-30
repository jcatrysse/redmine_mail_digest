# frozen_string_literal: true

module IssueDigest
  class RunLookup
    def self.latest_by_rule_id(rules)
      rule_ids = Array(rules).map(&:id).compact
      return {} if rule_ids.empty?

      # Three-query approach that avoids the original correlated NOT EXISTS
      # subquery (O(n*m)) while preserving started_at ordering + id tie-breaking.
      #
      # 1. MAX(started_at) per rule  →  bounded GROUP BY on rule_ids
      max_ts = IssueDigestRun
        .where(issue_digest_rule_id: rule_ids)
        .group(:issue_digest_rule_id)
        .maximum(:started_at)
      return {} if max_ts.empty?

      # 2. MAX(id) per rule where started_at = max  →  resolves same-second ties
      table = IssueDigestRun.arel_table
      ts_conditions = max_ts.map do |rule_id, ts|
        table[:issue_digest_rule_id].eq(rule_id).and(table[:started_at].eq(ts))
      end
      max_ids = IssueDigestRun
        .where(ts_conditions.reduce(:or))
        .group(:issue_digest_rule_id)
        .maximum(:id)
        .values
      return {} if max_ids.empty?

      # 3. Load the actual records by primary key
      IssueDigestRun.where(id: max_ids).index_by(&:issue_digest_rule_id)
    end
  end
end
