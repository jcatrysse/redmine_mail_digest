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
        @warning = "Saved query ##{@rule.query_id} no longer exists; digest delivery was blocked."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} not found; blocking delivery"
        return scope
      end

      # Defense in depth: never call #statement on something that
      # isn't a genuine IssueQuery, even if find_by returns an STI sibling.
      unless query.is_a?(IssueQuery)
        @warning = "Query ##{@rule.query_id} is not an IssueQuery; digest delivery was blocked."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} is not an IssueQuery; blocking delivery"
        return scope
      end

      unless self.class.query_usable_for_rule?(query, @rule)
        @warning = "Query ##{@rule.query_id} does not belong to this project; digest delivery was blocked."
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query ##{@rule.query_id} not in project; blocking delivery"
        return scope
      end

      stmt = query.statement
      stmt.present? ? scope.where(stmt) : scope
    rescue StandardError => e
      @warning = "Query filter error; digest delivery was blocked: #{e.message.truncate(200)}"
      Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: query adapter error: #{e.message}; blocking delivery"
      scope
    end

    # A saved query is usable by a rule when it is an IssueQuery that either is
    # global (no project) or belongs to the rule's project. Redmine's per-user
    # visibility is intentionally NOT considered: digest rules are managed
    # collaboratively by anyone with the project permission, so every manager
    # sees and can use the same project/global queries. Per-recipient data
    # protection is still enforced separately via Issue.visible(user).
    def self.query_usable_for_rule?(query, rule)
      return false unless query.is_a?(IssueQuery)

      query.project_id.nil? || query.project_id == rule.project_id
    end
  end
end
