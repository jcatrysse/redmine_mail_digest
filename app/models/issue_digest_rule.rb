# frozen_string_literal: true

class IssueDigestRule < ActiveRecord::Base
  SCHEDULE_TYPES = %w[
    daily
    weekdays
    weekly
    monthly_date
    monthly_last_day
    interval_days
    interval_weeks
    interval_hours
    interval_minutes
    manual
  ].freeze

  SUB_DAILY_TYPES = %w[interval_hours interval_minutes].freeze

  NON_BUSINESS_DAY_BEHAVIORS = %w[skip previous_weekday next_weekday].freeze
  GROUP_BY_OPTIONS = %w[none assignee priority tracker status version category].freeze
  RECIPIENT_MODE_PATTERN = /\A(?:project_members|assignees|authors|watchers|role:\d+|user:\d+|email:[^@\s]+@[^@\s]+\.[^@\s]+)\z/

  HHMM_PATTERN = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/

  belongs_to :project
  belongs_to :query, class_name: 'IssueQuery', foreign_key: :query_id, optional: true
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User', optional: true
  has_many :issue_digest_runs, dependent: :destroy

  serialize :schedule_config, coder: JSON
  serialize :recipient_modes, coder: JSON

  # Ensure schedule_config is always deserialized to a Hash before validation.
  # Rails does not deserialize the DB-level default ('{}'  text) for new in-memory
  # records, so without this hook the serialized column holds the raw String and
  # the is_a?(Hash) check inside schedule_config_valid would fail.
  before_validation :coerce_schedule_config
  before_validation :coerce_recipient_modes

  validates :name, presence: true, length: { maximum: 255 }
  validates :schedule_type, inclusion: { in: SCHEDULE_TYPES }
  validates :send_time, presence: true, unless: -> { manual_schedule? || sub_daily_schedule? }
  validates :timezone, presence: true, length: { maximum: 64 }
  validates :grace_window_hours,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 48 }
  validates :non_business_day_behavior, inclusion: { in: NON_BUSINESS_DAY_BEHAVIORS }
  validates :group_by, inclusion: { in: GROUP_BY_OPTIONS }
  validates :due_soon_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 }
  validates :recently_updated_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 }
  validates :recently_created_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 }
  validates :overdue_min_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 },
            allow_nil: true
  validates :email_subject, length: { maximum: 255 }, allow_nil: true
  validates :email_intro, length: { maximum: 2000 }, allow_nil: true

  validate :end_on_after_start_on
  validate :recipient_modes_valid
  validate :schedule_config_valid
  validate :timezone_valid
  validate :query_belongs_to_project, if: :query_id_needs_validation?

  scope :enabled, -> { where(active: true) }
  scope :in_date_range, lambda {
    today = Date.current
    where('start_on IS NULL OR start_on <= ?', today)
      .where('end_on IS NULL OR end_on >= ?', today)
  }
  # Candidate rules for the scheduler. Final due-check is delegated to
  # IssueDigest::ScheduleEvaluator (Agent 2) since it depends on send_time,
  # grace window, timezone, and schedule_config. This scope provides the
  # cheap SQL pre-filter so the rake task does not load every rule.
  scope :due_now, -> { enabled.in_date_range }
  scope :active_for_project, ->(project) { where(project: project, active: true) }

  # Returns true when the rule is enabled and today is within the start_on/end_on window.
  def active?
    active && within_date_range?
  end

  def within_date_range?
    today = current_date_in_zone
    return false if start_on && start_on > today
    return false if end_on && end_on < today

    true
  end

  # Returns one of :active, :disabled, :pending, :expired for UI badges.
  def status_label
    return :disabled unless active

    today = current_date_in_zone
    return :pending if start_on && start_on > today
    return :expired if end_on && end_on < today

    :active
  end

  # "Today" interpreted in the rule's own timezone, so start_on/end_on
  # boundaries flip on the same calendar day the scheduler uses (which also
  # works per-rule timezone). Falls back to the server date on bad input.
  def current_date_in_zone
    Time.current.in_time_zone(timezone.presence || 'UTC').to_date
  rescue StandardError
    Date.current
  end

  def last_run
    issue_digest_runs.order(started_at: :desc).first
  end

  def manual_schedule?
    schedule_type == 'manual'
  end

  def sub_daily_schedule?
    SUB_DAILY_TYPES.include?(schedule_type)
  end

  private

  def coerce_schedule_config
    val = schedule_config
    # The column is NOT NULL with no DB default (MySQL forbids defaults on TEXT),
    # so normalize a missing value to an empty Hash here. The serializer then
    # writes '{}' on insert.
    if val.nil?
      self.schedule_config = {}
      return
    end

    return unless val.is_a?(String)

    # Parse valid JSON strings. On failure, leave the raw String in place so
    # schedule_config_valid adds the proper :invalid error rather than silently
    # accepting nil as an empty config.
    begin
      self.schedule_config = JSON.parse(val)
    rescue JSON::ParserError
      # intentionally left blank — validator will reject the non-Hash value
    end
  end

  def coerce_recipient_modes
    val = recipient_modes
    # NOT NULL with no DB default (see coerce_schedule_config): normalize a
    # missing value to []. recipient_modes_valid still rejects an empty array
    # (at least one mode is required), but the column never receives NULL.
    if val.nil?
      self.recipient_modes = []
      return
    end

    if val.is_a?(String)
      begin
        self.recipient_modes = JSON.parse(val)
      rescue JSON::ParserError
        # intentionally left blank — validator will reject the non-Array value
        return
      end
    end

    return unless recipient_modes.is_a?(Array)

    # Persist a clean array: drop blanks and duplicates while preserving the
    # order in which modes were chosen. The resolver also de-duplicates users at
    # send time, but storing a normalized array keeps UI summaries and diffs clear.
    self.recipient_modes = recipient_modes
                           .reject { |m| m.respond_to?(:blank?) ? m.blank? : m.nil? }
                           .uniq
  end

  def query_id_needs_validation?
    query_id.present? && (new_record? || will_save_change_to_query_id?)
  end

  def query_belongs_to_project
    q = IssueQuery.find_by(id: query_id)
    return if q && IssueDigest::QueryAdapter.query_usable_for_rule?(q, self)

    errors.add(:query_id, :invalid, message: I18n.t(:error_query_invalid))
  end

  def end_on_after_start_on
    return unless start_on && end_on
    return if end_on >= start_on

    errors.add(:end_on, :must_be_on_or_after_start_on)
  end

  def recipient_modes_valid
    modes = recipient_modes
    if modes.blank? || !modes.is_a?(Array)
      errors.add(:recipient_modes, :blank)
      return
    end

    return if modes.all? { |m| m.is_a?(String) && m.match?(RECIPIENT_MODE_PATTERN) }

    errors.add(:recipient_modes, :invalid)
  end

  def schedule_config_valid
    config = schedule_config || {}
    unless config.is_a?(Hash)
      errors.add(:schedule_config, :invalid)
      return
    end

    case schedule_type
    when 'daily', 'monthly_last_day', 'manual'
      # No additional fields required.
    when 'weekdays'
      days = config['days']
      unless days.is_a?(Array) && days.any? &&
             days.all? { |d| d.is_a?(Integer) && (1..7).cover?(d) }
        errors.add(:schedule_config, :invalid_days)
      end
    when 'weekly'
      day = config['day']
      errors.add(:schedule_config, :invalid_day) unless day.is_a?(Integer) && (1..7).cover?(day)
    when 'monthly_date'
      day = config['day']
      errors.add(:schedule_config, :invalid_day_of_month) unless day.is_a?(Integer) && (1..28).cover?(day)
    when 'interval_days', 'interval_weeks'
      every = config['every']
      errors.add(:schedule_config, :invalid_interval) unless every.is_a?(Integer) && every >= 1
    when 'interval_hours', 'interval_minutes'
      every = config['every']
      errors.add(:schedule_config, :invalid_interval) unless every.is_a?(Integer) && every >= 1
      validate_sub_daily_time_window(config)
      validate_sub_daily_days(config)
    end
  end

  def validate_sub_daily_time_window(config)
    from_s = config['from'].presence
    to_s   = config['to'].presence
    return unless from_s || to_s

    errors.add(:schedule_config, :invalid_time_window) unless from_s&.match?(HHMM_PATTERN)
    errors.add(:schedule_config, :invalid_time_window) unless to_s&.match?(HHMM_PATTERN)
  end

  def validate_sub_daily_days(config)
    days = config['days']
    return if days.blank?

    unless days.is_a?(Array) && days.all? { |d| d.is_a?(Integer) && (1..7).cover?(d) }
      errors.add(:schedule_config, :invalid_days)
    end
  end

  def timezone_valid
    return if timezone.blank?

    TZInfo::Timezone.get(timezone)
  rescue TZInfo::InvalidTimezoneIdentifier
    errors.add(:timezone, :invalid)
  end
end
