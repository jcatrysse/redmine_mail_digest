# frozen_string_literal: true

require_relative 'spec_helper'

ENV['RAILS_ENV'] ||= 'test'

# Locate Redmine root by walking up from this file (or from REDMINE_ROOT env override).
# This is symlink-resilient: the plugin may live outside the Redmine tree and be
# symlinked into redmine/plugins/, in which case __FILE__ resolves outside Redmine.
def self.locate_redmine_root
  return ENV['REDMINE_ROOT'] if ENV['REDMINE_ROOT'] && File.exist?(File.join(ENV['REDMINE_ROOT'], 'config', 'environment.rb'))

  # Try ascending from the symlinked location first ($LOAD_PATH or caller path).
  candidates = [
    File.expand_path('../..', __dir__),                 # plugin's parent (works when not symlinked)
    File.expand_path('../../../../..', __FILE__)        # plugins/<name>/spec → redmine root
  ]
  # Also probe up to 6 levels above CWD.
  pwd = Dir.pwd
  6.times { |i| candidates << File.expand_path('../' * i, pwd) }

  candidates.uniq.each do |dir|
    return dir if File.exist?(File.join(dir, 'config', 'environment.rb')) &&
                  File.directory?(File.join(dir, 'plugins'))
  end
  raise "Cannot locate Redmine root. Set REDMINE_ROOT or run rspec from a Redmine tree."
end

require File.join(locate_redmine_root, 'config', 'environment')

abort('Rails is running in production') if Rails.env.production?

require 'rspec/rails'
require 'factory_bot_rails'

# Load all factories defined in spec/factories.
Dir[File.expand_path('factories/**/*.rb', __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers

  # Redmine plugin tests do not load Redmine's MiniTest fixtures by default;
  # specs that need them can opt in via fixtures(...).
end
