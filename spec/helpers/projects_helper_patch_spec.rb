# frozen_string_literal: true

require_relative '../rails_helper'

# The Digest Rules tab is added through ProjectsController's helper chain, not
# by patching ProjectsHelper: other plugins wrap project_settings_tabs with
# alias_method chains and with prepend, and only a module outside
# ProjectsHelper.ancestors composes with both in any load order.
RSpec.describe 'ProjectsHelper patch', type: :helper do
  it 'is in the helper chain of ProjectsController' do
    expect(ProjectsController._helpers.ancestors).to include(IssueDigest::ProjectsHelperPatch)
    expect(ProjectsController._helpers.ancestors).to include(IssueDigest::DigestRulesHelper)
  end

  it 'comes before ProjectsHelper in that chain, so its super reaches ProjectsHelper' do
    ancestors = ProjectsController._helpers.ancestors
    expect(ancestors.index(IssueDigest::ProjectsHelperPatch)).to be < ancestors.index(ProjectsHelper)
  end

  it 'is not in ProjectsHelper.ancestors, where an alias_method chain could copy it' do
    expect(ProjectsHelper.ancestors).not_to include(IssueDigest::ProjectsHelperPatch)
    expect(ProjectsHelper.method_defined?(:project_settings_tabs_without_issue_digest)).to be false
  end

  # A stand-in for ProjectsHelper as other plugins leave it: wrapped by a
  # prepend, by an alias chain, or by both (in the order in which those two
  # compose with each other at all).
  describe 'with other plugins wrapping project_settings_tabs' do
    def fake_projects_helper
      Module.new do
        def project_settings_tabs
          [{ name: 'core' }]
        end
      end
    end

    def alias_chain!(mod, name)
      mod.module_eval do
        define_method(:"project_settings_tabs_with_#{name}") do
          send(:"project_settings_tabs_without_#{name}") + [{ name: name }]
        end
        alias_method :"project_settings_tabs_without_#{name}", :project_settings_tabs
        alias_method :project_settings_tabs, :"project_settings_tabs_with_#{name}"
      end
    end

    def prepend!(mod, name)
      mod.prepend(Module.new { define_method(:project_settings_tabs) { super() + [{ name: name }] } })
    end

    def tabs_through_controller_chain(helper_mod)
      project = create(:project)
      project.enabled_modules.create!(name: 'issue_digest') unless project.module_enabled?(:issue_digest)
      allow(User).to receive(:current).and_return(User.find_by(admin: true) || create(:user, admin: true))
      view = Class.new do
        include helper_mod
        include IssueDigest::ProjectsHelperPatch
      end.new
      view.instance_variable_set(:@project, project)
      view.project_settings_tabs.map { |t| t[:name] }
    end

    it 'keeps every tab with a prepend on ProjectsHelper' do
      mod = fake_projects_helper
      prepend!(mod, 'prepended')
      expect(tabs_through_controller_chain(mod)).to contain_exactly('core', 'prepended', 'digest_rules')
    end

    it 'keeps every tab with an alias chain on ProjectsHelper' do
      mod = fake_projects_helper
      alias_chain!(mod, 'chained')
      expect(tabs_through_controller_chain(mod)).to contain_exactly('core', 'chained', 'digest_rules')
    end

    it 'keeps every tab when an alias chain comes before a prepend' do
      mod = fake_projects_helper
      alias_chain!(mod, 'chained')
      prepend!(mod, 'prepended')
      expect(tabs_through_controller_chain(mod)).to contain_exactly('core', 'prepended', 'chained', 'digest_rules')
    end
  end

  # Helper object that supplies `params` (needed by Redmine's original
  # project_settings_tabs for the versions tab URL hash), built from the real
  # controller helper chain.
  def build_helper_obj
    Class.new do
      include ProjectsController._helpers

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
