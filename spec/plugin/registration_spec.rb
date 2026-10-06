# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe 'redmine_mail_digest registration' do
  let(:project) do
    p = create(:project, is_public: false)
    p.enabled_modules.create!(name: 'issue_digest') unless p.module_enabled?(:issue_digest)
    p
  end
  let(:user) { create(:user) }

  before { allow_any_instance_of(User).to receive(:deliver_security_notification) }

  def member_with(*permissions)
    role = Role.create!(name: "Digest_#{SecureRandom.hex(4)}", permissions: permissions)
    Member.create!(principal: user, project: project, roles: [role])
    user.reload
  end

  describe 'project menu entry' do
    let(:item) { Redmine::MenuManager.items(:project_menu).detect { |i| i.name == :issue_digest_rules } }

    it 'points at the rule list, before Settings' do
      expect(item).not_to be_nil
      expect(item.url).to eq(controller: 'issue_digest_rules', action: 'index')
      names = Redmine::MenuManager.items(:project_menu).map(&:name)
      expect(names.index(:issue_digest_rules)).to be < names.index(:settings)
    end

    it 'is allowed with view_digest_rules alone' do
      member_with(:view_issues, :view_digest_rules)
      expect(user.allowed_to?(item.url, project)).to be(true)
    end

    it 'is not allowed without view_digest_rules' do
      member_with(:view_issues)
      expect(user.allowed_to?(item.url, project)).to be(false)
    end

    it 'is not allowed when the module is off' do
      member_with(:view_issues, :view_digest_rules)
      project.enabled_modules.where(name: 'issue_digest').destroy_all
      expect(user.allowed_to?(item.url, project.reload)).to be(false)
    end
  end

  # Every save redirects to the Digest Rules tab of the project settings, so
  # manage_digest_rules must open that page, as core's manage_categories does.
  describe 'manage_digest_rules and the project settings' do
    let(:settings_url) { { controller: 'projects', action: 'settings' } }

    it 'opens the project settings' do
      member_with(:view_digest_rules, :manage_digest_rules)
      expect(user.allowed_to?(settings_url, project)).to be(true)
    end

    it 'view_digest_rules alone does not' do
      member_with(:view_issues, :view_digest_rules)
      expect(user.allowed_to?(settings_url, project)).to be(false)
    end
  end
end
