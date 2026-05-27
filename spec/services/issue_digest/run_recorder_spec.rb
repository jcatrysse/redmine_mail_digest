# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::RunRecorder, type: :service do
  let!(:project) { create(:project) }
  let!(:rule)    { create(:issue_digest_rule, project: project) }
  let!(:user)    { create(:user) }

  before do
    allow_any_instance_of(User).to receive(:deliver_security_notification)
  end

  describe '#start' do
    it 'creates an IssueDigestRun with status=running and the configured trigger' do
      recorder = described_class.new(rule, trigger: :scheduled, schedule_key: 'k-1')
      run = recorder.start
      expect(run).to be_a(IssueDigestRun)
      expect(run).to be_persisted
      expect(run.status).to eq('running')
      expect(run.trigger).to eq('scheduled')
      expect(run.schedule_key).to eq('k-1')
      expect(run.started_at).to be_within(5.seconds).of(Time.current)
    end

    it 'accepts trigger=manual' do
      recorder = described_class.new(rule, trigger: :manual)
      run = recorder.start
      expect(run.trigger).to eq('manual')
    end

    it 'accepts trigger=dry_run' do
      recorder = described_class.new(rule, trigger: :dry_run)
      run = recorder.start
      expect(run.trigger).to eq('dry_run')
    end

    it 'raises ArgumentError on invalid trigger' do
      recorder = described_class.new(rule, trigger: :bogus)
      expect { recorder.start }.to raise_error(ArgumentError, /invalid trigger/)
    end

    it 'returns nil and logs when DB write fails' do
      recorder = described_class.new(rule, trigger: :scheduled)
      allow(IssueDigestRun).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      expect(Rails.logger).to receive(:error).with(/failed to create run record/)
      expect(recorder.start).to be_nil
    end
  end

  describe '#record_delivery' do
    let(:recorder) { described_class.new(rule, trigger: :scheduled).tap(&:start) }

    it 'creates a sent delivery row' do
      d = recorder.record_delivery(user, 'sent', issues_count: 5, sent_at: Time.current)
      expect(d).to be_a(IssueDigestDelivery)
      expect(d.status).to eq('sent')
      expect(d.user_id).to eq(user.id)
      expect(d.email).to eq(user.mail)
      expect(d.issues_count).to eq(5)
      expect(d.sent_at).to be_within(5.seconds).of(Time.current)
      expect(d.error_message).to be_nil
    end

    it 'creates a failed delivery row with truncated error message' do
      big = 'x' * 5000
      d = recorder.record_delivery(user, 'failed', issues_count: 0, error_message: big)
      expect(d.status).to eq('failed')
      expect(d.error_message.length).to be <= 2000
    end

    it 'creates a skipped delivery row' do
      d = recorder.record_delivery(user, 'skipped', issues_count: 0)
      expect(d.status).to eq('skipped')
      expect(d.issues_count).to eq(0)
    end

    it 'accepts symbol status' do
      d = recorder.record_delivery(user, :sent, issues_count: 1)
      expect(d.status).to eq('sent')
    end

    it 'raises ArgumentError for invalid status' do
      expect { recorder.record_delivery(user, 'bogus') }.to raise_error(ArgumentError, /invalid delivery status/)
    end

    it 'returns nil and logs on persistence failure (no raise)' do
      allow(IssueDigestDelivery).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      expect(Rails.logger).to receive(:error).with(/failed to record delivery/)
      expect(recorder.record_delivery(user, 'sent')).to be_nil
    end
  end

  describe '#finish' do
    let(:recorder) { described_class.new(rule, trigger: :scheduled).tap(&:start) }

    it 'updates the run with final status and counts' do
      run = recorder.finish('success',
                            recipients_count: 3,
                            emails_sent_count: 3,
                            emails_failed_count: 0,
                            issues_count: 12)
      expect(run.status).to eq('success')
      expect(run.recipients_count).to eq(3)
      expect(run.emails_sent_count).to eq(3)
      expect(run.emails_failed_count).to eq(0)
      expect(run.issues_count).to eq(12)
      expect(run.finished_at).to be_within(5.seconds).of(Time.current)
    end

    it 'accepts symbol status' do
      run = recorder.finish(:partial_failure,
                            recipients_count: 2,
                            emails_sent_count: 1,
                            emails_failed_count: 1)
      expect(run.status).to eq('partial_failure')
    end

    it 'truncates error_message' do
      big = 'x' * 5000
      run = recorder.finish('error', error_message: big)
      expect(run.error_message.length).to be <= 2000
    end

    it 'stores warning_message' do
      run = recorder.finish('success', warning_message: 'Query #42 no longer exists.')
      expect(run.warning_message).to eq('Query #42 no longer exists.')
    end

    it 'truncates warning_message at 2000 chars' do
      run = recorder.finish('success', warning_message: 'w' * 5000)
      expect(run.warning_message.length).to be <= 2000
    end

    it 'stores nil warning_message by default' do
      run = recorder.finish('success')
      expect(run.warning_message).to be_nil
    end

    it 'raises ArgumentError for invalid status' do
      expect { recorder.finish('bogus') }.to raise_error(ArgumentError, /invalid run status/)
    end

    it 'returns nil when run was not started' do
      recorder_no_start = described_class.new(rule, trigger: :scheduled)
      expect(recorder_no_start.finish('skipped')).to be_nil
    end

    it 'returns nil and logs when persistence fails' do
      run = recorder.run
      allow(run).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      expect(Rails.logger).to receive(:error).with(/failed to finalize run/)
      expect(recorder.finish('success')).to be_nil
    end
  end
end
