# frozen_string_literal: true

require 'json'
require 'rspec'

# Structure checks on deploy.json.
RSpec.describe 'state_machines/deploy.json' do # rubocop:disable RSpec/DescribeClass
  let(:states) { JSON.parse(File.read(File.join(__dir__, '..', 'state_machines', 'deploy.json'))).fetch('States') }

  it 'hands Start the deploy run, for its started event' do
    expect(states['StartDeploy']['Parameters']).to include('ExecutionArn.$' => '$$.Execution.Id')
  end
end
