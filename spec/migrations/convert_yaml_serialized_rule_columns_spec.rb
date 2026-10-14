# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../../db/migrate/012_convert_yaml_serialized_rule_columns_to_json'

# Rules saved on Redmine 5.1 (Rails 6.1 ignores `coder: JSON`) hold YAML in
# schedule_config and recipient_modes. Seed such rows the way 5.1 wrote them
# and check the migration makes them readable on Redmine 7.
RSpec.describe ConvertYamlSerializedRuleColumnsToJson do
  let(:project) { create(:project) }
  let(:user)    { create(:user) }

  def insert_raw(schedule_config, recipient_modes, name)
    rule = create(:issue_digest_rule, :weekly, project: project, created_by: user, name: name)
    # Raw SQL: update_all would pass the strings through the JSON coder.
    sql = IssueDigestRule.sanitize_sql_array(
      ["UPDATE #{IssueDigestRule.table_name} SET schedule_config = ?, recipient_modes = ? WHERE id = ?",
       schedule_config, recipient_modes, rule.id]
    )
    IssueDigestRule.connection.execute(sql)
    rule.id
  end

  def raw(id, column)
    IssueDigestRule.connection.select_value(
      IssueDigestRule.where(id: id).select(column).to_sql
    )
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  let!(:yaml_id) do
    insert_raw("--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\nday: 3\n",
               "---\n- project_members\n- user:5\n", 'from 5.1 form')
  end
  let!(:plain_yaml_id) { insert_raw("---\nevery: 2\n", "---\n- assignees\n", 'from 5.1 console') }
  let!(:json_id) { insert_raw('{"day":4}', '["watchers"]', 'already JSON') }

  it 'cannot be read before the migration (the 5.1 rows break on Redmine 7)' do
    expect { IssueDigestRule.find(yaml_id).schedule_config }.to raise_error(JSON::ParserError)
  end

  it 'converts YAML rows to JSON, leaves JSON rows alone, and is idempotent' do
    migrate_up

    rule = IssueDigestRule.find(yaml_id)
    expect(rule.schedule_config).to eq('day' => 3)
    expect(rule.recipient_modes).to eq(%w[project_members user:5])
    expect(rule).to be_valid

    plain = IssueDigestRule.find(plain_yaml_id)
    expect(plain.schedule_config).to eq('every' => 2)
    expect(plain.recipient_modes).to eq(%w[assignees])

    expect(raw(json_id, :schedule_config)).to eq('{"day":4}')
    expect(raw(json_id, :recipient_modes)).to eq('["watchers"]')

    before = %i[schedule_config recipient_modes].map { |c| raw(yaml_id, c) }
    migrate_up
    expect(%i[schedule_config recipient_modes].map { |c| raw(yaml_id, c) }).to eq(before)
  end

  it 'keeps the converted rows readable as YAML, so a rollback to Redmine 5.1 still works' do
    migrate_up
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) }
    expect(YAML.safe_load(raw(yaml_id, :schedule_config))).to eq('day' => 3)
    expect(YAML.safe_load(raw(yaml_id, :recipient_modes))).to eq(%w[project_members user:5])
  end
end
