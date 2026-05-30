# frozen_string_literal: true

module IssueDigest
  module DigestRulesHelper
    STATUS_BADGE_CLASSES = {
      active:   'badge badge-success',
      disabled: 'badge badge-inactive',
      expired:  'badge badge-error',
      pending:  'badge badge-warning'
    }.freeze

    RUN_STATUS_BADGE_CLASSES = {
      'running'          => 'badge badge-warning',
      'success'          => 'badge badge-success',
      'partial_failure'  => 'badge badge-warning',
      'failed'           => 'badge badge-error',
      'error'            => 'badge badge-error',
      'skipped'          => 'badge badge-inactive'
    }.freeze

    DAY_OF_WEEK_KEYS = {
      1 => :label_monday,
      2 => :label_tuesday,
      3 => :label_wednesday,
      4 => :label_thursday,
      5 => :label_friday,
      6 => :label_saturday,
      7 => :label_sunday
    }.freeze

    def digest_rule_status_badge(rule)
      status = rule.status_label
      css    = STATUS_BADGE_CLASSES[status] || 'badge'
      label  = l(:"status_#{status}")
      content_tag(:span, label, class: css, 'aria-label' => l(:aria_rule_status, label: label))
    end

    def format_run_status(run)
      return ''.html_safe if run.nil?

      css   = RUN_STATUS_BADGE_CLASSES[run.status] || 'badge'
      label = l(:"run_status_#{run.status}")
      content_tag(:span, label, class: css, 'aria-label' => l(:aria_run_status, label: label))
    end

    def schedule_description(rule)
      time_part = rule.send_time.present? ? format_send_time(rule) : ''
      tz_part   = rule.timezone.presence || 'UTC'
      case rule.schedule_type
      when 'daily'
        l(:schedule_desc_daily, time: time_part, tz: tz_part).strip
      when 'weekdays'
        days = Array(rule.schedule_config && rule.schedule_config['days']).map { |d| day_of_week_name(d) }.join(', ')
        l(:schedule_desc_weekdays, days: days, time: time_part, tz: tz_part).strip
      when 'weekly'
        day = rule.schedule_config && rule.schedule_config['day']
        l(:schedule_desc_weekly, day: day_of_week_name(day), time: time_part, tz: tz_part).strip
      when 'monthly_date'
        day = rule.schedule_config && rule.schedule_config['day']
        l(:schedule_desc_monthly_date, day: day, time: time_part, tz: tz_part).strip
      when 'monthly_last_day'
        l(:schedule_desc_monthly_last_day, time: time_part, tz: tz_part).strip
      when 'interval_days'
        every = rule.schedule_config && rule.schedule_config['every']
        l(:schedule_desc_interval_days, every: every, time: time_part, tz: tz_part).strip
      when 'interval_weeks'
        every = rule.schedule_config && rule.schedule_config['every']
        l(:schedule_desc_interval_weeks, every: every, time: time_part, tz: tz_part).strip
      when 'interval_hours', 'interval_minutes'
        sub_daily_schedule_description(rule, tz_part)
      when 'manual'
        l(:schedule_type_manual)
      else
        rule.schedule_type.to_s
      end
    end

    def recipient_modes_description(rule, cache: nil)
      modes = Array(rule.recipient_modes)
      return '' if modes.empty?

      modes.map { |m| recipient_mode_label(m, cache: cache) }.join(', ')
    end

    # Optional +cache+ (from #recipient_label_cache) lets list views resolve the
    # role:/user: names without a per-rule find_by, avoiding an N+1 when many
    # rules are shown. When nil, falls back to a direct lookup (fine for the
    # single-rule show page).
    def recipient_mode_label(mode, cache: nil)
      case mode
      when 'project_members' then l(:recipient_mode_project_members)
      when 'assignees'       then l(:recipient_mode_assignees)
      when 'authors'         then l(:recipient_mode_authors)
      when 'watchers'        then l(:recipient_mode_watchers)
      when /\Arole:(\d+)\z/
        id   = Regexp.last_match(1).to_i
        role = cache ? cache[:roles][id] : Role.find_by(id: id)
        "#{l(:recipient_mode_role)} #{role&.name || id}"
      when /\Auser:(\d+)\z/
        id   = Regexp.last_match(1).to_i
        user = cache ? cache[:users][id] : User.find_by(id: id)
        "#{l(:recipient_mode_users)} #{user&.name || id}"
      when /\Aemail:(.+)\z/
        Regexp.last_match(1)
      else
        mode
      end
    end

    # Builds an id => record lookup for the role:/user: recipient modes across
    # the given rules, so a list view can render every rule's recipients with
    # two queries total instead of one find_by per role/user per rule.
    def recipient_label_cache(rules)
      modes    = Array(rules).flat_map { |r| Array(r.recipient_modes) }
      role_ids = modes.grep(/\Arole:\d+\z/).map { |m| m.delete_prefix('role:').to_i }.uniq
      user_ids = modes.grep(/\Auser:\d+\z/).map { |m| m.delete_prefix('user:').to_i }.uniq
      {
        roles: role_ids.any? ? Role.where(id: role_ids).index_by(&:id) : {},
        users: user_ids.any? ? User.where(id: user_ids).index_by(&:id) : {}
      }
    end

    def external_recipients_allowed?
      ActiveModel::Type::Boolean.new.cast(Setting.plugin_redmine_mail_digest['allow_external_recipients'])
    end

    def project_members_for_digest(project)
      User.joins(:members)
          .where(members: { project_id: project.id })
          .where(status: User::STATUS_ACTIVE)
          .order(:lastname, :firstname)
    end

    def available_roles_for_digest
      Role.givable
    end

    def available_timezones
      # Memoized per request: ActiveSupport::TimeZone.all builds and sorts the
      # full zone list, which is wasted work if the form re-reads it.
      # Sorted by UTC offset (standard time) so the dropdown reads west→east.
      @available_timezones ||=
        ActiveSupport::TimeZone.all
          .sort_by(&:utc_offset)
          .map { |tz| ["(UTC#{tz.formatted_offset}) #{tz.name}", tz.tzinfo.name] }
    end

    # Renders the native "+/-" toggle that sits next to the specific-users
    # multiselect, matching Redmine's filter UI on both supported lines:
    #   * Redmine 6.x ships SVG sprite icons; the span carries an <svg> and
    #     toggleMultiSelectIconInit() picks the plus/minus glyph on page load
    #     from the number of selected options (so no modifier class here).
    #   * Redmine 5.1 uses CSS background-image icons, so the plus/minus
    #     modifier class must be set server-side.
    # The click handler is delegated by Redmine on #content for both lines.
    def digest_multiselect_toggle(multiple)
      if respond_to?(:sprite_icon)
        content_tag(:span, sprite_icon(''), class: 'toggle-multiselect icon-only')
      else
        modifier = multiple ? 'icon-toggle-minus' : 'icon-toggle-plus'
        content_tag(:span, '&nbsp;'.html_safe, class: "toggle-multiselect icon-only #{modifier}")
      end
    end

    def available_queries_for_project(project)
      return IssueQuery.none unless project.module_enabled?(:issue_tracking)

      # Show every global or project-scoped saved query regardless of its
      # per-user visibility: digest rules are a shared, project-level config, so
      # all managers must see the same list. This matches QueryAdapter's
      # usability rule (global or same project) so the dropdown, the model
      # validation, and the send-time filter never disagree.
      #
      # global_or_on_project is available on Redmine 5.1+. The fallback covers
      # any future major version that may rename the scope.
      scope = if IssueQuery.respond_to?(:global_or_on_project)
                IssueQuery.global_or_on_project(project)
              else
                IssueQuery.where(project_id: [nil, project.id])
              end
      scope.includes(:user).order(:name)
    end

    # Returns a display label that disambiguates queries with identical names.
    # Format: "Query name [owner_login, public]" or "Query name [owner_login, project]"
    def query_dropdown_label(query)
      vis = case query.visibility
            when Query::VISIBILITY_PUBLIC  then l(:label_public)
            when Query::VISIBILITY_PRIVATE then l(:label_private, default: 'Private')
            else l(:label_mine)
            end
      owner = query.user&.login.presence || l(:label_none)
      "#{query.name} [#{owner}, #{vis}]"
    end

    def schedule_type_options
      IssueDigestRule::SCHEDULE_TYPES.map { |t| [l(:"schedule_type_#{t}"), t] }
    end

    def group_by_options
      IssueDigestRule::GROUP_BY_OPTIONS.map { |g| [l(:"group_by_#{g}"), g] }
    end

    def non_business_day_behavior_options
      IssueDigestRule::NON_BUSINESS_DAY_BEHAVIORS.map { |b| [l(:"non_business_day_#{b}"), b] }
    end

    def day_of_week_options
      DAY_OF_WEEK_KEYS.map { |d, key| [day_of_week_name(d), d] }
    end

    def day_of_week_name(day)
      return '' if day.blank?

      key = DAY_OF_WEEK_KEYS[day.to_i]
      return day.to_s unless key

      ::I18n.t(key, default: Date::DAYNAMES[day.to_i % 7])
    end

    def filter_summary(rule)
      parts = []
      parts << l(:field_include_open)    if rule.include_open?
      parts << l(:field_include_closed)  if rule.include_closed?
      if rule.include_overdue?
        min_days = rule.respond_to?(:overdue_min_days) && rule.overdue_min_days.to_i > 0 ? rule.overdue_min_days.to_i : nil
        parts << (min_days ? l(:filter_overdue_since_summary, days: min_days) : l(:field_include_overdue))
      end
      parts << l(:filter_due_soon_summary, days: rule.due_soon_days)                  if rule.include_due_soon?
      parts << l(:filter_recently_updated_summary, days: rule.recently_updated_days)  if rule.include_recently_updated?
      parts << l(:filter_recently_created_summary, days: rule.recently_created_days)  if rule.include_recently_created?
      parts << l(:field_include_subprojects)                                           if rule.include_subprojects?
      parts << l(:filter_since_last_run_created) if rule.respond_to?(:since_last_run_created?) && rule.since_last_run_created?
      parts << l(:filter_since_last_run_updated) if rule.respond_to?(:since_last_run_updated?) && rule.since_last_run_updated?
      parts.empty? ? l(:text_no_active_filters) : parts.join(', ')
    end

    def personalization_summary(rule)
      parts = []
      parts << l(:field_filter_assigned_to_recipient) if rule.filter_assigned_to_recipient?
      parts << l(:field_filter_watched_by_recipient)  if rule.filter_watched_by_recipient?
      parts << l(:field_filter_authored_by_recipient) if rule.filter_authored_by_recipient?
      parts.empty? ? nil : parts.join(', ')
    end

    private

    def sub_daily_schedule_description(rule, tz_part)
      config = rule.schedule_config || {}
      every  = config['every'] || '?'
      key    = rule.schedule_type == 'interval_hours' ? :schedule_desc_interval_hours : :schedule_desc_interval_minutes
      parts  = [l(key, every: every, tz: tz_part).strip]

      if config['from'].present? && config['to'].present?
        parts << l(:schedule_desc_time_window, from: config['from'], to: config['to'])
      end

      if (days = config['days']).is_a?(Array) && days.any?
        day_names = days.map { |d| day_of_week_name(d) }.join(', ')
        parts << l(:schedule_desc_on_days, days: day_names)
      end

      parts.join(' ')
    end

    def format_send_time(rule)
      t = rule.send_time
      return '' if t.nil?

      t.strftime('%H:%M')
    end
  end
end
