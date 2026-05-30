# frozen_string_literal: true

# Plugin-level Gemfile. Redmine merges this into its own bundle via:
#   Dir.glob "plugins/*/{Gemfile,PluginGemfile}" { |f| eval_gemfile f }
#
# Only declare the gems the plugin's own test suite needs; runtime
# dependencies come from Redmine itself.
group :test do
  gem 'rspec-rails'
  gem 'factory_bot_rails'
  gem 'rails-controller-testing'
end
