# frozen_string_literal: true

require 'json'
require 'rspec'

# Read at require time by src/lib.rb.
ENV['DEPLOYOMAT_SERVICE_NAME'] = 'Deployomat'
ENV['DEPLOYOMAT_META_ROLE_ARN'] = 'arn:aws:iam::111111111111:role/meta'
ENV['DEPLOYOMAT_ENV'] = 'test'
ENV['DEPLOYOMAT_TABLE'] = 'Deployomat'
ENV['AWS_REGION'] = 'us-east-1'

require 'aws-sdk-core'
require_relative '../src/lambda_handlers'

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed
end
