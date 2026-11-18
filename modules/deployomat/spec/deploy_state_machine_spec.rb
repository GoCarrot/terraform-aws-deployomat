# frozen_string_literal: true

require 'json'
require 'rspec'

# Structure checks on deploy.json: a rollback goes through Report, and nothing names a path that
# a failed run may not have. Step Functions fails a run on a missing path with States.Runtime,
# which a States.ALL Catch doesn't catch.
RSpec.describe 'state_machines/deploy.json' do # rubocop:disable RSpec/DescribeClass
  let(:states) { JSON.parse(File.read(File.join(__dir__, '..', 'state_machines', 'deploy.json'))).fetch('States') }

  def targets(state)
    [state['Next'], state['Default'], *Array(state['Choices']).map { |c| c['Next'] },
     *Array(state['Catch']).map { |c| c['Next'] }].compact
  end

  def reachable(from)
    seen = []
    queue = Array(from)
    until queue.empty?
      name = queue.shift
      next if seen.include?(name)

      seen << name
      queue.concat(targets(states.fetch(name)))
    end
    seen
  end

  # Every JSONPath a state reads: Parameters values ending .$, Choice variables, Input/Output paths.
  def paths(state)
    found = []
    walk = lambda do |obj|
      case obj
      when Hash
        obj.each do |key, value|
          path_key = key.end_with?('.$') || %w[Variable InputPath OutputPath].include?(key)
          found << value if path_key && value.is_a?(String)
          walk.call(value)
        end
      when Array then obj.each { |v| walk.call(v) }
      end
    end
    walk.call(state.except('Comment'))
    found
  end

  it 'hands Start the deploy run, for its started event' do
    expect(states['StartDeploy']['Parameters']).to include('ExecutionArn.$' => '$$.Execution.Id')
  end

  it 'runs Report only after Rollback, where no Lambda decided the ending' do
    expect(states.select { |_, s| targets(s).include?('Report') }.keys).to eq(['RolledBack'])
    expect(states['Report']['ResultPath']).to eq('$.Outcome')
    expect(states['Rollback']['Next']).to eq('RolledBack')
  end

  it 'falls back to an unreported ending when Report fails' do
    expect(states['Report']['Catch']).to eq([{ 'ErrorEquals' => ['States.ALL'], 'ResultPath' => '$.ReportError',
                                               'Next' => 'Unreported' }])
  end

  it 'checks Reported is present before comparing it, in rules of their own' do
    choices = states['ReportBranch']['Choices']

    expect(choices.first).to eq('Not' => { 'Variable' => '$.Outcome.Reported', 'IsPresent' => true },
                                'Next' => 'Unreported')
    expect(choices.last).to eq('Variable' => '$.Outcome.Reported', 'BooleanEquals' => true, 'Next' => 'Reported')
    expect(states['ReportBranch']['Default']).to eq('Unreported')
  end

  it 'hands Report the whole state, nothing it would have to find first' do
    expect(states['Report']['Parameters']).to eq(
      'AllInput.$' => '$', 'ExecutionArn.$' => '$$.Execution.Id', 'Step' => 'Report'
    )
  end

  it 'reads nothing under $.StartDeploy after a Catch or a failed Start' do
    catch_targets = states.values.flat_map { |s| Array(s['Catch']).map { |c| c['Next'] } }
    after_failure = reachable(catch_targets + ['KnownStartError']) - ['KnownStartError']

    reads = after_failure.to_h { |name| [name, paths(states.fetch(name)).grep(/\A\$\.StartDeploy/)] }

    expect(reads.reject { |_, p| p.empty? }).to eq({})
  end
end
