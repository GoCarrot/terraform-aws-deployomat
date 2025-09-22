# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

# RSpec tasks
RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = 'modules/**/spec/**/*_spec.rb'
  t.rspec_opts = '--format documentation --color'
end

# RuboCop linting task
RuboCop::RakeTask.new(:rubocop) do |t|
  t.patterns = ['modules/**/*.rb']
  t.options = ['--display-cop-names']
end

# Run tests for a specific module
namespace :spec do
  desc 'Run tests for deployomat module'
  task :deployomat do
    sh 'rspec modules/deployomat/spec --format documentation --color'
  end

  desc 'Run tests for slack_notifier module'
  task :slack_notifier do
    sh 'rspec modules/slack_notifier/spec --format documentation --color'
  end
end

# Terraform tasks
namespace :terraform do
  desc 'Format all Terraform files'
  task :fmt do
    sh 'terraform fmt -recursive'
  end

  desc 'Validate Terraform configuration'
  task :validate do
    sh 'terraform init -backend=false'
    sh 'terraform validate'
  end
end

# Combined tasks
desc 'Run all tests'
task test: [:spec]

desc 'Run all checks (tests, linting, terraform validation)'
task check: ['terraform:fmt', 'terraform:validate', :rubocop, :spec]

# Default task
task default: :test