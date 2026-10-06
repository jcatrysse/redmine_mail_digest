# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe 'settings/_issue_digest_settings', type: :view do
  let(:settings) do
    { 'max_issues_per_email' => 500, 'run_history_retention_days' => 90, 'allow_external_recipients' => true }
  end

  before { render partial: 'settings/issue_digest_settings', locals: { settings: settings } }

  # The label's for= must reach the checkbox: the hidden "0" field used to carry
  # the same id, so the id was duplicated and the label toggled nothing.
  it 'gives the external-recipients id to the checkbox only' do
    doc = Nokogiri::HTML(rendered)
    nodes = doc.css('#settings_allow_external_recipients')
    expect(nodes.size).to eq(1)
    expect(nodes.first['type']).to eq('checkbox')
    expect(nodes.first['checked']).to be_present
    expect(doc.css('input[type=hidden][name="settings[allow_external_recipients]"]').size).to eq(1)
  end
end
