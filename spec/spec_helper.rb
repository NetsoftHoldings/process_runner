# frozen_string_literal: true

require 'bundler/setup'

require 'fakefs/safe'
require 'simplecov'
SimpleCov.start

Dir[File.join(__dir__, 'support/*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.expect_with :rspec do |c|
    c.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles        = true
    c.verify_doubled_constant_names = true
  end

  config.warnings = true

  config.profile_examples = 10

  config.order = :random

  Kernel.srand config.seed

  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  config.default_formatter                = 'doc' if config.files_to_run.one?

  config.before do
    allow(Redis).to receive(:new).and_raise(NotImplementedError, 'Please stub redis')

    ProcessRunner.reset
  end
end
