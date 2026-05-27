# frozen_string_literal: true

require_relative '../rails_helper'

# End-to-end exercise of the digest pipeline:
#   rule  →  ScheduleEvaluator (forced)  →  DigestSender  →
#   RecipientResolver  →  IssueResolver  →  IssueDigestMailer  →
#   RunRecorder
#
# The mailer is real (ActionMailer::Base#deliveries) – the SMTP layer is
# replaced by Rails' :test delivery method via test environment.
RSpec.describe 'Digest pipeline integration', type: :request do
  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
    allow(Setting).to receive(:mail_from).and_return('redmine@example.com')
    allow(Setting).to receive(:host_name).and_return('redmine.example.com')
    allow(Setting).to receive(:protocol).and_return('https')
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.deliveries.clear
  end

  let!(:role) do
    Role.create!(
      name: "IntegRole_#{SecureRandom.hex(4)}",
      permissions: %i[view_issues view_digest_rules manage_digest_rules]
    )
  end
  let!(:project)  { create(:project, is_public: true) }
  let!(:open_st)  { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
  let!(:tracker)  { t = create(:tracker, default_status: open_st); project.trackers << t; t }
  let!(:priority) { create(:issue_priority, is_default: true) }
  let!(:alice)    { create(:user) }
  let!(:bob)      { create(:user) }

  def add_member(user, project_to_add = project)
    Member.create!(principal: user, project: project_to_add, roles: [role])
  end

  def make_issue(attrs = {})
    create(:issue, { project: project, tracker: tracker, status: open_st,
                     priority: priority, author: alice }.merge(attrs))
  end

  describe 'end-to-end: create rule, send digest, recipients get personalized emails' do
    it 'sends one email per eligible recipient with their visible issues' do
      add_member(alice)
      add_member(bob)

      # Two issues; one assigned to alice, one to bob.
      issue_a = make_issue(subject: 'Alice work')
      issue_b = make_issue(subject: 'Bob work')

      rule = create(:issue_digest_rule,
                    project: project,
                    name: 'Daily open issues',
                    schedule_type: 'daily',
                    include_open: true,
                    recipient_modes: ['project_members'])

      ActionMailer::Base.deliveries.clear
      result = IssueDigest::DigestSender.new(rule, dry_run: false, trigger: :manual).send

      expect(result).to be_a(IssueDigestRun)
      expect(result.status).to eq('success')
      expect(result.emails_sent_count).to eq(2)
      expect(ActionMailer::Base.deliveries.size).to eq(2)

      recipients = ActionMailer::Base.deliveries.flat_map(&:to)
      expect(recipients).to match_array([alice.mail, bob.mail])

      # Both recipients see both issues (filter_assigned_to_recipient is OFF).
      ActionMailer::Base.deliveries.each do |mail|
        html = mail.html_part.body.to_s
        expect(html).to include('Alice work')
        expect(html).to include('Bob work')
      end
    end
  end

  describe 'personalization: filter_assigned_to_recipient' do
    it 'each recipient sees only issues assigned to them' do
      add_member(alice)
      add_member(bob)

      make_issue(subject: 'For Alice', assigned_to: alice)
      make_issue(subject: 'For Bob',   assigned_to: bob)
      make_issue(subject: 'Unassigned')

      rule = create(:issue_digest_rule,
                    project: project,
                    include_open: true,
                    recipient_modes: ['project_members'],
                    filter_assigned_to_recipient: true)

      ActionMailer::Base.deliveries.clear
      IssueDigest::DigestSender.new(rule, dry_run: false, trigger: :manual).send

      alice_mail = ActionMailer::Base.deliveries.find { |m| m.to.include?(alice.mail) }
      bob_mail   = ActionMailer::Base.deliveries.find { |m| m.to.include?(bob.mail)   }

      expect(alice_mail.html_part.body.to_s).to include('For Alice')
      expect(alice_mail.html_part.body.to_s).not_to include('For Bob')
      expect(bob_mail.html_part.body.to_s).to include('For Bob')
      expect(bob_mail.html_part.body.to_s).not_to include('For Alice')
    end
  end

  describe 'visibility: private project excludes non-members' do
    it 'does not include a non-member as recipient' do
      private_project = create(:project, is_public: false)
      private_tracker = create(:tracker, default_status: open_st)
      private_project.trackers << private_tracker
      add_member(alice, private_project)
      # bob is NOT a member of the private project
      add_member(bob)

      create(:issue, project: private_project, tracker: private_tracker,
             status: open_st, priority: priority, author: alice,
             subject: 'Secret work')

      rule = create(:issue_digest_rule,
                    project: private_project,
                    include_open: true,
                    recipient_modes: ['project_members'])

      ActionMailer::Base.deliveries.clear
      result = IssueDigest::DigestSender.new(rule, dry_run: false, trigger: :manual).send
      expect(result.emails_sent_count).to eq(1)
      expect(ActionMailer::Base.deliveries.first.to).to eq([alice.mail])
    end
  end

  describe 'send_empty=false skips users with no matching issues' do
    it 'records a skipped delivery for users with zero matching issues' do
      add_member(alice)
      add_member(bob)
      make_issue(subject: 'For Alice', assigned_to: alice)
      # bob has nothing assigned

      rule = create(:issue_digest_rule,
                    project: project,
                    include_open: true,
                    recipient_modes: ['project_members'],
                    filter_assigned_to_recipient: true,
                    send_empty: false)

      ActionMailer::Base.deliveries.clear
      result = IssueDigest::DigestSender.new(rule, dry_run: false, trigger: :manual).send
      expect(result.emails_sent_count).to eq(1)
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.first.to).to eq([alice.mail])
      # bob got a 'skipped' delivery record
      bob_delivery = result.issue_digest_deliveries.find_by(user_id: bob.id)
      expect(bob_delivery.status).to eq('skipped')
    end
  end

  describe 'multi-project isolation' do
    it 'runs the right rule for the right project' do
      other_project = create(:project, is_public: true)
      other_tracker = create(:tracker, default_status: open_st)
      other_project.trackers << other_tracker
      add_member(alice, other_project)

      create(:issue, project: other_project, tracker: other_tracker,
             status: open_st, priority: priority, author: alice,
             subject: 'Other project issue')

      add_member(alice)
      make_issue(subject: 'My project issue')

      rule_main  = create(:issue_digest_rule, project: project, include_open: true, recipient_modes: ['project_members'])
      rule_other = create(:issue_digest_rule, project: other_project, include_open: true, recipient_modes: ['project_members'])

      ActionMailer::Base.deliveries.clear
      IssueDigest::DigestSender.new(rule_main, dry_run: false, trigger: :manual).send
      IssueDigest::DigestSender.new(rule_other, dry_run: false, trigger: :manual).send

      # 2 emails to alice (one per project); each contains only its own issue.
      expect(ActionMailer::Base.deliveries.size).to eq(2)
      bodies = ActionMailer::Base.deliveries.map { |m| m.html_part.body.to_s }
      main_body  = bodies.find { |b| b.include?('My project issue') }
      other_body = bodies.find { |b| b.include?('Other project issue') }
      expect(main_body).not_to include('Other project issue')
      expect(other_body).not_to include('My project issue')
    end
  end

  describe 'dry_run does not deliver or persist' do
    it 'returns a plan summary and no emails are queued' do
      add_member(alice)
      make_issue(assigned_to: alice)
      rule = create(:issue_digest_rule, project: project, include_open: true, recipient_modes: ['project_members'])

      ActionMailer::Base.deliveries.clear
      run_count_before = IssueDigestRun.count
      delivery_count_before = IssueDigestDelivery.count

      result = IssueDigest::DigestSender.new(rule, dry_run: true).send

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(IssueDigestRun.count).to eq(run_count_before)
      expect(IssueDigestDelivery.count).to eq(delivery_count_before)
      expect(result).to be_a(Hash)
      expect(result[:recipients_count]).to eq(1)
      expect(result[:plans].first[:action]).to eq(:send)
    end
  end
end
