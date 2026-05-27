# frozen_string_literal: true

module IssueDigest
  class ScheduleEvaluator
    TYPE_CODES = {
      'daily'            => 'D',
      'weekdays'         => 'WD',
      'weekly'           => 'W',
      'monthly_date'     => 'MD',
      'monthly_last_day' => 'ML',
      'interval_days'    => 'ID',
      'interval_weeks'   => 'IW',
      'interval_hours'   => 'IH',
      'interval_minutes' => 'IM',
      'manual'           => 'M'
    }.freeze

    def initialize(rule, time: nil, force: false)
      @rule  = rule
      @time  = time || Time.current
      @force = force
    end

    def due?
      return false if @rule.schedule_type == 'manual' && !@force
      return false unless @rule.active?

      config = parse_config
      return false if config.nil?

      tz         = @rule.timezone.presence || 'UTC'
      local_time = @time.in_time_zone(tz)
      local_date = local_time.to_date

      return sub_daily_due?(local_time, config) if sub_daily_type?

      # For weekdays the user explicitly chose the days; no shift applies.
      if @rule.schedule_type == 'weekdays'
        days = config['days']
        return false unless days.is_a?(Array) && days.any? && days.include?(local_date.cwday)
        return false unless within_grace_window?(local_time, local_date, tz)
        key = compute_schedule_key_for(local_date, config)
        return false if key && @rule.last_schedule_key == key && !@force
        return true
      end

      # For all other types: derive the canonical period date, shift to execution date.
      canonical = canonical_period_date(local_date, config)
      return false if canonical.nil?

      execution = execution_date(canonical)
      return false if execution.nil?
      return false if execution != local_date

      return false unless within_grace_window?(local_time, local_date, tz)

      key = compute_schedule_key_for(canonical, config)
      return false if key && @rule.last_schedule_key == key && !@force

      true
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] ScheduleEvaluator error for rule ##{@rule.id}: #{e.class}: #{e.message}"
      false
    end

    def compute_schedule_key
      return sub_daily_schedule_key if sub_daily_type?

      config = parse_config
      return nil if config.nil?

      tz         = @time.in_time_zone(@rule.timezone.presence || 'UTC')
      local_date = tz.to_date
      canonical  = @rule.schedule_type == 'weekdays' ? local_date : canonical_period_date(local_date, config)
      compute_schedule_key_for(canonical, config)
    rescue StandardError
      nil
    end

    private

    def sub_daily_type?
      IssueDigestRule::SUB_DAILY_TYPES.include?(@rule.schedule_type)
    end

    # Returns the period number (integer) for the current time against the anchor.
    # Two cron runs within the same period will compute the same period number,
    # which the schedule_key idempotency check uses to suppress duplicate sends.
    def sub_daily_due?(local_time, config)
      every = config['every'].to_i
      return false if every < 1

      # Optional day-of-week filter
      if (days = config['days']).is_a?(Array) && days.any?
        return false unless days.include?(local_time.to_date.cwday)
      end

      # Optional time-window filter (HH:MM strings, 24-hour)
      if config['from'].present? && config['to'].present?
        current_minutes = local_time.hour * 60 + local_time.min
        from_minutes    = parse_hhmm(config['from'])
        to_minutes      = parse_hhmm(config['to'])
        return false unless minutes_in_window?(current_minutes, from_minutes, to_minutes)
      end

      key = sub_daily_period_key(every)
      return false if key.nil?
      return false if @rule.last_schedule_key == key && !@force

      true
    rescue StandardError => e
      Rails.logger.error "[IssueDigest] ScheduleEvaluator sub_daily_due? error rule ##{@rule.id}: #{e.class}: #{e.message}"
      false
    end

    def sub_daily_schedule_key
      config = parse_config
      return nil if config.nil?

      every = config['every'].to_i
      return nil if every < 1

      sub_daily_period_key(every)
    rescue StandardError
      nil
    end

    # Single source of truth for the period-based idempotency key used by
    # both sub_daily_due? and sub_daily_schedule_key.
    def sub_daily_period_key(every)
      interval_seconds = sub_daily_interval_seconds(every)
      return nil unless interval_seconds

      anchor  = sub_daily_anchor_time
      elapsed = @time.to_i - anchor.to_i
      return nil if elapsed < 0

      period_number = elapsed / interval_seconds
      "#{@rule.id}:#{TYPE_CODES[@rule.schedule_type]}:#{period_number}"
    end

    def sub_daily_interval_seconds(every)
      case @rule.schedule_type
      when 'interval_hours'   then every * 3600
      when 'interval_minutes' then every * 60
      end
    end

    # Anchor is the start of the rule's start_on date (or created_at date) in the rule's timezone.
    # Using beginning_of_day keeps periods aligned to midnight, so "every 1 hour" fires at
    # 00:00, 01:00, 02:00, … in the configured timezone rather than at an arbitrary offset.
    def sub_daily_anchor_time
      tz = @rule.timezone.presence || 'UTC'
      if @rule.start_on
        @rule.start_on.in_time_zone(tz).beginning_of_day
      else
        created = @rule.respond_to?(:created_at) ? @rule.created_at : nil
        base    = created || @time
        base.in_time_zone(tz).beginning_of_day
      end
    end

    def parse_hhmm(str)
      parts = str.to_s.split(':')
      parts[0].to_i * 60 + parts[1].to_i
    end

    # Returns true when +current+ minutes-since-midnight falls in [from, to).
    # Handles windows that wrap midnight (e.g. from=22:00 to=06:00).
    def minutes_in_window?(current, from, to)
      if from <= to
        current >= from && current < to
      else
        current >= from || current < to
      end
    end

    def parse_config
      raw = @rule.schedule_config
      return {} if raw.nil?
      return raw if raw.is_a?(Hash)

      JSON.parse(raw)
    rescue JSON::ParserError => e
      Rails.logger.error "[IssueDigest] Rule ##{@rule.id}: invalid schedule_config: #{e.message}"
      nil
    end

    # Returns the canonical date for the current scheduling period.
    # This is the date the rule WOULD fire on, before any business-day shift.
    # Returns nil when the period does not produce a valid date (e.g. weekday not included).
    def canonical_period_date(local_date, config)
      case @rule.schedule_type
      when 'daily'
        local_date
      when 'weekly'
        day = config['day']
        return nil unless day.is_a?(Integer)

        # The Monday-anchored ISO week's instance of the configured weekday.
        week_start = local_date - (local_date.cwday - 1)
        week_start + (day - 1)
      when 'monthly_date'
        day = config['day']
        return nil unless day.is_a?(Integer) && (1..28).cover?(day)

        Date.new(local_date.year, local_date.month, day)
      when 'monthly_last_day'
        local_date.end_of_month.to_date
      when 'interval_days'
        every = config['every'].to_i
        return nil if every < 1

        anchor = rule_anchor
        period = ((local_date - anchor).to_i / every).floor
        anchor + (period * every)
      when 'interval_weeks'
        every = config['every'].to_i
        return nil if every < 1

        anchor = rule_anchor
        period = ((local_date - anchor).to_i / (every * 7)).floor
        anchor + (period * every * 7)
      when 'manual'
        @force ? local_date : nil
      else
        nil
      end
    end

    def rule_anchor
      @rule.start_on || @rule.created_at.to_date
    end

    # Applies business-day shift to get the actual execution date.
    # Returns nil for 'skip' when canonical falls on a weekend.
    def execution_date(canonical)
      return canonical unless @rule.business_days_only?

      if canonical.saturday? || canonical.sunday?
        case @rule.non_business_day_behavior
        when 'skip'             then nil
        when 'previous_weekday' then canonical.prev_weekday
        when 'next_weekday'     then canonical.next_weekday
        else nil
        end
      else
        canonical
      end
    end

    def within_grace_window?(local_time, local_date, tz)
      return true unless @rule.send_time

      seconds     = @rule.send_time.seconds_since_midnight
      window_open = local_date.in_time_zone(tz) + seconds.seconds
      window_close = window_open + @rule.grace_window_hours.to_i.hours

      @time >= window_open && @time <= window_close
    end

    def compute_schedule_key_for(date, config)
      return nil if date.nil?

      id   = @rule.id
      code = TYPE_CODES[@rule.schedule_type]

      window = case @rule.schedule_type
               when 'daily', 'weekdays'
                 date.strftime('%Y-%m-%d')
               when 'weekly'
                 date.strftime('%G-W%V')
               when 'monthly_date', 'monthly_last_day'
                 date.strftime('%Y-%m')
               when 'interval_days'
                 every = config['every'].to_i
                 anchor = rule_anchor
                 ((date - anchor).to_i / every).floor.to_s
               when 'interval_weeks'
                 every = config['every'].to_i
                 anchor = rule_anchor
                 ((date - anchor).to_i / (every * 7)).floor.to_s
               when 'manual'
                 @time.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
               end

      "#{id}:#{code}:#{window}"
    end
  end
end
