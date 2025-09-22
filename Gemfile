# frozen_string_literal: true

source 'https://rubygems.org'

# Testing dependencies
group :test do
  gem 'rspec', '~> 3.12'
  gem 'rspec_junit_formatter', '~> 0.6'  # For CircleCI test reporting
  gem 'webmock', '~> 3.18'  # For mocking HTTP requests
  gem 'simplecov', '~> 0.22'  # For code coverage
end

# Development dependencies
group :development do
  gem 'rubocop', '~> 1.50'  # Ruby linter
  gem 'rubocop-rspec', '~> 2.20'  # RSpec-specific linting rules
  gem 'pry', '~> 0.14'  # Debugging tool
end

# AWS SDK - matches Lambda Ruby 2.7 runtime
# These are provided by Lambda runtime but needed for local testing
group :test, :development do
  gem 'aws-sdk-autoscaling', '~> 1'
  gem 'aws-sdk-dynamodb', '~> 1'
  gem 'aws-sdk-ec2', '~> 1'
  gem 'aws-sdk-elasticloadbalancingv2', '~> 1'
  gem 'aws-sdk-ssm', '~> 1'
  gem 'aws-sdk-sts', '~> 1'
end