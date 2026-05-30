# frozen_string_literal: true

require_relative '../rails_helper'
require 'rake'

# Stub the mailer (Agent 5 deliverable) so DigestSender can call it without raising.
class IssueDigestMailer
  def self.digest_email(_rule, _user, _issues, _grouped)
    raise NotImplementedError
  end
end unless defined?(IssueDigestMailer)

RSpec.describe 'redmine:issue_digest rake tasks' do
  before(:all) do
    Rake.application = Rake::Application.new
    Rake::Task.clear
    Rails.application.load_tasks
    rake_path = File.expand_path('../../lib/tasks/issue_digest.rake', __dir__)
    load rake_path unless Rake::Task.task_defined?('redmine:issue_digest:send')
  end

  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
  end

  let!(:project) do
    p = create(:project, is_public: true)
    # Enable the issue_digest module so the rake-task scope finds the project.
    p.enabled_modules.create!(name: 'issue_digest')
    p
  end
  let!(:user)     { create(:user, admin: true) }
  let!(:open_st)  { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
  let!(:tracker)  { t = create(:tracker, default_status: open_st); project.trackers << t; t }
  let!(:priority) { create(:issue_priority, is_default: true) }

  let(:mail_double) { instance_double('ActionMailer::MessageDelivery', deliver_now: true) }

  def make_issue
    create(:issue, project: project, tracker: tracker, priority: priority,
                   status: open_st, author: user)
  end

  def reenable(task_name)
    task = Rake::Task[task_name]
    task.reenable
    task
  end

  def reset_env_keys
    %w[DRY_RUN PROJECT_IDENTIFIER RULE_ID VERBOSE FORCE MANUAL].each { |k| ENV.delete(k) }
  end

  before { reset_env_keys }
  after  { reset_env_keys }

  describe 'redmine:issue_digest:send' do
    let!(:rule) do
      create(:issue_digest_rule,
             project: project,
             recipient_modes: ["user:#{user.id}"],
             send_empty: true,
             active: true)
    end

    before do
      Member.create!(principal: user, project: project,
                     roles: [Role.create!(name: "RakeRole_#{SecureRandom.hex(4)}",
                                          permissions: %i[view_issues])])
      allow(IssueDigestMailer).to receive(:digest_email).and_return(mail_double)
      # Bypass ScheduleEvaluator due-check (tested in its own spec).
      allow_any_instance_of(IssueDigest::ScheduleEvaluator).to receive(:due?).and_return(true)
      allow_any_instance_of(IssueDigest::ScheduleEvaluator).to receive(:compute_schedule_key).and_return('test-key-1')
    end

    it 'sends digests for due rules with module enabled' do
      make_issue
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(1)
        .and change(IssueDigestDelivery, :count).by(1)

      expect(IssueDigestMailer).to have_received(:digest_email)
      expect(IssueDigestRun.last.status).to eq('success')
    end

    it 'skips rules for projects without the issue_digest module enabled' do
      project.enabled_modules.where(name: 'issue_digest').delete_all
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
    end

    it 'skips rules for archived projects' do
      project.update_column(:status, Project::STATUS_ARCHIVED)
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
    end

    it 'skips inactive rules' do
      rule.update_column(:active, false)
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
    end

    it 'honors PROJECT_IDENTIFIER to scope rules' do
      other_project = create(:project, is_public: true, identifier: "other-#{SecureRandom.hex(3)}")
      other_project.enabled_modules.create!(name: 'issue_digest')
      create(:issue_digest_rule, project: other_project, recipient_modes: ["user:#{user.id}"])

      ENV['PROJECT_IDENTIFIER'] = project.identifier
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(1)

      expect(IssueDigestRun.last.issue_digest_rule_id).to eq(rule.id)
    end

    it 'honors RULE_ID to scope to a single rule' do
      other_rule = create(:issue_digest_rule, project: project, recipient_modes: ["user:#{user.id}"])
      ENV['RULE_ID'] = rule.id.to_s
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(1)
      expect(IssueDigestRun.last.issue_digest_rule_id).to eq(rule.id)
      expect(IssueDigestRun.where(issue_digest_rule_id: other_rule.id).count).to eq(0)
    end

    it 'performs the schedule_key atomic claim and updates last_schedule_key' do
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change { rule.reload.last_schedule_key }.to('test-key-1')

      expect(rule.last_run_at).to be_within(10.seconds).of(Time.current)
    end

    it 'does not re-process a rule when last_schedule_key already matches (no FORCE)' do
      rule.update_column(:last_schedule_key, 'test-key-1')
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
    end

    it 're-processes when FORCE=1 even if last_schedule_key matches' do
      rule.update_column(:last_schedule_key, 'test-key-1')
      ENV['FORCE'] = '1'
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(1)
    end

    it 'uses trigger=manual when MANUAL=1 is scoped to a specific RULE_ID' do
      ENV['MANUAL'] = '1'
      ENV['RULE_ID'] = rule.id.to_s
      reenable('redmine:issue_digest:send').invoke
      expect(IssueDigestRun.last.trigger).to eq('manual')
      expect(IssueDigestRun.last.issue_digest_rule_id).to eq(rule.id)
    end

    it 'with MANUAL=1 and no RULE_ID only processes manual schedule rules' do
      manual_rule = create(:issue_digest_rule,
                           project: project,
                           schedule_type: 'manual',
                           send_time: nil,
                           schedule_config: {},
                           recipient_modes: ["user:#{user.id}"],
                           send_empty: true,
                           active: true)
      ENV['MANUAL'] = '1'

      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(1)

      expect(IssueDigestRun.last.trigger).to eq('manual')
      expect(IssueDigestRun.last.issue_digest_rule_id).to eq(manual_rule.id)
      expect(IssueDigestRun.where(issue_digest_rule_id: rule.id)).to be_empty
    end

    it 'in DRY_RUN mode writes no DB records and sends no mail' do
      make_issue
      ENV['DRY_RUN'] = '1'
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
        .and change(IssueDigestDelivery, :count).by(0)

      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'exits gracefully when the lock cannot be acquired' do
      allow(IssueDigest::LockManager).to receive(:with_lock).and_return(false)
      expect { reenable('redmine:issue_digest:send').invoke }
        .to change(IssueDigestRun, :count).by(0)
    end
  end

  describe 'redmine:issue_digest:cleanup' do
    let!(:rule) { create(:issue_digest_rule, project: project) }

    before do
      # Stub the plugin setting (Agent 4 wires init.rb).
      allow(Setting).to receive(:respond_to?).and_call_original
      # Ensure the rake task's `Setting.plugin_redmine_mail_digest rescue {}` resolves to {}.
    end

    it 'deletes runs older than the retention window' do
      old_run = create(:issue_digest_run, issue_digest_rule: rule, started_at: 200.days.ago)
      recent_run = create(:issue_digest_run, issue_digest_rule: rule, started_at: 5.days.ago)

      reenable('redmine:issue_digest:cleanup').invoke

      expect(IssueDigestRun.exists?(old_run.id)).to be false
      expect(IssueDigestRun.exists?(recent_run.id)).to be true
    end

    it 'cascades to deliveries' do
      old_run = create(:issue_digest_run, issue_digest_rule: rule, started_at: 200.days.ago)
      create(:issue_digest_delivery, issue_digest_run: old_run)

      expect { reenable('redmine:issue_digest:cleanup').invoke }
        .to change(IssueDigestDelivery, :count).by(-1)
    end

    it 'retains all records when run_history_retention_days is 0 (keep forever)' do
      old_run = create(:issue_digest_run, issue_digest_rule: rule, started_at: 500.days.ago)
      allow(Setting).to receive(:plugin_redmine_mail_digest)
        .and_return('run_history_retention_days' => 0)

      expect { reenable('redmine:issue_digest:cleanup').invoke }
        .not_to change(IssueDigestRun, :count)
      expect(IssueDigestRun.exists?(old_run.id)).to be true
    end

    it 'retains all records when run_history_retention_days is missing from settings' do
      old_run = create(:issue_digest_run, issue_digest_rule: rule, started_at: 500.days.ago)
      allow(Setting).to receive(:plugin_redmine_mail_digest).and_return({})

      expect { reenable('redmine:issue_digest:cleanup').invoke }
        .not_to change(IssueDigestRun, :count)
      expect(IssueDigestRun.exists?(old_run.id)).to be true
    end
  end
end
