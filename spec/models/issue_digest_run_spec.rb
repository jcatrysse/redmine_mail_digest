# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe IssueDigestRun, type: :model do
  describe 'validations' do
    it 'is valid with required fields' do
      expect(build(:issue_digest_run)).to be_valid
    end

    it 'is invalid without status' do
      expect(build(:issue_digest_run, status: nil)).not_to be_valid
    end

    it 'is invalid with an unknown status' do
      expect(build(:issue_digest_run, status: 'unknown')).not_to be_valid
    end

    it 'is invalid with an unknown trigger' do
      expect(build(:issue_digest_run, trigger: 'wat')).not_to be_valid
    end

    it 'accepts all defined status values' do
      IssueDigestRun::STATUSES.each do |status|
        expect(build(:issue_digest_run, status: status)).to be_valid
      end
    end

    it 'rejects negative counts' do
      expect(build(:issue_digest_run, recipients_count: -1)).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to an issue_digest_rule' do
      expect(build(:issue_digest_run).issue_digest_rule).to be_a(IssueDigestRule)
    end

    it 'has many deliveries' do
      run = create(:issue_digest_run)
      create(:issue_digest_delivery, issue_digest_run: run)
      create(:issue_digest_delivery, issue_digest_run: run)
      expect(run.issue_digest_deliveries.count).to eq(2)
    end

    it 'cascade-deletes deliveries on destroy' do
      run = create(:issue_digest_run)
      create(:issue_digest_delivery, issue_digest_run: run)
      expect { run.destroy }.to change(IssueDigestDelivery, :count).by(-1)
    end
  end

  describe '.recent_first' do
    it 'orders by started_at descending' do
      rule = create(:issue_digest_rule)
      older = create(:issue_digest_run, issue_digest_rule: rule, started_at: 2.days.ago)
      newer = create(:issue_digest_run, issue_digest_rule: rule, started_at: 1.day.ago)
      expect(IssueDigestRun.recent_first.pluck(:id).first(2)).to eq([newer.id, older.id])
    end
  end
end
