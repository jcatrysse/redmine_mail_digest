# frozen_string_literal: true

# IssueDigestMailer renders and delivers digest emails for one recipient at a time.
#
# Why ActionMailer::Base (and not Redmine's `Mailer`)?
#   Redmine's Mailer is tightly coupled to its notification system (per-user
#   notification preferences, event hooks, tracking). Digests are scheduled,
#   bulk, opt-in via a separate rule mechanism and should NOT participate in
#   any of that. Inheriting from ActionMailer::Base keeps the digest path
#   independent and predictable.
#
# Entry point:
#   IssueDigestMailer.digest_email(rule, user, issues, grouped_issues).deliver_now
#
#   - rule:            IssueDigestRule
#   - user:            User (recipient; mail goes to user.mail)
#   - issues:          Array<Issue> or ActiveRecord::Relation already filtered
#                      by Issue.visible(user) (caller is responsible)
#   - grouped_issues:  nil OR Hash<String, Array<Issue>>; nil means flat layout
#
# URL construction is intentionally manual (Setting.host_name / Setting.protocol)
# because mailers may be invoked from a rake task with no routing context.
class IssueDigestMailer < ActionMailer::Base
  # View helpers — also included as instance methods on the mailer so specs
  # can call them directly.
  #
  # NOTE: the URL helpers are deliberately named `digest_*` rather than
  # `issue_url` / `settings_url`. The digest_email.html.erb template now renders
  # the user-supplied intro through `textilizable` (so it honours Redmine's text
  # formatting, matching the rule's show page and the form's preview pane).
  # `textilizable` calls Rails' route helper `issue_url(issue, only_path: ...)`
  # when it expands `#123` references; a same-named helper here would shadow that
  # route helper and break formatting. Keeping these names distinct avoids the
  # collision.
  module DigestHelper
    def digest_issue_url(issue)
      "#{base_url}/issues/#{issue.id}"
    end

    def digest_settings_url
      "#{base_url}/projects/#{@project.identifier}/settings?tab=digest_rules"
    end

    def base_url
      proto = Setting.respond_to?(:protocol) ? Setting.protocol.presence : nil
      host  = Setting.respond_to?(:host_name) ? Setting.host_name.presence : nil
      "#{proto || 'http'}://#{host || 'localhost'}"
    end

    def format_assignee(issue)
      issue.assigned_to&.name.presence || I18n.t('redmine_digest.mailer.unassigned')
    end

    def format_due_date(issue)
      issue.due_date ? I18n.l(issue.due_date) : '—'
    end

    def overdue?(issue)
      issue.due_date.present? && issue.due_date < Date.current
    end

    def priority_css_class(issue)
      name = issue.priority&.name.to_s.downcase
      return '' if name.empty?

      "priority-#{name.gsub(/[^a-z0-9]+/, '-')}"
    end
  end

  include DigestHelper
  helper DigestHelper

  # Make Redmine's formatting helpers (textilizable / format_text) available to
  # the email templates so the intro text is rendered with the same formatter as
  # the rule's show page and the form's preview pane.
  helper :application

  default from: -> { Setting.mail_from }

  # textilizable expands `#123` / `project#42` references into absolute links.
  # Those use Rails route helpers, which need a host. Mirror Redmine's own
  # Mailer.default_url_options (derived from Setting.host_name / protocol) so the
  # links resolve when rendered outside a web request (e.g. the rake task).
  def self.default_url_options
    options = { protocol: (Setting.respond_to?(:protocol) ? Setting.protocol.presence : nil) || 'http' }
    host = Setting.respond_to?(:host_name) ? Setting.host_name.to_s : ''
    if host =~ %r{\A(https?://)?(.+?)(:(\d+))?(/.+)?\z}i
      options.merge!(host: Regexp.last_match(2), port: Regexp.last_match(4), script_name: Regexp.last_match(5))
    else
      options[:host] = host.presence || 'localhost'
    end
    options
  end

  def digest_email(rule, user, issues, grouped_issues = nil)
    @rule           = rule
    @user           = user
    @issues         = issues || []
    @grouped_issues = grouped_issues
    @issues_count   = @issues.respond_to?(:size) ? @issues.size : @issues.count
    # v1: we don't receive a separate "total before truncation" count, so we
    # leave the truncated-banner off. Spec §12 makes it optional.
    @total_issues_count = nil
    @project        = rule.project
    @date           = Date.current

    mail(
      to: user.mail,
      subject: render_subject
    ) do |format|
      format.text { render 'digest_email' }
      format.html { render 'digest_email' }
    end
  end

  private

  # Subject rendering. Templates support tokens {project}, {rule_name},
  # {date}, {issues_count}. Substitution is done with String#gsub against
  # a literal allowlist – NEVER eval / ERB / format strings.
  def render_subject
    template = @rule.email_subject.to_s.strip
    template = I18n.t('redmine_digest.mailer.subject_default',
                      project: @project.name,
                      rule_name: @rule.name,
                      date: @date.strftime('%Y-%m-%d')) if template.empty?

    tokens = {
      '{project}'       => @project.name.to_s,
      '{rule_name}'     => @rule.name.to_s,
      '{date}'          => @date.strftime('%Y-%m-%d'),
      '{issues_count}'  => @issues_count.to_s
    }

    result = template.dup
    tokens.each { |placeholder, value| result.gsub!(placeholder, value) }

    # Cap at 255 chars (no ellipsis – email clients handle long subjects).
    result.length > 255 ? result[0, 255] : result
  end
end
