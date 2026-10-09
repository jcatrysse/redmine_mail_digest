# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../../db/migrate/011_add_starting_soon_and_unassigned_to_issue_digest_rules'

RSpec.describe AddStartingSoonAndUnassignedToIssueDigestRules do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns)    { %w[include_starting_soon starting_soon_days filter_unassigned] }

  def column_names
    connection.columns(:issue_digest_rules).map(&:name)
  end

  def run(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    IssueDigestRule.reset_column_information
  end

  # DDL is transactional on PostgreSQL; on MySQL it is not, so always migrate
  # back up, whatever happens in the example.
  after do
    run(:up) unless (columns - column_names).empty?
  end

  it 'removes the three columns on down and restores them with their defaults on up' do
    expect(column_names).to include(*columns)

    run(:down)
    expect(column_names).not_to include(*columns)

    run(:up)
    cols = connection.columns(:issue_digest_rules).index_by(&:name)
    expect(cols['include_starting_soon'].null).to be(false)
    expect(cols['filter_unassigned'].null).to be(false)
    expect(cols['starting_soon_days'].null).to be(false)
    rule = IssueDigestRule.new
    expect(rule.include_starting_soon).to be(false)
    expect(rule.starting_soon_days).to eq(7)
    expect(rule.filter_unassigned).to be(false)
  end
end
