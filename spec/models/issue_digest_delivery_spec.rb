# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe IssueDigestDelivery, type: :model do
  describe 'validations' do
    it 'is valid with required fields' do
      expect(build(:issue_digest_delivery)).to be_valid
    end

    it 'is invalid with an unknown status' do
      expect(build(:issue_digest_delivery, status: 'bounced')).not_to be_valid
    end

    it 'is invalid without an email' do
      expect(build(:issue_digest_delivery, email: nil)).not_to be_valid
    end

    it 'rejects negative issues_count' do
      expect(build(:issue_digest_delivery, issues_count: -5)).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to a run' do
      expect(build(:issue_digest_delivery).issue_digest_run).to be_a(IssueDigestRun)
    end

    it 'allows user to be nil' do
      delivery = build(:issue_digest_delivery, user: nil)
      expect(delivery).to be_valid
    end
  end
end
