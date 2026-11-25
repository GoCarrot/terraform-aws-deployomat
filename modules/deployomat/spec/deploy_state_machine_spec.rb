# frozen_string_literal: true

require 'json'
require 'rspec'
require_relative 'support/state_machine_graph'

# Structure checks on deploy.json: every ending carries the Reported of the step that decided it,
# or goes through Report after Rollback, and nothing names a path that a failed run may not have. Step Functions
# fails a run on a missing path with States.Runtime, which a States.ALL Catch doesn't catch.
RSpec.describe 'state_machines/deploy.json' do # rubocop:disable RSpec/DescribeClass
  include StateMachineGraph

  let(:machine) { 'deploy' }
  let(:report_endings) { %w[ReportedOutcome UnreportedOutcome FailReported Fail] }

  it 'ends only after Report' do
    ends = states.select { |_, s| s['End'] || %w[Fail Succeed].include?(s['Type']) }.keys

    expect(ends).to match_array(report_endings)
    report_endings.each do |name|
      sources = states.select { |_, s| targets(s).include?(name) }.keys
      expect(sources - %w[ReportBranch Reported Unreported]).to be_empty, "#{name} is reached from #{sources}"
    end
  end

  it 'runs Report only where no Lambda decided the ending: after Rollback, or a cancel lost the lock' do
    into_report = states.select { |_, s| targets(s).include?('Report') }.keys
    expect(into_report).to match_array(%w[RolledBack SupersededDuringCancel])
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

  # Each cancelled ending takes its Error from the step whose Reported it copies, so the reason is the
  # step's own, not a wording written into the state machine.
  it 'takes the Error for every CancelledAt* ending from the step that decided it, with no literal' do
    cancelled = states.keys.grep(/\ACancelledAt/)
    expect(cancelled).to match_array(%w[CancelledAtCheckHealthy CancelledAtRollout CancelledAtCoalesce CancelledAtBake])

    cancelled.each do |name|
      parameters = states[name]['Parameters']
      expect(parameters).not_to have_key('Error')
      expect(parameters['Error.$']).to eq(parameters['Reported.$'].sub(/Reported\z/, 'Error')), name
    end
  end

  # The cancel of a concurrent deploy can lose the deploy lock to another run's cancel. The loser is
  # superseded: aborted through Report, not failed, and not back to Start to fight the winner.
  it 'ends a deploy whose cancel lost the lock as aborted, not failed, and does not retry Start' do
    expect(states['CancelConcurrentDeploy']['ResultPath']).to eq('$.Cancel')
    expect(states['CancelConcurrentDeploy']['Catch']).to be_nil
    rule = states['CancelBranch']['Choices'].first
    expect(rule['And'].last).to eq('Variable' => '$.Cancel.Output.Status', 'StringEquals' => 'deploy_aborted')
    expect(rule['Next']).to eq('SupersededDuringCancel')
    expect(states['CancelBranch']['Default']).to eq('StartDeploy')
    expect(states['SupersededDuringCancel']['Parameters']).to include('Status' => 'deploy_aborted')
    expect(states['SupersededDuringCancel']['Next']).to eq('Report')
    expect(states['SupersededDuringCancel']['ResultPath']).to eq('$.Outcome')
  end
end
