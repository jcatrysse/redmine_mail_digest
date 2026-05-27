# frozen_string_literal: true

module IssueDigest
  class QueryAdapter
    attr_reader :warning

    def initialize(rule)
      @rule    = rule
      @warning = nil
    end

    def apply_to(scope)
      return scope if @rule.query_id.blank?

      query = IssueQuery.find_by(id: @rule.query_id)

      if query.nil?
        @warning = "Saved query ##{@rule.query_id} no longer exists; the query filter was skipped."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} not found; skipping query filter"
        return scope
      end

      # Defense in depth: never call #statement on something that
      # isn't a genuine IssueQuery, even if find_by returns an STI sibling.
      unless query.is_a?(IssueQuery)
        @warning = "Query ##{@rule.query_id} is not an IssueQuery; the query filter was skipped."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} is not an IssueQuery; skipping query filter"
        return scope
      end

      unless query_visible?(query)
        @warning = "Query ##{@rule.query_id} is not visible to this rule; the query filter was skipped."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} not visible; skipping query filter"
        return scope
      end

      stmt = query.statement
      stmt.present? ? scope.where(stmt) : scope
    rescue StandardError => e
      @warning = "Query filter error: #{e.message.truncate(200)}"
      Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query adapter error: #{e.message}; skipping query filter"
      scope
    end

    private

    def query_visible?(query)
      query.visibility == Query::VISIBILITY_PUBLIC ||
        query.project_id == @rule.project_id
    end
  end
end
