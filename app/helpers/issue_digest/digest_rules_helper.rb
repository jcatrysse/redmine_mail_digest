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
      content_tag(:span, label, class: css, 'aria-label' => "Status: #{label}")
    end

    def format_run_status(run)
      return ''.html_safe if run.nil?

      css   = RUN_STATUS_BADGE_CLASSES[run.status] || 'badge'
      label = l(:"run_status_#{run.status}")
      content_tag(:span, label, class: css, 'aria-label' => "Run status: #{label}")
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

    def recipient_modes_description(rule)
      modes = Array(rule.recipient_modes)
      return '' if modes.empty?

      modes.map { |m| recipient_mode_label(m) }.join(', ')
    end

    def recipient_mode_label(mode)
      case mode
      when 'project_members' then l(:recipient_mode_project_members)
      when 'assignees'       then l(:recipient_mode_assignees)
      when 'authors'         then l(:recipient_mode_authors)
      when 'watchers'        then l(:recipient_mode_watchers)
      when /\Arole:(\d+)\z/
        role = Role.find_by(id: Regexp.last_match(1))
        "#{l(:recipient_mode_role)} #{role&.name || Regexp.last_match(1)}"
      when /\Auser:(\d+)\z/
        user = User.find_by(id: Regexp.last_match(1))
        "#{l(:recipient_mode_users)} #{user&.name || Regexp.last_match(1)}"
      when /\Aemail:(.+)\z/
        Regexp.last_match(1)
      else
        mode
      end
    end

    def external_recipients_allowed?
      ActiveModel::Type::Boolean.new.cast(Setting.plugin_redmine_digest['allow_external_recipients'])
    end

    def project_members_for_digest(project)
      User.joins(:members)
          .where(members: { project_id: project.id })
          .where(status: User::STATUS_ACTIVE)
          .order(:lastname, :firstname)
    end

    def available_timezones
      # Memoized per request: ActiveSupport::TimeZone.all builds and sorts the
      # full zone list, which is wasted work if the form re-reads it.
      @available_timezones ||=
        ActiveSupport::TimeZone.all.map { |tz| [tz.name, tz.tzinfo.name] }.sort_by(&:first)
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

      IssueQuery.where('project_id = ? OR visibility = ?', project.id, Query::VISIBILITY_PUBLIC)
                .includes(:user)
                .order(:name)
    end

    # Returns a display label that disambiguates queries with identical names.
    # Format: "Query name [owner_login, public]" or "Query name [owner_login, project]"
    def query_dropdown_label(query)
      vis   = query.visibility == Query::VISIBILITY_PUBLIC ? l(:label_public) : l(:label_mine)
      owner = query.user&.login.presence || '—'
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
      parts << l(:filter_only_since_last_run)                                          if rule.respond_to?(:only_since_last_run?) && rule.only_since_last_run?
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

      if t.respond_to?(:strftime)
        t.strftime('%H:%M')
      else
        t.to_s
      end
    end
  end
end
