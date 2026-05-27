# frozen_string_literal: true

module IssueDigest
  module ProjectsHelperPatch
    def self.included(base)
      base.module_eval do
        include IssueDigest::DigestRulesHelper unless include?(IssueDigest::DigestRulesHelper)
        unless method_defined?(:project_settings_tabs_without_issue_digest)
          alias_method :project_settings_tabs_without_issue_digest, :project_settings_tabs
          alias_method :project_settings_tabs, :project_settings_tabs_with_issue_digest
        end
      end
    end

    def project_settings_tabs_with_issue_digest
      tabs = project_settings_tabs_without_issue_digest
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
