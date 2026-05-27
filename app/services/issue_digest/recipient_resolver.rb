# frozen_string_literal: true

module IssueDigest
  class RecipientResolver
    def initialize(rule, issues_scope: nil)
      @rule         = rule
      @issues_scope = issues_scope
    end

    def resolve
      users = []
      Array(@rule.recipient_modes).each do |mode|
        users.concat(resolve_mode(mode))
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: recipient mode '#{mode}' error: #{e.class}: #{e.message}"
      end

      users.uniq(&:id).select { |u| eligible?(u) }
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: RecipientResolver failed: #{e.class}: #{e.message}"
      []
    end

    private

    def resolve_mode(mode)
      case mode
      when 'project_members'
        project_member_users
      when /\Arole:(\d+)\z/
        role_users(Regexp.last_match(1).to_i)
      when 'assignees'
        assignee_users
      when 'authors'
        author_users
      when 'watchers'
        watcher_users
      when /\Auser:(\d+)\z/
        specific_user(Regexp.last_match(1).to_i)
      when /\Aemail:(.+)\z/
        user_by_email(Regexp.last_match(1))
      else
        []
      end
    end

    def project_member_users
      User.joins(:members).where(members: { project_id: @rule.project_id })
    end

    def role_users(role_id)
      User.joins(members: :member_roles)
          .where(members: { project_id: @rule.project_id })
          .where(member_roles: { role_id: role_id })
    end

    def assignee_users
      User.where(id: issues_scope.select(:assigned_to_id).where.not(assigned_to_id: nil))
    end

    def author_users
      User.where(id: issues_scope.select(:author_id))
    end

    def watcher_users
      User.where(id: Watcher.where(watchable_type: 'Issue', watchable_id: issues_scope.select(:id)).select(:user_id))
    end

    def specific_user(user_id)
      user = User.find_by(id: user_id)
      return [] unless user

      member = Member.find_by(user_id: user_id, project_id: @rule.project_id)
      return [] unless member

      [user]
    end

    def user_by_email(email)
      # In Redmine 5+, user emails live in the email_addresses table.
      # User.find_by(mail: email) queries users.mail (legacy column) which may
      # differ, so we look up through email_addresses instead.
      user = User.joins(:email_addresses)
                 .where(email_addresses: { address: email })
                 .first
      if user.nil?
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: no Redmine user found for email '#{email}'"
        return []
      end
      [user]
    end

    def issues_scope
      @issues_scope || IssueDigest::IssueResolver.new(@rule, user: nil).base_scope
    end

    def eligible?(user)
      return false unless user.is_a?(User)
      return false if user.anonymous?
      return false unless user.active?
      return false if user.mail.blank?
      return false unless user.allowed_to?(:view_issues, @rule.project)

      true
    end
  end
end
