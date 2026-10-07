# frozen_string_literal: true

module IssueDigest
  # The Digest Rules tab in the project settings.
  #
  # Added to ProjectsController's helper chain (ProjectsController.helper in
  # init.rb), not to ProjectsHelper. project_settings_tabs is patched by many
  # plugins, with alias_method chains and with prepend. An alias chain and a
  # prepend on ProjectsHelper compose in one order only: a chain installed
  # after a prepend copies the prepended method and `super` then fails, and the
  # reverse recurses; either way Project > Settings answers 500. The view
  # context includes the controller's helper modules after ProjectsHelper, so
  # this module sits in front of ProjectsHelper and its `super` reaches
  # whatever the other plugins made of it, in any load order. It is not in
  # ProjectsHelper.ancestors, so no alias_method on ProjectsHelper can copy it.
  # Same pattern as redmine_reporter_dashboards and redmine_custom_workflows.
  module ProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      if @project.present? && User.current.allowed_to?(:view_digest_rules, @project)
        tabs << {
          name:    'digest_rules',
          partial: 'projects/settings/digest_rules',
          label:   :label_issue_digest
        }
      end
      tabs
    end
  end
end
