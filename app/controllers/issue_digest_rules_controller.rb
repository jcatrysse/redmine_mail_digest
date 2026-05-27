# frozen_string_literal: true

class IssueDigestRulesController < ApplicationController
  before_action :find_project
  before_action :authorize
  before_action :find_rule, only: [:show, :edit, :update, :destroy, :enable, :disable]

  helper IssueDigest::DigestRulesHelper

  def index
    @rules = project_rules.order(:name)
    rule_ids = @rules.map(&:id)
    @latest_runs = if rule_ids.any?
      max_ids = IssueDigestRun
        .where(issue_digest_rule_id: rule_ids)
        .group(:issue_digest_rule_id)
        .maximum(:id)
        .values
      IssueDigestRun.where(id: max_ids).index_by(&:issue_digest_rule_id)
    else
      {}
    end
  end

  SHOW_DEFAULT_LIMIT = 20
  SHOW_ALL_LIMIT     = 500

  def show
    @total_run_count = @rule.issue_digest_runs.count
    limit = params[:show_all].present? ? SHOW_ALL_LIMIT : SHOW_DEFAULT_LIMIT
    @runs = @rule.issue_digest_runs.recent_first.limit(limit)
  end

  def new
    @rule = IssueDigestRule.new(default_rule_attributes.merge(project: @project))
  end

  def create
    @rule = IssueDigestRule.new(digest_rule_params)
    @rule.project = @project
    @rule.created_by = User.current
    if @rule.save
      flash[:notice] = l(:notice_issue_digest_rule_saved)
      redirect_to settings_project_path(@project, tab: 'digest_rules')
    else
      flash.now[:error] = l(:error_issue_digest_rule_not_saved)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @rule.updated_by = User.current
    if @rule.update(digest_rule_params)
      flash[:notice] = l(:notice_issue_digest_rule_saved)
      redirect_to settings_project_path(@project, tab: 'digest_rules')
    else
      flash.now[:error] = l(:error_issue_digest_rule_not_saved)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @rule.destroy
      flash[:notice] = l(:notice_issue_digest_rule_deleted)
    else
      flash[:error] = l(:error_issue_digest_rule_not_saved)
    end
    redirect_to settings_project_path(@project, tab: 'digest_rules')
  end

  def enable
    if @rule.update(active: true)
      flash[:notice] = l(:notice_issue_digest_rule_enabled)
    else
      flash[:error] = l(:error_issue_digest_rule_not_saved)
    end
    redirect_to settings_project_path(@project, tab: 'digest_rules')
  end

  def disable
    if @rule.update(active: false)
      flash[:notice] = l(:notice_issue_digest_rule_disabled)
    else
      flash[:error] = l(:error_issue_digest_rule_not_saved)
    end
    redirect_to settings_project_path(@project, tab: 'digest_rules')
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_rule
    @rule = project_rules.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def project_rules
    IssueDigestRule.where(project_id: @project.id)
  end

  def default_rule_attributes
    {
      active: true,
      schedule_type: 'daily',
      send_time: '08:00:00',
      timezone: default_timezone_iana,
      grace_window_hours: 24,
      non_business_day_behavior: 'skip',
      recipient_modes: ['project_members'],
      include_open: true,
      group_by: 'none',
      due_soon_days: 7,
      recently_updated_days: 7,
      recently_created_days: 7
    }
  end

  def default_timezone_iana
    # Redmine stores the global timezone preference under `default_users_time_zone`,
    # not `default_timezone`. Fall back to UTC when the setting is absent or blank.
    key = Setting.respond_to?(:default_users_time_zone) ? :default_users_time_zone : nil
    return 'UTC' unless key

    as_name = Setting.public_send(key).to_s.presence
    return 'UTC' if as_name.blank?

    tz = ActiveSupport::TimeZone[as_name]
    tz ? tz.tzinfo.name : 'UTC'
  rescue StandardError
    'UTC'
  end

  def digest_rule_params
    permitted = params.require(:issue_digest_rule).permit(
      :name, :active, :schedule_type,
      :start_on, :end_on, :send_time, :timezone,
      :query_id, :include_subprojects,
      :include_open, :include_closed, :include_overdue,
      :include_due_soon, :due_soon_days,
      :include_recently_updated, :recently_updated_days,
      :include_recently_created, :recently_created_days,
      :only_since_last_run,
      :filter_assigned_to_recipient, :filter_watched_by_recipient,
      :filter_authored_by_recipient,
      :overdue_min_days,
      :group_by, :send_empty,
      :email_subject, :email_intro,
      :grace_window_hours, :business_days_only, :non_business_day_behavior,
      schedule_config: {},
      recipient_modes: []
    )
    # Reject the blank sentinel emitted by the select's leading empty option
    # when no specific user is chosen (HTML always submits one value for a
    # non-multiple <select>; the blank option is our "none selected" marker).
    # Only apply when the field is actually present in the submitted params.
    if permitted.key?(:recipient_modes)
      permitted[:recipient_modes] = Array(permitted[:recipient_modes]).reject(&:blank?)
    end
    merge_email_recipients(permitted)
    normalize_schedule_config(permitted)
    permitted
  end

  # Convert the free-text `recipient_email_addresses` textarea into `email:addr`
  # entries and merge them into the recipient_modes array.
  # When the allow_external_recipients plugin setting is disabled, any email: modes
  # that were explicitly submitted are stripped (policy enforcement / crafted-request
  # protection). If recipient_modes was not submitted at all (partial update), it is
  # left untouched so the existing DB value is preserved.
  def merge_email_recipients(permitted)
    unless external_recipients_allowed?
      if permitted.key?(:recipient_modes)
        permitted[:recipient_modes] = Array(permitted[:recipient_modes]).reject { |m| m.start_with?('email:') }
      end
      return
    end
    email_text = params.dig(:issue_digest_rule, :recipient_email_addresses).to_s
    email_modes = email_text.split(/[\n\r,;]+/)
                            .map(&:strip)
                            .reject(&:blank?)
                            .uniq
                            .map { |addr| "email:#{addr}" }
    permitted[:recipient_modes] = Array(permitted[:recipient_modes]) + email_modes if email_modes.any?
  end

  def external_recipients_allowed?
    ActiveModel::Type::Boolean.new.cast(Setting.plugin_redmine_digest['allow_external_recipients'])
  end

  # Coerce schedule_config nested integer fields from form strings to integers
  # so the model's validators (which require Integer values) accept them.
  def normalize_schedule_config(permitted)
    config = permitted[:schedule_config]
    return if config.nil?

    # Always convert ActionController::Parameters to a plain Ruby Hash so the
    # model's `is_a?(Hash)` check passes even when schedule_config is empty.
    config = config.respond_to?(:to_unsafe_h) ? config.to_unsafe_h : config.to_h
    case permitted[:schedule_type]
    when 'weekly', 'monthly_date'
      config['day'] = Integer(config['day']) if config['day'].present?
    when 'weekdays'
      if config['days'].is_a?(Array)
        config['days'] = config['days'].reject(&:blank?).map { |d| Integer(d) }
      end
    when 'interval_days', 'interval_weeks'
      config['every'] = Integer(config['every']) if config['every'].present?
    when 'interval_hours', 'interval_minutes'
      config['every'] = Integer(config['every']) if config['every'].present?
      if config['days'].is_a?(Array)
        config['days'] = config['days'].reject(&:blank?).map { |d| Integer(d) }
      elsif config['days'].blank?
        config.delete('days')
      end
      config.delete('from') if config['from'].blank?
      config.delete('to')   if config['to'].blank?
    end
  rescue ArgumentError, TypeError
    # Non-numeric value submitted — the specific key that failed is left as-is
    # (a string). The model validator will add the precise error code (e.g.
    # :invalid_days, :invalid_day). Fall through to ensure so the converted
    # plain Hash is always written back, preventing ActionController::Parameters
    # from reaching the model's is_a?(Hash) guard.
  ensure
    permitted[:schedule_config] = config if config
  end
end
