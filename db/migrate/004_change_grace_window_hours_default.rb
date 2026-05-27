# frozen_string_literal: true

class ChangeGraceWindowHoursDefault < ActiveRecord::Migration[6.1]
  def change
    change_column_default :issue_digest_rules, :grace_window_hours, from: 4, to: 24
  end
end
