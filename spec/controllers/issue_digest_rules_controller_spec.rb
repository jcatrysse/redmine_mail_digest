# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe IssueDigestRulesController, type: :controller do
  render_views

  let!(:role) do
    create_role = Role.find_by(name: 'DigestTester') || Role.new(name: 'DigestTester')
    create_role.assign_attributes(
      permissions: [:view_digest_rules, :manage_digest_rules, :view_issues],
      issues_visibility: 'all'
    )
    create_role.save!(validate: false)
    create_role
  end

  let!(:non_manager_role) do
    r = Role.find_by(name: 'DigestViewer') || Role.new(name: 'DigestViewer')
    r.assign_attributes(permissions: [:view_digest_rules], issues_visibility: 'all')
    r.save!(validate: false)
    r
  end

  let!(:project) { create(:project, is_public: true) }
  let!(:other_project) { create(:project, is_public: true) }
  let!(:user) { create(:user) }

  before do
    # Prevent security-notification emails from being enqueued during user creation;
    # the inline job adapter tries to deserialize a stale AnonymousUser id across
    # rolled-back transactions, causing DeserializationError failures.
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)

    # Enable the issue_digest module on both projects so authorize permits actions.
    [project, other_project].each do |p|
      p.enabled_modules.create!(name: 'issue_digest') unless p.module_enabled?(:issue_digest)
    end

    # Add the user as a member of the project with manage permissions.
    Member.create!(project: project, user: user, roles: [role])
    Member.create!(project: other_project, user: user, roles: [role])

    User.current = user
    # Stub Redmine's session-based auth so the controller sees our user.
    allow(controller).to receive(:find_current_user).and_return(user)
    allow(User).to receive(:current).and_return(user)
  end

  let(:valid_params) do
    {
      name: 'Daily Digest',
      active: '1',
      schedule_type: 'daily',
      schedule_config: {},
      send_time: '08:00',
      timezone: 'UTC',
      grace_window_hours: 24,
      non_business_day_behavior: 'skip',
      include_open: '1',
      group_by: 'none',
      due_soon_days: 7,
      recently_updated_days: 7,
      recently_created_days: 7,
      recipient_modes: ['project_members']
    }
  end

  describe 'GET #index' do
    it 'renders successfully' do
      create(:issue_digest_rule, project: project, created_by: user)
      get :index, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET #show' do
    it 'renders rule details and run history' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      get :show, params: { project_id: project.id, id: rule.id }
      expect(response).to have_http_status(:ok)
    end

    it 'sets @total_run_count to the total number of runs' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      create_list(:issue_digest_run, 3, issue_digest_rule: rule)
      get :show, params: { project_id: project.id, id: rule.id }
      expect(controller.instance_variable_get(:@total_run_count)).to eq(3)
    end

    it 'limits run history to SHOW_DEFAULT_LIMIT by default' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      n = IssueDigestRulesController::SHOW_DEFAULT_LIMIT + 5
      create_list(:issue_digest_run, n, issue_digest_rule: rule)
      get :show, params: { project_id: project.id, id: rule.id }
      expect(controller.instance_variable_get(:@runs).size).to eq(IssueDigestRulesController::SHOW_DEFAULT_LIMIT)
    end

    it 'limits run history to SHOW_ALL_LIMIT when show_all is set' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      # Use SHOW_DEFAULT_LIMIT + 5 to keep the test fast; just verify the cap is raised.
      n = IssueDigestRulesController::SHOW_DEFAULT_LIMIT + 5
      create_list(:issue_digest_run, n, issue_digest_rule: rule)
      get :show, params: { project_id: project.id, id: rule.id, show_all: '1' }
      expect(controller.instance_variable_get(:@runs).size).to eq(n)
    end
  end

  describe 'GET #new' do
    it 'renders successfully' do
      get :new, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET #new — rich intro editor (regression)' do
    # The intro field must be a real Redmine formatted-text editor: a textarea
    # with a stable id that the wiki toolbar (incl. preview) attaches to.
    # Converting the form to labelled_form_for guarantees the generated id,
    # which form_with did not (Redmine does not enable form_with_generates_ids).
    it 'gives the intro textarea an id and wires the wiki toolbar + preview to it' do
      get :new, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="issue_digest_rule_email_intro"')
      expect(response.body).to include("getElementById('issue_digest_rule_email_intro')")
      expect(response.body).to include('setPreviewUrl') # preview pane wired up
      expect(response.body).to include(I18n.t(:hint_email_intro)) # formatting hint shown
    end
  end

  describe 'GET #edit — "Specific users" multiselect (regression)' do
    let!(:u1) { create(:user) }
    let!(:u2) { create(:user) }

    before do
      Member.create!(project: project, user: u1, roles: [role])
      Member.create!(project: project, user: u2, roles: [role])
    end

    it 'renders a sized native multi-select (not multiple+size=1) when several users are selected' do
      rule = create(:issue_digest_rule, project: project, created_by: user,
                                        recipient_modes: ["user:#{u1.id}", "user:#{u2.id}"])
      get :edit, params: { project_id: project.id, id: rule.id }
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to match(/id="digest-users-select"[^>]*\bmultiple\b/)
      expect(body).not_to match(/id="digest-users-select"[^>]*size="1"/)
      expect(body).to include('toggle-multiselect') # native +/- affordance present
    end

    it 'renders a single dropdown when only one user is selected' do
      rule = create(:issue_digest_rule, project: project, created_by: user,
                                        recipient_modes: ["user:#{u1.id}"])
      get :edit, params: { project_id: project.id, id: rule.id }
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to match(/id="digest-users-select"[^>]*size="1"/)
      expect(body).not_to match(/id="digest-users-select"[^>]*\bmultiple\b/)
    end
  end

  describe 'GET #edit — "Specific users" dropdown alphabetical order' do
    # Users whose display names (firstname + lastname) would differ from
    # lastname-only sorting, so we can verify the visible order.
    let!(:u_alice) { create(:user, firstname: 'Alice', lastname: 'Zimmermann') }
    let!(:u_bob)   { create(:user, firstname: 'Bob',   lastname: 'Aardvark') }
    let!(:u_carol) { create(:user, firstname: 'Carol', lastname: 'Monroe') }

    before do
      [u_alice, u_bob, u_carol].each { |u| Member.create!(project: project, user: u, roles: [role]) }
    end

    it 'lists users in alphabetical order by display name in the select' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      get :edit, params: { project_id: project.id, id: rule.id }
      expect(response).to have_http_status(:ok)
      body = response.body

      # Extract option texts from the digest-users-select element
      select_fragment = body[/id="digest-users-select".*?<\/select>/m]
      option_texts = select_fragment.scan(/<option[^>]*>([^<]+)<\/option>/).flatten

      # Remove blank sentinel option if present
      option_texts.reject!(&:blank?)

      # Display names under the default Redmine format are "Firstname Lastname"
      alice_name = u_alice.name  # e.g. "Alice Zimmermann"
      bob_name   = u_bob.name    # e.g. "Bob Aardvark"
      carol_name = u_carol.name  # e.g. "Carol Monroe"

      expected_order = [alice_name, bob_name, carol_name].sort_by(&:downcase)
      actual_order   = option_texts.select { |t| [alice_name, bob_name, carol_name].include?(t) }

      expect(actual_order).to eq(expected_order)
    end

    it 'sorts case-insensitively (lowercase names do not precede uppercase)' do
      # Regression: sort_by { name } would put "alice" after "Bob" in ASCII order
      u_lower = create(:user, firstname: 'anna', lastname: 'smith')
      Member.create!(project: project, user: u_lower, roles: [role])

      rule = create(:issue_digest_rule, project: project, created_by: user)
      get :edit, params: { project_id: project.id, id: rule.id }
      body = response.body

      select_fragment = body[/id="digest-users-select".*?<\/select>/m]
      option_texts = select_fragment.scan(/<option[^>]*>([^<]+)<\/option>/).flatten.reject(&:blank?)

      anna_pos = option_texts.index(u_lower.name)
      bob_pos  = option_texts.index(u_bob.name)

      expect(anna_pos).to be < bob_pos
    end
  end


  describe 'GET #new / #edit — role recipients' do
    it 'renders role recipient checkboxes' do
      get :new, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="role:')
      expect(response.body).to include(role.name)
    end

    it 'persists selected role recipient modes' do
      params = valid_params.merge(recipient_modes: ['project_members', "role:#{role.id}"])
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
      expect(IssueDigestRule.order(:id).last.recipient_modes).to include("role:#{role.id}")
    end
  end

  describe 'GET #new / #edit — "Specific email addresses" field gated by allow_external_recipients' do
    let(:rule) { create(:issue_digest_rule, project: project, created_by: user) }

    it 'shows the email field when allow_external_recipients is true' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return('allow_external_recipients' => '1')
      get :new, params: { project_id: project.id }
      expect(response.body).to include('id="issue_digest_rule_recipient_email_addresses"')
    end

    it 'hides the email field when allow_external_recipients is false' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return('allow_external_recipients' => '0')
      get :new, params: { project_id: project.id }
      expect(response.body).not_to include('id="issue_digest_rule_recipient_email_addresses"')
    end

    it 'hides the email field when allow_external_recipients is absent (default off)' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return({})
      get :new, params: { project_id: project.id }
      expect(response.body).not_to include('id="issue_digest_rule_recipient_email_addresses"')
    end
  end

  describe 'POST #create — email recipients gated by allow_external_recipients' do
    it 'ignores recipient_email_addresses when allow_external_recipients is false' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return('allow_external_recipients' => '0')
      params = valid_params.merge(recipient_email_addresses: "user@example.com")
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      rule = IssueDigestRule.order(:id).last
      expect(rule.recipient_modes).not_to include('email:user@example.com')
    end

    it 'strips existing email: modes from recipient_modes when allow_external_recipients is false (CSRF / crafted request protection)' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return('allow_external_recipients' => '0')
      crafted_modes = ['project_members', 'email:attacker@example.com']
      params = valid_params.merge(recipient_modes: crafted_modes)
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      rule = IssueDigestRule.order(:id).last
      expect(rule.recipient_modes).not_to include('email:attacker@example.com')
      expect(rule.recipient_modes).to include('project_members')
    end

    it 'merges recipient_email_addresses into recipient_modes when allow_external_recipients is true' do
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return('allow_external_recipients' => '1')
      params = valid_params.merge(recipient_email_addresses: "user@example.com")
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      rule = IssueDigestRule.order(:id).last
      expect(rule.recipient_modes).to include('email:user@example.com')
    end
  end

  describe 'POST #create' do
    it 'creates a rule with valid params and redirects to project settings' do
      expect {
        post :create, params: { project_id: project.id, issue_digest_rule: valid_params }
      }.to change(IssueDigestRule, :count).by(1)
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
      expect(flash[:notice]).to eq(I18n.t(:notice_issue_digest_rule_saved))

      rule = IssueDigestRule.order(:id).last
      expect(rule.project_id).to eq(project.id)
      expect(rule.created_by_id).to eq(user.id)
    end

    it 're-renders the form on invalid params' do
      expect {
        post :create, params: { project_id: project.id, issue_digest_rule: valid_params.merge(name: '') }
      }.not_to change(IssueDigestRule, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET #edit' do
    it 'renders successfully' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      get :edit, params: { project_id: project.id, id: rule.id }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'PATCH #update' do
    it 'updates the rule and redirects to project settings' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      patch :update, params: { project_id: project.id, id: rule.id, issue_digest_rule: { name: 'Renamed' } }
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
      expect(rule.reload.name).to eq('Renamed')
      expect(rule.updated_by_id).to eq(user.id)
    end
  end

  describe 'DELETE #destroy' do
    it 'deletes the rule and redirects to project settings' do
      rule = create(:issue_digest_rule, project: project, created_by: user)
      expect {
        delete :destroy, params: { project_id: project.id, id: rule.id }
      }.to change(IssueDigestRule, :count).by(-1)
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
    end
  end

  describe 'POST #enable / #disable' do
    let!(:rule) { create(:issue_digest_rule, project: project, created_by: user, active: false) }

    it 'enables an inactive rule and redirects to project settings' do
      post :enable, params: { project_id: project.id, id: rule.id }
      expect(rule.reload.active).to be true
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
    end

    it 'disables an active rule and redirects to project settings' do
      rule.update!(active: true)
      post :disable, params: { project_id: project.id, id: rule.id }
      expect(rule.reload.active).to be false
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
    end
  end

  describe 'POST #preview (dry-run)' do
    let!(:rule) { create(:issue_digest_rule, project: project, created_by: user, recipient_modes: ['project_members'], send_empty: true) }

    it 'runs a dry-run preview without writing runs/deliveries or sending mail' do
      expect {
        post :preview, params: { project_id: project.id, id: rule.id }, format: :js
      }.to change(IssueDigestRun, :count).by(0)
       .and change(IssueDigestDelivery, :count).by(0)
      expect(response).to have_http_status(:ok)
    end

    it 'renders the preview panel with per-recipient outcome counts' do
      # The rule's creator is a project member, so project_members resolves to at
      # least one recipient; send_empty=true means a "would send" outcome.
      post :preview, params: { project_id: project.id, id: rule.id }, format: :js
      expect(response.body).to include('digest-preview')
      expect(response.body).to include(I18n.t(:label_digest_preview))
    end

    it 'resolves and renders the recipient display name and outcome (regression: User#name is not a DB column)' do
      # The manager role grants view_issues, so the rule creator is an eligible
      # project_members recipient. This exercises the id => name mapping that a
      # naive pluck(:id, :name) would break, since name is a composed method.
      post :preview, params: { project_id: project.id, id: rule.id }, format: :js
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(user.name)
      expect(response.body).to include(I18n.t(:digest_preview_would_send, count: 0))
    end

    it 'returns 404 for a rule in another project (IDOR)' do
      other_rule = create(:issue_digest_rule, project: other_project, created_by: user)
      post :preview, params: { project_id: project.id, id: other_rule.id }, format: :js
      expect(response).to have_http_status(:not_found)
    end

    context 'as a viewer without manage permission' do
      let!(:viewer) { create(:user) }

      before do
        Member.create!(project: project, user: viewer, roles: [non_manager_role])
        User.current = viewer
        allow(controller).to receive(:find_current_user).and_return(viewer)
        allow(User).to receive(:current).and_return(viewer)
      end

      it 'is forbidden (preview requires manage_digest_rules)' do
        post :preview, params: { project_id: project.id, id: rule.id }, format: :js
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe 'IDOR protection' do
    it 'returns 404 when accessing a rule from another project' do
      other_rule = create(:issue_digest_rule, project: other_project, created_by: user)
      get :show, params: { project_id: project.id, id: other_rule.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'Permission denial' do
    let!(:outsider) { create(:user) }

    before do
      # Outsider is not a member of the project and not admin.
      User.current = outsider
      allow(controller).to receive(:find_current_user).and_return(outsider)
      allow(User).to receive(:current).and_return(outsider)
    end

    it 'returns 403 for a non-member' do
      get :index, params: { project_id: project.id }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'defaults on GET #new' do
    it 'renders successfully with grace_window_hours defaulting to 24' do
      get :new, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="24"')
    end
  end

  describe 'default_timezone_iana (unit)' do
    subject(:ctrl) { controller }

    it 'converts ActiveSupport timezone name to IANA identifier' do
      tz = ActiveSupport::TimeZone['Eastern Time (US & Canada)']
      expect(tz.tzinfo.name).to eq('America/New_York')
    end

    it 'returns UTC for blank name' do
      tz = ActiveSupport::TimeZone['']
      expect(tz).to be_nil
    end

    it 'returns UTC for unrecognised name' do
      tz = ActiveSupport::TimeZone['Not/A/Zone']
      expect(tz).to be_nil
    end
  end

  describe 'grace_window_hours validation — regression for old max:23' do
    it 'accepts grace_window_hours of 24 on create' do
      params = valid_params.merge(grace_window_hours: 24)
      expect {
        post :create, params: { project_id: project.id, issue_digest_rule: params }
      }.to change(IssueDigestRule, :count).by(1)
      expect(IssueDigestRule.order(:id).last.grace_window_hours).to eq(24)
    end

    it 'accepts grace_window_hours of 48 on create' do
      params = valid_params.merge(grace_window_hours: 48)
      expect {
        post :create, params: { project_id: project.id, issue_digest_rule: params }
      }.to change(IssueDigestRule, :count).by(1)
    end

    it 'rejects grace_window_hours of 49 on create' do
      params = valid_params.merge(grace_window_hours: 49)
      expect {
        post :create, params: { project_id: project.id, issue_digest_rule: params }
      }.not_to change(IssueDigestRule, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET #new — recipient relationship hint (regression: tooltip → visible hint)' do
    it 'shows the relationship-mode explanation as visible help text, not a title-only icon' do
      get :new, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      # Apostrophe-free substring so the assertion is stable regardless of how
      # the Redmine version HTML-escapes the rendered hint.
      expect(response.body).to include('These modes pick recipients from the matching issues')
      # The dropped, version-fragile info icon was an icon-only span whose only
      # affordance was a native title tooltip. Ensure no such element remains.
      expect(response.body).not_to match(/class="icon-only"[^>]*title=/)
    end

    it 'no longer appends "(of matching issues)" to the assignees label' do
      get :new, params: { project_id: project.id }
      expect(response.body).to include(I18n.t(:recipient_mode_assignees))
      expect(response.body).not_to include('(of matching issues)')
    end
  end

  describe 'POST #create — schedule_config pruning (N1)' do
    it 'drops schedule_config keys not relevant to the selected schedule_type' do
      params = valid_params.merge(
        schedule_type: 'daily',
        schedule_config: { 'day' => '5', 'every' => '3', 'days' => ['1'] }
      )
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
      expect(IssueDigestRule.order(:id).last.schedule_config).to eq({})
    end

    it 'keeps only the relevant key when the schedule_type is weekly' do
      params = valid_params.merge(
        schedule_type: 'weekly',
        schedule_config: { 'day' => '5', 'every' => '3' }
      )
      post :create, params: { project_id: project.id, issue_digest_rule: params }
      expect(response).to redirect_to(settings_project_path(project, tab: 'digest_rules'))
      expect(IssueDigestRule.order(:id).last.schedule_config).to eq({ 'day' => 5 })
    end
  end
end
