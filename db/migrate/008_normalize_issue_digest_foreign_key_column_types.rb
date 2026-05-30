# frozen_string_literal: true

# Converge the foreign-key column types to match a fresh install.
#
# Redmine's core tables (projects, users) use legacy int(11)/integer primary
# keys. The initial migrations (001/003) originally created these foreign-key
# columns with Rails' default :bigint, which works on PostgreSQL but is rejected
# by MySQL (errno 150). 001/003 were corrected to create them as :integer, but
# installs created before that correction still carry bigint columns.
#
# This migration aligns those installs with the corrected schema. It only
# touches columns that are still bigint, so it is a safe no-op on fresh installs
# (where 001/003 already created integer columns) and on any later re-run.
#
# Only the foreign keys that point at Redmine's core tables are changed. The
# plugin's own primary keys and the foreign keys between plugin tables stay
# bigint (they are self-consistent and never reference a Redmine int(11) key).
class NormalizeIssueDigestForeignKeyColumnTypes < ActiveRecord::Migration[6.1]
  COLUMNS = [
    %i[issue_digest_rules project_id],
    %i[issue_digest_rules created_by_id],
    %i[issue_digest_rules updated_by_id],
    %i[issue_digest_deliveries user_id]
  ].freeze

  def up
    COLUMNS.each do |table, column|
      change_column_type(table, column, :integer) if bigint?(table, column)
    end
  end

  def down
    # The bigint column state only ever existed on PostgreSQL: MySQL rejects a
    # bigint foreign key to Redmine's int(11) keys (errno 150), so it never had
    # that state to restore — and MySQL additionally refuses to MODIFY a column
    # that participates in a foreign key. Reverting to bigint is therefore a
    # PostgreSQL-only operation; elsewhere this is a safe no-op.
    return unless connection.adapter_name.downcase.include?('postgresql')

    COLUMNS.each do |table, column|
      change_column_type(table, column, :bigint) unless bigint?(table, column)
    end
  end

  private

  def bigint?(table, column)
    col = connection.columns(table).find { |c| c.name == column.to_s }
    col && col.sql_type.to_s =~ /bigint/i
  end

  # PostgreSQL cannot implicitly narrow bigint -> integer, so an explicit USING
  # cast is required (and harmless for the widening integer -> bigint direction).
  # Altering the *referencing* column keeps the existing foreign key and rebuilds
  # its index automatically. Other adapters accept a plain change_column.
  def change_column_type(table, column, type)
    if connection.adapter_name.downcase.include?('postgresql')
      sql_type = type.to_s
      execute(
        "ALTER TABLE #{connection.quote_table_name(table)} " \
        "ALTER COLUMN #{connection.quote_column_name(column)} TYPE #{sql_type} " \
        "USING #{connection.quote_column_name(column)}::#{sql_type}"
      )
    else
      change_column table, column, type
    end
  end
end
