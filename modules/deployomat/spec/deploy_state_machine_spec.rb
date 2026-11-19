# frozen_string_literal: true

require 'json'
require 'rspec'

# Structure checks on deploy.json: every ending carries the Reported of the step that decided it,
# or goes through Report after Rollback, and nothing names a path that a failed run may not have. Step Functions
# fails a run on a missing path with States.Runtime, which a States.ALL Catch doesn't catch.
RSpec.describe 'state_machines/deploy.json' do # rubocop:disable RSpec/DescribeClass
  let(:states) { JSON.parse(File.read(File.join(__dir__, '..', 'state_machines', 'deploy.json'))).fetch('States') }
  let(:report_endings) { %w[ReportedOutcome UnreportedOutcome FailReported Fail] }

  def targets(state)
    [state['Next'], state['Default'], *Array(state['Choices']).map { |c| c['Next'] },
     *Array(state['Catch']).map { |c| c['Next'] }].compact
  end

  def deciding_choices(name)
    states.select { |_, s| targets(s).include?(name) }.flat_map do |source, state|
      next [source] if state['Type'] == 'Choice'

      state.key?('ResultPath') && state['ResultPath'].nil? ? deciding_choices(source) : []
    end
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

  it 'ends only after Report' do
    ends = states.select { |_, s| s['End'] || %w[Fail Succeed].include?(s['Type']) }.keys

    expect(ends).to match_array(report_endings)
    report_endings.each do |name|
      sources = states.select { |_, s| targets(s).include?(name) }.keys
      expect(sources - %w[ReportBranch Reported Unreported]).to be_empty, "#{name} is reached from #{sources}"
    end
  end

  it 'runs Report only after Rollback, where no Lambda decided the ending' do
    expect(states.select { |_, s| targets(s).include?('Report') }.keys).to eq(['RolledBack'])
    expect(states['Report']['ResultPath']).to eq('$.Outcome')
  end

  # A Pass ending copies Reported from the step whose result the Choice before it read, walking
  # back over tasks that keep the state (ResultPath null), like RollbackFromCheckHealthy.
  it 'carries Reported into every other ending from the step that decided it' do
    into_branch = states.select { |_, s| targets(s).include?('ReportBranch') }

    expect(into_branch.keys).to match_array(
      %w[KnownStartError FailConcurrentDeploy UndeployInProgress KnownHealthError CancelledAtCheckHealthy
         CancelledAtRollout CancelledAtCoalesce CancelledAtBake FinishDeploy Report]
    )
    into_branch.each do |name, state|
      expect(state['ResultPath']).to eq('$.Outcome'), name
      next unless state['Type'] == 'Pass'

      deciders = deciding_choices(name)
      step_paths = deciders.flat_map { |c| states[c]['Choices'].map { |r| r['Variable'].sub(/\.[^.]+\z/, '') } }.uniq
      expect(step_paths.map { |p| "#{p}.Reported" }).to eq([state['Parameters']['Reported.$']]), name
    end
  end

  it 'hands every step that reports the deploy run, and Start\'s Ami and SkipNotifications' do
    expected = { 'ExecutionArn.$' => '$$.Execution.Id', 'Ami.$' => '$.StartDeploy.Ami',
                 'SkipNotifications.$' => '$.StartDeploy.SkipNotifications' }

    %w[CheckHealthy Rollout BakeDeploy].each do |name|
      expect(states[name]['Parameters']['Input']).to include(expected), name
    end
    %w[Coalesce FinishDeploy].each { |name| expect(states[name]['Parameters']).to include(expected), name }
    expect(states['StartDeploy']['Parameters']).to include('ExecutionArn.$' => '$$.Execution.Id')
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
