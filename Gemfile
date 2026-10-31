# frozen_string_literal: true

source 'https://rubygems.org'

ruby '~> 3.4.0'

gem 'rake'

# Testing dependencies
group :test do
  gem 'rspec', '~> 3.12'
  gem 'rspec_junit_formatter', '~> 0.6' # For CircleCI test reporting
  gem 'simplecov', '~> 0.22' # For code coverage
  gem 'webmock', '~> 3.18' # For mocking HTTP requests
end

# Development dependencies
group :development do
  gem 'pry', '~> 0.14' # Debugging tool
  gem 'rubocop', '~> 1.50' # Ruby linter
  gem 'rubocop-rspec', '~> 3.0' # RSpec-specific linting rules
end

# AWS SDK - the Lambdas run on the managed ruby3.4 runtime's own gems. These are
# only for local testing.
group :test, :development do
  gem 'aws-sdk-autoscaling', '~> 1'
  gem 'aws-sdk-dynamodb', '~> 1'
  gem 'aws-sdk-ec2', '~> 1'
  gem 'aws-sdk-elasticloadbalancingv2', '~> 1'
  gem 'aws-sdk-eventbridge', '~> 1'
  gem 'aws-sdk-ssm', '~> 1'
  gem 'aws-sdk-sts', '~> 1'
end
