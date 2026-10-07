# frozen_string_literal: true

require_relative 'lib/issue_digest/projects_helper_patch'

Redmine::Plugin.register :redmine_mail_digest do
  name        'Redmine Mail Digest'
  author      'Jan Catrysse'
  description 'Scheduled issue digest emails for Redmine projects'
  version     '1.0.0'
  url         'https://github.com/jcatrysse/redmine_mail_digest'
  author_url  'https://github.com/jcatrysse'

  requires_redmine version_or_higher: '6.0.0'

  settings default: {
             'max_issues_per_email'       => 500,
             'run_history_retention_days' => 90,
             'allow_external_recipients'  => false
           },
           partial: 'settings/issue_digest_settings'

  project_module :issue_digest do
    permission :view_digest_rules,
               { 'issue_digest_rules' => [:index, :show] },
               read: true
    # projects#settings, as core does for manage_categories and manage_versions:
    # the rules are managed in the project settings tab, and every save
    # redirects there.
    permission :manage_digest_rules,
               { 'issue_digest_rules' => [:new, :create, :edit, :update, :destroy, :enable, :disable, :preview],
                 'projects' => [:settings] }
  end

  # The settings tab needs a settings permission, which view_digest_rules does
  # not give; the menu entry lets those users reach the rule list. Shown when
  # the module is on and the user may see the index.
  menu :project_menu, :issue_digest_rules,
       { controller: 'issue_digest_rules', action: 'index' },
       caption: :label_issue_digest_rules, param: :project_id, before: :settings
end

# Redmine's PluginLoader already runs init.rb from within its own to_prepare
# callback, so this runs again after every code reload (controllers and their
# helper chains are rebuilt then). The settings tab partial needs
# DigestRulesHelper; both go into ProjectsController's helpers, never into
# ProjectsHelper itself (see lib/issue_digest/projects_helper_patch.rb).
ProjectsController.helper(IssueDigest::DigestRulesHelper)
ProjectsController.helper(IssueDigest::ProjectsHelperPatch)
