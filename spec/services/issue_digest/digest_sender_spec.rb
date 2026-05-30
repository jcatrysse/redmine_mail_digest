# frozen_string_literal: true

require_relative '../../rails_helper'

# Stub mailer so we don't depend on Agent 5's not-yet-built class.
class IssueDigestMailer
  def self.digest_email(_rule, _user, _issues, _grouped)
    raise NotImplementedError, 'stub must be replaced via allow(...) in specs'
  end
end unless defined?(IssueDigestMailer)

RSpec.describe IssueDigest::DigestSender, type: :service do
  let!(:project)   { create(:project, is_public: true) }
  # Use lazy `let` (not `let!`) for user records so they are created only when
  # first accessed in a test — after the `before` stub for
  # deliver_security_notification is in place.  Eager `let!` would run before
  # the stub, triggering real background-job delivery and causing
  # DeserializationError against stale AnonymousUser IDs from prior transactions.
  let(:admin)      { create(:user, admin: true) }
  let!(:open_st)   { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
  let!(:tracker)   { t = create(:tracker, default_status: open_st); project.trackers << t; t }
  let!(:priority)  { create(:issue_priority, is_default: true) }
  let(:user_a)     { create(:user, admin: true) }
  let(:user_b)     { create(:user, admin: true) }

  let(:mail_double) { instance_double('ActionMailer::MessageDelivery', deliver_now: true) }

  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
    allow(IssueDigestMailer).to receive(:digest_email).and_return(mail_double)
  end

  def make_issue(attrs = {})
    create(:issue, { project: project, tracker: tracker, priority: priority,
                     status: open_st, author: admin }.merge(attrs))
  end

  # Build a RecipientResolver::Recipient. Defaults to :broad (no source
  # narrowing) so per-recipient issue expectations match the full matching list.
  def recipient(user, modes = [:broad])
    IssueDigest::RecipientResolver::Recipient.new(user: user, modes: Set.new(modes))
  end

  let(:rule) do
    create(:issue_digest_rule,
           project: project,
           recipient_modes: ["user:#{user_a.id}", "user:#{user_b.id}"],
           send_empty: true)
  end

  describe '#send (non-dry-run)' do
    it 'creates a run, delivers to each recipient, and finishes success' do
      make_issue
      make_issue
      # Pretend both users are valid recipients
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a), recipient(user_b)])

      expect(IssueDigestMailer).to receive(:digest_email).twice.and_return(mail_double)
      expect(mail_double).to receive(:deliver_now).twice

      run = described_class.new(rule, dry_run: false).send
      expect(run).to be_a(IssueDigestRun)
      expect(run.status).to eq('success')
      expect(run.recipients_count).to eq(2)
      expect(run.emails_sent_count).to eq(2)
      expect(run.emails_failed_count).to eq(0)
      expect(run.issues_count).to eq(4)
      expect(run.issue_digest_deliveries.count).to eq(2)
      expect(run.issue_digest_deliveries.pluck(:status)).to all(eq('sent'))
    end

    it 'updates rule.last_success_at when success' do
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      make_issue
      rule.update_column(:last_success_at, nil)

      described_class.new(rule, dry_run: false).send
      expect(rule.reload.last_success_at).to be_within(5.seconds).of(Time.current)
    end

    it 'finishes skipped when no recipients are resolved' do
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([])

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('skipped')
      expect(run.recipients_count).to eq(0)
      expect(run.issue_digest_deliveries.count).to eq(0)
      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'records skipped delivery when recipient has zero issues and send_empty=false' do
      rule.update!(send_empty: false)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      # No issues created → IssueResolver returns Issue.none

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('skipped')
      expect(run.recipients_count).to eq(1)
      expect(run.issue_digest_deliveries.count).to eq(1)
      d = run.issue_digest_deliveries.first
      expect(d.status).to eq('skipped')
      expect(d.issues_count).to eq(0)
      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'preloads issue associations before rendering to avoid mailer N+1 queries' do
      relation = instance_double(ActiveRecord::Relation)
      loaded = [make_issue]
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow_any_instance_of(IssueDigest::IssueResolver).to receive(:resolve).and_return(relation)
      allow(relation).to receive(:limit).and_return(relation)
      expect(relation).to receive(:includes)
        .with(:tracker, :status, :priority, :assigned_to, :fixed_version, :category)
        .and_return(loaded)

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('success')
    end

    it 'fails deliveries instead of sending a broader digest when saved query evaluation warns' do
      rule.update_column(:query_id, 999_999)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(Rails.logger).to receive(:warn)

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('failed')
      expect(run.emails_sent_count).to eq(0)
      expect(run.emails_failed_count).to eq(1)
      expect(run.warning_message).to match(/no longer exists/)
      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'mirrors the blocked-delivery outcome in dry-run when the saved query is unusable' do
      rule.update_column(:query_id, 999_999)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(Rails.logger).to receive(:warn)

      summary = described_class.new(rule, dry_run: true).send
      expect(summary[:warning_message]).to match(/no longer exists/)
      expect(summary[:plans]).to contain_exactly(hash_including(user_id: user_a.id, action: :fail))
      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'sends empty digest when send_empty=true' do
      rule.update!(send_empty: true)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('success')
      expect(run.emails_sent_count).to eq(1)
      d = run.issue_digest_deliveries.first
      expect(d.status).to eq('sent')
      expect(d.issues_count).to eq(0)
    end

    it 'records failure when mailer raises and finishes failed when all fail' do
      make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(IssueDigestMailer).to receive(:digest_email).and_raise(StandardError, 'smtp down')

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('failed')
      expect(run.emails_sent_count).to eq(0)
      expect(run.emails_failed_count).to eq(1)
      d = run.issue_digest_deliveries.first
      expect(d.status).to eq('failed')
      expect(d.error_message).to include('smtp down')
    end

    it 'returns partial_failure when some succeed and some fail' do
      make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a), recipient(user_b)])
      call_count = 0
      allow(IssueDigestMailer).to receive(:digest_email) do
        call_count += 1
        raise StandardError, 'fail' if call_count == 2

        mail_double
      end

      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('partial_failure')
      expect(run.emails_sent_count).to eq(1)
      expect(run.emails_failed_count).to eq(1)
    end

    it 'does not update last_success_at when failed' do
      make_issue
      rule.update_column(:last_success_at, nil)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(IssueDigestMailer).to receive(:digest_email).and_raise(Net::SMTPError, 'down')

      described_class.new(rule, dry_run: false).send
      expect(rule.reload.last_success_at).to be_nil
    end

    it 'records error status when RecipientResolver itself raises' do
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_raise(StandardError, 'broken')
      run = described_class.new(rule, dry_run: false).send
      expect(run.status).to eq('error')
      expect(run.error_message).to include('broken')
    end

    it 'passes the rule, user, issues and grouped_issues to the mailer' do
      i1 = make_issue
      i2 = make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      described_class.new(rule, dry_run: false).send

      expect(IssueDigestMailer).to have_received(:digest_email) do |r, u, issues, grouped|
        expect(r).to eq(rule)
        expect(u).to eq(user_a)
        expect(issues.map(&:id)).to match_array([i1.id, i2.id])
        # group_by defaults to 'none' → grouped should be nil
        expect(grouped).to be_nil
      end
    end

    it 'groups issues when group_by is set' do
      i1 = make_issue
      i2 = make_issue
      rule.update!(group_by: 'tracker')
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      described_class.new(rule, dry_run: false).send

      expect(IssueDigestMailer).to have_received(:digest_email) do |_r, _u, _issues, grouped|
        expect(grouped).to be_a(Hash)
        expect(grouped.values.flatten.map(&:id)).to match_array([i1.id, i2.id])
        expect(grouped.keys).to all(be_a(String))
      end
    end

    it 'limits issues to max_issues_per_email setting' do
      3.times { make_issue }
      # Setting.plugin_redmine_mail_digest is generated when init.rb registers settings
      # (Agent 4's responsibility). Stub the sender's setting lookup directly.
      allow_any_instance_of(described_class).to receive(:max_issues_per_email).and_return(2)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      described_class.new(rule, dry_run: false).send

      expect(IssueDigestMailer).to have_received(:digest_email) do |_r, _u, issues, _g|
        expect(issues.size).to eq(2)
      end
    end
  end

  describe '#send (orphaned query warning)' do
    it 'populates warning_message on the run when the query no longer exists' do
      rule.update_column(:query_id, 999_999)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(Rails.logger).to receive(:warn)

      run = described_class.new(rule, dry_run: false).send
      expect(run).to be_a(IssueDigestRun)
      expect(run.warning_message).to match(/no longer exists/)
    end

    it 'does not set warning_message when no query is referenced' do
      rule.update!(query_id: nil)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      run = described_class.new(rule, dry_run: false).send
      expect(run.warning_message).to be_nil
    end
  end

  describe '#send (dry_run)' do
    it 'returns a summary hash, writes no DB records, and does not send mail' do
      make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a), recipient(user_b)])

      expect do
        result = described_class.new(rule, dry_run: true).send
        expect(result).to be_a(Hash)
        expect(result[:rule_id]).to eq(rule.id)
        expect(result[:recipients_count]).to eq(2)
        expect(result[:plans].size).to eq(2)
        expect(result[:plans].map { |p| p[:action] }).to all(eq(:send))
        expect(result[:warning_message]).to be_nil
      end.to change(IssueDigestRun, :count).by(0)
         .and change(IssueDigestDelivery, :count).by(0)

      expect(IssueDigestMailer).not_to have_received(:digest_email)
    end

    it 'includes warning_message in dry-run summary when the query no longer exists' do
      rule.update_column(:query_id, 999_999)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])
      allow(Rails.logger).to receive(:warn)

      result = described_class.new(rule, dry_run: true).send
      expect(result[:warning_message]).to match(/no longer exists/)
    end

    it 'reports skip plans for users with no issues when send_empty=false' do
      rule.update!(send_empty: false)
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      result = described_class.new(rule, dry_run: true).send
      expect(result[:plans].first[:action]).to eq(:skip)
    end

    it 'collects the human-readable lines into summary[:log] for the UI preview' do
      make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      result = described_class.new(rule, dry_run: true).send
      expect(result[:log]).to be_an(Array)
      expect(result[:log].first).to include("Rule ##{rule.id}")
      expect(result[:log].join("\n")).to match(/Would send 1 issues to user ##{user_a.id}/)
    end

    it 'can suppress stdout while still collecting summary log lines' do
      make_issue
      allow_any_instance_of(IssueDigest::RecipientResolver).to receive(:recipients).and_return([recipient(user_a)])

      result = nil
      expect { result = described_class.new(rule, dry_run: true, emit_stdout: false).send }
        .not_to output.to_stdout
      expect(result[:log].join("\n")).to match(/Would send 1 issues to user ##{user_a.id}/)
    end
  end
end

RSpec.describe IssueDigest::DigestSender, type: :service do
  describe '.clamped_max_issues_per_email' do
    it 'falls back to the default for non-positive values' do
      expect(described_class.clamped_max_issues_per_email('-10')).to eq(described_class::DEFAULT_MAX_ISSUES_PER_EMAIL)
      expect(described_class.clamped_max_issues_per_email('0')).to eq(described_class::DEFAULT_MAX_ISSUES_PER_EMAIL)
    end

    it 'caps very large values at the documented maximum' do
      expect(described_class.clamped_max_issues_per_email('999999')).to eq(described_class::MAX_MAX_ISSUES_PER_EMAIL)
    end
  end
end
