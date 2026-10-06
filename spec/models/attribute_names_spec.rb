# frozen_string_literal: true

require_relative '../rails_helper'

# Redmine translates attribute names through field_<name> (labels in the form
# and in error messages). Redmine 5.1 patched ActiveRecord::Base for that;
# Redmine 6 and 7 do it in ApplicationRecord only, so a model on
# ActiveRecord::Base fell back to "Grace window hours", "End on" in every
# language.
RSpec.describe 'plugin model attribute names' do
  it 'come from the field_ keys of the locale' do
    I18n.with_locale(:nl) do
      expect(IssueDigestRule.human_attribute_name(:grace_window_hours)).to eq(I18n.t(:field_grace_window_hours))
      expect(IssueDigestRule.human_attribute_name(:end_on)).to eq(I18n.t(:field_end_on))
    end
  end

  it 'are used in the validation messages' do
    rule = build(:issue_digest_rule, project: create(:project), name: '')
    I18n.with_locale(:nl) do
      rule.valid?
      expect(rule.errors.full_messages).to include(start_with(I18n.t(:field_name)))
    end
  end
end
