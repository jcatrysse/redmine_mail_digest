# frozen_string_literal: true

require_relative '../rails_helper'

# Verify that the ProjectsHelper patch is applied at boot time.
# init.rb runs inside Redmine's PluginLoader to_prepare callback; the
# include must be applied directly (not inside a nested to_prepare) so
# it takes effect in the same cycle.
RSpec.describe 'ProjectsHelper patch', type: :helper do
  it 'includes IssueDigest::ProjectsHelperPatch in ProjectsHelper' do
    expect(ProjectsHelper.included_modules).to include(IssueDigest::ProjectsHelperPatch)
  end

  it 'defines project_settings_tabs_with_issue_digest on ProjectsHelper' do
    expect(ProjectsHelper.method_defined?(:project_settings_tabs_with_issue_digest)).to be true
  end

  it 'saves the original method as project_settings_tabs_without_issue_digest' do
    expect(ProjectsHelper.method_defined?(:project_settings_tabs_without_issue_digest)).to be true
  end

  # Helper object that supplies `params` (needed by Redmine's original
  # project_settings_tabs for the versions tab URL hash).
  def build_helper_obj
    Class.new do
      include ProjectsHelper

      def params
        ActionController::Parameters.new({})
      end
    end.new
  end

  it 'adds the digest_rules tab when user has view_digest_rules on the project' do
    project = create(:project)
    user = create(:user)
    role = Role.find_by(name: 'DigestViewer_patch') ||
           Role.new(name: 'DigestViewer_patch',
                    permissions: [:view_digest_rules], issues_visibility: 'all')
    role.save!(validate: false)
    project.enabled_modules.create!(name: 'issue_digest') unless project.module_enabled?(:issue_digest)
    Member.create!(project: project, user: user, roles: [role])

    allow(User).to receive(:current).and_return(user)

    helper_obj = build_helper_obj
    helper_obj.instance_variable_set(:@project, project)

    tab_names = helper_obj.project_settings_tabs.map { |t| t[:name] }
    expect(tab_names).to include('digest_rules')
  end

  it 'does not add the digest_rules tab when user lacks view_digest_rules' do
    project = create(:project)
    user = create(:user)

    allow(User).to receive(:current).and_return(user)

    helper_obj = build_helper_obj
    helper_obj.instance_variable_set(:@project, project)

    tab_names = helper_obj.project_settings_tabs.map { |t| t[:name] }
    expect(tab_names).not_to include('digest_rules')
  end
end
