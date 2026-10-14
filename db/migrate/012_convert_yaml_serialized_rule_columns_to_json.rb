# frozen_string_literal: true

# On Rails 6.1 (Redmine 5.1) `serialize :col, coder: JSON` ignores the
# coder: keyword and stores YAML; Rails 7.1+ (Redmine 6/7) reads JSON. Rules
# saved on Redmine 5.1 therefore raise JSON::ParserError on Redmine 7 (500 on
# every page listing them; the scheduler skips them as invalid).
#
# Convert every YAML value of the rule's serialized columns to JSON. Values
# that are not YAML (already JSON) are left alone, so the migration is
# idempotent. A YAML value that cannot be read is left as is and reported.
#
# down is a no-op on purpose: JSON is valid YAML for these values, so the
# Redmine 5.1 code still reads the converted rows after a rollback.
class ConvertYamlSerializedRuleColumnsToJson < ActiveRecord::Migration[6.1]
  class MigrationRule < ActiveRecord::Base
    self.table_name = 'issue_digest_rules'
  end

  COLUMNS = %w[schedule_config recipient_modes].freeze
  PERMITTED = %w[ActiveSupport::HashWithIndifferentAccess Symbol Date Time].freeze

  def up
    MigrationRule.reset_column_information
    MigrationRule.find_each do |rule|
      changes = {}
      COLUMNS.each do |column|
        raw = rule.read_attribute_before_type_cast(column)
        next unless raw.is_a?(String) && raw.lstrip.start_with?('---')

        value = YAML.safe_load(raw, permitted_classes: PERMITTED.map(&:constantize), aliases: true)
        changes[column] = JSON.generate(value.as_json)
      rescue Psych::Exception => e
        say "issue_digest_rules ##{rule.id}.#{column}: not converted (#{e.class}: #{e.message})"
      end
      next if changes.empty?

      rule.update_columns(changes)
      say "issue_digest_rules ##{rule.id}: #{changes.keys.join(', ')} converted from YAML to JSON"
    end
  end

  def down
    # JSON rows stay readable for the YAML coder of Redmine 5.1; nothing to undo.
  end
end
