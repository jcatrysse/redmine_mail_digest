# frozen_string_literal: true

module IssueDigest
  class RecipientResolver
    # A resolved recipient plus the personalization categories (:assignees,
    # :authors, :watchers, :broad) of the recipient modes that selected them.
    # DigestSender uses #modes for source-aware per-recipient issue scoping.
    Recipient = Struct.new(:user, :modes, keyword_init: true)

    def initialize(rule, issues_scope: nil)
      @rule         = rule
      @issues_scope = issues_scope
    end

    # Backward-compatible: returns the de-duplicated, eligible [User] list.
    def resolve
      recipients.map(&:user)
    end

    # Returns [Recipient]. Each user is de-duplicated across modes; the union
    # of the mode categories that matched them is preserved so the sender can
    # decide whether to narrow their digest (assignees/authors/watchers) or
    # send the full matching list (any :broad mode).
    def recipients
      by_user = {}
      Array(@rule.recipient_modes).each do |mode|
        category = mode_category(mode)
        resolve_mode(mode).each do |user|
          entry = (by_user[user.id] ||= { user: user, modes: Set.new })
          entry[:modes] << category
        end
      rescue StandardError => e
        Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: recipient mode '#{mode}' error: #{e.class}: #{e.message}"
      end

      by_user.values
             .select { |entry| eligible?(entry[:user]) }
             .map { |entry| Recipient.new(user: entry[:user], modes: entry[:modes]) }
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: RecipientResolver failed: #{e.class}: #{e.message}"
      []
    end

    private

    # Maps a raw recipient-mode string to its personalization category.
    # Only assignees/authors/watchers narrow the recipient's issue list; every
    # other mode (project members, role, specific user, email) is :broad and
    # grants the full matching list.
    def mode_category(mode)
      case mode
      when 'assignees' then :assignees
      when 'authors'   then :authors
      when 'watchers'  then :watchers
      else :broad
      end
    end

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
      User.where(status: User::STATUS_ACTIVE)
          .joins(:members).where(members: { project_id: @rule.project_id })
    end

    def role_users(role_id)
      User.where(status: User::STATUS_ACTIVE)
          .joins(members: :member_roles)
          .where(members: { project_id: @rule.project_id })
          .where(member_roles: { role_id: role_id })
    end

    def assignee_users
      User.where(status: User::STATUS_ACTIVE)
          .where(id: matching_issues.where.not(assigned_to_id: nil).select(:assigned_to_id))
    end

    def author_users
      User.where(status: User::STATUS_ACTIVE)
          .where(id: matching_issues.select(:author_id))
    end

    def watcher_users
      User.where(status: User::STATUS_ACTIVE)
          .where(id: Watcher.where(watchable_type: 'Issue', watchable_id: matching_issues.select(:id)).select(:user_id))
    end

    # The matching-issue scope used as a subquery for assignee/author/watcher
    # resolution. Stripping the ORDER BY keeps the generated subquery portable
    # across PostgreSQL/MySQL/SQLite (an ordered subquery in IN (...) is at best
    # pointless and at worst rejected on some configurations).
    def matching_issues
      issues_scope.reorder(nil)
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
        Rails.logger.warn "[IssueDigest] Rule ##{@rule.id}: no Redmine user found for configured email recipient (#{redacted_email(email)})"
        return []
      end
      [user]
    end

    def redacted_email(email)
      local, domain = email.to_s.split('@', 2)
      return '[invalid]' if local.blank? || domain.blank?

      "#{local.first}***@#{domain}"
    end

    def issues_scope
      # Must be the *filtered* matching scope (spec §6.1: "assigned to at least
      # one matching issue"), not base_scope. Using base_scope here was the root
      # cause of digests reaching every historical assignee in the project
      # regardless of the rule's status/date/since-last-run filters.
      @issues_scope || IssueDigest::IssueResolver.new(@rule, user: nil).resolve
    end

    def eligible?(user)
      return false unless user.is_a?(User)
      return false if user.anonymous?
      return false unless user.active?
      return false if user.mail.blank?
      return false unless can_view_issues_in_scope?(user)

      true
    end

    # Permission gate for recipients. With include_subprojects the matching
    # issues can live in any project of the rule's subtree, so a recipient is
    # eligible when they may view issues in the rule's project OR in any
    # descendant project that is part of the scope (e.g. someone who is only a
    # member of a subproject but is the assignee/author/watcher of a matching
    # subproject issue). Without subprojects the check stays scoped to the
    # rule's own project, preserving the previous behaviour exactly.
    def can_view_issues_in_scope?(user)
      if @rule.include_subprojects?
        scope_projects.any? { |project| user.allowed_to?(:view_issues, project) }
      else
        user.allowed_to?(:view_issues, @rule.project)
      end
    end

    # The rule's project subtree, excluding archived projects (mirrors the
    # candidate issue scope in IssueResolver#base_scope). Memoized so the
    # per-recipient permission loop does not re-query the tree.
    def scope_projects
      @scope_projects ||= @rule.project
                               .self_and_descendants
                               .where.not(status: Project::STATUS_ARCHIVED)
                               .to_a
    end
  end
end
